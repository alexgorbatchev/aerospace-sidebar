import AppKit
@testable import SidebarKit
import Testing

@MainActor
@Suite(.leavesDesktopAlone)
struct ColorWellTests {
    /// The color panel comes forward beside Settings, away from the sidebar, although the app is inactive; one the
    /// user already placed stays where it is. A transparent `TestPanel` stands in for the shared color panel, which
    /// would show on the user's screen.
    @Test(.enabled(if: !NSScreen.screens.isEmpty, "requires a display"))
    func showsTheColorPanelBesideSettingsWhileTheAppIsInactive() throws {
        let screen = try #require(NSScreen.screens.first)
        let window = TestPanel(
            contentRect: NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let well = SettingsColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        well.sidebarSide = { .left }
        window.contentView?.addSubview(well)
        let panel = TestPanel(contentRect: NSRect(x: 0, y: -5000, width: 200, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        panel.hidesOnDeactivate = true
        defer { panel.orderOut(nil) }
        let size = panel.frame.size

        well.show(panel, placing: true)

        #expect(panel.isVisible)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.frame == FontChooser.frame(of: size, beside: window.frame, awayFrom: .left, in: screen.visibleFrame))

        panel.setFrameOrigin(NSPoint(x: 10, y: 10))
        well.show(panel, placing: false)
        #expect(panel.frame.origin == NSPoint(x: 10, y: 10))
    }

    /// Closing Settings closes the color panel its well opened; another window closing, such as a second Settings
    /// window in tests, leaves it alone.
    @Test func closesThePanelOnlyWithTheWindowWhoseWellOpenedIt() {
        let window = TestPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let well = SettingsColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        window.contentView?.addSubview(well)
        let panel = TestPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        SettingsColorWell.active = well
        defer { SettingsColorWell.active = nil }

        SettingsColorWell.closePanel(of: TestPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false), panel: panel)
        #expect(panel.isVisible)
        #expect(SettingsColorWell.active === well)

        SettingsColorWell.closePanel(of: window, panel: panel)
        #expect(!panel.isVisible)
        #expect(SettingsColorWell.active == nil)
    }

    /// Checking whether a click went to the font or color panel creates neither.
    @Test func checkingThePickerPanelsCreatesNone() {
        let fontPanelExisted = NSFontPanel.sharedFontPanelExists
        let colorPanelExisted = NSColorPanel.sharedColorPanelExists

        _ = ActivationYielder.isPointerOverPickerPanel()

        #expect(NSFontPanel.sharedFontPanelExists == fontPanelExisted)
        #expect(NSColorPanel.sharedColorPanelExists == colorPanelExisted)
    }
}
