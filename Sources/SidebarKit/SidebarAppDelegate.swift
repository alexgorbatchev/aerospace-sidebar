import AppKit
import os
import SidebarProtocol

/// Wires the sidebar panel, settings, notification interception, the URL scheme and the control socket.
@MainActor
public final class SidebarAppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.alexgorbatchev.aerospace-sidebar", category: "app")

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
    /// Notifications listed from NotificationCenter or its database, shared so neither lists one twice.
    private let identities = NotificationIdentities()
    private var server: ControlServer?
    private var pruneTimer: Timer?
    private let makeController: @MainActor (SidebarModel, SettingsStore, _ openSettings: @escaping @MainActor () -> Void) -> SidebarPanelController
    private let makeMonitor: @MainActor (SidebarModel, SettingsStore, NotificationIdentities) -> NotificationCenterMonitor
    private let makeDatabaseMonitor: @MainActor (SidebarModel, NotificationIdentities) -> NotificationDatabaseMonitor
    private let makeServer: @MainActor (SidebarModel, AppIconFont) -> ControlServer
    private let makeSettingsWindow: @MainActor (SettingsStore, AeroSpaceSync) -> SettingsWindowController
    private let urlSender: @MainActor () -> String?

    /// - Parameter urlSender: Name of the process that opened the URL being handled.
    public init(
        settings: SettingsStore = SettingsStore(file: SettingsFile(
            home: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        )),
        makeModel: @MainActor (SidebarSettings) -> SidebarModel = { SidebarModel(store: FileNotificationStore(), history: $0.history) },
        icons: AppIconFont = .bundled(),
        makeController: @escaping @MainActor (SidebarModel, SettingsStore, _ openSettings: @escaping @MainActor () -> Void) -> SidebarPanelController = {
            SidebarPanelController(model: $0, settings: $1, openSettings: $2)
        },
        makeMonitor: @escaping @MainActor (SidebarModel, SettingsStore, NotificationIdentities) -> NotificationCenterMonitor = {
            SidebarAppDelegate.makeMonitor(model: $0, settings: $1, identities: $2)
        },
        makeDatabaseMonitor: @escaping @MainActor (SidebarModel, NotificationIdentities) -> NotificationDatabaseMonitor = {
            SidebarAppDelegate.makeDatabaseMonitor(model: $0, identities: $1)
        },
        makeServer: @escaping @MainActor (SidebarModel, AppIconFont) -> ControlServer = { SidebarAppDelegate.makeServer(model: $0, icons: $1) },
        makeAeroSpaceSync: @MainActor (SettingsStore) -> AeroSpaceSync = SidebarAppDelegate.makeAeroSpaceSync,
        makeSettingsWindow: @escaping @MainActor (SettingsStore, AeroSpaceSync) -> SettingsWindowController = {
            SettingsWindowController(store: $0, onboarding: SidebarAppDelegate.makeOnboarding(), aeroSpace: $1)
        },
        urlSender: @escaping @MainActor () -> String? = SidebarAppDelegate.currentAppleEventSender
    ) {
        self.settings = settings
        self.model = makeModel(settings.settings)
        self.icons = icons
        self.aeroSpace = makeAeroSpaceSync(settings)
        self.syncedSidebar = settings.settings.sidebar
        self.makeController = makeController
        self.makeMonitor = makeMonitor
        self.makeDatabaseMonitor = makeDatabaseMonitor
        self.makeServer = makeServer
        self.makeSettingsWindow = makeSettingsWindow
        self.urlSender = urlSender
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = makeController(model, settings) { [weak self] in self?.showSettings() }
        controller.pin()
        self.controller = controller

        aeroSpace.start()

        let monitor = makeMonitor(model, settings, identities)
        self.monitor = monitor
        let databaseMonitor = makeDatabaseMonitor(model, identities)
        self.databaseMonitor = databaseMonitor
        settings.observe { [weak self, model] settings in
            self?.syncAeroSpace(for: settings.sidebar)
            model.apply(history: settings.history)
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
        server?.stop()
    }

    /// Opens the Settings window, creating it on first use.
    public func showSettings() {
        let window = settingsWindow ?? makeSettingsWindow(settings, aeroSpace)
        settingsWindow = window
        window.show()
    }

    private func syncAeroSpace(for sidebar: SidebarSettings.Sidebar) {
        guard sidebar != syncedSidebar else { return }
        syncedSidebar = sidebar
        Task { await aeroSpace.sync() }
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

    public static func makeMonitor(
        model: SidebarModel,
        settings: SettingsStore,
        identities: NotificationIdentities = NotificationIdentities(),
        platform: any AccessibilityPlatform = SystemAccessibility()
    ) -> NotificationCenterMonitor {
        NotificationCenterMonitor(
            platform: platform,
            interceptor: SystemNotificationInterceptor(
                identities: identities,
                leavesToMacOS: { settings.settings.notifications.leavesToMacOS($0) },
                leavesActionableToMacOS: { settings.settings.notifications.actionableLeftToMacOS },
                onNotification: { model.add($0) }
            ),
            onStatus: { model.interception = $0 }
        )
    }

    public static func makeDatabaseMonitor(
        model: SidebarModel,
        identities: NotificationIdentities,
        database: NotificationDatabase = NotificationDatabase(home: FileManager.default.homeDirectoryForCurrentUser),
        defaults: UserDefaults = .standard
    ) -> NotificationDatabaseMonitor {
        NotificationDatabaseMonitor(database: database, identities: identities, defaults: defaults) { model.add($0) }
    }

    public static func makeServer(
        model: SidebarModel,
        icons: AppIconFont,
        path: String = SidebarApp.controlSocketPath
    ) -> ControlServer {
        ControlServer(path: path) { request in
            switch request {
            case .pushNotification(let payload):
                model.add(SidebarNotification(payload: payload, source: "aerospace-sidebar", icons: icons))
                return ControlResponse(error: nil)
            }
        }
    }

    public static func makeOnboarding() -> OnboardingModel {
        OnboardingModel(
            permissions: PermissionFlowGuide(
                notificationDatabase: NotificationDatabase(home: FileManager.default.homeDirectoryForCurrentUser)
            ),
            loginItems: MainAppLoginItem()
        )
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
