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
    private static let specialSentinelId = UUID()

    /// Returns the id of the recording currently executing, if any.
    func currentlyRunningId() -> UUID? { runningId }

    /// Returns true if any driver is active (whether running or waiting).
    func hasActiveDrivers() -> Bool { !drivers.isEmpty }

    /// Starts driving every enabled recording in the given order.
    /// The first recording in the array is highest priority.
    /// Stops any previously running drivers first.
    func startAll(_ recordings: [Recording], pauseOnMouseMove: Bool, pauseOnOwnWindow: Bool) {
        self.pauseOnMouseMove = pauseOnMouseMove
        self.pauseOnOwnWindow = pauseOnOwnWindow
        UserActivityMonitor.shared.start()
        stopAllInternal()
        for (index, recording) in recordings.enumerated() where recording.enabled {
            let driver = Task { [weak self] in
                guard let self else { return }
                await self.driveRecording(recording, priority: index)
            }
            drivers[recording.id] = driver
        }
    }

    /// Cancels every macro driver and any in-flight macro playback.
    /// Does NOT touch the special clicker. Idempotent.
    func stopAll() {
        stopAllInternal()
    }

    /// Starts (or restarts with new config) the follow-cursor auto-clicker.
    /// Lowest priority — yields to any macro that wants the slot.
    func startSpecialClicker(_ config: SpecialClicker, pauseOnMouseMove: Bool, pauseOnOwnWindow: Bool) {
        self.pauseOnMouseMove = pauseOnMouseMove
        self.pauseOnOwnWindow = pauseOnOwnWindow
        UserActivityMonitor.shared.start()
        specialTask?.cancel()
        guard config.enabled else {
            specialActive = false
            return
        }
        specialActive = true
        let interval = config.intervalSeconds
        let buttonIdx = config.button.mouseButtonIndex
        specialTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // Skip the click if the user is actively moving the mouse,
                // or if the cursor is hovering over any tinyClicker window
                // (otherwise we'd click our own Stop All button etc.).
                let pMove = await self.pauseOnMouseMove
                let pWindow = await self.pauseOnOwnWindow
                let userActive = pMove && UserActivityMonitor.shared.isUserActive(within: 0.5)
                let onOwnWindow = pWindow ? await WindowGuard.cursorIsInOwnWindow() : false
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
    }

    /// Stops everything — macros AND special clicker. Used by the F10 panic key.
    func panicStopAll() {
        stopSpecialClicker()
        stopAllInternal()
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

    private func driveRecording(_ recording: Recording, priority: Int) async {
        var cursor = 0
        var held: [HeldInput] = []
        while !Task.isCancelled {
            let signal = await acquire(priority: priority, recordingId: recording.id)
            if Task.isCancelled {
                await release()
                return
            }
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
                // Sleep the configured interval before next iteration.
                let nanos = UInt64(max(0, recording.intervalSeconds) * 1_000_000_000)
                if nanos > 0 {
                    try? await Task.sleep(nanoseconds: nanos)
                }
            case .paused(let at, let h):
                cursor = at
                held = h
                // Brief sleep before retrying so user-activity pauses don't
                // spin tight when the user keeps wiggling the mouse.
                try? await Task.sleep(nanoseconds: 50_000_000)
            case .cancelled:
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
