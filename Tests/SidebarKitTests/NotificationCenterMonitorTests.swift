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
    /// for `settleDuration`, and give up after `maxSweepDuration`. A banner without an identifier is closed.
    @Test func keepsSweepingUntilNotificationCenterSettles() throws {
        let harness = Harness()
        let banner = FakeElement.banner(id: nil)
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
        #expect(Set(model.notifications.map(\.nativeIdentifiers)) == [["z"], ["m"]])
        #expect(zoom.performed.isEmpty)
        // Hidden but left open, so that its card can open it.
        #expect(mail.performed.isEmpty)
    }

    /// A window holding a native notification moves left of a right-side sidebar, so the sidebar does not
    /// cover it, follows the sidebar's width, and returns to the origin when the sidebar moves to the left.
    @Test func defaultMonitorKeepsNativeNotificationsBesideTheSidebar() throws {
        let directory = try TemporaryDirectory()
        let settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        settings.update { $0.sidebar = .init(side: .right, width: 300) }
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let platform = FakePlatform()
        let banner = FakeElement.banner(id: "s", app: "Calendar", title: "Standup")
        banner.actions.append("Name:Snooze\nTarget:0x0\nSelector:(null)")
        let window = FakeElement.window(banner)
        platform.windowsByPID[42] = [window]
        let monitor = SidebarAppDelegate.makeMonitor(
            model: model,
            settings: settings,
            platform: platform,
            targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1920, height: 1050) }
        )

        monitor.start()
        defer { monitor.stop() }
        #expect(window.position == CGPoint(x: -300, y: 0))

        settings.update { $0.sidebar.width = 400 }
        monitor.refresh()
        #expect(window.position == CGPoint(x: -400, y: 0))

        settings.update { $0.sidebar.side = .left }
        monitor.refresh()
        #expect(window.position == .zero)

        monitor.stop()
        window.position = CGPoint(x: -400, y: 0)
        monitor.refresh()
        #expect(window.moves == [CGPoint(x: -300, y: 0), CGPoint(x: -400, y: 0), .zero])
    }

    /// Wired up as the app does it, an alert with choices gets a card that offers them; performing one
    /// acts on the alert, and dismissing the card closes the alert. Without NotificationCenter, nothing can.
    @Test func cardsActOnTheAlertsTheyStandFor() throws {
        let directory = try TemporaryDirectory()
        let settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let platform = FakePlatform()
        let first = FakeElement.alert(id: "first", title: "Standup")
        let second = FakeElement.alert(id: "second", title: "Review")
        let window = FakeElement.window(first, second)
        platform.windowsByPID[42] = [window]
        let monitor = SidebarAppDelegate.makeMonitor(model: model, settings: settings, platform: platform)
        model.alerts = monitor

        #expect(!monitor.perform(.open, onAlert: "first"))
        monitor.notificationsReleased()
        monitor.start()
        defer { monitor.stop() }

        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(model.presentAlerts == ["first", "second"])
        let standup = try #require(model.notifications.first { $0.title == "Standup" })
        #expect(model.presentAlert(of: standup)?.choices == ["Allow…"])

        model.choose("Allow…", for: standup.id)
        #expect(first.performed == ["Name:Allow…\nTarget:0x0\nSelector:(null)"])
        #expect(model.notifications.map(\.title) == ["Review"])

        model.dismiss(model.notifications[0].id)
        #expect(second.performed == ["Name:Close\nTarget:0x0\nSelector:(null)"])
        #expect(monitor.isSweeping)

        monitor.stop()
        #expect(model.presentAlerts.isEmpty)
        #expect(window.position == .zero)
    }

    @Test func noAlertCanBeActedOnOnceNotificationCenterExits() {
        var present: [Set<String>] = []
        let platform = FakePlatform()
        platform.windowsByPID[42] = [FakeElement.window(FakeElement.alert(id: "a"))]
        let monitor = NotificationCenterMonitor(
            platform: platform,
            interceptor: SystemNotificationInterceptor(listsNotification: { _ in true }, onPresentAlerts: { present.append($0) }) { _ in },
            workspaceCenter: NotificationCenter(),
            onStatus: { _ in }
        )
        monitor.start()
        defer { monitor.stop() }

        monitor.notificationCenterExited(pid: 42)

        #expect(present == [["a"], []])
        #expect(!monitor.perform(.choice("Allow…"), onAlert: "a"))
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

    /// A notification NotificationCenter still shows or hides is pressed where it is.
    @Test func opensNotificationsWhereNotificationCenterKeepsThem() {
        let harness = Harness()
        var results: [Bool] = []
        harness.monitor.open(["b"], from: "Mail") { results.append($0) }
        let banner = FakeElement.banner(id: "b")
        harness.platform.windowsByPID[42] = [FakeElement.window(banner)]
        harness.monitor.start()
        defer { harness.monitor.stop() }

        harness.monitor.open(["b"], from: "Mail") { results.append($0) }

        #expect(results == [false, true])
        #expect(banner.performed == [kAXPressAction])
        #expect(!harness.monitor.isOpeningHistory)
    }

    /// Any other notification is opened from the history: its steps replace the sweeps, which would move the
    /// panel's window back on screen, and sweeping resumes once the panel is closed. Meanwhile another
    /// request fails at once.
    @Test func opensNotificationsFromTheHistoryInsteadOfSweeping() async throws {
        let harness = Harness()
        let application = FakeElement()
        harness.platform.applicationsByPID[42] = application
        let clock = FakeElement()
        harness.platform.clock = clock
        harness.monitor.start()
        defer { harness.monitor.stop() }
        var results: [Bool] = []

        harness.monitor.open(["h"], from: "Vivaldi") { results.append($0) }
        #expect(clock.performed == [kAXPressAction])
        #expect(harness.monitor.isOpeningHistory)
        #expect(!harness.monitor.isSweeping)
        harness.monitor.open(["other"], from: "Vivaldi") { results.append($0) }
        #expect(results == [false])

        let entry = FakeElement.banner(id: "h", app: "Vivaldi")
        let panel = FakeElement.window(entry)
        application.flags["AXExpanded"] = true
        harness.platform.windowsByPID[42] = [panel]
        // The timer steps on its own; an event steps at once.
        for _ in 0..<200 where entry.performed.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(entry.performed == [kAXPressAction])
        #expect(results == [false, true])
        #expect(panel.position == SystemNotificationInterceptor.offScreen)
        #expect(clock.performed == [kAXPressAction, kAXPressAction])

        application.flags["AXExpanded"] = false
        let handler = try #require(harness.platform.handler)
        handler(panel)
        #expect(!harness.monitor.isOpeningHistory)
        #expect(harness.monitor.isSweeping)
        #expect(harness.received.map(\.nativeIdentifiers) == [["h"]])
    }

    /// Stopping, or NotificationCenter exiting, abandons the history request.
    @Test func stopsOpeningTheHistoryWhenDetached() {
        let harness = Harness()
        harness.platform.clock = FakeElement()
        harness.monitor.start()
        var results: [Bool] = []

        harness.monitor.open(["h"], from: "Vivaldi") { results.append($0) }
        harness.monitor.notificationCenterExited(pid: 42)
        harness.monitor.stepHistory()

        #expect(!harness.monitor.isOpeningHistory)
        #expect(results == [false])
        harness.monitor.stop()
    }

    /// Without a clock to press, the card's own action runs at once.
    @Test func failsAtOnceWithoutAClock() {
        let harness = Harness()
        harness.monitor.start()
        defer { harness.monitor.stop() }
        var results: [Bool] = []

        harness.monitor.open(["h"], from: "Vivaldi") { results.append($0) }

        #expect(results == [false])
        #expect(!harness.monitor.isOpeningHistory)
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

    /// The clock is the one menu extra with its identifier; the test process may lack the permission to see it.
    @Test func findsTheMenuBarClock() {
        let clock = platform.menuBarClock()

        #expect(clock == nil || clock?.string(kAXIdentifierAttribute) == SystemAccessibility.clockIdentifier)
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
