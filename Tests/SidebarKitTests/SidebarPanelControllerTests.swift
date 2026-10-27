import AppKit
@testable import SidebarKit
import SwiftUI
import Testing
import ViewInspector

@MainActor
struct SidebarPanelControllerTests {
    let directory: TemporaryDirectory
    let settings: SettingsStore

    init() throws {
        _ = NSApplication.shared
        directory = try TemporaryDirectory()
        settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
    }

    @Test func pinShowsPanelOnReservedStrip() {
        let controller = SidebarPanelController(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            layout: { SidebarLayout(width: 240) },
            targetVisibleFrame: { CGRect(x: 0, y: 40, width: 1440, height: 860) },
            notificationCenter: NotificationCenter()
        )

        controller.pin()

        #expect(controller.panel.frame == CGRect(x: 1200, y: 40, width: 240, height: 860))
        #expect(controller.panel.isVisible)
    }

    @Test func pinHidesPanelWhenTargetScreenIsGone() {
        var visibleFrame: CGRect? = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let controller = SidebarPanelController(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { visibleFrame },
            notificationCenter: NotificationCenter()
        )
        controller.pin()

        visibleFrame = nil
        controller.pin()

        #expect(!controller.panel.isVisible)
    }

    @Test func repinsWhenScreenParametersChange() {
        let notificationCenter = NotificationCenter()
        var visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let controller = SidebarPanelController(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            layout: { SidebarLayout(width: 300) },
            targetVisibleFrame: { visibleFrame },
            notificationCenter: notificationCenter
        )
        controller.pin()

        visibleFrame = CGRect(x: 0, y: 80, width: 2560, height: 1300)
        notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        #expect(controller.panel.frame == CGRect(x: 2260, y: 80, width: 300, height: 1300))
    }

    @Test(.enabled(if: !NSScreen.screens.isEmpty, "requires a display"))
    func defaultControllerPinsToPrimaryScreen() throws {
        let primary = try #require(NSScreen.screens.first)
        let controller = SidebarPanelController(model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()), settings: settings, notificationCenter: NotificationCenter())

        controller.pin()

        #expect(controller.panel.frame.maxX == primary.visibleFrame.maxX)
        #expect(controller.panel.frame.height == primary.visibleFrame.height)
    }

    /// AeroSpace treats windows of accessory apps without a close button as popups,
    /// which keeps the sidebar out of tiling and workspace hiding.
    @Test func panelStaysOutOfAeroSpaceManagement() {
        let panel = SidebarPanelController(model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()), settings: settings, notificationCenter: NotificationCenter()).panel

        #expect(panel.standardWindowButton(.closeButton) == nil)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!panel.hidesOnDeactivate)
    }

    @Test func panelAcceptsKeyboardFocus() {
        let controller = SidebarPanelController(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
            notificationCenter: NotificationCenter()
        )
        controller.pin()

        // Borderless windows refuse key status unless the panel overrides it. Asserting
        // `isKeyWindow` races with other tests that make their own windows key.
        #expect(controller.panel.canBecomeKey)
        #expect(controller.panel.styleMask.contains(.nonactivatingPanel))
    }

    @Test func rendersContentInsidePanel() throws {
        let controller = SidebarPanelController(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
            notificationCenter: NotificationCenter()
        )
        controller.pin()
        let contentView = try #require(controller.panel.contentView)

        contentView.layoutSubtreeIfNeeded()

        // The SwiftUI content fills the panel directly; there is no window background behind it.
        #expect(contentView is NSHostingView<ModifiedContent<SidebarView, TypographyModifier>>)
        #expect(contentView.frame.size == controller.panel.frame.size)
    }
}
