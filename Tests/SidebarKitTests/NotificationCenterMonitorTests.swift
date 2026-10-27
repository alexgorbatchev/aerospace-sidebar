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
        var now = Date(timeIntervalSince1970: 0)
        var monitor: NotificationCenterMonitor!

        @MainActor init() {
            let interceptor = SystemNotificationInterceptor(now: { [unowned self] in now }) { [unowned self] in received.append($0) }
            monitor = NotificationCenterMonitor(
                platform: platform,
                interceptor: interceptor,
                workspaceCenter: workspaceCenter,
                now: { [unowned self] in now },
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

    /// The element an event names may be the banner or its list rather than the window, so every event
    /// sweeps NotificationCenter's windows.
    @Test func eventsSweepNotificationCenterWindows() throws {
        let harness = Harness()
        harness.monitor.start()
        defer { harness.monitor.stop() }
        let banner = FakeElement.banner()
        let window = FakeElement.window(banner)
        harness.platform.windowsByPID[42] = [window]

        let handler = try #require(harness.platform.handler)
        handler(banner)

        #expect(harness.received.count == 1)
        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(harness.monitor.isSweeping)
    }

    /// Sweeps repeat while a notification is still closing, stop once NotificationCenter has been quiet
    /// for `settleDuration`, and give up after `maxSweepDuration`.
    @Test func keepsSweepingUntilNotificationCenterSettles() throws {
        let harness = Harness()
        let banner = FakeElement.banner()
        harness.platform.windowsByPID[42] = [FakeElement.window(banner)]
        harness.monitor.start()
        defer { harness.monitor.stop() }
        #expect(banner.performed.count == 1)

        harness.now += NotificationCenterMonitor.settleDuration
        harness.monitor.sweepAgain()
        #expect(banner.performed.count == 2)
        #expect(harness.monitor.isSweeping)

        harness.now += NotificationCenterMonitor.maxSweepDuration
        harness.monitor.sweepAgain()
        #expect(!harness.monitor.isSweeping)

        harness.platform.windowsByPID[42] = []
        harness.monitor.notificationCenterChanged()
        harness.monitor.sweepAgain()
        #expect(harness.monitor.isSweeping)
        harness.now += NotificationCenterMonitor.settleDuration
        harness.monitor.sweepAgain()
        #expect(!harness.monitor.isSweeping)
    }

    @Test func leavesTheHistoryPanelAlone() {
        let harness = Harness()
        let application = FakeElement()
        application.flags["AXExpanded"] = true
        harness.platform.applicationsByPID[42] = application
        let banner = FakeElement.banner()
        let window = FakeElement.window(banner, position: SystemNotificationInterceptor.offScreen)
        harness.platform.windowsByPID[42] = [window]

        harness.monitor.start()
        defer { harness.monitor.stop() }

        #expect(banner.performed.isEmpty)
        #expect(harness.received.isEmpty)
        #expect(window.position == .zero)
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

    @Test func reportsMissingNotificationCenterAndRetries() {
        let harness = Harness()
        harness.platform.pid = nil

        harness.monitor.start()

        #expect(harness.statuses == [.notificationCenterUnavailable])
        #expect(harness.monitor.isWaitingToReattach)
        harness.monitor.stop()
        #expect(!harness.monitor.isWaitingToReattach)
    }

    @Test func reportsRefusedObserver() {
        let harness = Harness()
        harness.platform.observeSucceeds = false

        harness.monitor.start()
        defer { harness.monitor.stop() }

        #expect(harness.statuses == [.notificationCenterUnavailable])
        #expect(harness.monitor.isWaitingToReattach)
    }

    /// Launch notifications alone miss NotificationCenter relaunches, so its exit is watched and the
    /// monitor attaches to the next NotificationCenter process.
    @Test func reattachesAfterNotificationCenterExits() async throws {
        let platform = FakePlatform()
        var statuses: [InterceptionStatus] = []
        let monitor = NotificationCenterMonitor(
            platform: platform,
            interceptor: SystemNotificationInterceptor { _ in },
            workspaceCenter: NotificationCenter(),
            initialReattachDelay: 0.01,
            onStatus: { statuses.append($0) }
        )
        monitor.start()
        defer { monitor.stop() }

        monitor.notificationCenterExited(pid: 7)
        #expect(statuses == [.active])

        platform.pid = 99
        let exited = try #require(platform.exitHandlers[42])
        exited()
        #expect(statuses == [.active, .notificationCenterUnavailable])
        #expect(monitor.isWaitingToReattach)
        for _ in 0..<200 where statuses.last != .active {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(statuses == [.active, .notificationCenterUnavailable, .active])
        #expect(platform.observedPIDs == [42, 99])
        #expect(!monitor.isWaitingToReattach)
    }

    @Test func attachesAgainAfterWake() {
        let harness = Harness()
        harness.monitor.start()
        defer { harness.monitor.stop() }

        harness.workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        #expect(harness.platform.observedPIDs == [42, 42])
    }

    @Test func waitsForPermissionRatherThanWakeOrLaunch() {
        let harness = Harness()
        harness.platform.trusted = false
        harness.monitor.start()
        defer { harness.monitor.stop() }

        harness.workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        #expect(harness.statuses == [.needsAccessibility])
        #expect(harness.platform.observedPIDs.isEmpty)
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
        #expect(!harness.monitor.isSweeping)
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
        #expect(application.bool(kAXRoleAttribute) == nil)
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

    @Test func reportsWhenAProcessExits() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        var exited = false
        let watch = platform.watchExit(of: process.processIdentifier) { exited = true }
        #expect(watch != nil)

        process.terminate()
        for _ in 0..<200 where !exited {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(exited)
        #expect(platform.watchExit(of: -1) { } == nil)
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
        #expect(platform.application(ofProcess: -1)?.bool("AXExpanded") == nil)
        #expect(element.string(kAXRoleAttribute) == nil)
        #expect(element.actionNames.isEmpty)
        #expect(!element.perform(kAXPressAction))
        #expect(!element.setPosition(.zero))
    }
}
