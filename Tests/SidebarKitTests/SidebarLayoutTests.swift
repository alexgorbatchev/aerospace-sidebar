import CoreGraphics
import Foundation
import SidebarKit
import Testing

struct SidebarLayoutTests {
    let visibleFrame = CGRect(x: 1920, y: 70, width: 2560, height: 1340)

    @Test func pinsStripToRightEdgeAtFullHeight() {
        let frame = SidebarLayout(SidebarSettings.Sidebar(side: .right, width: 300)).frame(in: visibleFrame)

        #expect(frame == CGRect(x: 4180, y: 70, width: 300, height: 1340))
    }

    @Test func pinsStripToLeftEdgeAtFullHeight() {
        let frame = SidebarLayout(SidebarSettings.Sidebar(side: .left, width: 250)).frame(in: visibleFrame)

        #expect(frame == CGRect(x: 1920, y: 70, width: 250, height: 1340))
    }

    @Test(arguments: SidebarSettings.Sidebar.Side.allCases)
    func clampsWidthToVisibleFrame(side: SidebarSettings.Sidebar.Side) {
        let visibleFrame = CGRect(x: 0, y: 0, width: 200, height: 800)

        let frame = SidebarLayout(width: 300, side: side).frame(in: visibleFrame)

        #expect(frame == visibleFrame)
    }

    /// NotificationCenter draws at the screen's right edge: a right-side strip covers it from there, a
    /// Dock on the right adds its width, and a left-side strip covers nothing.
    @Test func coversTheRightEdgeOnlyFromTheRightSide() {
        let screen = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let besideDock = CGRect(x: 1920, y: 70, width: 2480, height: 1340)

        #expect(SidebarLayout(width: 300, side: .right).coverage(ofRightEdgeOf: screen, visibleFrame: visibleFrame) == 300)
        #expect(SidebarLayout(width: 300, side: .right).coverage(ofRightEdgeOf: screen, visibleFrame: besideDock) == 380)
        #expect(SidebarLayout(width: 300, side: .left).coverage(ofRightEdgeOf: screen, visibleFrame: visibleFrame) == 0)
    }
}
