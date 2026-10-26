import CoreGraphics
import Foundation
import SidebarKit
import Testing

struct SidebarLayoutTests {
    @Test func pinsStripToRightEdgeAtFullHeight() {
        let visibleFrame = CGRect(x: 1920, y: 70, width: 2560, height: 1340)

        let frame = SidebarLayout(width: 300).frame(in: visibleFrame)

        #expect(frame == CGRect(x: 4180, y: 70, width: 300, height: 1340))
    }

    @Test func clampsWidthToVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 200, height: 800)

        let frame = SidebarLayout(width: 300).frame(in: visibleFrame)

        #expect(frame == visibleFrame)
    }

    @Test func sizesToAeroSpaceReservedStrip() throws {
        let home = try TemporaryDirectory()
        try home.write("[gaps]\nouter.right = [{ monitor.main = 285 }, 5]", to: ".config/aerospace/aerospace.toml")

        let layout = SidebarLayout.fromAeroSpaceConfig(home: home.url, environment: [:])

        #expect(layout.width == 280)
    }

    @Test func fallsBackWhenAeroSpaceConfigIsUnreadable() throws {
        let home = try TemporaryDirectory()

        let layout = SidebarLayout.fromAeroSpaceConfig(home: home.url, environment: [:])

        #expect(layout.width == SidebarLayout.fallbackWidth)
    }
}
