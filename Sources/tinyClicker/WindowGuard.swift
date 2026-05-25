import AppKit
import CoreGraphics
import Foundation

/// Checks whether the live cursor position falls inside any of tinyClicker's
/// own visible windows. Used by playback to pause itself whenever the user's
/// (or the system's) cursor is over our UI — both to avoid clicking our own
/// Stop All button and to let the user interact with the app without playback
/// stomping over them.
enum WindowGuard {
    /// `NSApplication.shared.windows` access requires the main actor.
    @MainActor
    static func cursorIsInOwnWindow() -> Bool {
        guard let cg = CGEvent(source: nil)?.location else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = NSPoint(x: cg.x, y: primaryHeight - cg.y)
        for window in NSApplication.shared.windows where window.isVisible {
            if window.frame.contains(cocoa) { return true }
        }
        return false
    }
}
