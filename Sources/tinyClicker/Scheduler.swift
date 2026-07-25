import AppKit
import CoreGraphics
import Foundation

/// Coordinates concurrent macro playback with priority-based preemption.
///
/// Priority is the recording's index in the user's list — lower index = higher
/// priority. When a higher-priority recording wants to play while a lower one
/// is already running, the lower one pauses (releasing held inputs), the
/// higher one runs to completion, then the lower one resumes from the same
/// event cursor.
/// Snapshot of what the scheduler is doing, for the UI's status poll.
struct PlaybackStatus: Sendable {
    let runningId: UUID?
    /// Next start time per recording, as `CFAbsoluteTime`. Only contains
    /// recordings currently sleeping out their interval.
    let nextFireAt: [UUID: Double]
}

actor PlaybackScheduler {
    private struct Waiter {
        let priority: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let player = Player()
    private var runningPriority: Int? = nil
    private var runningId: UUID? = nil
    private var pauseSignal: PauseSignal? = nil
    private var waiters: [Waiter] = []
    private var drivers: [UUID: Task<Void, Never>] = [:]
    private var specialTask: Task<Void, Never>? = nil
    private(set) var specialActive: Bool = false
    private var pauseOnMouseMove: Bool = true
    private var pauseOnOwnWindow: Bool = true
    /// When non-nil, the cursor is warped back to this point after each macro
    /// finishes a pass (the "Lock Cursor Position" feature). Set once at Play
    /// All start and cleared on stop; deliberately untouched by `startAll`'s
    /// mid-session restarts so a reorder/edit keeps the original anchor.
    private var cursorAnchor: CGPoint? = nil
    /// Wall clock (`CFAbsoluteTime`) at which each waiting recording will next
    /// start playing. An entry exists only while that recording is sleeping
    /// out its interval — it's removed while the recording actually runs.
    private var nextFireAt: [UUID: Double] = [:]
    /// Bumped every time the driver set is torn down. A driver only writes
    /// `nextFireAt` while its epoch is current, so a cancelled task that
    /// wakes up late can't resurrect a countdown for a stopped recording.
    private var epoch: UInt64 = 0
    private static let specialSentinelId = UUID()

    /// Returns the id of the recording currently executing, if any.
    ///
    /// The special clicker's sentinel is deliberately NOT reported: it takes
    /// and releases the slot on every click (up to 20×/sec), and since the
    /// sentinel matches no recording it would only churn `AppState`'s
    /// `@Published nowPlayingId` — re-rendering every view for no visible
    /// change. Real macro playback holds the slot for its whole run.
    func currentlyRunningId() -> UUID? {
        runningId == Self.specialSentinelId ? nil : runningId
    }

    /// Everything the UI polls for, fetched in a single actor hop.
    func status() -> PlaybackStatus {
        PlaybackStatus(runningId: currentlyRunningId(), nextFireAt: nextFireAt)
    }

    /// Returns true if any driver is active (whether running or waiting).
    func hasActiveDrivers() -> Bool { !drivers.isEmpty }

    /// Sets (or clears) the cursor-lock anchor. Pass `nil` to disable. Called
    /// by `AppState.playAll` with the pointer's location at Play All start.
    func setCursorAnchor(_ anchor: CGPoint?) {
        cursorAnchor = anchor
    }

    /// Starts driving every enabled recording in the given order.
    /// The first recording in the array is highest priority.
    /// Stops any previously running drivers first.
    func startAll(_ recordings: [Recording], pauseOnMouseMove: Bool, pauseOnOwnWindow: Bool) {
        self.pauseOnMouseMove = pauseOnMouseMove
        self.pauseOnOwnWindow = pauseOnOwnWindow
        stopAllInternal()
        let currentEpoch = epoch
        for (index, recording) in recordings.enumerated() where recording.enabled {
            let driver = Task { [weak self] in
                guard let self else { return }
                await self.driveRecording(recording, priority: index, epoch: currentEpoch)
            }
            drivers[recording.id] = driver
        }
        // Started only if something will actually play, so a no-op start
        // never installs a tap that nothing will stop.
        if drivers.isEmpty {
            stopMonitorIfIdle()
        } else {
            UserActivityMonitor.shared.start()
        }
    }

    /// Cancels every macro driver and any in-flight macro playback.
    /// Does NOT touch the special clicker. Idempotent.
    func stopAll() {
        cursorAnchor = nil
        stopAllInternal()
        stopMonitorIfIdle()
    }

    /// Balances the `UserActivityMonitor.shared.start()` calls in `startAll`
    /// and `startSpecialClicker`. The tap listens for `mouseMoved` — the
    /// highest-frequency event on macOS — so leaving it installed while the
    /// app is idle taxes every mouse movement for the rest of the process's
    /// life. Only safe once `drivers` / `specialTask` have been cleared,
    /// which is why this is called from the public stop entry points and NOT
    /// from `stopAllInternal()` (which `startAll` also runs before
    /// immediately restarting).
    private func stopMonitorIfIdle() {
        guard drivers.isEmpty, specialTask == nil else { return }
        UserActivityMonitor.shared.stop()
    }

    /// Starts (or restarts with new config) the follow-cursor auto-clicker.
    /// Lowest priority — yields to any macro that wants the slot.
    func startSpecialClicker(_ config: SpecialClicker, pauseOnMouseMove: Bool, pauseOnOwnWindow: Bool) {
        self.pauseOnMouseMove = pauseOnMouseMove
        self.pauseOnOwnWindow = pauseOnOwnWindow
        specialTask?.cancel()
        guard config.enabled else {
            // Must clear the handle, not just cancel it: `stopMonitorIfIdle`
            // treats a non-nil `specialTask` as "still running" and would
            // never tear the tap down again.
            specialTask = nil
            specialActive = false
            stopMonitorIfIdle()
            return
        }
        // Started only once we know we'll actually click, so a disabled
        // config never installs a tap that nothing will stop.
        UserActivityMonitor.shared.start()
        specialActive = true
        let interval = config.intervalSeconds
        let buttonIdx = config.button.mouseButtonIndex
        // Captured once rather than re-read from the actor every iteration:
        // these only change via start*(), which restarts this task anyway.
        let pMove = pauseOnMouseMove
        let pWindow = pauseOnOwnWindow
        specialTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // Skip the click if the user is actively moving the mouse,
                // or if the cursor is hovering over any tinyClicker window
                // (otherwise we'd click our own Stop All button etc.).
                let userActive = pMove && UserActivityMonitor.shared.isUserActive(within: 0.5)
                let onOwnWindow = pWindow ? WindowGuard.cursorIsInOwnWindow() : false
                if !userActive && !onOwnWindow {
                    _ = await self.acquire(priority: Int.max, recordingId: Self.specialSentinelId)
                    if Task.isCancelled { await self.release(); return }
                    await Self.postClickAtCursor(buttonIdx: buttonIdx)
                    await self.release()
                }
                let nanos = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    /// Stops the follow-cursor auto-clicker. Idempotent.
    func stopSpecialClicker() {
        specialTask?.cancel()
        specialTask = nil
        specialActive = false
        stopMonitorIfIdle()
    }

    /// Stops everything — macros AND special clicker. Used by the F10 panic key.
    func panicStopAll() {
        cursorAnchor = nil
        stopSpecialClicker()
        stopAllInternal()
        stopMonitorIfIdle()
    }

    private static func postClickAtCursor(buttonIdx: Int) async {
        let pos = CGEvent(source: nil)?.location ?? .zero
        let button: CGMouseButton = buttonIdx == 1 ? .right : .left
        let downType: CGEventType = buttonIdx == 1 ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = buttonIdx == 1 ? .rightMouseUp : .leftMouseUp
        if let down = CGEvent(
            mouseEventSource: InputSource.marked,
            mouseType: downType,
            mouseCursorPosition: pos,
            mouseButton: button
        ) {
            down.post(tap: .cghidEventTap)
        }
        // Sleep for a short duration (25ms) to ensure the target UI registers the click.
        try? await Task.sleep(nanoseconds: 25_000_000)
        if let up = CGEvent(
            mouseEventSource: InputSource.marked,
            mouseType: upType,
            mouseCursorPosition: pos,
            mouseButton: button
        ) {
            up.post(tap: .cghidEventTap)
        }
    }

    private func stopAllInternal() {
        for (_, task) in drivers {
            task.cancel()
        }
        drivers.removeAll()
        nextFireAt.removeAll()
        epoch &+= 1
        // Wake any waiters so they observe Task.isCancelled and exit.
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume()
        }
        // Signal the running playback (if any) to stop.
        // The driver task is already cancelled; Player checks Task.isCancelled.
        Task { [pauseSignal] in
            await pauseSignal?.pause()
        }
    }

    // MARK: - Driver loop (one per enabled recording)

    /// Records (or clears) a recording's next start time, ignoring writes from
    /// drivers that have since been torn down.
    private func setNextFire(_ time: Double?, for id: UUID, epoch: UInt64) {
        guard epoch == self.epoch else { return }
        nextFireAt[id] = time
    }

    private func driveRecording(_ recording: Recording, priority: Int, epoch: UInt64) async {
        var cursor = 0
        var held: [HeldInput] = []
        while !Task.isCancelled {
            let signal = await acquire(priority: priority, recordingId: recording.id)
            if Task.isCancelled {
                setNextFire(nil, for: recording.id, epoch: epoch)
                await release()
                return
            }
            // Holding the slot now — no longer counting down.
            setNextFire(nil, for: recording.id, epoch: epoch)
            let outcome = await player.play(
                recording,
                from: cursor,
                restoring: held,
                pauseSignal: signal,
                pauseOnMouseMove: self.pauseOnMouseMove,
                pauseOnOwnWindow: self.pauseOnOwnWindow
            )
            await release()

            switch outcome {
            case .completed:
                cursor = 0
                held = []
                // Lock Cursor Position: return the pointer to the anchor now
                // that this macro's pass is done, before it sleeps its
                // interval. Warp posts no mouseMoved event, so it won't trip
                // the user-activity pause.
                if let anchor = cursorAnchor {
                    CGWarpMouseCursorPosition(anchor)
                }
                // Sleep the configured interval before next iteration.
                let interval = max(0, recording.intervalSeconds)
                let nanos = UInt64(interval * 1_000_000_000)
                if nanos > 0 {
                    // Published so the UI can count down to the next run.
                    let due = CFAbsoluteTimeGetCurrent() + interval
                    setNextFire(due, for: recording.id, epoch: epoch)
                    try? await Task.sleep(nanoseconds: nanos)
                    setNextFire(nil, for: recording.id, epoch: epoch)
                }
            case .paused(let at, let h):
                cursor = at
                held = h
                // Brief sleep before retrying so user-activity pauses don't
                // spin tight when the user keeps wiggling the mouse.
                try? await Task.sleep(nanoseconds: 50_000_000)
            case .cancelled:
                setNextFire(nil, for: recording.id, epoch: epoch)
                return
            }
        }
    }

    // MARK: - Slot acquisition

    private func acquire(priority: Int, recordingId: UUID) async -> PauseSignal {
        // Block until we can take the slot at this priority.
        while true {
            if Task.isCancelled {
                // Caller will check and exit; return a dummy signal.
                let dummy = PauseSignal()
                await dummy.pause()
                return dummy
            }
            if runningPriority == nil {
                runningPriority = priority
                runningId = recordingId
                let signal = PauseSignal()
                pauseSignal = signal
                return signal
            }
            if let current = runningPriority, priority < current {
                // We're higher priority — request preemption then wait
                // for the current playback to release the slot.
                await pauseSignal?.pause()
            }
            await waitForSlot(at: priority)
        }
    }

    private func waitForSlot(at priority: Int) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(Waiter(priority: priority, continuation: cont))
        }
    }

    private func release() async {
        runningPriority = nil
        runningId = nil
        pauseSignal = nil
        // Wake the highest-priority waiter (lowest priority value).
        guard !waiters.isEmpty else { return }
        var bestIdx = 0
        for i in 1..<waiters.count where waiters[i].priority < waiters[bestIdx].priority {
            bestIdx = i
        }
        let waiter = waiters.remove(at: bestIdx)
        waiter.continuation.resume()
    }
}
