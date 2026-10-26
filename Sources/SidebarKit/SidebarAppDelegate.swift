import AppKit
import os
import SidebarProtocol

/// Wires the sidebar panel, settings, notification interception, the URL scheme and the control socket.
@MainActor
public final class SidebarAppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.alexgorbatchev.aerospace-sidebar", category: "app")

    public let settings: SettingsStore
    public let model: SidebarModel
    public private(set) var controller: SidebarPanelController?
    public private(set) var settingsWindow: SettingsWindowController?
    public private(set) var monitor: NotificationCenterMonitor?
    private var server: ControlServer?
    private var pruneTimer: Timer?
    private let makeController: @MainActor (SidebarModel, _ openSettings: @escaping @MainActor () -> Void) -> SidebarPanelController
    private let makeMonitor: @MainActor (SidebarModel, SettingsStore) -> NotificationCenterMonitor
    private let makeServer: @MainActor (SidebarModel) -> ControlServer
    private let makeSettingsWindow: @MainActor (SettingsStore, _ onAeroSpaceUpdated: @escaping @MainActor () -> Void) -> SettingsWindowController
    private let urlSender: @MainActor () -> String?

    /// - Parameter urlSender: Name of the process that opened the URL being handled.
    public init(
        settings: SettingsStore = SettingsStore(file: SettingsFile(
            home: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        )),
        makeModel: @MainActor (SidebarSettings) -> SidebarModel = { SidebarModel(store: FileNotificationStore(), history: $0.history) },
        makeController: @escaping @MainActor (SidebarModel, _ openSettings: @escaping @MainActor () -> Void) -> SidebarPanelController = {
            SidebarPanelController(model: $0, openSettings: $1)
        },
        makeMonitor: @escaping @MainActor (SidebarModel, SettingsStore) -> NotificationCenterMonitor = { SidebarAppDelegate.makeMonitor(model: $0, settings: $1) },
        makeServer: @escaping @MainActor (SidebarModel) -> ControlServer = { SidebarAppDelegate.makeServer(model: $0) },
        makeSettingsWindow: @escaping @MainActor (SettingsStore, _ onAeroSpaceUpdated: @escaping @MainActor () -> Void) -> SettingsWindowController = SidebarAppDelegate.makeSettingsWindow,
        urlSender: @escaping @MainActor () -> String? = SidebarAppDelegate.currentAppleEventSender
    ) {
        self.settings = settings
        self.model = makeModel(settings.settings)
        self.makeController = makeController
        self.makeMonitor = makeMonitor
        self.makeServer = makeServer
        self.makeSettingsWindow = makeSettingsWindow
        self.urlSender = urlSender
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = makeController(model) { [weak self] in self?.showSettings() }
        controller.pin()
        self.controller = controller

        let monitor = makeMonitor(model, settings)
        self.monitor = monitor
        settings.observe { [model] settings in
            model.apply(history: settings.history)
            if settings.notifications.replaceSystem {
                monitor.start()
            } else {
                monitor.stop()
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

        let server = makeServer(model)
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
        monitor?.stop()
        server?.stop()
    }

    /// Opens the Settings window, creating it on first use.
    public func showSettings() {
        let window = settingsWindow ?? makeSettingsWindow(settings) { [weak self] in self?.controller?.pin() }
        settingsWindow = window
        window.show()
    }

    /// Handles `aerospace-sidebar://` URLs; see `SidebarRequest` for the routes.
    public func application(_ application: NSApplication, open urls: [URL]) {
        let source = urlSender() ?? "URL"
        for url in urls {
            do {
                switch try SidebarRequest(url: url) {
                case .pushNotification(let payload):
                    model.add(SidebarNotification(payload: payload, source: source))
                }
            } catch {
                Self.logger.error("Rejected \(url.absoluteString, privacy: .public): \(error.description, privacy: .public)")
            }
        }
    }

    public static func makeMonitor(
        model: SidebarModel,
        settings: SettingsStore,
        platform: any AccessibilityPlatform = SystemAccessibility()
    ) -> NotificationCenterMonitor {
        NotificationCenterMonitor(
            platform: platform,
            interceptor: SystemNotificationInterceptor(
                leavesToMacOS: { settings.settings.notifications.leavesToMacOS($0) },
                onNotification: { model.add($0) }
            ),
            onStatus: { model.interception = $0 }
        )
    }

    public static func makeServer(model: SidebarModel, path: String = SidebarApp.controlSocketPath) -> ControlServer {
        ControlServer(path: path) { request in
            switch request {
            case .pushNotification(let payload):
                model.add(SidebarNotification(payload: payload, source: "aerospace-sidebar"))
                return ControlResponse(error: nil)
            }
        }
    }

    public static func makeSettingsWindow(
        settings: SettingsStore,
        onAeroSpaceUpdated: @escaping @MainActor () -> Void
    ) -> SettingsWindowController {
        SettingsWindowController(store: settings, onboarding: OnboardingModel(
            accessibility: SystemAccessibility(),
            loginItems: MainAppLoginItem(),
            setup: AeroSpaceSetup(),
            performer: WorkspaceActionPerformer(),
            onAeroSpaceUpdated: onAeroSpaceUpdated
        ))
    }

    /// The app that sent the Apple Event currently being handled, such as the browser that opened a URL.
    public static func currentAppleEventSender() -> String? {
        guard let pid = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value
        else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
