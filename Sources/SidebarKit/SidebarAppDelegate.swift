import AppKit
import os
import PermissionFlow
import SidebarProtocol

/// Wires the sidebar panel, settings, notification interception, the URL scheme and the control socket.
@MainActor
public final class SidebarAppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(category: "app")

    public let settings: SettingsStore
    public let model: SidebarModel
    public let icons: AppIconFont
    /// Keeps the AeroSpace config in line with the sidebar's side and width from launch on, whether or
    /// not Settings is ever opened.
    public let aeroSpace: AeroSpaceSync
    /// The side and width the AeroSpace config was last synced for.
    private var syncedSidebar: SidebarSettings.Sidebar
    public private(set) var controller: SidebarPanelController?
    public private(set) var settingsWindow: SettingsWindowController?
    public private(set) var monitor: NotificationCenterMonitor?
    public private(set) var databaseMonitor: NotificationDatabaseMonitor?
    /// The notification database, read by `databaseMonitor` and checked for Full Disk Access by `onboarding`.
    public let notificationDatabase: NotificationDatabase
    /// The Permissions steps, shared by Settings and the sidebar's Set Up… buttons; made on first use.
    public private(set) lazy var onboarding: OnboardingModel = {
        let onboarding = makeOnboarding(notificationDatabase)
        onboarding.willRemoveAccessibility = { [weak self] in self?.monitor?.stop() }
        onboarding.onPermissionsChanged = { [weak self] in self?.permissionsChanged() }
        return onboarding
    }()
    /// The apps whose notifications are switched off in System Settings, which Settings › Notifications lists and
    /// whose cards cannot open their notifications; made on first use.
    public private(set) lazy var appNotifications: AppNotificationsModel = makeAppNotifications(model)
    /// Notifications listed from NotificationCenter or its database, shared so neither lists one twice,
    /// and kept across launches.
    private let identities: NotificationIdentities
    private var server: ControlServer?
    private var pruneTimer: Timer?
    private let makeController: @MainActor (SidebarModel, SettingsStore, _ openSettings: @escaping @MainActor (SettingsGroup) -> Void, _ setUp: @escaping @MainActor (PermissionFlowPane, CGRect?) -> Void) -> SidebarPanelController
    private let makeMonitor: @MainActor (SidebarModel, SettingsStore, NotificationIdentities, NotificationDatabase) -> NotificationCenterMonitor
    private let makeDatabaseMonitor: @MainActor (
        SidebarModel, NotificationIdentities, NotificationDatabase, _ onChoices: @escaping @MainActor (_ identifier: String, _ choices: [NativeChoice]) -> Void
    ) -> NotificationDatabaseMonitor
    private let makeServer: @MainActor (SidebarModel, AppIconFont) -> ControlServer
    private let makeOnboarding: @MainActor (NotificationDatabase) -> OnboardingModel
    private let makeAppNotifications: @MainActor (SidebarModel) -> AppNotificationsModel
    private let makeSettingsWindow: @MainActor (SettingsStore, AeroSpaceSync, OnboardingModel, AppNotificationsModel, SidebarModel) -> SettingsWindowController
    private let urlSender: @MainActor () -> String?
    private let activation: ActivationYielder

    /// - Parameters:
    ///   - identities: Notifications already listed; tests pass one that is not saved in `UserDefaults.standard`.
    ///   - notificationDatabase: macOS's notification database; tests pass one in a temporary directory.
    ///   - urlSender: Name of the process that opened the URL being handled.
    ///   - activation: Hands activation back to the app the user was in; tests that call
    ///     `applicationDidBecomeActive` pass one that activates and deactivates nothing.
    public init(
        settings: SettingsStore = SettingsStore(file: SettingsFile(
            home: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        )),
        makeModel: @MainActor (SidebarSettings) -> SidebarModel = {
            SidebarModel(
                store: FileNotificationStore(),
                receivedStore: FileNotificationStore(url: FileNotificationStore.receivedURL),
                defaults: .standard,
                history: $0.history,
                rules: $0.rules,
                listsSwitchedOffApps: $0.notifications.listsSwitchedOffApps
            )
        },
        icons: AppIconFont = .bundled(),
        identities: NotificationIdentities = NotificationIdentities(defaults: .standard),
        notificationDatabase: NotificationDatabase = NotificationDatabase(home: FileManager.default.homeDirectoryForCurrentUser),
        makeController: @escaping @MainActor (SidebarModel, SettingsStore, _ openSettings: @escaping @MainActor (SettingsGroup) -> Void, _ setUp: @escaping @MainActor (PermissionFlowPane, CGRect?) -> Void) -> SidebarPanelController = {
            SidebarPanelController(model: $0, settings: $1, openSettings: $2, setUp: $3)
        },
        makeMonitor: @escaping @MainActor (SidebarModel, SettingsStore, NotificationIdentities, NotificationDatabase) -> NotificationCenterMonitor = {
            SidebarAppDelegate.makeMonitor(model: $0, settings: $1, identities: $2, declaredChoices: DeclaredChoices(database: $3))
        },
        makeDatabaseMonitor: @escaping @MainActor (
            SidebarModel, NotificationIdentities, NotificationDatabase, _ onChoices: @escaping @MainActor (_ identifier: String, _ choices: [NativeChoice]) -> Void
        ) -> NotificationDatabaseMonitor = {
            SidebarAppDelegate.makeDatabaseMonitor(model: $0, identities: $1, database: $2, onChoices: $3)
        },
        makeServer: @escaping @MainActor (SidebarModel, AppIconFont) -> ControlServer = { SidebarAppDelegate.makeServer(model: $0, icons: $1) },
        makeAeroSpaceSync: @MainActor (SettingsStore) -> AeroSpaceSync = SidebarAppDelegate.makeAeroSpaceSync,
        makeOnboarding: @escaping @MainActor (NotificationDatabase) -> OnboardingModel = SidebarAppDelegate.makeOnboarding(notificationDatabase:),
        makeAppNotifications: @escaping @MainActor (SidebarModel) -> AppNotificationsModel = { SidebarAppDelegate.makeAppNotifications(model: $0) },
        makeSettingsWindow: @escaping @MainActor (SettingsStore, AeroSpaceSync, OnboardingModel, AppNotificationsModel, SidebarModel) -> SettingsWindowController = {
            store, aeroSpace, onboarding, appNotifications, model in
            SettingsWindowController(store: store, onboarding: onboarding, appNotifications: appNotifications, aeroSpace: aeroSpace) {
                model.received
            }
        },
        urlSender: @escaping @MainActor () -> String? = SidebarAppDelegate.currentAppleEventSender,
        activation: ActivationYielder = ActivationYielder()
    ) {
        self.settings = settings
        self.model = makeModel(settings.settings)
        self.icons = icons
        self.identities = identities
        self.notificationDatabase = notificationDatabase
        self.aeroSpace = makeAeroSpaceSync(settings)
        self.syncedSidebar = settings.settings.sidebar
        self.makeController = makeController
        self.makeMonitor = makeMonitor
        self.makeDatabaseMonitor = makeDatabaseMonitor
        self.makeServer = makeServer
        self.makeOnboarding = makeOnboarding
        self.makeAppNotifications = makeAppNotifications
        self.makeSettingsWindow = makeSettingsWindow
        self.urlSender = urlSender
        self.activation = activation
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.mainMenu = Self.makeMainMenu()
        let controller = makeController(model, settings, { [weak self] in self?.showSettings($0) }, { [weak self] in self?.setUp($0, from: $1) })
        controller.pin()
        self.controller = controller

        aeroSpace.start()

        let monitor = makeMonitor(model, settings, identities, notificationDatabase)
        self.monitor = monitor
        model.nativeNotifications = monitor
        model.notificationsAreOff = { [appNotifications] in appNotifications.notificationsAreOff(for: $0) }
        model.allowAppNotifications = { [appNotifications] in await appNotifications.switchOn(bundleIdentifier: $0, name: $1) }
        // Cards follow the switches as they flip, in System Settings or through Allow.
        appNotifications.start()
        let databaseMonitor = makeDatabaseMonitor(model, identities, notificationDatabase) { [weak self] in self?.offer($1, forNotification: $0) }
        self.databaseMonitor = databaseMonitor
        settings.observe { [weak self, model] settings in
            self?.sidebarChanged(to: settings.sidebar)
            model.apply(history: settings.history)
            model.apply(rules: settings.rules)
            model.apply(listsSwitchedOffApps: settings.notifications.listsSwitchedOffApps)
            if settings.notifications.replaceSystem {
                monitor.start()
                databaseMonitor.start()
            } else {
                monitor.stop()
                databaseMonitor.stop()
                model.interception = .disabled
            }
        }
        do {
            try settings.startWatching()
        } catch {
            Self.logger.error("Cannot watch settings: \(String(describing: error), privacy: .public)")
        }

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [model] _ in
            MainActor.assumeIsolated { model.pruneExpired() }
        }

        let server = makeServer(model, icons)
        do {
            try server.start()
            self.server = server
        } catch {
            Self.logger.error("Control socket unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        pruneTimer?.invalidate()
        settings.stopWatching()
        aeroSpace.stop()
        monitor?.stop()
        databaseMonitor?.stop()
        appNotifications.stop()
        server?.stop()
    }

    /// Opens the Settings window on `group`, creating it on first use.
    public func showSettings(_ group: SettingsGroup = .general) {
        let window = settingsWindow ?? makeSettingsWindow(settings, aeroSpace, onboarding, appNotifications, model)
        settingsWindow = window
        window.show(group)
    }

    /// Shows Settings › Permissions, where the step's status and Remove are, and opens `pane` in System
    /// Settings with PermissionFlow's drag panel, which flies there from `sourceFrame` on screen.
    public func setUp(_ pane: PermissionFlowPane, from sourceFrame: CGRect?) {
        showSettings(.permissions)
        onboarding.authorize(pane, from: sourceFrame)
    }

    /// Checks the permissions now that Settings removed one, rather than at the monitors' next poll or read.
    /// Removing Accessibility stops interception first, which moves NotificationCenter's windows back while
    /// the permission still allows it; interception starts again here and waits for the permission, or
    /// attaches again when it was not removed after all.
    private func permissionsChanged() {
        if settings.settings.notifications.replaceSystem {
            monitor?.start()
        }
        monitor?.checkPermission()
        databaseMonitor?.checkAccess()
    }

    /// Lets the card that lists a native notification without its choices offer those the notification database
    /// named for it, then sweeps, so that the notification, an alert still on screen, is handed over to the card
    /// and hidden. A notification from an app left to macOS stays there.
    private func offer(_ choices: [NativeChoice], forNotification identifier: String) {
        let leavesToMacOS = settings.settings.notifications.leavesToMacOS
        guard !model.notifications.contains(where: { $0.nativeIdentifiers.contains(identifier) && leavesToMacOS($0.source) }),
              model.offer(choices, forNotification: identifier)
        else { return }
        monitor?.refresh()
    }

    /// Brings AeroSpace's reserved strip in line with the sidebar and moves native notifications out from
    /// under it.
    private func sidebarChanged(to sidebar: SidebarSettings.Sidebar) {
        guard sidebar != syncedSidebar else { return }
        syncedSidebar = sidebar
        Task { await aeroSpace.sync() }
        monitor?.refresh()
    }

    /// The menu bar an `LSUIElement` app never shows. Key equivalents such as ⌘C and ⌘V reach text fields
    /// only through the main menu's Edit items, so without one Settings' fields ignore them. It holds no
    /// Quit item: ⌘Q quits only from Settings › General.
    static func makeMainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let menu = NSMenu()
        // The first item is the application menu, whichever title it has.
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = NSMenu()
        menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        return menu
    }

    /// Launch Services activates the app to open a URL or at launch; see `ActivationYielder`.
    public func applicationDidBecomeActive(_ notification: Notification) {
        activation.appDidBecomeActive()
    }

    /// Handles `aerospace-sidebar://` URLs; see `SidebarRequest` for the routes.
    public func application(_ application: NSApplication, open urls: [URL]) {
        let source = urlSender() ?? "URL"
        for url in urls {
            do {
                switch try SidebarRequest(url: url) {
                case .pushNotification(let payload):
                    model.add(SidebarNotification(payload: payload, source: source, icons: icons))
                }
            } catch {
                Self.logger.error("Rejected \(url.absoluteString, privacy: .public): \(error.description, privacy: .public)")
            }
        }
    }

    /// - Parameters:
    ///   - declaredChoices: What apps declared their notifications' choices as, which lets cards offer them.
    ///   - targetVisibleFrame: The visible frame of the sidebar's screen, whose right edge the sidebar may
    ///     cover; native notifications are moved left of the sidebar there.
    public static func makeMonitor(
        model: SidebarModel,
        settings: SettingsStore,
        identities: NotificationIdentities = NotificationIdentities(),
        declaredChoices: DeclaredChoices,
        platform: any AccessibilityPlatform = SystemAccessibility(),
        targetVisibleFrame: @escaping @MainActor () -> CGRect? = SidebarPanelController.primaryScreenVisibleFrame
    ) -> NotificationCenterMonitor {
        NotificationCenterMonitor(
            platform: platform,
            interceptor: SystemNotificationInterceptor(
                identities: identities,
                leavesToMacOS: { settings.settings.notifications.leavesToMacOS($0) },
                bundleIdentifier: { InstalledApps.shared.bundleIdentifier(named: $0) },
                leavesActionableToMacOS: { settings.settings.notifications.actionableLeftToMacOS },
                listsNotification: { model.lists(notification: $0) },
                listsChoices: { model.lists(choicesOf: $0) },
                declaredChoices: { declaredChoices.choices(ofApp: $0, titled: $1) },
                declaresNoChoices: { declaredChoices.declaresNone(ofApp: $0) },
                onUnavailableChoices: { model.unavailableChoices = $0 },
                nativeOrigin: {
                    guard let visibleFrame = targetVisibleFrame() else { return .zero }
                    return CGPoint(x: -SidebarLayout(settings.settings.sidebar).coverage(ofRightEdgeOf: visibleFrame), y: 0)
                },
                onNotification: { model.add($0) }
            ),
            onStatus: { model.interception = $0 }
        )
    }

    /// - Parameter onChoices: Receives the choices a database record names for a notification listed before,
    ///   whose card may lack them.
    public static func makeDatabaseMonitor(
        model: SidebarModel,
        identities: NotificationIdentities,
        database: NotificationDatabase,
        defaults: UserDefaults = .standard,
        onChoices: @escaping @MainActor (_ identifier: String, _ choices: [NativeChoice]) -> Void = { _, _ in }
    ) -> NotificationDatabaseMonitor {
        NotificationDatabaseMonitor(
            database: database, identities: identities, defaults: defaults,
            onStatus: { model.database = $0 },
            onChoices: onChoices,
            onNotification: { model.add($0) }
        )
    }

    public static func makeServer(
        model: SidebarModel,
        icons: AppIconFont,
        path: String = SidebarApp.controlSocketPath
    ) -> ControlServer {
        ControlServer(path: path) { request in
            switch request {
            case .push(let payload):
                model.add(SidebarNotification(payload: payload, source: "aerospace-sidebar", icons: icons))
            case .ask(let payload, let asker):
                model.ask(SidebarNotification(payload: payload, source: "aerospace-sidebar", icons: icons), asker: asker)
            }
        }
    }

    /// - Parameter notificationDatabase: Whether it opens tells whether Full Disk Access is granted.
    public static func makeOnboarding(notificationDatabase: NotificationDatabase) -> OnboardingModel {
        OnboardingModel(
            permissions: PermissionFlowGuide(notificationDatabase: notificationDatabase),
            loginItems: MainAppLoginItem()
        )
    }

    /// Reads which apps have notifications switched off from usernoted's settings, which takes Full Disk Access.
    public static func makeAppNotifications(
        model: SidebarModel,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AppNotificationsModel {
        AppNotificationsModel(preferences: NotificationPreferences(home: home)) { model.received }
    }

    public static func makeAeroSpaceSync(settings: SettingsStore) -> AeroSpaceSync {
        AeroSpaceSync(setup: AeroSpaceSetup(), sidebar: { settings.settings.sidebar })
    }

    /// The app that sent the Apple Event currently being handled, such as the browser that opened a URL.
    public static func currentAppleEventSender() -> String? {
        guard let pid = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value
        else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
