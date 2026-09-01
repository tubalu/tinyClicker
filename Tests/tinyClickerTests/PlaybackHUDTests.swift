import AppKit
import Testing
@testable import tinyClicker

struct PlaybackHUDTests {
    private let panelSize = NSSize(width: 210, height: 44)

    @Test("origin pins the panel to the top-left corner, inset by the edge margin")
    func topLeftOnPrimaryScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = PlaybackHUD.topLeftOrigin(screenFrame: screen, panelSize: panelSize)

        #expect(origin.x == screen.minX + 12)
        #expect(origin.y == screen.maxY - panelSize.height - 12)
    }

    @Test("origin respects a screen that does not start at (0, 0)")
    func topLeftOnOffsetScreen() {
        let screen = NSRect(x: 1440, y: 200, width: 1920, height: 1080)
        let origin = PlaybackHUD.topLeftOrigin(screenFrame: screen, panelSize: panelSize)

        #expect(origin.x == 1440 + 12)
        #expect(origin.y == 200 + 1080 - panelSize.height - 12)
    }
}
