import AppKit
@testable import SidebarKit
import SwiftUI
import Testing
import ViewInspector

@MainActor
struct SidebarPanelControllerTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func pinShowsPanelOnReservedStrip() {
        let controller = SidebarPanelController(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
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
        let controller = SidebarPanelController(model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()), notificationCenter: NotificationCenter())

        controller.pin()

        #expect(controller.panel.frame.maxX == primary.visibleFrame.maxX)
        #expect(controller.panel.frame.height == primary.visibleFrame.height)
    }

    /// AeroSpace treats windows of accessory apps without a close button as popups,
    /// which keeps the sidebar out of tiling and workspace hiding.
    @Test func panelStaysOutOfAeroSpaceManagement() {
        let panel = SidebarPanelController(model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()), notificationCenter: NotificationCenter()).panel

        #expect(panel.standardWindowButton(.closeButton) == nil)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!panel.hidesOnDeactivate)
    }

    @Test func panelAcceptsKeyboardFocus() {
        let controller = SidebarPanelController(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
            notificationCenter: NotificationCenter()
        )
        controller.pin()

        controller.panel.makeKey()

        #expect(controller.panel.isKeyWindow)
    }

    @Test func quitButtonTerminatesApp() throws {
        var terminateCalls = 0
        let controller = SidebarPanelController(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
            notificationCenter: NotificationCenter(),
            terminate: { _ in terminateCalls += 1 }
        )
        controller.pin()
        let hostingView = try #require(controller.panel.contentView?.subviews.first as? NSHostingView<SidebarView>)

        try hostingView.rootView.inspect().find(button: "Quit Sidebar").tap()

        #expect(terminateCalls == 1)
    }

    @Test func rendersContentInsidePanel() throws {
        let controller = SidebarPanelController(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
            notificationCenter: NotificationCenter()
        )
        controller.pin()
        let contentView = try #require(controller.panel.contentView)

        contentView.layoutSubtreeIfNeeded()

        #expect(contentView.subviews.count == 1)
        #expect(contentView.subviews[0].frame == contentView.bounds)
    }
}
