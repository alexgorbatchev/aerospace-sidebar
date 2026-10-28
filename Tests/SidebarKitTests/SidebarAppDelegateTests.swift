import AppKit
@testable import SidebarKit
import SidebarProtocol
import Testing

@MainActor
@Suite(.leavesDesktopAlone)
struct SidebarAppDelegateTests {
    let directory: TemporaryDirectory
    let settings: SettingsStore
    let platform = FakePlatform()
    let permissions = FakePermissions()
    let cli = FakeAeroSpaceCLI()
    let database: NotificationDatabaseFixture
    /// Kept in the fixture's defaults domain, never `UserDefaults.standard`.
    let identities: NotificationIdentities

    init() throws {
        _ = NSApplication.shared
        directory = try TemporaryDirectory()
        settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        database = try NotificationDatabaseFixture()
        identities = NotificationIdentities(defaults: database.defaults)
    }

    /// Reads a database in the test's directory, never the real one.
    /// Keeps the record id in the fixture's defaults domain; the delegate hands it the fixture's database.
    func makeDatabaseMonitor(_ model: SidebarModel, _ identities: NotificationIdentities, _ database: NotificationDatabase) -> NotificationDatabaseMonitor {
        SidebarAppDelegate.makeDatabaseMonitor(model: model, identities: identities, database: database, defaults: self.database.defaults)
    }

    /// Edits a config in the test's directory, never the real AeroSpace config.
    func makeAeroSpaceSync(_ settings: SettingsStore) -> AeroSpaceSync {
        .fake(store: settings, home: directory.url, cli: cli)
    }

