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

    /// The sidebar never shows macOS's own prompt; the needsAccessibility status offers PermissionFlow instead.
    @Test func losingAccessibilityLetsGoOfNotificationCenterUntilItIsBack() throws {
        let harness = Harness()
        harness.monitor.start()
        defer { harness.monitor.stop() }
        let handler = try #require(harness.platform.handler)

        harness.platform.trusted = false
        harness.monitor.checkPermission()
        harness.monitor.checkPermission()
        #expect(harness.statuses == [.active, .needsAccessibility])
        #expect(harness.monitor.isWaitingForPermission)

        let banner = FakeElement.banner()
        harness.platform.windowsByPID[42] = [FakeElement.window(banner)]
        handler(banner)
        #expect(harness.received.isEmpty)

        harness.platform.trusted = true
        harness.monitor.checkPermission()
        #expect(harness.statuses == [.active, .needsAccessibility, .active])
        #expect(harness.platform.observedPIDs == [42, 42])
        #expect(harness.received.count == 1)
    }

    /// An attempt to attach again, after NotificationCenter exited or the Mac woke, that finds the permission
    /// gone says so and waits for it rather than retrying.
    @Test func attachingWithoutAccessibilityWaitsForIt() throws {
        let harness = Harness()
        harness.monitor.start()
        defer { harness.monitor.stop() }
        let exited = try #require(harness.platform.exitHandlers[42])
        exited()
        #expect(harness.monitor.isWaitingToReattach)

        harness.platform.trusted = false
        harness.workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        #expect(harness.statuses == [.active, .notificationCenterUnavailable, .needsAccessibility])
        #expect(!harness.monitor.isWaitingToReattach)
        #expect(harness.monitor.isWaitingForPermission)
    }

    @Test func checksNothingWhileStopped() {
        let harness = Harness()
        harness.platform.trusted = false

        harness.monitor.checkPermission()

        #expect(harness.statuses.isEmpty)
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

        let monitor = SidebarAppDelegate.makeMonitor(model: model, settings: settings, declaredChoices: .none, platform: platform)
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
            declaredChoices: .none,
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
    static let reply = NativeChoice(title: "Reply", textInput: NativeChoice.TextInput(placeholder: "Message", sendTitle: "Send"))

    /// A banner whose app declared a reply keeps offering it after timing out into the history, where the
    /// card's reply is written and sent on its entry.
    @Test func cardsAnswerBannersInTheHistory() throws {
        let directory = try TemporaryDirectory()
        let settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let platform = FakePlatform()
        let application = FakeElement()
        platform.applicationsByPID[42] = application
        platform.clock = FakeElement()
        platform.windowsByPID[42] = [FakeElement.window(FakeElement.replyBanner(id: "r", app: "Calendar"))]
        // Calendar declared a Reply that asks for text, as usernoted keeps it.
        let database = try NotificationDatabaseFixture()
        try database.create()
        let categories = try PropertyListSerialization.data(fromPropertyList: [[
            "id": "reply", "acts": [["id": "reply", "ti": "Reply", "st": 1, "tip": "Message", "tia": "Send"]],
        ]], format: .binary, options: 0)
        try database.execute("""
            CREATE TABLE categories (app_id INTEGER PRIMARY KEY, categories BLOB);
            INSERT INTO app VALUES (3, 'com.apple.iCal');
            INSERT INTO categories VALUES (3, x'\(categories.map { String(format: "%02x", $0) }.joined())');
            """)
        let declared = DeclaredChoices(database: database.database)
        let monitor = SidebarAppDelegate.makeMonitor(model: model, settings: settings, declaredChoices: declared, platform: platform)
        model.nativeNotifications = monitor
        monitor.start()
        defer { monitor.stop() }

        platform.windowsByPID[42] = [FakeElement.window()]
        monitor.notificationCenterChanged()
        let card = try #require(model.notifications.first)
        #expect(model.offeredChoices(of: card)?.choices == [Self.reply])

        model.reply("Reply", text: "On my way", for: card.id)
        #expect(model.answering == [card.id])
        let entry = FakeElement.replyBanner(id: "r", app: "Calendar")
        application.flags["AXExpanded"] = true
        platform.windowsByPID[42] = [FakeElement.window(entry)]
        monitor.stepHistory()

        #expect(entry.string("sent") == "On my way")
        #expect(entry.performed.filter { $0.hasPrefix("Name:Send") }.count == 1)
        #expect(platform.clock?.performed.count == 2)
        #expect(model.answering.isEmpty)
        #expect(model.notifications.isEmpty)
    }

    /// A notification on screen that refuses a choice fails it there; the history panel, which shares its
    /// window, is left alone.
    @Test func failsAChoiceTheNotificationRefusesOnScreen() {
        let harness = Harness()
        let clock = FakeElement()
        harness.platform.clock = clock
        let alert = FakeElement.alert(id: "a")
        alert.actionSucceeds = false
        harness.platform.windowsByPID[42] = [FakeElement.window(alert)]
        harness.monitor.start()
        defer { harness.monitor.stop() }
        var results: [Bool] = []

        harness.monitor.perform(.choice("Allow…"), on: ["a"], from: "Calendar") { results.append($0) }

        #expect(results == [false])
        #expect(alert.performed == ["Name:Allow…\nTarget:0x0\nSelector:(null)"])
        #expect(clock.performed.isEmpty)
        #expect(!harness.monitor.isOpeningHistory)
    }

    /// A choice the history no longer holds fails, and its card stops offering it but stays.
    @Test func forgetsChoicesTheHistoryNoLongerHolds() throws {
        // Recent: the model lists nothing older than its retention.
        var now = Date()
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let platform = FakePlatform()
        let application = FakeElement()
        platform.applicationsByPID[42] = application
        platform.clock = FakeElement()
        platform.windowsByPID[42] = [FakeElement.window(FakeElement.replyBanner(id: "gone"))]
        let interceptor = SystemNotificationInterceptor(
            now: { now },
            bundleIdentifier: { _ in "com.example.probe" },
            listsNotification: { model.lists(notification: $0) },
            listsChoices: { model.lists(choicesOf: $0) },
            declaredChoices: { _, _ in [Self.reply] },
            onPresentChoices: { model.presentChoices = $0 },
            onNotification: { model.add($0) }
        )
        let monitor = NotificationCenterMonitor(platform: platform, interceptor: interceptor, workspaceCenter: NotificationCenter(), now: { now }) { _ in }
        model.nativeNotifications = monitor
        monitor.start()
        defer { monitor.stop() }
        platform.windowsByPID[42] = [FakeElement.window()]
        monitor.notificationCenterChanged()
        #expect(model.presentChoices == ["gone"])
        let card = try #require(model.notifications.first)

        model.reply("Reply", text: "Too late", for: card.id)
        application.flags["AXExpanded"] = true
        monitor.stepHistory()
        // Past `listGrace`, within `timeout`; exactly `listGrace` may fall short of it this far from 2001.
        now += 1
        monitor.stepHistory()

        #expect(model.presentChoices.isEmpty)
        #expect(model.notifications.map(\.id) == [card.id])
        #expect(model.answering.isEmpty)
    }

    @Test func cardsActOnTheAlertsTheyStandFor() throws {
        let directory = try TemporaryDirectory()
        let settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let platform = FakePlatform()
        let first = FakeElement.alert(id: "first", title: "Standup")
        let second = FakeElement.alert(id: "second", title: "Review")
        let window = FakeElement.window(first, second)
        platform.windowsByPID[42] = [window]
        let monitor = SidebarAppDelegate.makeMonitor(model: model, settings: settings, declaredChoices: .none, platform: platform)
        model.nativeNotifications = monitor

        var unattached: [Bool] = []
        monitor.perform(.open, on: ["first"], from: "Calendar") { unattached.append($0) }
        #expect(unattached == [false])
        monitor.notificationsReleased()
        monitor.start()
        defer { monitor.stop() }

        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(model.presentChoices == ["first", "second"])
        let standup = try #require(model.notifications.first { $0.title == "Standup" })
        #expect(model.offeredChoices(of: standup)?.choices == ["Allow…"])

        model.choose("Allow…", for: standup.id)
        #expect(first.performed == ["Name:Allow…\nTarget:0x0\nSelector:(null)"])
        #expect(model.notifications.map(\.title) == ["Review"])

        model.dismiss(model.notifications[0].id)
        #expect(second.performed == ["Name:Close\nTarget:0x0\nSelector:(null)"])
        #expect(monitor.isSweeping)

        monitor.stop()
        #expect(model.presentChoices.isEmpty)
        #expect(window.position == .zero)
    }

    /// Wired up as the app does it, an alert the notification database listed first stays with macOS and its
    /// card offers no choices: the database cannot tell them.
    @Test func cardsWithoutAnAlertsChoicesLeaveItToMacOS() throws {
        let directory = try TemporaryDirectory()
        let settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let identities = NotificationIdentities()
        identities.insert("a")
        model.add(SidebarNotification(source: "Calendar", title: "Standup", bundleIdentifier: "com.apple.iCal", nativeIdentifiers: ["a"]))
        let platform = FakePlatform()
        let alert = FakeElement.alert(id: "a")
        let window = FakeElement.window(alert)
        platform.windowsByPID[42] = [window]
        let monitor = SidebarAppDelegate.makeMonitor(
            model: model, settings: settings, identities: identities, declaredChoices: .none, platform: platform, targetVisibleFrame: { nil }
        )
        model.nativeNotifications = monitor

        monitor.start()
        defer { monitor.stop() }

        #expect(window.moves.isEmpty)
        #expect(model.presentChoices.isEmpty)
        #expect(model.notifications.map(\.title) == ["Standup"])

        model.dismiss(model.notifications[0].id)
        #expect(alert.performed.isEmpty)
    }

    @Test func noAlertCanBeActedOnOnceNotificationCenterExits() {
        var present: [Set<String>] = []
        let platform = FakePlatform()
        platform.windowsByPID[42] = [FakeElement.window(FakeElement.alert(id: "a"))]
        let monitor = NotificationCenterMonitor(
            platform: platform,
            interceptor: SystemNotificationInterceptor(
                listsNotification: { _ in true }, listsChoices: { _ in true }, onPresentChoices: { present.append($0) }
            ) { _ in },
            workspaceCenter: NotificationCenter(),
            onStatus: { _ in }
        )
        monitor.start()
        defer { monitor.stop() }

        monitor.notificationCenterExited(pid: 42)

        #expect(present == [["a"], []])
        var detached: [Bool] = []
        monitor.perform(.choice("Allow…"), on: ["a"], from: "Calendar") { detached.append($0) }
        #expect(detached == [false])
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

    /// Attaching and stopping move the notifications' window back on screen, never the desktop widgets'.
    @Test func stopRestoresWindowsAndStopsListening() {
        let harness = Harness()
        let window = FakeElement.window()
        let widgets = FakeElement.widgetWindow(position: CGPoint(x: -1920, y: 0))
        harness.platform.windowsByPID[42] = [window, widgets]
        harness.monitor.start()
        window.position = SystemNotificationInterceptor.offScreen

        harness.monitor.stop()
        #expect(!harness.monitor.isSweeping)
        harness.workspaceCenter.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        #expect(window.position == .zero)
        #expect(widgets.moves.isEmpty)
        #expect(harness.platform.observedPIDs == [42])
    }

    /// A language read that fails, as one can while NotificationCenter is slow after a wake, keeps the words
    /// read before: English ones would leave every German notification to macOS for its unknown actions.
    /// Sweeps read the language again until it succeeds.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: NotificationCenterLabels.tableURL.path)))
    func keepsNotificationCentersWordsWhenItsLanguageDoesNotRead() {
        let harness = Harness()
        let application = FakeElement(["AXPreferredLanguage": "de"])
        harness.platform.applicationsByPID[42] = application
        harness.monitor.start()
        defer { harness.monitor.stop() }

        func banner(id: String, labels: NotificationCenterLabels) -> FakeElement {
            let banner = FakeElement.banner(id: id)
            banner.actions = [kAXPressAction] + [labels.showDetails, labels.close].map { "Name:\($0)\nTarget:0x0\nSelector:(null)" }
            return banner
        }
        let german = NotificationCenterLabels.load(language: "de")
        #expect(german.close != NotificationCenterLabels.english.close)

        application.attributes["AXPreferredLanguage"] = nil
        harness.workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        let window = FakeElement.window(banner(id: "de", labels: german))
        harness.platform.windowsByPID[42] = [window]
        harness.monitor.notificationCenterChanged()

        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(harness.received.map(\.shownByMacOS) == [false])

        application.attributes["AXPreferredLanguage"] = "ja"
        harness.platform.windowsByPID[42] = [FakeElement.window(banner(id: "ja", labels: NotificationCenterLabels.load(language: "ja")))]
        harness.monitor.notificationCenterChanged()
        #expect(harness.received.map(\.shownByMacOS) == [false, false])
    }

    /// A notification NotificationCenter still shows or hides is pressed where it is.
    @Test func opensNotificationsWhereNotificationCenterKeepsThem() {
        let harness = Harness()
        var results: [Bool] = []
        harness.monitor.perform(.open, on: ["b"], from: "Mail") { results.append($0) }
        let banner = FakeElement.banner(id: "b")
        harness.platform.windowsByPID[42] = [FakeElement.window(banner)]
        harness.monitor.start()
        defer { harness.monitor.stop() }

        harness.monitor.perform(.open, on: ["b"], from: "Mail") { results.append($0) }

        #expect(results == [false, true])
        #expect(banner.performed == [kAXPressAction])
        #expect(!harness.monitor.isOpeningHistory)
    }

    /// Any other notification is opened from the history: its steps replace the sweeps, which would move the
    /// panel's window back on screen, and sweeping resumes once the panel is closed.
    @Test func opensNotificationsFromTheHistoryInsteadOfSweeping() async throws {
        let harness = Harness()
        let application = FakeElement()
        harness.platform.applicationsByPID[42] = application
        let clock = FakeElement()
        harness.platform.clock = clock
        harness.monitor.start()
        defer { harness.monitor.stop() }
        var results: [Bool] = []

        harness.monitor.perform(.open, on: ["h"], from: "Vivaldi") { results.append($0) }
        #expect(clock.performed == [kAXPressAction])
        #expect(harness.monitor.isOpeningHistory)
        #expect(!harness.monitor.isSweeping)

        let entry = FakeElement.banner(id: "h", app: "Vivaldi")
        let panel = FakeElement.window(entry)
        application.flags["AXExpanded"] = true
        harness.platform.windowsByPID[42] = [panel]
        // The timer steps on its own; an event steps at once.
        for _ in 0..<200 where entry.performed.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(entry.performed == [kAXPressAction])
        #expect(results == [true])
        #expect(panel.position == SystemNotificationInterceptor.offScreen)
        #expect(clock.performed == [kAXPressAction, kAXPressAction])

        application.flags["AXExpanded"] = false
        let handler = try #require(harness.platform.handler)
        handler(panel)
        #expect(harness.monitor.isOpeningHistory)
        harness.now += NotificationHistoryOpener.closeGrace
        handler(panel)
        #expect(!harness.monitor.isOpeningHistory)
        #expect(harness.monitor.isSweeping)
        #expect(harness.received.map(\.nativeIdentifiers) == [["h"]])
    }

    /// A card clicked while another card's notification is being opened from the history waits for it, closing
    /// its panel included, and then opens the panel for its own notification; sweeping resumes after both.
    @Test func opensFromTheHistoryOneRequestAfterAnother() throws {
        let harness = Harness()
        let application = FakeElement()
        harness.platform.applicationsByPID[42] = application
        let clock = FakeElement()
        harness.platform.clock = clock
        harness.monitor.start()
        defer { harness.monitor.stop() }
        var results: [String] = []
        harness.monitor.perform(.open, on: ["a"], from: "Vivaldi") { results.append("a \($0)") }
        harness.monitor.perform(.open, on: ["b"], from: "Vivaldi") { results.append("b \($0)") }
        #expect(results.isEmpty)
        #expect(clock.performed == [kAXPressAction])
        let handler = try #require(harness.platform.handler)

        let first = FakeElement.banner(id: "a", app: "Vivaldi")
        let window = FakeElement.window(first)
        application.flags["AXExpanded"] = true
        harness.platform.windowsByPID[42] = [window]
        handler(window)
        #expect(results == ["a true"])
        application.flags["AXExpanded"] = false
        handler(window)
        harness.now += NotificationHistoryOpener.closeGrace
        handler(window)
        #expect(harness.monitor.isOpeningHistory)
        #expect(!harness.monitor.isSweeping)
        handler(window)
        #expect(clock.performed == [kAXPressAction, kAXPressAction, kAXPressAction])

        let second = FakeElement.banner(id: "b", app: "Vivaldi")
        let next = FakeElement.window(second)
        application.flags["AXExpanded"] = true
        harness.platform.windowsByPID[42] = [next]
        handler(next)
        #expect(second.performed == [kAXPressAction])
        #expect(results == ["a true", "b true"])
        #expect(next.position == SystemNotificationInterceptor.offScreen)
        application.flags["AXExpanded"] = false
        handler(next)
        harness.now += NotificationHistoryOpener.closeGrace
        handler(next)
        #expect(!harness.monitor.isOpeningHistory)
        #expect(harness.monitor.isSweeping)
    }

    /// The sidebar's own moves of NotificationCenter's window report `kAXWindowMoved` like NotificationCenter's;
    /// the sweep or history step such an event starts finds the window where it belongs and moves nothing.
    @Test func answersItsOwnWindowMovesWithoutMovingAgain() throws {
        let harness = Harness()
        let application = FakeElement()
        harness.platform.applicationsByPID[42] = application
        harness.platform.clock = FakeElement()
        let window = FakeElement.window(FakeElement.banner())
        harness.platform.windowsByPID[42] = [window]
        harness.monitor.start()
        defer { harness.monitor.stop() }
        let handler = try #require(harness.platform.handler)
        #expect(window.moves == [SystemNotificationInterceptor.offScreen])

        handler(window)
        #expect(window.moves == [SystemNotificationInterceptor.offScreen])

        harness.monitor.perform(.open, on: ["h"], from: "Vivaldi") { _ in }
        let panel = FakeElement.window()
        application.flags["AXExpanded"] = true
        harness.platform.windowsByPID[42] = [panel]
        handler(panel)
        #expect(panel.moves == [SystemNotificationInterceptor.offScreen])
        handler(panel)
        #expect(panel.moves == [SystemNotificationInterceptor.offScreen])
    }

    /// A request that runs out of time with the panel open keeps the sweeps away until the panel has closed:
    /// a sweep would move the closing panel back on screen.
    @Test func keepsSweepsAwayWhileThePanelCloses() throws {
        let harness = Harness()
        let application = FakeElement()
        harness.platform.applicationsByPID[42] = application
        let clock = FakeElement()
        harness.platform.clock = clock
        harness.monitor.start()
        defer { harness.monitor.stop() }
        var results: [Bool] = []
        harness.monitor.perform(.open, on: ["h"], from: "Vivaldi") { results.append($0) }
        let handler = try #require(harness.platform.handler)

        let panel = FakeElement.window()
        application.flags["AXExpanded"] = true
        harness.platform.windowsByPID[42] = [panel]
        harness.now += NotificationHistoryOpener.timeout
        handler(panel)
        #expect(results == [false])
        #expect(clock.performed == [kAXPressAction, kAXPressAction])

        harness.now += NotificationHistoryOpener.closeTimeout / 2
        handler(panel)
        #expect(panel.position == SystemNotificationInterceptor.offScreen)
        #expect(harness.monitor.isOpeningHistory)
        #expect(!harness.monitor.isSweeping)

        application.flags["AXExpanded"] = false
        handler(panel)
        harness.now += NotificationHistoryOpener.closeGrace
        handler(panel)
        #expect(!harness.monitor.isOpeningHistory)
        #expect(harness.monitor.isSweeping)
    }

    /// A panel that opens after its request gave up is handed back to the history opener by the next sweep,
    /// which would otherwise leave it open on screen: it is hidden and closed, and sweeping resumes after.
    @Test func closesAPanelThatOpensAfterTheRequestGaveUp() throws {
        let harness = Harness()
        let application = FakeElement()
        harness.platform.applicationsByPID[42] = application
        let clock = FakeElement()
        harness.platform.clock = clock
        harness.monitor.start()
        defer { harness.monitor.stop() }
        var results: [Bool] = []
        harness.monitor.perform(.open, on: ["h"], from: "Vivaldi") { results.append($0) }
        let handler = try #require(harness.platform.handler)

        harness.now += NotificationHistoryOpener.timeout
        let window = FakeElement.window()
        handler(window)
        #expect(results == [false])
        #expect(!harness.monitor.isOpeningHistory)
        #expect(harness.monitor.isSweeping)

        application.flags["AXExpanded"] = true
        harness.platform.windowsByPID[42] = [window]
        handler(window)
        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(clock.performed == [kAXPressAction, kAXPressAction])
        #expect(harness.monitor.isOpeningHistory)
        #expect(!harness.monitor.isSweeping)

        application.flags["AXExpanded"] = false
        handler(window)
        harness.now += NotificationHistoryOpener.closeGrace
        handler(window)
        #expect(!harness.monitor.isOpeningHistory)
        #expect(harness.monitor.isSweeping)
        #expect(results == [false])
    }

    /// NotificationCenter exiting abandons the history request; its panel went with it, so the clock is not
    /// pressed again, which would open the next NotificationCenter's panel.
    @Test func stopsOpeningTheHistoryWhenDetached() {
        let harness = Harness()
        let clock = FakeElement()
        harness.platform.clock = clock
        let application = FakeElement()
        harness.platform.applicationsByPID[42] = application
        harness.monitor.start()
        var results: [Bool] = []

        harness.monitor.perform(.open, on: ["h"], from: "Vivaldi") { results.append($0) }
        application.flags["AXExpanded"] = true
        harness.monitor.notificationCenterExited(pid: 42)
        harness.monitor.stepHistory()

        #expect(!harness.monitor.isOpeningHistory)
        #expect(results == [false])
        #expect(clock.performed == [kAXPressAction])
        harness.monitor.stop()
    }

    /// Stopping, as on quit or when replace_system is switched off, closes the panel a request opened before
    /// it moves NotificationCenter's window back on screen, so the panel does not stay open there.
    @Test func stoppingClosesTheHistoryPanelItOpened() {
        let harness = Harness()
        let clock = FakeElement()
        harness.platform.clock = clock
        let application = FakeElement()
        harness.platform.applicationsByPID[42] = application
        harness.monitor.start()
        var results: [Bool] = []
        harness.monitor.perform(.open, on: ["h"], from: "Vivaldi") { results.append($0) }
        let panel = FakeElement.window()
        application.flags["AXExpanded"] = true
        harness.platform.windowsByPID[42] = [panel]
        harness.monitor.stepHistory()
        #expect(panel.position == SystemNotificationInterceptor.offScreen)

        harness.monitor.stop()

        #expect(!harness.monitor.isOpeningHistory)
        #expect(results == [false])
        #expect(clock.performed == [kAXPressAction, kAXPressAction])
        #expect(panel.position == .zero)
    }

    /// Without a clock to press, the card's own action runs at once.
    @Test func failsAtOnceWithoutAClock() {
        let harness = Harness()
        harness.monitor.start()
        defer { harness.monitor.stop() }
        var results: [Bool] = []

        harness.monitor.perform(.open, on: ["h"], from: "Vivaldi") { results.append($0) }

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
        let trusted = platform.isTrusted()
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
        #expect(!element.setValue("text"))
    }
}
