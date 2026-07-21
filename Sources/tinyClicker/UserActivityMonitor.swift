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
///
/// The tap listens for `mouseMoved` — by far the highest-frequency event on
/// macOS (hundreds to 1000+/sec while the mouse moves). Two properties keep
/// that from taxing the UI:
///
/// 1. The run-loop source lives on a **dedicated thread**, never the main
///    run loop, so event delivery cannot compete with SwiftUI rendering.
/// 2. `stop()` fully removes the tap, so an idle app pays nothing. `start()`
///    and `stop()` are balanced by `PlaybackScheduler`.
final class UserActivityMonitor {
    static let shared = UserActivityMonitor()

    /// Stamped on `CGEventSource.userData` for every event tinyClicker posts.
    /// The tap callback uses this to skip our own events.
    static let sourceMarker: Int64 = 0x744B43 // 'tKC' (ASCII)

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Guards tap lifetime (`tap` / `runLoopSource` / the monitor thread).
    /// Kept separate from `lock` so the per-event hot path never contends
    /// with start/stop.
    private let lifecycleLock = NSLock()

    /// Guards `lastUserActivity` only — taken on every tapped event.
    private let lock = NSLock()
    private var lastUserActivity: TimeInterval = 0

    /// Long-lived thread hosting the tap's run loop. Created on first
    /// `start()` and parked for the process lifetime; an idle run loop
    /// costs no CPU, and reusing it keeps `start()` cheap on later calls.
    private var monitorThread: Thread?
    private var monitorRunLoop: CFRunLoop?

    private init() {}

    /// Idempotent. Returns true if the tap is running. If Accessibility has
    /// not been granted, `CGEvent.tapCreate` returns nil and we return false;
    /// callers should tolerate this (we'll just never report activity).
    @discardableResult
    func start() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        if tap != nil { return true }
        guard let runLoop = ensureMonitorRunLoopLocked() else { return false }

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
                monitor.reenableAfterSystemDisable()
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
        // CFRunLoopAddSource is thread-safe; the source is serviced by the
        // dedicated monitor thread, not by whoever called start().
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopWakeUp(runLoop)

        self.tap = port
        self.runLoopSource = source
        return true
    }

    /// Removes the tap so an idle app pays nothing for mouse movement.
    /// Idempotent, and safe to call from any thread. Mirrors `Recorder.stop()`.
    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source = runLoopSource, let runLoop = monitorRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopWakeUp(runLoop)
        }
        CFMachPortInvalidate(port)
        tap = nil
        runLoopSource = nil
    }

    /// Spins up the monitor thread on first use and returns its run loop.
    /// Caller must hold `lifecycleLock`.
    private func ensureMonitorRunLoopLocked() -> CFRunLoop? {
        if let existing = monitorRunLoop { return existing }

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let runLoop = RunLoop.current
            // A run loop with no sources exits immediately; this port keeps
            // the thread parked so the tap source can come and go freely.
            runLoop.add(NSMachPort(), forMode: .common)
            self?.monitorRunLoop = CFRunLoopGetCurrent()
            ready.signal()
            while !Thread.current.isCancelled {
                runLoop.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "com.tinyClicker.activity-monitor"
        thread.qualityOfService = .userInitiated
        thread.start()

        // One-time, sub-millisecond wait on first start() only — never in a
        // hot path. Later start() calls reuse the parked thread.
        _ = ready.wait(timeout: .now() + 2.0)
        monitorThread = thread
        return monitorRunLoop
    }

    /// macOS disables a tap whose callback misses its deadline. Re-enable it,
    /// but only if `stop()` hasn't torn it down in the meantime.
    ///
    /// Runs on the monitor thread. Uses `try()` rather than blocking: if the
    /// lock is held, a start/stop is already in flight and owns the tap's
    /// fate — re-enabling here would either be redundant or race a teardown.
    private func reenableAfterSystemDisable() {
        guard lifecycleLock.try() else { return }
        let port = tap
        lifecycleLock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
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
