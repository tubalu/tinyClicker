import SwiftUI

/// Live "next run" countdown for a recording waiting out its interval.
///
/// `TimelineView` drives the per-second tick locally, so only this label
/// redraws. Deliberately NOT a `@Published` countdown on `AppState`: that
/// would re-render every view in the app once a second.
struct NextRunCountdown: View {
    let due: Date
    var style: Style = .compact

    enum Style {
        /// Sidebar row — short, fits under the recording name.
        case compact
        /// Detail pane — the headline answer to "when does this fire next?".
        case prominent
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = due.timeIntervalSince(context.date)
            let isDue = remaining <= 0.5
            let clock = Self.format(max(0, remaining))

            switch style {
            case .compact:
                HStack(spacing: 3) {
                    Image(systemName: "timer")
                    Text(isDue ? "due" : clock)
                }
                .font(.caption.weight(.semibold))
                .monospacedDigit()

            case .prominent:
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                    Text(isDue ? "Running next" : "Next run in \(clock)")
                }
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
        }
    }

    /// `m:ss` past a minute, plain seconds below it — a 110s interval reads
    /// better as "1:50" than "110s".
    private static func format(_ remaining: TimeInterval) -> String {
        let total = Int(remaining.rounded())
        guard total >= 60 else { return "\(total)s" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
