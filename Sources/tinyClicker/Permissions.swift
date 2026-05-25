import ApplicationServices
import AppKit
import Combine
import Foundation

@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var isTrusted: Bool = PermissionMonitor.checkTrusted()

    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?

    init() {
        let center = NotificationCenter.default
        let activate = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        observers.append(activate)

        // Fires whenever ANY app's accessibility setting changes — re-check ours.
        let dcenter = DistributedNotificationCenter.default()
        let axChange = dcenter.addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        observers.append(axChange)

        // Fallback poll while untrusted, in case the distributed notification
        // doesn't fire for our process's identity.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
            DistributedNotificationCenter.default().removeObserver(token)
        }
        pollTimer?.invalidate()
    }

    func refresh() {
        let trusted = Self.checkTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
        }
        if trusted {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    /// Triggers the system permission prompt if not already trusted.
    func prompt() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings to the Accessibility pane.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Quits the app. macOS often won't propagate a freshly granted
    /// Accessibility permission to an already-running process; relaunching
    /// is the most reliable way to pick it up.
    func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    /// Spawns a fresh instance of this app bundle, then quits the current
    /// process. The new instance starts with a clean AX trust check, so any
    /// recently granted permission will take effect immediately.
    func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundlePath]
        do {
            try task.run()
        } catch {
            // If the relaunch fails, fall back to a plain quit so the user
            // can manually relaunch.
        }
        // Give the OS a beat to dispatch the launch before we terminate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Explicitly bypass any in-process caching by going through the
    /// options-based API with no prompt.
    private static func checkTrusted() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