    func makeDelegate(socketPath: String = ControlServerTests.socketPath(), sender: String? = "Safari") -> SidebarAppDelegate {
        SidebarAppDelegate(
            settings: settings,
            makeModel: { SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(), history: $0.history) },
            icons: .vendored,
            identities: identities,
            notificationDatabase: database.database,
            makeController: { model, settings, openSettings, setUp in
                SidebarPanelController.forTesting(
                    model: model,
                    settings: settings,
                    targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
                    notificationCenter: NotificationCenter(),
                    openSettings: openSettings,
                    setUp: setUp
                )
            },
            makeMonitor: { [platform] model, settings, identities in
                NotificationCenterMonitor(
                    platform: platform,
                    interceptor: SystemNotificationInterceptor(
                        identities: identities,
                        leavesToMacOS: { settings.settings.notifications.leavesToMacOS($0) },
                        // Stands in for the screen geometry: native notifications move left by the width.
                        nativeOrigin: { CGPoint(x: -CGFloat(settings.settings.sidebar.width), y: 0) },
                        onNotification: { model.add($0) }
                    ),
                    workspaceCenter: NotificationCenter(),
                    onStatus: { model.interception = $0 }
                )
            },
            makeDatabaseMonitor: makeDatabaseMonitor,
            makeServer: { SidebarAppDelegate.makeServer(model: $0, icons: $1, path: socketPath) },
            makeAeroSpaceSync: makeAeroSpaceSync,
            makeOnboarding: { [permissions] _ in OnboardingModel(permissions: permissions, loginItems: FakeLoginItems()) },
            makeSettingsWindow: { store, aeroSpace, onboarding, model in
                SettingsWindowController.forTesting(store: store, onboarding: onboarding, aeroSpace: aeroSpace, history: { model.received })
            },
            urlSender: { sender }
        )
    }

    /// Text fields get ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V and ⌘A only from main menu items, which an `LSUIElement` app
    /// has none of until it builds them; ⌘Q stays with Settings › General.
    @Test func launchingInstallsTheEditMenusKeyEquivalents() throws {
        let delegate = makeDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        let items = try #require(NSApplication.shared.mainMenu).items.flatMap { $0.submenu?.items ?? [] }
        let actions = Dictionary(items.filter { !$0.keyEquivalent.isEmpty }.map { ($0.keyEquivalent, $0.action) }) { first, _ in first }
        #expect(actions == [
            "z": Selector(("undo:")), "Z": Selector(("redo:")), "x": #selector(NSText.cut(_:)),
            "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)), "a": #selector(NSText.selectAll(_:)),
        ])
        #expect(items.allSatisfy { $0.target == nil && $0.keyEquivalentModifierMask == .command })
    }

    @Test func launchingPinsSidebarStartsInterceptionAndControlSocket() async throws {
        let path = ControlServerTests.socketPath()
        platform.windowsByPID[42] = [FakeElement.window(FakeElement.banner(app: "Mail"))]
        let delegate = makeDelegate(socketPath: path)

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let payload = try NotificationPayload(title: "from cli", severity: .critical, icon: "ghostty")
        let response = try await UnixSocket.exchange(.pushNotification(payload), path: path)

        #expect(try #require(delegate.controller).panel.isVisible)
        #expect(delegate.model.interception == .active)
        #expect(response == ControlResponse(error: nil))
        #expect(delegate.model.notifications.map(\.source) == ["aerospace-sidebar", "Mail"])
        #expect(delegate.model.notifications.map(\.icon?.id) == ["ghostty", nil])
        #expect(delegate.model.alerts === delegate.monitor)

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(delegate.monitor?.isRunning == false)
    }

    /// The database source runs while macOS notifications are replaced, and stops with interception.
    @Test func readsTheNotificationDatabaseWhileReplacingNotifications() throws {
        try database.create()
        let delegate = makeDelegate()

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(delegate.model.database == .reading)

        settings.update { $0.notifications.replaceSystem = false }
        #expect(delegate.model.database == .stopped)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }

    /// The sidebar's Set Up… shows the Permissions steps and starts the one it asks for, with PermissionFlow's
    /// drag panel flying from the button.
    @Test func setUpShowsPermissionsAndStartsTheStep() throws {
        let delegate = makeDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        let button = CGRect(x: 1200, y: 840, width: 70, height: 22)

        delegate.setUp(.fullDiskAccess, from: button)

        let window = try #require(delegate.settingsWindow)
        defer { window.window.orderOut(nil) }
        #expect(window.window.isVisible)
        #expect(window.navigation.selection == .permissions)
        #expect(permissions.authorized == [.fullDiskAccess])
        #expect(permissions.sourceFrames == [button])
    }

    /// Settings › Permissions checks Full Disk Access on the database the monitor reads.
    @Test func onboardingChecksTheDatabaseTheMonitorReads() throws {
        let delegate = SidebarAppDelegate(
            settings: settings,
            makeModel: { SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(), history: $0.history) },
            identities: identities,
            notificationDatabase: database.database,
            makeAeroSpaceSync: makeAeroSpaceSync
        )
        // A database that does not exist says nothing about the permission.
        #expect(delegate.onboarding.fullDiskAccess == .unknown)

        try database.create()
        delegate.onboarding.refresh()

        #expect(delegate.onboarding.fullDiskAccess == .granted)
    }

    /// Removing a permission in Settings takes effect at once, rather than at the next poll or notification.
    @Test func removingAPermissionChecksItAtOnce() async throws {
        try database.create()
        permissions.states = [.accessibility: .granted]
        let delegate = makeDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        #expect(delegate.model.interception == .active)

        platform.trusted = false
        await delegate.onboarding.removeAccessibility()

        #expect(delegate.model.interception == .needsAccessibility)
        #expect(delegate.model.database == .reading)
    }

    @Test func settingsTurnInterceptionOffAndOnAndApplyHistory() throws {
        let delegate = makeDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        settings.update { $0.notifications.replaceSystem = false; $0.history.maxCount = 50 }
        #expect(delegate.monitor?.isRunning == false)
        #expect(delegate.model.interception == .disabled)
        #expect(delegate.model.history.maxCount == 50)

        settings.update { $0.notifications.replaceSystem = true }
        #expect(delegate.monitor?.isRunning == true)
        #expect(delegate.model.interception == .active)
    }

    @Test func appsLeftToMacOSStayNative() throws {
        settings.update { $0.notifications.appsLeftToMacOS = ["zoom.us"] }
        let banner = FakeElement.banner(app: "zoom.us", title: "Meeting")
        platform.windowsByPID[42] = [FakeElement.window(banner)]
        let delegate = makeDelegate()

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        #expect(banner.performed.isEmpty)
        #expect(delegate.model.notifications.first?.shownByMacOS == true)
    }

    /// Native notifications follow the sidebar when its side or width changes, without waiting for
    /// NotificationCenter to report anything.
    @Test func changingTheSidebarMovesNativeNotifications() throws {
        settings.update {
            $0.notifications.appsLeftToMacOS = ["zoom.us"]
            $0.sidebar = SidebarSettings.Sidebar(side: .right, width: 300)
        }
        let window = FakeElement.window(FakeElement.banner(app: "zoom.us", title: "Meeting"))
        platform.windowsByPID[42] = [window]
        let delegate = makeDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        #expect(window.position == CGPoint(x: -300, y: 0))

        settings.update { $0.sidebar.width = 400 }

        #expect(window.position == CGPoint(x: -400, y: 0))
    }

    @Test func settingsButtonOpensOneSettingsWindow() throws {
        let delegate = makeDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        delegate.showSettings()
        let first = try #require(delegate.settingsWindow)
        #expect(first.navigation.selection == .general)
        delegate.showSettings(.permissions)

        #expect(delegate.settingsWindow === first)
        #expect(first.window.isVisible)
        #expect(first.navigation.selection == .permissions)
    }

    /// A notification still on screen when the sidebar relaunches is the one already listed: it is
    /// neither listed again nor stacked onto its card as a repeat.
    @Test func relaunchingDoesNotListNotificationsOnScreenAgain() throws {
        settings.update { $0.notifications.appsLeftToMacOS = ["Zoom"] }
        platform.windowsByPID[42] = [FakeElement.window(FakeElement.banner(id: "meeting", app: "Zoom", title: "Meeting"))]
        let first = makeDelegate()
        first.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        first.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(first.model.notifications.map(\.title) == ["Meeting"])

        let relaunched = SidebarAppDelegate(
            settings: settings,
            makeModel: { _ in first.model },
            icons: .vendored,
            identities: NotificationIdentities(defaults: database.defaults),
            notificationDatabase: database.database,
            makeController: { model, settings, _, _ in
                SidebarPanelController(model: model, settings: settings, targetVisibleFrame: { nil }, notificationCenter: NotificationCenter())
            },
            makeMonitor: { [platform] model, settings, identities in
                NotificationCenterMonitor(
                    platform: platform,
                    interceptor: SystemNotificationInterceptor(
                        identities: identities,
                        leavesToMacOS: { settings.settings.notifications.leavesToMacOS($0) },
                        onNotification: { model.add($0) }
                    ),
                    workspaceCenter: NotificationCenter(),
                    onStatus: { _ in }
                )
            },
            makeDatabaseMonitor: makeDatabaseMonitor,
            makeServer: { SidebarAppDelegate.makeServer(model: $0, icons: $1, path: ControlServerTests.socketPath()) },
            makeAeroSpaceSync: makeAeroSpaceSync
        )
        relaunched.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        relaunched.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        #expect(relaunched.model.notifications.map(\.occurrences) == [1])
    }

    @Test func launchSurvivesUnavailableControlSocket() throws {
        let path = ControlServerTests.socketPath()
        let occupant = ControlServer(path: path) { _ in ControlResponse(error: nil) }
        try occupant.start()
        defer { occupant.stop() }
        let delegate = makeDelegate(socketPath: path)

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        #expect(delegate.controller != nil)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func launchSurvivesUnwatchableSettings() throws {
        let unwatchable = SettingsStore(file: SettingsFile(url: URL(fileURLWithPath: "/nonexistent-root/config.toml")))
        let delegate = SidebarAppDelegate(
            settings: unwatchable,
            makeModel: { SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(), history: $0.history) },
            identities: identities,
            notificationDatabase: database.database,
            makeController: { model, settings, _, _ in
                SidebarPanelController(model: model, settings: settings, targetVisibleFrame: { nil }, notificationCenter: NotificationCenter())
            },
            makeMonitor: { [platform] model, _, _ in
                NotificationCenterMonitor(platform: platform, interceptor: SystemNotificationInterceptor { model.add($0) },
                                          workspaceCenter: NotificationCenter(), onStatus: { _ in })
            },
            makeDatabaseMonitor: makeDatabaseMonitor,
            makeServer: { SidebarAppDelegate.makeServer(model: $0, icons: $1, path: ControlServerTests.socketPath()) },
            makeAeroSpaceSync: makeAeroSpaceSync
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        #expect(delegate.controller != nil)
    }

    @Test func savedRulesApplyToArrivingNotifications() throws {
        let delegate = makeDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        settings.update { $0.rules = [.init(source: "Safari", action: .hide)] }
        delegate.application(NSApplication.shared, open: [try SidebarRequest.pushNotification(NotificationPayload(title: "Hidden")).url()])

        #expect(delegate.model.notifications.isEmpty)
    }

    @Test func urlsPushNotificationsLabeledWithSender() throws {
        let delegate = makeDelegate()
        let url = try SidebarRequest.pushNotification(NotificationPayload(title: "From a page", severity: .high, icon: "safari")).url()

        delegate.application(NSApplication.shared, open: [url, URL(string: "aerospace-sidebar://bogus")!])

        #expect(delegate.model.notifications.map(\.title) == ["From a page"])
        #expect(delegate.model.notifications.first?.source == "Safari")
        #expect(delegate.model.notifications.first?.icon == SidebarNotification.Icon(id: "safari"))
    }

    @Test func changingSideOrWidthUpdatesAndReloadsAeroSpace() async throws {
        try directory.write("[gaps]\nouter.right = [{ monitor.main = 305 }, 5]\n\n\(AeroSpaceConfigEditor.floatRule)\n", to: ".aerospace.toml")
        let delegate = makeDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        settings.update { $0.notifications.replaceSystem = false }
        #expect(cli.calls.isEmpty)

        settings.update { $0.sidebar = SidebarSettings.Sidebar(side: .left, width: 400) }
        for _ in 0..<200 where cli.calls.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(cli.calls == [["reload-config", "--dry-run", "--no-gui"], ["reload-config", "--no-gui"]])
        let config = try String(contentsOf: directory.url.appendingPathComponent(".aerospace.toml"), encoding: .utf8)
        #expect(config.hasPrefix("[gaps]\n" + [
            AeroSpaceConfigEditor.blockStart, "outer.left = [{ monitor.main = 400 }, 0]", "outer.right = 5", AeroSpaceConfigEditor.blockEnd,
        ].joined(separator: "\n")))
    }

    @Test func urlsWithoutKnownSenderAreLabeledURL() throws {
        let delegate = makeDelegate(sender: nil)

        delegate.application(NSApplication.shared, open: [try SidebarRequest.pushNotification(NotificationPayload(body: "b")).url()])

        #expect(delegate.model.notifications.first?.source == "URL")
    }

    @Test func noAppleEventMeansNoSender() {
        #expect(SidebarAppDelegate.currentAppleEventSender() == nil)
    }

    @Test func defaultFactoriesBuildWithoutStarting() {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())

        let monitor = SidebarAppDelegate.makeMonitor(model: model, settings: settings)
        let databaseMonitor = SidebarAppDelegate.makeDatabaseMonitor(model: model, identities: NotificationIdentities(), database: database.database)
        let window = SettingsWindowController(
            store: settings,
            onboarding: SidebarAppDelegate.makeOnboarding(notificationDatabase: database.database),
            aeroSpace: SidebarAppDelegate.makeAeroSpaceSync(settings: settings),
            history: { model.received }
        )

        #expect(!monitor.isRunning)
        #expect(databaseMonitor.status == .stopped)
        #expect(model.interception == .starting)
        #expect(!window.window.isVisible)
    }
}
