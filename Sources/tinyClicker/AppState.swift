import Combine
import CoreGraphics
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var selectedId: UUID?
    @Published var isRecording: Bool = false
    @Published var isPlayingAll: Bool = false
    @Published var nowPlayingId: UUID?
    /// When each waiting recording will next fire. These are *deadlines*, not
    /// countdowns — a value changes only once per cycle, so publishing it
    /// costs one re-render per interval. The per-second ticking happens
    /// locally in the row's `TimelineView`.
    @Published var nextFireAt: [UUID: Date] = [:]
    /// Events lifted by "Copy Events", awaiting a paste. Session-only —
    /// published so paste controls can enable themselves and show the source.
    @Published var eventClipboard: EventClipboard?
    @Published var specialClicker: SpecialClicker = .init()
    @Published var pauseOnMouseMove: Bool = true {
        didSet {
            UserDefaults.standard.set(pauseOnMouseMove, forKey: "tinyClicker.pauseOnMouseMove")
        }
    }
    @Published var pauseOnOwnWindow: Bool = true {
        didSet {
            UserDefaults.standard.set(pauseOnOwnWindow, forKey: "tinyClicker.pauseOnOwnWindow")
        }
    }
    /// When on, Play All remembers the cursor location at start; the Follow
    /// Cursor Clicker then clicks there instead of following the live cursor.
    /// Macro playback is unaffected either way. Opt-in (default off).
    @Published var lockCursorPosition: Bool = false {
        didSet {
            UserDefaults.standard.set(lockCursorPosition, forKey: "tinyClicker.lockCursorPosition")
        }
    }

    private let store = Store()
    private let recorder = Recorder()
    private let scheduler = PlaybackScheduler()
    private let hud = PlaybackHUD()
    private var playAllHotKey: HotKey?
    private var recordHotKey: HotKey?
    private var saveDebounce: AnyCancellable?
    private var specialDebounce: AnyCancellable?
    private var nowPlayingPoll: Task<Void, Never>?

    init() {
        self.recordings = store.load()
        self.selectedId = recordings.first?.id
        self.specialClicker = SpecialClicker.load()

        // Publish window-frame snapshots for the off-main-thread hover guard.
        // Started at launch (not at playback start) so the cache is always
        // warm before the first click can fire.
        WindowGuard.beginTracking()
        
        if UserDefaults.standard.object(forKey: "tinyClicker.pauseOnMouseMove") == nil {
            self.pauseOnMouseMove = true
        } else {
            self.pauseOnMouseMove = UserDefaults.standard.bool(forKey: "tinyClicker.pauseOnMouseMove")
        }
        
        if UserDefaults.standard.object(forKey: "tinyClicker.pauseOnOwnWindow") == nil {
            self.pauseOnOwnWindow = true
        } else {
            self.pauseOnOwnWindow = UserDefaults.standard.bool(forKey: "tinyClicker.pauseOnOwnWindow")
        }

        // Opt-in: absent key means off.
        self.lockCursorPosition = UserDefaults.standard.bool(forKey: "tinyClicker.lockCursorPosition")

        // Debounced persistence on any change.
        saveDebounce = $recordings
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [store] recordings in
                store.save(recordings)
            }

        // Persist + apply special clicker config on change.
        // The driver only actually runs while a Play All session is active;
        // toggling Enabled outside of Play All just arms it for the next one.
        specialDebounce = $specialClicker
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] config in
                config.save()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.isPlayingAll && config.enabled {
                        await self.scheduler.startSpecialClicker(config, pauseOnMouseMove: self.pauseOnMouseMove, pauseOnOwnWindow: self.pauseOnOwnWindow)
                    } else {
                        await self.scheduler.stopSpecialClicker()
                    }
                }
            }

        // Play All start/stop toggle (F10). Stopping works from anywhere,
        // so it still doubles as the panic key.
        let hotKey = HotKey()
        hotKey.onPress { [weak self] in
            Task { @MainActor [weak self] in self?.togglePlayAll() }
        }
        self.playAllHotKey = hotKey

        // Record start/stop toggle (F9) — avoids contaminating the recording
        // with the click that stopped it.
        let recordKey = HotKey(keyCode: UInt32(0x65)) // kVK_F9 = 0x65
        recordKey.onPress { [weak self] in
            Task { @MainActor [weak self] in self?.toggleRecording() }
        }
        self.recordHotKey = recordKey

        // Light polling for the "now playing" indicator in the UI.
        nowPlayingPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let status = await self.scheduler.status()
                // CFAbsoluteTime is seconds since the 2001 reference date.
                let due = status.nextFireAt.mapValues {
                    Date(timeIntervalSinceReferenceDate: $0)
                }
                await MainActor.run {
                    if self.nowPlayingId != status.runningId {
                        self.nowPlayingId = status.runningId
                    }
                    // Assign only on change: an unchanged deadline must not
                    // republish, or this 10 Hz poll becomes a re-render storm.
                    if self.nextFireAt != due { self.nextFireAt = due }
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
    }

    // MARK: - Recording CRUD

    func addRecording() {
        let new = Recording(name: "Recording \(recordings.count + 1)")
        recordings.append(new)
        selectedId = new.id
    }

    func deleteRecording(id: UUID) {
        guard recordings.first(where: { $0.id == id })?.locked != true else { return }
        recordings.removeAll { $0.id == id }
        if selectedId == id { selectedId = recordings.first?.id }
    }

    func move(from source: IndexSet, to destination: Int) {
        recordings.move(fromOffsets: source, toOffset: destination)
        // If playback was running, reorder changes priorities — restart.
        if isPlayingAll {
            Task { await scheduler.startAll(recordings, pauseOnMouseMove: pauseOnMouseMove, pauseOnOwnWindow: pauseOnOwnWindow) }
        }
    }

    func update(_ recording: Recording) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[idx] = recording
        if isPlayingAll {
            Task { await scheduler.startAll(recordings, pauseOnMouseMove: pauseOnMouseMove, pauseOnOwnWindow: pauseOnOwnWindow) }
        }
    }

    // MARK: - Event editing (copy / paste / clone / manual add)

    /// The one rule every event-editing command shares: never mutate a
    /// recording the recorder or scheduler is touching, and never a locked
    /// one. Mirrors `EventTable.isEditable` in the detail view.
    ///
    /// Because this already refuses while `isPlayingAll`, callers can write
    /// `recordings[idx]` directly instead of going through `update(_:)` —
    /// there is no live scheduler to restart, and the `@Published` change
    /// still triggers the debounced autosave.
    private func editableIndex(of id: UUID) -> Int? {
        guard !isRecording, !isPlayingAll,
              let idx = recordings.firstIndex(where: { $0.id == id }),
              !recordings[idx].locked else { return nil }
        return idx
    }

    var canEditEvents: Bool { !isRecording && !isPlayingAll }

    /// Lifts a whole recording's events into the clipboard. Always safe —
    /// reading never mutates, so locked recordings are copyable too.
    func copyEvents(from id: UUID) {
        guard let recording = recordings.first(where: { $0.id == id }),
              !recording.events.isEmpty else { return }
        eventClipboard = EventClipboard(sourceName: recording.name, events: recording.events)
    }

    func pasteEvents(into id: UUID, mode: PasteMode) {
        guard let clipboard = eventClipboard, let idx = editableIndex(of: id) else { return }
        switch mode {
        case .append:
            recordings[idx].events = EventEditing.appending(clipboard.events, to: recordings[idx].events)
        case .replace:
            recordings[idx].events = EventEditing.reidentified(clipboard.events)
        }
    }

    /// Clones a recording into the slot directly below the original.
    ///
    /// Position is priority in this app, so appending to the bottom would
    /// silently hand the clone the lowest priority. Locked recordings *can*
    /// be duplicated — the source is only read.
    func duplicateRecording(id: UUID) {
        guard !isRecording, !isPlayingAll,
              let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        let source = recordings[idx]
        let clone = Recording(
            name: "\(source.name) copy",
            events: EventEditing.reidentified(source.events),
            intervalSeconds: source.intervalSeconds,
            enabled: false,
            locked: false
        )
        recordings.insert(clone, at: idx + 1)
        selectedId = clone.id
    }

    /// Appends a hand-built action to the end of a recording.
    ///
    /// Coordinates are seeded from the last mouse event already in the macro,
    /// falling back to the live cursor location — anything beats dropping a
    /// click at (0, 0) and making the user type both numbers.
    func addActivity(_ template: ActivityTemplate, to id: UUID) {
        guard let idx = editableIndex(of: id) else { return }
        let existing = recordings[idx].events
        let start = (existing.last?.timestamp ?? 0) + EventEditing.joinGap
        let seed = existing.last(where: { $0.position != nil })?.position
            ?? CGEvent(source: nil)?.location
            ?? .zero
        recordings[idx].events += EventEditing.events(for: template, startingAt: start, at: seed)
    }

    // MARK: - Record

    var isSelectedRecordingLocked: Bool {
        guard let id = selectedId else { return false }
        return recordings.first(where: { $0.id == id })?.locked ?? false
    }

    func startRecording() {
        guard !isRecording else { return }
        guard let id = selectedId,
              let idx = recordings.firstIndex(where: { $0.id == id }),
              !recordings[idx].locked else { return }
        let started = recorder.start()
        if started {
            isRecording = true
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        let events = recorder.stop()
        isRecording = false
        guard let id = selectedId,
              let idx = recordings.firstIndex(where: { $0.id == id }),
              !recordings[idx].locked else { return }
        recordings[idx].events = events
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else if !isPlayingAll {
            startRecording()
        }
    }

    // MARK: - Playback

    func playAll() {
        guard !isPlayingAll else { return }
        let snapshot = recordings
        let specialSnapshot = specialClicker
        // Captured once, at start: where the pointer sits when Play All begins.
        // Same global-display coordinate space the scheduler warps into.
        let cursorAnchor = lockCursorPosition ? CGEvent(source: nil)?.location : nil
        isPlayingAll = true
        // Shrink to the floating Stop control; the main window drops to the Dock.
        // The HUD counts down the longest interval among the checked macros.
        hud.show(longestInterval: snapshot.longestPlayableInterval) { [weak self] in
            self?.stopAllPlayback()
        }
        Task {
            await scheduler.setCursorAnchor(cursorAnchor)
            await scheduler.startAll(snapshot, pauseOnMouseMove: pauseOnMouseMove, pauseOnOwnWindow: pauseOnOwnWindow)
            if specialSnapshot.enabled {
                await scheduler.startSpecialClicker(specialSnapshot, pauseOnMouseMove: pauseOnMouseMove, pauseOnOwnWindow: pauseOnOwnWindow)
            }
        }
    }

    func togglePlayAll() {
        if isPlayingAll {
            stopAllPlayback()
            return
        }
        guard !isRecording else { return }
        // Same condition that enables the toolbar's Play All button —
        // avoids entering a phantom "playing" state with nothing to run.
        let hasPlayable = recordings.contains { $0.enabled && !$0.events.isEmpty }
            || specialClicker.enabled
        guard hasPlayable else { return }
        playAll()
    }

    func stopAllPlayback() {
        isPlayingAll = false
        hud.hide()
        // Keep `specialClicker.enabled` as-is — it's persistent armed state,
        // so the next Play All session re-runs it without re-toggling.
        Task { await scheduler.panicStopAll() }
        nowPlayingId = nil
        nextFireAt = [:]
    }
}
