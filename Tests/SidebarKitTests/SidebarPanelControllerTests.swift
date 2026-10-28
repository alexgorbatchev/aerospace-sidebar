import AppKit
@testable import SidebarKit
import SwiftUI
import Testing
import ViewInspector

@MainActor
@Suite(.leavesDesktopAlone)
struct SidebarPanelControllerTests {
    let directory: TemporaryDirectory
    let settings: SettingsStore

    init() throws {
        _ = NSApplication.shared
        directory = try TemporaryDirectory()
        settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
    }

    @Test func pinShowsPanelOnConfiguredStrip() {
        settings.update { $0.sidebar.width = 240 }
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 40, width: 1440, height: 860) },
            notificationCenter: NotificationCenter()
        )

        controller.pin()

        #expect(controller.panel.frame == CGRect(x: 1200, y: 40, width: 240, height: 860))
        #expect(controller.panel.isVisible)
    }

    @Test func repinsWhenSideOrWidthChanges() {
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 40, width: 1440, height: 860) },
            notificationCenter: NotificationCenter()
        )
        controller.pin()
        #expect(controller.panel.frame == CGRect(x: 1140, y: 40, width: 300, height: 860))

        settings.update { $0.sidebar = SidebarSettings.Sidebar(side: .left, width: 400) }

        #expect(controller.panel.frame == CGRect(x: 0, y: 40, width: 400, height: 860))
    }

    @Test func otherSettingsLeaveTheHiddenPanelAlone() {
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 40, width: 1440, height: 860) },
            notificationCenter: NotificationCenter()
        )

        settings.update { $0.history.maxCount = 50 }

        #expect(!controller.panel.isVisible)
    }

    @Test func pinHidesPanelWhenTargetScreenIsGone() {
        let visibleFrame = Mutable<CGRect?>(CGRect(x: 0, y: 0, width: 1440, height: 900))
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { visibleFrame.value },
            notificationCenter: NotificationCenter()
        )
        controller.pin()

        visibleFrame.value = nil
        controller.pin()

        #expect(!controller.panel.isVisible)
    }

    @Test func repinsWhenScreenParametersChange() {
        let notificationCenter = NotificationCenter()
        let visibleFrame = Mutable(CGRect(x: 0, y: 0, width: 1440, height: 900))
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { visibleFrame.value },
            notificationCenter: notificationCenter
        )
        controller.pin()

        visibleFrame.value = CGRect(x: 0, y: 80, width: 2560, height: 1300)
        notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        #expect(controller.panel.frame == CGRect(x: 2260, y: 80, width: 300, height: 1300))
    }

    @Test(.enabled(if: !NSScreen.screens.isEmpty, "requires a display"))
    func defaultControllerPinsToPrimaryScreen() throws {
        let primary = try #require(NSScreen.screens.first)
        let controller = SidebarPanelController.forTesting(model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()), settings: settings, notificationCenter: NotificationCenter())

        controller.pin()

        #expect(controller.panel.frame.maxX == primary.visibleFrame.maxX)
        #expect(controller.panel.frame.height == primary.visibleFrame.height)
    }

    /// AeroSpace treats windows of accessory apps without a close button as popups,
    /// which keeps the sidebar out of tiling and workspace hiding.
    @Test func panelStaysOutOfAeroSpaceManagement() {
        let panel = SidebarPanelController.forTesting(model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()), settings: settings, notificationCenter: NotificationCenter()).panel

        #expect(panel.standardWindowButton(.closeButton) == nil)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!panel.hidesOnDeactivate)
    }

    /// Borderless windows refuse key status unless the panel overrides it; the panel accepts it only for a
    /// click on it, so launching or closing Settings leaves keyboard focus with the frontmost app. Making
    /// the panel key to assert `isKeyWindow` would take the user's keyboard focus from the frontmost app.
    @Test func panelTakesKeyboardFocusOnlyWhenClicked() throws {
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
            notificationCenter: NotificationCenter()
        )
        controller.pin()
        let panel = try #require(controller.panel as? SidebarPanel)
        func event(_ type: NSEvent.EventType, in window: NSWindow) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        let other = TestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        other.orderFrontRegardless()
        defer { other.orderOut(nil) }

        #expect(panel.styleMask.contains(.nonactivatingPanel))
        // Launching: AppKit makes a window key with no event to handle.
        #expect(!panel.canBecomeKey)
        #expect(!panel.acceptsKeyStatus(during: nil))
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            #expect(panel.acceptsKeyStatus(during: event(type, in: panel)))
        }
        #expect(!panel.acceptsKeyStatus(during: event(.leftMouseUp, in: panel)))
        // Closing Settings with a click: AppKit looks for the next key window.
        #expect(!panel.acceptsKeyStatus(during: event(.leftMouseDown, in: other)))
    }

    @Test func rendersContentInsidePanel() throws {
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
            notificationCenter: NotificationCenter()
        )
        controller.pin()
        let contentView = try #require(controller.panel.contentView)

        contentView.layoutSubtreeIfNeeded()

        // The SwiftUI content fills the panel directly.
        #expect(contentView is NSHostingView<SidebarPanelContent>)
        #expect(contentView.frame.size == controller.panel.frame.size)
    }

    @Test(.enabled(if: !NSScreen.screens.isEmpty, "requires a display"))
    func transparentListAreaRetainsMouseEvents() async throws {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        model.add(SidebarNotification(source: "test", title: "One card"))
        // Not `forTesting`: the window server skips transparent windows, so this panel shows on screen
        // briefly. Borderless and never made key, it leaves the user's keyboard focus alone.
        let controller = SidebarPanelController(model: model, settings: settings, notificationCenter: NotificationCenter())
        let panel = controller.panel
        panel.identifier = .windowServerProbe
        let screen = try #require(NSScreen.screens.first)
        panel.setFrame(CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.minY, width: 300, height: 600), display: true)
        panel.level = .popUpMenu
        panel.orderFrontRegardless()
        defer { panel.close() }
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        // Sample the entire lower list, including both gutters and empty space below the card.
        // These must stay interactive even where there are no cards.
        for x in [CGFloat(2), 150, 298] {
            for y in stride(from: CGFloat(200), through: 500, by: 50) {
                let point = CGPoint(x: x, y: content.isFlipped ? y : 600 - y)
                #expect(content.hitTest(point) != nil, "List lost mouse events at \(point)")
                let screenPoint = panel.convertPoint(toScreen: content.convert(point, to: nil))
                #expect(NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == panel.windowNumber,
                        "Window server passed through the list at \(point)")
            }
        }
    }
}
