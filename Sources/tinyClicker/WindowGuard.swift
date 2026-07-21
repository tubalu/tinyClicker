import AppKit
import CoreGraphics
import Foundation

/// Checks whether the live cursor position falls inside any of tinyClicker's
/// own visible windows. Used by playback to pause itself whenever the user's
/// (or the system's) cursor is over our UI — both to avoid clicking our own
/// Stop All button and to let the user interact with the app without playback
/// stomping over them.
///
/// The check runs in the playback hot loops (~50×/sec in `Player`'s sleep
/// slices, plus once per special-clicker cycle), so it must NOT touch the
/// main actor: `NSApplication.shared.windows` is main-actor-only, and hopping
/// there tens of times a second starves SwiftUI rendering.
///
/// Instead the main actor publishes a snapshot of our window frames, and the
/// hot path does a lock-protected point-in-rect test off-thread. Window
/// geometry changes on human timescales, so a snapshot refreshed on move /
/// resize notifications plus a slow safety poll is always fresh enough.
enum WindowGuard {
    private static let lock = NSLock()
    private static var frames: [CGRect] = []
    private static var primaryHeight: CGFloat = 0

    private static var observers: [NSObjectProtocol] = []
    private static var refreshTimer: Timer?

    /// Hot path. Safe to call from any thread — no main-actor hop.
    ///
    /// Before the first snapshot lands this returns false (clicks proceed).
    /// `beginTracking()` is called at app launch and refreshes synchronously,
    /// so the cache is always warm long before any playback starts.
    static func cursorIsInOwnWindow() -> Bool {
        guard let cg = CGEvent(source: nil)?.location else { return false }

        lock.lock()
        let snapshot = frames
        let height = primaryHeight
        lock.unlock()

        guard !snapshot.isEmpty else { return false }

        // CGEvent coordinates are top-left origin; NSWindow.frame is
        // bottom-left origin relative to the primary screen.
        let cocoa = CGPoint(x: cg.x, y: height - cg.y)
        for frame in snapshot where frame.contains(cocoa) { return true }
        return false
    }

    /// Starts publishing window-frame snapshots. Idempotent. Called once at
    /// app launch and left running — the cost is a handful of rect copies a
    /// few times a second, versus the ~50 main-actor round trips per second
    /// this replaces.
    @MainActor
    static func beginTracking() {
        guard refreshTimer == nil else { return }
        refresh()

        let center = NotificationCenter.default
        for name: NSNotification.Name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { refresh() }
            }
            observers.append(token)
        }

        // Safety net for geometry changes with no notification (display
        // reconfiguration, Spaces switches, window ordering).
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { refresh() }
        }
    }

    /// Recomputes the snapshot. Main-actor only — `NSApplication.shared.windows`
    /// and `NSScreen.screens` require it.
    @MainActor
    static func refresh() {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let visible = NSApplication.shared.windows
            .filter { $0.isVisible }
            .map { $0.frame }

        lock.lock()
        frames = visible
        primaryHeight = height
        lock.unlock()
    }
}
