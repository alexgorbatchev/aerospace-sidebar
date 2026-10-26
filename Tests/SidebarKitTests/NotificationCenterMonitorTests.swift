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

    @Test func attachesOnceAccessibilityIsGrantedLater() async throws {
        let platform = FakePlatform()
        platform.trusted = false
        var statuses: [InterceptionStatus] = []
        let monitor = NotificationCenterMonitor(
            platform: platform,
            interceptor: SystemNotificationInterceptor { _ in },
            workspaceCenter: NotificationCenter(),
            permissionPollInterval: 0.01,
            onStatus: { statuses.append($0) }
        )
        monitor.start()
        defer { monitor.stop() }

        platform.trusted = true
        for _ in 0..<200 where statuses.last != .active {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(statuses == [.needsAccessibility, .active])
        #expect(platform.observedPIDs == [42])
    }

    @Test func defaultMonitorWiresSettingsAndModel() throws {
        let directory = try TemporaryDirectory()
        let settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        settings.update { $0.notifications.appsLeftToMacOS = ["zoom.us"] }
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let platform = FakePlatform()
        let zoom = FakeElement.banner(id: "z", app: "zoom.us", title: "Meeting")
        let mail = FakeElement.banner(id: "m", app: "Mail", title: "Lunch")
        platform.windowsByPID[42] = [FakeElement.window(zoom), FakeElement.window(mail)]

        let monitor = SidebarAppDelegate.makeMonitor(model: model, settings: settings, platform: platform)
        monitor.start()
        defer { monitor.stop() }

        #expect(model.interception == .active)
        #expect(Set(model.notifications.map { "\($0.title):\($0.shownByMacOS)" }) == ["Meeting:true", "Lunch:false"])
        #expect(zoom.performed.isEmpty)
        #expect(mail.performed.count == 1)
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

/// Read-only checks against the real Accessibility API, using the Dock because every logged-in
/// session runs it. Assertions hold whether or not the test process has the Accessibility
/// permission; nothing here moves or closes real windows.
@MainActor
struct SystemAccessibilityTests {
    let platform = SystemAccessibility()

    nonisolated static var dockPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    }

    @Test(.enabled(if: dockPID != nil, "requires a logged-in session"))
    func readsRunningAppWithOrWithoutPermission() throws {
        let pid = try #require(Self.dockPID)
        let trusted = platform.isTrusted(prompt: false)
        let application = AXElement(AXUIElementCreateApplication(pid))

        #expect(application.string(kAXRoleAttribute) == (trusted ? kAXApplicationRole : nil))
        #expect(application.children.isEmpty == !trusted)
        _ = application.actionNames
        if trusted {
            _ = application.position
        } else {
            #expect(application.position == nil)
            #expect(platform.windows(ofProcess: pid).isEmpty)
        }
        let observation = platform.observe(process: pid) { _ in }
        if trusted {
            #expect(observation != nil)
        }
    }

    @Test func findsNotificationCenterProcess() {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: NotificationCenterMonitor.notificationCenterBundleID
        ).first

        #expect(platform.notificationCenterPID() == running?.processIdentifier)
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
