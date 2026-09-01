import AppKit
import Testing
@testable import tinyClicker

struct PlaybackHUDTests {
    private let panelSize = NSSize(width: 210, height: 44)

    @Test("origin centers the panel horizontally and pins it near the top edge")
    func topCenterOnPrimaryScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = PlaybackHUD.topCenterOrigin(screenFrame: screen, panelSize: panelSize)

        #expect(origin.x == screen.midX - panelSize.width / 2)
        #expect(origin.y == screen.maxY - panelSize.height - 12)
    }

    @Test("origin respects a screen that does not start at (0, 0)")
    func topCenterOnOffsetScreen() {
        let screen = NSRect(x: 1440, y: 200, width: 1920, height: 1080)
        let origin = PlaybackHUD.topCenterOrigin(screenFrame: screen, panelSize: panelSize)

        #expect(origin.x == 1440 + 1920 / 2 - panelSize.width / 2)
        #expect(origin.y == 200 + 1080 - panelSize.height - 12)
    }
}
