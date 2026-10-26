import AppKit
import ApplicationServices
@testable import SidebarKit
import Testing

@MainActor
struct NotificationCenterMonitorTests {
    final class Harness {
        let platform = FakePlatform()
        let workspaceCenter = NotificationCenter()
        var statuses: [InterceptionStatus] = []
        var received: [SidebarNotification] = []
        var monitor: NotificationCenterMonitor!

        @MainActor init() {
            let interceptor = SystemNotificationInterceptor { [unowned self] in received.append($0) }
            monitor = NotificationCenterMonitor(
                platform: platform,
                interceptor: interceptor,
                workspaceCenter: workspaceCenter,
                onStatus: { [unowned self] in statuses.append($0) }
            )
        }
    }

    @Test func attachesRestoresAndProcessesExistingWindows() {
        let harness = Harness()
        let hidden = FakeElement.window(FakeElement.banner(), position: SystemNotificationInterceptor.offScreen)
        harness.platform.windowsByPID[42] = [hidden]

        harness.monitor.start()

        #expect(harness.platform.promptRequests.first == true)
        #expect(harness.platform.observedPIDs == [42])
        #expect(harness.statuses == [.active])
        #expect(hidden.moves == [.zero, SystemNotificationInterceptor.offScreen])
        #expect(harness.received.count == 1)
    }

    @Test func forwardsObservedElementsToInterceptor() throws {
        let harness = Harness()
        harness.monitor.start()

        let handler = try #require(harness.platform.handler)
        handler(FakeElement.window(FakeElement.banner()))

        #expect(harness.received.count == 1)
    }

    @Test func waitsForAccessibilityPermission() {
        let harness = Harness()
        harness.platform.trusted = false

        harness.monitor.start()
        harness.monitor.checkPermission()
        #expect(harness.statuses == [.needsAccessibility])
        #expect(harness.platform.observedPIDs.isEmpty)

        harness.platform.trusted = true
        harness.monitor.checkPermission()
        #expect(harness.statuses == [.needsAccessibility, .active])
        harness.monitor.stop()
    }

    @Test func reportsMissingNotificationCenter() {
        let harness = Harness()
        harness.platform.pid = nil

        harness.monitor.start()

        #expect(harness.statuses == [.notificationCenterUnavailable])
    }

    @Test func reportsRefusedObserver() {
        let harness = Harness()
        harness.platform.observeSucceeds = false

        harness.monitor.start()

        #expect(harness.statuses == [.notificationCenterUnavailable])
    }

    @Test(.enabled(if: !NSRunningApplication.runningApplications(withBundleIdentifier: NotificationCenterMonitor.notificationCenterBundleID).isEmpty))
    func reattachesWhenNotificationCenterRelaunches() throws {
        let harness = Harness()
        harness.monitor.start()
        harness.platform.pid = 99
        let notificationCenter = try #require(NSRunningApplication.runningApplications(
            withBundleIdentifier: NotificationCenterMonitor.notificationCenterBundleID
        ).first)

        harness.workspaceCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
        )
        harness.workspaceCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: notificationCenter]
        )

        #expect(harness.platform.observedPIDs == [42, 99])
    }

    @Test func stopRestoresWindowsAndStopsListening() {
        let harness = Harness()
        let window = FakeElement(position: SystemNotificationInterceptor.offScreen)
        harness.platform.windowsByPID[42] = [window]
        harness.monitor.start()

        harness.monitor.stop()
        harness.workspaceCenter.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        #expect(window.position == .zero)
        #expect(harness.platform.observedPIDs == [42])
    }
}

/// Read-only checks against the real Accessibility API. Assertions hold whether or not the test
/// process has the Accessibility permission; nothing here moves or closes real windows.
@MainActor
struct SystemAccessibilityTests {
    let platform = SystemAccessibility()

    @Test(.enabled(if: !NSRunningApplication.runningApplications(withBundleIdentifier: NotificationCenterMonitor.notificationCenterBundleID).isEmpty))
    func readsNotificationCenter() throws {
        let pid = try #require(platform.notificationCenterPID())
        let trusted = platform.isTrusted(prompt: false)
        let application = AXElement(AXUIElementCreateApplication(pid))

        #expect(application.string(kAXRoleAttribute) == (trusted ? kAXApplicationRole : nil))
        for window in platform.windows(ofProcess: pid) {
            #expect(window.position != nil)
            _ = window.children
            _ = window.actionNames
        }
        if trusted {
            #expect(platform.observe(process: pid) { _ in } != nil)
        }
    }

    @Test func refusesInvalidProcess() {
        let element = AXElement(AXUIElementCreateApplication(-1))

        #expect(platform.windows(ofProcess: -1).isEmpty)
        #expect(platform.observe(process: -1) { _ in } == nil)
        #expect(element.string(kAXRoleAttribute) == nil)
        #expect(element.actionNames.isEmpty)
        #expect(!element.perform(kAXPressAction))
        #expect(!element.setPosition(.zero))
    }
}
