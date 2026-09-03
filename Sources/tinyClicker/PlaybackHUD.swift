import AppKit
import SwiftUI

/// While a Play All session is running, tinyClicker's main window would sit in
/// the way — a big surface the own-window pause guard (`WindowGuard`) has to
/// keep dodging. `PlaybackHUD` shrinks the app to a tiny always-on-top panel
/// for the duration: the main window drops to the Dock, and a floating capsule
/// with a Stop button takes its place.
///
/// The panel is a `.nonactivatingPanel` at `.floating` level with
/// `fullScreenAuxiliary` behavior, so the Stop control stays reachable even
/// when the click target is a fullscreen app. Its frame *is* still reported by
/// `WindowGuard`, which is intentional: playback pauses when the cursor rests
/// on the Stop button rather than clicking through it.
@MainActor
final class PlaybackHUD {
    private static let panelSize = NSSize(width: 210, height: 44)
    private nonisolated static let edgeMargin: CGFloat = 12
    // v2: the default corner moved from top-center to top-left, so a
    // previously persisted centered origin must not carry over.
    private static let originDefaultsKey = "tinyClicker.playbackHUD.origin.v2"

    private var panel: NSPanel?
    private weak var miniaturizedWindow: NSWindow?
    private var onStop: (() -> Void)?

    /// Shows the floating control and miniaturizes the main window.
    /// `onStop` is invoked when the panel's Stop button is clicked.
    /// `longestInterval` drives the capsule's looping countdown; pass `nil`
    /// (no macro checked) to fall back to a plain "Playing…" label.
    func show(longestInterval: TimeInterval?, onStop: @escaping () -> Void) {
        self.onStop = onStop

        let panel = panel ?? makePanel()
        self.panel = panel

        // Rebuilt every session so the countdown reflects the current set of
        // checked macros; the panel that hosts it is cached.
        panel.contentView = makeHostingView(longestInterval: longestInterval)

        // Capture the main window before it goes away — once miniaturized it is
        // no longer `isVisible`, so we could not find it again in `hide()`.
        let mainWindow = NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }

        panel.setFrameOrigin(startOrigin())
        panel.orderFrontRegardless()

        if let mainWindow {
            miniaturizedWindow = mainWindow
            mainWindow.miniaturize(nil)
        }
    }

    /// Hides the floating control and restores the main window.
    func hide() {
        if let panel {
            saveOrigin(panel.frame.origin)
            panel.orderOut(nil)
        }
        miniaturizedWindow?.deminiaturize(nil)
        miniaturizedWindow = nil
        onStop = nil
    }

    // MARK: - Panel construction

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }

    private func makeHostingView(longestInterval: TimeInterval?) -> NSView {
        let hosting = NSHostingView(
            rootView: PlaybackHUDView(longestInterval: longestInterval) { [weak self] in self?.onStop?() }
        )
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        hosting.autoresizingMask = [.width, .height]
        return hosting
    }

    // MARK: - Positioning

    /// Persisted origin if it still lands on a screen, otherwise the top-left
    /// corner of the main display.
    private func startOrigin() -> NSPoint {
        if let saved = savedOrigin(), isOnScreen(saved) { return saved }
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return Self.topLeftOrigin(screenFrame: screen, panelSize: Self.panelSize)
    }

    /// Pure geometry: bottom-left origin that pins a panel of `panelSize` to the
    /// top-left corner of `screenFrame`, inset by `edgeMargin` on both edges.
    nonisolated static func topLeftOrigin(screenFrame: NSRect, panelSize: NSSize) -> NSPoint {
        NSPoint(
            x: screenFrame.minX + edgeMargin,
            y: screenFrame.maxY - panelSize.height - edgeMargin
        )
    }

    private func isOnScreen(_ origin: NSPoint) -> Bool {
        let rect = NSRect(origin: origin, size: Self.panelSize)
        return NSScreen.screens.contains { $0.frame.intersects(rect) }
    }

    private func savedOrigin() -> NSPoint? {
        guard let string = UserDefaults.standard.string(forKey: Self.originDefaultsKey) else { return nil }
        let point = NSPointFromString(string)
        return point == .zero ? nil : point
    }

    private func saveOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(NSStringFromPoint(origin), forKey: Self.originDefaultsKey)
    }
}

/// The capsule shown while playback runs: a pulsing status dot, a label, and
/// the Stop button. Dragging anywhere on it moves the panel
/// (`isMovableByWindowBackground`).
private struct PlaybackHUDView: View {
    let longestInterval: TimeInterval?
    let onStop: () -> Void
    @State private var pulsing = false
    /// Anchor for the looping countdown — captured once when the capsule appears.
    @State private var startedAt = Date()

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.green)
                .frame(width: 9, height: 9)
                .opacity(pulsing ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)

            status

            Spacer(minLength: 4)

            Button(action: onStop) {
                Text("Stop (F10)").font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        )
        .onAppear { pulsing = true }
    }

    /// A looping countdown of the longest checked-macro interval, or a plain
    /// "Playing…" when nothing is checked. `TimelineView` ticks this label
    /// locally, once a second, so the panel is the only thing redrawing.
    @ViewBuilder
    private var status: some View {
        if let interval = longestInterval, interval > 0 {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(startedAt)
                let remaining = interval - elapsed.truncatingRemainder(dividingBy: interval)
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                    Text(NextRunCountdown.format(max(0, remaining)))
                }
                .font(.callout.weight(.medium))
                .monospacedDigit()
            }
        } else {
            Text("Playing…")
                .font(.callout.weight(.medium))
        }
    }
}
