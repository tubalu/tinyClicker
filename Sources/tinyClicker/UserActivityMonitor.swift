import AppKit
import CoreGraphics
import Foundation

/// Singleton CGEventTap that records the timestamp of the most recent
/// USER-initiated mouse motion. Events posted by tinyClicker itself are
/// filtered out via a source-data marker (see `sourceMarker`), so a macro
/// teleporting the cursor does NOT register as user activity.
///
/// Used by `Player` and the special-clicker driver in `Scheduler` to back
/// off while the user is touching the mouse.
final class UserActivityMonitor {
    static let shared = UserActivityMonitor()

    /// Stamped on `CGEventSource.userData` for every event tinyClicker posts.
    /// The tap callback uses this to skip our own events.
    static let sourceMarker: Int64 = 0x744B43 // 'tKC' (ASCII)

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()
    private var lastUserActivity: TimeInterval = 0

    private init() {}

    /// Idempotent. Returns true if the tap is running. If Accessibility has
    /// not been granted, `CGEvent.tapCreate` returns nil and we return false;
    /// callers should tolerate this (we'll just never report activity).
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<UserActivityMonitor>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port = monitor.tap { CGEvent.tapEnable(tap: port, enable: true) }
                return Unmanaged.passUnretained(event)
            }

            let ud = event.getIntegerValueField(.eventSourceUserData)
            if ud == UserActivityMonitor.sourceMarker {
                return Unmanaged.passUnretained(event)
            }

            monitor.markActivity()
            return Unmanaged.passUnretained(event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        self.tap = port
        self.runLoopSource = source
        return true
    }

    private func markActivity() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        lastUserActivity = now
        lock.unlock()
    }

    /// Returns true if a user-initiated mouse motion occurred within the
    /// last `seconds`.
    func isUserActive(within seconds: Double) -> Bool {
        lock.lock()
        let last = lastUserActivity
        lock.unlock()
        guard last > 0 else { return false }
        return (CFAbsoluteTimeGetCurrent() - last) < seconds
    }
}
