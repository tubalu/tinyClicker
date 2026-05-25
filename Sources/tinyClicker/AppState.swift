import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var selectedId: UUID?
    @Published var isRecording: Bool = false
    @Published var isPlayingAll: Bool = false
    @Published var nowPlayingId: UUID?
    @Published var specialClicker: SpecialClicker = .init()

    private let store = Store()
    private let recorder = Recorder()
    private let scheduler = PlaybackScheduler()
    private var stopHotKey: HotKey?
    private var recordHotKey: HotKey?
    private var saveDebounce: AnyCancellable?
    private var specialDebounce: AnyCancellable?
    private var nowPlayingPoll: Task<Void, Never>?

    init() {
        self.recordings = store.load()
        self.selectedId = recordings.first?.id
        self.specialClicker = SpecialClicker.load()

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
                        await self.scheduler.startSpecialClicker(config)
                    } else {
                        await self.scheduler.stopSpecialClicker()
                    }
                }
            }

        // Panic stop hotkey (F10).
        let hotKey = HotKey()
        hotKey.onPress { [weak self] in
            Task { @MainActor in self?.stopAllPlayback() }
        }
        self.stopHotKey = hotKey

        // Record start/stop toggle (F9) — avoids contaminating the recording
        // with the click that stopped it.
        let recordKey = HotKey(keyCode: UInt32(0x65)) // kVK_F9 = 0x65
        recordKey.onPress { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }
        self.recordHotKey = recordKey

        // Light polling for the "now playing" indicator in the UI.
        nowPlayingPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let id = await self.scheduler.currentlyRunningId()
                await MainActor.run {
                    if self.nowPlayingId != id { self.nowPlayingId = id }
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
        recordings.removeAll { $0.id == id }
        if selectedId == id { selectedId = recordings.first?.id }
    }

    func move(from source: IndexSet, to destination: Int) {
        recordings.move(fromOffsets: source, toOffset: destination)
        // If playback was running, reorder changes priorities — restart.
        if isPlayingAll {
            Task { await scheduler.startAll(recordings) }
        }
    }

    func update(_ recording: Recording) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[idx] = recording
        if isPlayingAll {
            Task { await scheduler.startAll(recordings) }
        }
    }

    // MARK: - Record

    func startRecording() {
        guard !isRecording else { return }
        guard let id = selectedId,
              recordings.firstIndex(where: { $0.id == id }) != nil else { return }
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
              let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
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
        isPlayingAll = true
        Task {
            await scheduler.startAll(snapshot)
            if specialSnapshot.enabled {
                await scheduler.startSpecialClicker(specialSnapshot)
            }
        }
    }

    func stopAllPlayback() {
        isPlayingAll = false
        // Keep `specialClicker.enabled` as-is — it's persistent armed state,
        // so the next Play All session re-runs it without re-toggling.
        Task { await scheduler.panicStopAll() }
        nowPlayingId = nil
    }
}
