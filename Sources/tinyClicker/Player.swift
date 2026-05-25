import CoreGraphics
import Foundation

/// Shared event source carrying the `UserActivityMonitor.sourceMarker`
/// stamp so events tinyClicker posts can be distinguished from real user
/// input inside the activity tap.
enum InputSource {
    static let marked: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = UserActivityMonitor.sourceMarker
        return source
    }()
}

/// Represents a key or mouse-button that was pressed but not yet released.
/// Persisted across pause/resume so we can release-then-re-press.
struct HeldInput: Equatable {
    enum Kind: Equatable {
        case mouseButton(Int, CGPoint)
        case key(UInt16, UInt64)
    }
    let kind: Kind
}

enum PlaybackOutcome: Equatable {
    case completed
    case paused(at: Int, held: [HeldInput])
    case cancelled
}

/// Shared pause signal — flipped by the Scheduler when a preempting macro
/// becomes due. Player checks it between every event.
actor PauseSignal {
    private(set) var isPaused: Bool = false
    func pause() { isPaused = true }
    func resume() { isPaused = false }
}

final class Player {
    /// Plays `recording` starting at index `cursor`, optionally re-pressing
    /// inputs that were held when a previous play call was paused.
    ///
    /// The task is cancellable via standard `Task` cancellation.
    /// Pause is requested via `pauseSignal.pause()`.
    func play(
        _ recording: Recording,
        from cursor: Int = 0,
        restoring held: [HeldInput] = [],
        pauseSignal: PauseSignal
    ) async -> PlaybackOutcome {
        // Re-press any inputs that were released at pause time.
        for input in held {
            postHeldDown(input)
        }
        var currentlyHeld = held

        let events = recording.events
        guard cursor < events.count else { return .completed }
        let runStartWall = CFAbsoluteTimeGetCurrent()
        let baseTimestamp = events[cursor].timestamp

        var i = cursor
        while i < events.count {
            if Task.isCancelled {
                releaseAll(currentlyHeld)
                return .cancelled
            }
            if await pauseSignal.isPaused {
                releaseAll(currentlyHeld)
                return .paused(at: i, held: currentlyHeld)
            }
            if UserActivityMonitor.shared.isUserActive(within: 0.5) {
                releaseAll(currentlyHeld)
                return .paused(at: i, held: currentlyHeld)
            }
            if await WindowGuard.cursorIsInOwnWindow() {
                releaseAll(currentlyHeld)
                return .paused(at: i, held: currentlyHeld)
            }

            let event = events[i]
            let targetWall = runStartWall + (event.timestamp - baseTimestamp)
            let now = CFAbsoluteTimeGetCurrent()
            let sleepFor = targetWall - now
            if sleepFor > 0 {
                // Sleep in short slices so pause/cancel are responsive.
                let deadline = now + sleepFor
                while CFAbsoluteTimeGetCurrent() < deadline {
                    if Task.isCancelled {
                        releaseAll(currentlyHeld)
                        return .cancelled
                    }
                    if await pauseSignal.isPaused {
                        releaseAll(currentlyHeld)
                        return .paused(at: i, held: currentlyHeld)
                    }
                    if UserActivityMonitor.shared.isUserActive(within: 0.5) {
                        releaseAll(currentlyHeld)
                        return .paused(at: i, held: currentlyHeld)
                    }
                    if await WindowGuard.cursorIsInOwnWindow() {
                        releaseAll(currentlyHeld)
                        return .paused(at: i, held: currentlyHeld)
                    }
                    let remaining = deadline - CFAbsoluteTimeGetCurrent()
                    let slice = min(remaining, 0.02) // 20ms slices
                    if slice > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
                    }
                }
            }

            postEvent(event)
            updateHeld(&currentlyHeld, after: event)
            i += 1
        }
        return .completed
    }

    // MARK: - Event posting

    private func postEvent(_ event: RecordedEvent) {
        switch event.kind {
        case .mouseDown, .mouseUp:
            postMouse(event)
        case .keyDown, .keyUp:
            postKey(event)
        }
    }

    private func postMouse(_ event: RecordedEvent) {
        guard let pos = event.position, let buttonIdx = event.button else { return }
        let button = CGMouseButton(rawValue: UInt32(buttonIdx)) ?? .left
        let mouseType: CGEventType
        switch (event.kind, button) {
        case (.mouseDown, .left): mouseType = .leftMouseDown
        case (.mouseUp,   .left): mouseType = .leftMouseUp
        case (.mouseDown, .right): mouseType = .rightMouseDown
        case (.mouseUp,   .right): mouseType = .rightMouseUp
        case (.mouseDown, _): mouseType = .otherMouseDown
        case (.mouseUp,   _): mouseType = .otherMouseUp
        default: return
        }
        guard let cg = CGEvent(
            mouseEventSource: InputSource.marked,
            mouseType: mouseType,
            mouseCursorPosition: pos,
            mouseButton: button
        ) else { return }
        if let flags = event.flags {
            cg.flags = CGEventFlags(rawValue: flags)
        }
        cg.post(tap: .cghidEventTap)
    }

    private func postKey(_ event: RecordedEvent) {
        guard let keyCode = event.keyCode else { return }
        let isDown = event.kind == .keyDown
        guard let cg = CGEvent(
            keyboardEventSource: InputSource.marked,
            virtualKey: keyCode,
            keyDown: isDown
        ) else { return }
        if let flags = event.flags {
            cg.flags = CGEventFlags(rawValue: flags)
        }
        cg.post(tap: .cghidEventTap)
    }

    private func postHeldDown(_ held: HeldInput) {
        switch held.kind {
        case .mouseButton(let idx, let pos):
            let event = RecordedEvent(
                kind: .mouseDown, timestamp: 0,
                position: pos, button: idx
            )
            postMouse(event)
        case .key(let code, let flags):
            let event = RecordedEvent(
                kind: .keyDown, timestamp: 0,
                keyCode: code, flags: flags
            )
            postKey(event)
        }
    }

    private func postHeldUp(_ held: HeldInput) {
        switch held.kind {
        case .mouseButton(let idx, let pos):
            let event = RecordedEvent(
                kind: .mouseUp, timestamp: 0,
                position: pos, button: idx
            )
            postMouse(event)
        case .key(let code, let flags):
            let event = RecordedEvent(
                kind: .keyUp, timestamp: 0,
                keyCode: code, flags: flags
            )
            postKey(event)
        }
    }

    private func releaseAll(_ held: [HeldInput]) {
        for input in held {
            postHeldUp(input)
        }
    }

    private func updateHeld(_ held: inout [HeldInput], after event: RecordedEvent) {
        switch event.kind {
        case .mouseDown:
            if let pos = event.position, let idx = event.button {
                held.append(HeldInput(kind: .mouseButton(idx, pos)))
            }
        case .mouseUp:
            if let idx = event.button {
                held.removeAll { input in
                    if case .mouseButton(let i, _) = input.kind { return i == idx }
                    return false
                }
            }
        case .keyDown:
            if let code = event.keyCode {
                held.append(HeldInput(kind: .key(code, event.flags ?? 0)))
            }
        case .keyUp:
            if let code = event.keyCode {
                held.removeAll { input in
                    if case .key(let c, _) = input.kind { return c == code }
                    return false
                }
            }
        }
    }
}
