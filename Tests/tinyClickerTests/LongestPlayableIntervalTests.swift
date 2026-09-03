import Foundation
import Testing
@testable import tinyClicker

struct LongestPlayableIntervalTests {
    private func macro(enabled: Bool, interval: Double, events: Int = 1) -> Recording {
        Recording(
            events: (0 ..< events).map { RecordedEvent(kind: .keyDown, timestamp: Double($0)) },
            intervalSeconds: interval,
            enabled: enabled
        )
    }

    @Test("picks the largest interval among the checked macros")
    func picksLargest() {
        let recordings = [
            macro(enabled: true, interval: 3),
            macro(enabled: true, interval: 12),
            macro(enabled: false, interval: 99),
        ]
        #expect(recordings.longestPlayableInterval == 12)
    }

    @Test("nil when nothing is checked — HUD falls back to \"Playing…\"")
    func noneChecked() {
        #expect([macro(enabled: false, interval: 5)].longestPlayableInterval == nil)
    }

    @Test("ignores checked macros that have no events to replay")
    func ignoresEmpty() {
        let recordings = [
            macro(enabled: true, interval: 4),
            macro(enabled: true, interval: 20, events: 0),
        ]
        #expect(recordings.longestPlayableInterval == 4)
    }

    @Test("nil for an empty list")
    func emptyList() {
        #expect([Recording]().longestPlayableInterval == nil)
    }
}

struct CountdownFormatTests {
    @Test("plain seconds below a minute, m:ss at or above it")
    func formatting() {
        #expect(NextRunCountdown.format(0) == "0s")
        #expect(NextRunCountdown.format(5.4) == "5s")
        #expect(NextRunCountdown.format(59) == "59s")
        #expect(NextRunCountdown.format(60) == "1:00")
        #expect(NextRunCountdown.format(110) == "1:50")
    }
}
