import CoreGraphics
import Foundation

/// Captures global mouse / keyboard events into an in-memory buffer.
/// Lifetime is tied to a single recording session: `start()` then `stop()`.
final class Recorder {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var startTime: TimeInterval = 0
    private let lock = NSLock()
    private var buffer: [RecordedEvent] = []

    var isRecording: Bool { tap != nil }

    /// Starts a tap. Returns false if Accessibility permission is missing or
    /// the tap could not be created.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, cgEvent, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(cgEvent) }
            let recorder = Unmanaged<Recorder>.fromOpaque(refcon).takeUnretainedValue()
            recorder.handle(type: type, event: cgEvent)
            return Unmanaged.passUnretained(cgEvent)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        startTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()

        self.tap = port
        self.runLoopSource = source
        return true
    }

    /// Stops the tap and returns the captured events (sorted by timestamp).
    func stop() -> [RecordedEvent] {
        guard let port = tap else { return [] }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil

        lock.lock()
        let copy = buffer
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        return copy
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // Re-enable the tap if the system disabled it (e.g., due to timeout).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let t = now - startTime

        let kind: RecordedEventKind
        var position: CGPoint? = nil
        var button: Int? = nil
        var keyCode: UInt16? = nil
        let flags: UInt64 = event.flags.rawValue

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            kind = .mouseDown
            position = event.location
            button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            kind = .mouseUp
            position = event.location
            button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        case .keyDown:
            // macOS emits synthetic auto-repeat keyDowns while a key is held.
            // Skip them so a hold becomes a single keyDown … keyUp pair; the
            // gap between them preserves the hold duration on playback.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            kind = .keyDown
            keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        case .keyUp:
            kind = .keyUp
            keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        default:
            return
        }

        let recorded = RecordedEvent(
            kind: kind,
            timestamp: t,
            position: position,
            button: button,
            keyCode: keyCode,
            flags: flags
        )

        lock.lock()
        buffer.append(recorded)
        lock.unlock()
    }
}
