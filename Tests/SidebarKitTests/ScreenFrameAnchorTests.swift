import AppKit
@testable import SidebarKit
import SwiftUI
import Testing

@MainActor
@Suite(.leavesDesktopAlone)
struct ScreenFrameAnchorTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func findsAViewOnScreenOnlyInAWindow() throws {
        let anchor = ScreenFrameAnchor()
        #expect(anchor.screenFrame == nil)

        let view = NSView(frame: CGRect(x: 10, y: 20, width: 50, height: 30))
        anchor.view = view
        #expect(anchor.screenFrame == nil)

        let window = TestPanel(contentRect: CGRect(x: 100, y: 200, width: 300, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        try #require(window.contentView).addSubview(view)

        #expect(anchor.screenFrame == CGRect(x: 110, y: 220, width: 50, height: 30))
    }

    /// The SwiftUI view hands the anchor the AppKit view behind it, at its own frame.
    @Test func readsTheFrameOfTheSwiftUIView() throws {
        let anchor = ScreenFrameAnchor()
        let window = TestPanel(contentRect: CGRect(x: 100, y: 200, width: 300, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        let hosting = NSHostingView(rootView: Color.clear.frame(width: 40, height: 20).screenFrameAnchor(anchor).frame(width: 300, height: 300))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let frame = try #require(anchor.screenFrame)
        #expect(frame.size == CGSize(width: 40, height: 20))
        #expect(frame.midX == 250 && frame.midY == 350)
    }
}
