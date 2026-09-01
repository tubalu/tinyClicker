import Foundation
import Testing
@testable import tinyClicker

struct PlayerPerformanceTests {
    @Test
    func recordedGapDoesNotPollSafetyAtFiftyHertz() async {
        let activityChecks = LockedCounter()
        let player = Player(
            isUserActive: { _ in
                activityChecks.increment()
                return false
            },
            cursorIsInOwnWindow: { false }
        )
        let recording = Recording(
            events: [
                // Missing key codes deliberately make event posting a no-op;
                // this test exercises real playback timing without typing.
                RecordedEvent(kind: .keyDown, timestamp: 0),
                RecordedEvent(kind: .keyUp, timestamp: 0.45),
            ]
        )

        let outcome = await player.play(
            recording,
            pauseSignal: PauseSignal(),
            pauseOnMouseMove: true,
            pauseOnOwnWindow: false
        )

        #expect(outcome == .completed)
        #expect(
            (5...8).contains(activityChecks.value),
            "A recorded gap should check safety about ten times per second, not fifty"
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
