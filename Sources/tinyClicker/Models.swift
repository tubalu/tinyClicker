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
    let timestamp: TimeInterval
    let position: CGPoint?
    let button: Int?
    let keyCode: UInt16?
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

    init(
        id: UUID = UUID(),
        name: String = "Untitled",
        events: [RecordedEvent] = [],
        intervalSeconds: Double = 2.0,
        enabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.events = events
        self.intervalSeconds = intervalSeconds
        self.enabled = enabled
    }

    var duration: TimeInterval {
        events.last?.timestamp ?? 0
    }
}
