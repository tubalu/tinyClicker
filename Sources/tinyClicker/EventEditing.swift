import CoreGraphics
import Foundation

/// Which way a paste lands in the target recording.
enum PasteMode {
    case append
    case replace
}

/// A high-level input action the user can add by hand. Each expands into the
/// down/up pair the player actually needs — `RecordedEvent` has no notion of
/// a "click", only `mouseDown` and `mouseUp`.
enum ActivityTemplate: String, CaseIterable, Identifiable {
    case click
    case rightClick
    case keyPress

    var id: String { rawValue }

    var label: String {
        switch self {
        case .click: return "Click"
        case .rightClick: return "Right Click"
        case .keyPress: return "Key Press"
        }
    }

    var symbol: String {
        switch self {
        case .click: return "cursorarrow.click"
        case .rightClick: return "cursorarrow.click.2"
        case .keyPress: return "keyboard"
        }
    }
}

/// Events held in the app-level clipboard by "Copy Events". Session-only —
/// deliberately not persisted, and it stores copied *values*, so deleting the
/// source recording afterwards leaves the clipboard intact.
struct EventClipboard: Equatable {
    let sourceName: String
    let events: [RecordedEvent]
}

/// Pure event-list surgery shared by copy/paste, cloning, and manual event
/// entry. No UI, no app state — everything is value-in / value-out.
enum EventEditing {
    /// Silence inserted between a recording's last event and pasted-in events,
    /// and before a manually added activity.
    static let joinGap: TimeInterval = 0.5

    /// How long a synthesized press is held before its matching release.
    private static let clickHold: TimeInterval = 0.10
    private static let keyHold: TimeInterval = 0.08

    /// Re-stamps every event with a fresh `id`, preserving all other fields.
    ///
    /// Mandatory for any copy: `RecordedEvent.id` is the identity SwiftUI's
    /// `Table` and the per-row write-through bindings key off, so two rows
    /// sharing an id would edit each other.
    static func reidentified(_ events: [RecordedEvent]) -> [RecordedEvent] {
        events.map { event in
            RecordedEvent(
                kind: event.kind,
                timestamp: event.timestamp,
                position: event.position,
                button: event.button,
                keyCode: event.keyCode,
                flags: event.flags
            )
        }
    }

    /// Returns `target` followed by `source`, re-based so the first pasted
    /// event lands `joinGap` after the target's last event while every gap
    /// *within* `source` is preserved exactly.
    ///
    /// Subtracting `source.first.timestamp` matters: a recorded macro rarely
    /// starts at exactly 0 — there is always some delay between pressing F9
    /// and the first click — and a naive offset would inherit that dead time.
    static func appending(_ source: [RecordedEvent], to target: [RecordedEvent]) -> [RecordedEvent] {
        guard !source.isEmpty else { return target }
        let sourceStart = source[0].timestamp
        let base = (target.last?.timestamp ?? 0) + joinGap
        let shifted = source.map { event in
            RecordedEvent(
                kind: event.kind,
                timestamp: base + (event.timestamp - sourceStart),
                position: event.position,
                button: event.button,
                keyCode: event.keyCode,
                flags: event.flags
            )
        }
        return target + shifted
    }

    /// Expands a template into its constituent events, the first at `start`.
    ///
    /// `flags` is set to 0 rather than left `nil` so a synthesized event is
    /// deterministic — it fires with no modifiers regardless of what the user
    /// happens to be holding down at playback time.
    static func events(
        for activity: ActivityTemplate,
        startingAt start: TimeInterval,
        at position: CGPoint
    ) -> [RecordedEvent] {
        switch activity {
        case .click:
            return mousePair(button: 0, start: start, position: position)
        case .rightClick:
            return mousePair(button: 1, start: start, position: position)
        case .keyPress:
            return [
                RecordedEvent(kind: .keyDown, timestamp: start, keyCode: 0, flags: 0),
                RecordedEvent(kind: .keyUp, timestamp: start + keyHold, keyCode: 0, flags: 0),
            ]
        }
    }

    private static func mousePair(
        button: Int,
        start: TimeInterval,
        position: CGPoint
    ) -> [RecordedEvent] {
        [
            RecordedEvent(kind: .mouseDown, timestamp: start, position: position, button: button, flags: 0),
            RecordedEvent(kind: .mouseUp, timestamp: start + clickHold, position: position, button: button, flags: 0),
        ]
    }
}
