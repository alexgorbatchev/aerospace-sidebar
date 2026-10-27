import AppKit
@testable import SidebarKit
import Testing

@MainActor
struct FontChooserTests {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)

    init() {
        _ = NSApplication.shared
    }

    static func isOnScreen(_ window: NSWindow) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { $0[kCGWindowNumber as String] as? Int == window.windowNumber }
    }

    func chooser(picking picked: NSFont) -> FontChooser {
        FontChooser(panel: { [panel] in panel }, convert: { _ in picked })
    }

    @Test func showsPanelOnCurrentFontAndReportsPicks() throws {
        let sut = chooser(picking: try #require(NSFont(name: "Menlo-Bold", size: 17)))
        var picks: [SidebarSettings.Font] = []

        sut.choose(SidebarSettings.Font(name: "Menlo", size: 15), beside: window) { picks.append($0) }

        #expect(panel.isVisible)
        #expect(NSFontManager.shared.target === sut)
        #expect(NSFontManager.shared.selectedFont?.familyName == "Menlo")
        #expect(NSFontManager.shared.selectedFont?.pointSize == 15)

        sut.changeFont(NSFontManager.shared)

        #expect(picks == [SidebarSettings.Font(name: "Menlo", size: 17)])
        sut.close()
    }

    /// The font manager, not the test, delivers the change and converts the font, as for panel picks.
    @Test func receivesFontManagerChanges() {
        let sut = FontChooser(panel: { [panel] in panel })
        var picks: [SidebarSettings.Font] = []
        sut.choose(SidebarSettings.Font(name: "Menlo", size: 15), beside: window) { picks.append($0) }
        let sizeUp = NSMenuItem()
        sizeUp.tag = Int(NSFontAction.sizeUpFontAction.rawValue)

        NSFontManager.shared.modifyFont(sizeUp)

        #expect(picks.count == 1)
        #expect(picks.first?.name == "Menlo")
        #expect((picks.first?.size ?? 0) > 15)
        sut.close()
    }

    @Test func systemFontPickIsSavedAsEmptyName() {
        let sut = chooser(picking: .systemFont(ofSize: 14))
        var picks: [SidebarSettings.Font] = []

        sut.choose(SidebarSettings.Font(name: "Menlo"), beside: window) { picks.append($0) }
        sut.changeFont(NSFontManager.shared)

        #expect(picks == [SidebarSettings.Font(name: "", size: 14)])
        sut.close()
    }

    @Test func closeHidesPanelAndStopsReporting() {
        let sut = chooser(picking: .systemFont(ofSize: 14))
        var picks = 0
        sut.choose(SidebarSettings.Font(), beside: window) { _ in picks += 1 }

        sut.close()
        sut.changeFont(NSFontManager.shared)

        #expect(!panel.isVisible)
        #expect(NSFontManager.shared.target == nil)
        #expect(picks == 0)
    }

    @Test(arguments: [
        // Room on the left: left of the window, top-aligned.
        (NSRect(x: 600, y: 300, width: 400, height: 500), NSRect(x: 192, y: 300, width: 400, height: 500)),
        // No room on the left: right of the window.
        (NSRect(x: 100, y: 300, width: 400, height: 500), NSRect(x: 508, y: 300, width: 400, height: 500)),
        // Neither fits, and the top is off-screen: pulled onto the screen.
        (NSRect(x: 100, y: 700, width: 1700, height: 500), NSRect(x: 1520, y: 400, width: 400, height: 500)),
    ])
    func placesPanelBesideWindowOnScreen(window: NSRect, expected: NSRect) {
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 900)

        #expect(FontChooser.frame(of: NSSize(width: 400, height: 500), beside: window, in: visible) == expected)
    }

    @Test(.enabled(if: !NSScreen.screens.isEmpty, "requires a display"))
    func opensOffScreenPanelBesideWindow() throws {
        let screen = try #require(NSScreen.screens.first)
        window.setFrame(NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 300, height: 200), display: false)
        window.orderFrontRegardless()
        panel.setFrameOrigin(NSPoint(x: 216, y: -5000))
        let sut = chooser(picking: .systemFont(ofSize: 13))

        sut.choose(SidebarSettings.Font(), beside: window) { _ in }

        #expect(panel.frame.maxX == window.frame.minX - FontChooser.spacing)
        #expect(panel.frame.maxY == window.frame.maxY)
        #expect(screen.visibleFrame.contains(panel.frame))
        sut.close()
        window.orderOut(nil)
    }

    /// Asks the window server rather than AppKit, whose `isVisible` is true for a panel the window
    /// server keeps hidden because its app is inactive.
    @Test(.enabled(if: !NSScreen.screens.isEmpty, "requires a display"))
    func realFontPanelReachesTheScreenWhileTheAppIsInactive() async throws {
        let screen = try #require(NSScreen.screens.first)
        // Other tests' windows can activate the test process; the app this guards never is.
        NSApp.deactivate()
        for _ in 0..<100 where NSApp.isActive {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!NSApp.isActive)
        window.setFrame(NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 300, height: 200), display: false)
        window.orderFrontRegardless()
        let sut = FontChooser()

        sut.choose(SidebarSettings.Font(), beside: window) { _ in }
        let panel = try #require(NSFontManager.shared.fontPanel(false))
        // The window server applies ordering asynchronously.
        for _ in 0..<100 where !Self.isOnScreen(panel) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(Self.isOnScreen(panel))
        sut.close()
        window.orderOut(nil)
        #expect(!panel.isVisible)
    }

    /// The font panel is shared by the whole app, so a chooser that never showed it, such as one in a Settings window
    /// closing without its font picked, leaves it alone.
    @Test func closingLeavesThePanelOfAnotherChooserShowing() {
        let showing = chooser(picking: .systemFont(ofSize: 14))
        let idle = chooser(picking: .systemFont(ofSize: 14))
        var picks = 0
        showing.choose(SidebarSettings.Font(), beside: window) { _ in picks += 1 }

        idle.close()
        showing.changeFont(NSFontManager.shared)

        #expect(panel.isVisible)
        #expect(NSFontManager.shared.target === showing)
        #expect(picks == 1)
        showing.close()
        #expect(!panel.isVisible)
    }

    @Test func offersOnlyModesThatMapToSettings() {
        #expect(chooser(picking: .systemFont(ofSize: 13)).validModesForFontPanel(NSFontPanel.shared) == [.collection, .face, .size])
    }
}
