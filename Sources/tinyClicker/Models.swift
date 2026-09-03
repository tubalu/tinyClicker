import CoreGraphics
import Foundation

enum RecordedEventKind: String, Codable {
    case mouseDown
    case mouseUp
    case keyDown
    case keyUp
}

struct RecordedEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: RecordedEventKind
    var timestamp: TimeInterval
    var position: CGPoint?
    var button: Int?
    var keyCode: UInt16?
    let flags: UInt64?

    init(
        id: UUID = UUID(),
        kind: RecordedEventKind,
        timestamp: TimeInterval,
        position: CGPoint? = nil,
        button: Int? = nil,
        keyCode: UInt16? = nil,
        flags: UInt64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.position = position
        self.button = button
        self.keyCode = keyCode
        self.flags = flags
    }
}

struct Recording: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var events: [RecordedEvent]
    var intervalSeconds: Double
    var enabled: Bool
    var locked: Bool

    init(
        id: UUID = UUID(),
        name: String = "Untitled",
        events: [RecordedEvent] = [],
        intervalSeconds: Double = 2.0,
        enabled: Bool = false,
        locked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.events = events
        self.intervalSeconds = intervalSeconds
        self.enabled = enabled
        self.locked = locked
    }

    enum CodingKeys: String, CodingKey {
        case id, name, events, intervalSeconds, enabled, locked
    }

    /// Hand-written to stay backward compatible with `recordings.json` files
    /// saved before `locked` existed — synthesized `Decodable` would throw
    /// on the missing key instead of falling back to `false`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        events = try container.decode([RecordedEvent].self, forKey: .events)
        intervalSeconds = try container.decode(Double.self, forKey: .intervalSeconds)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked) ?? false
    }

    var duration: TimeInterval {
        events.last?.timestamp ?? 0
    }
}

extension Sequence where Element == Recording {
    /// Longest interval among checked macros that actually have something to
    /// replay. `nil` when nothing is checked — the Play All HUD then shows a
    /// plain "Playing…" instead of a countdown.
    var longestPlayableInterval: TimeInterval? {
        filter { $0.enabled && !$0.events.isEmpty }
            .map(\.intervalSeconds)
            .max()
    }
}
