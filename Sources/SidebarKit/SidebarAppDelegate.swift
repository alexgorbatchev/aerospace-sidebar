import AppKit
import os
import SidebarProtocol

/// Wires the sidebar panel, notification interception, the URL scheme and the control socket.
@MainActor
public final class SidebarAppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.alexgorbatchev.aerospace-sidebar", category: "app")

    public let model: SidebarModel
    public private(set) var controller: SidebarPanelController?
    private var monitor: NotificationCenterMonitor?
    private var server: ControlServer?
    private var pruneTimer: Timer?
    private let makeController: @MainActor (SidebarModel) -> SidebarPanelController
    private let makeMonitor: @MainActor (SidebarModel) -> NotificationCenterMonitor
    private let makeServer: @MainActor (SidebarModel) -> ControlServer
    private let urlSender: @MainActor () -> String?

    /// - Parameter urlSender: Name of the process that opened the URL being handled.
    public init(
        model: SidebarModel = SidebarModel(store: FileNotificationStore()),
        makeController: @escaping @MainActor (SidebarModel) -> SidebarPanelController = { SidebarPanelController(model: $0) },
        makeMonitor: @escaping @MainActor (SidebarModel) -> NotificationCenterMonitor = SidebarAppDelegate.makeMonitor,
        makeServer: @escaping @MainActor (SidebarModel) -> ControlServer = { SidebarAppDelegate.makeServer(model: $0) },
        urlSender: @escaping @MainActor () -> String? = SidebarAppDelegate.currentAppleEventSender
    ) {
        self.model = model
        self.makeController = makeController
        self.makeMonitor = makeMonitor
        self.makeServer = makeServer
        self.urlSender = urlSender
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = makeController(model)
        controller.pin()
        self.controller = controller

        let monitor = makeMonitor(model)
        monitor.start()
        self.monitor = monitor

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
        monitor?.stop()
        server?.stop()
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

    public static func makeMonitor(model: SidebarModel) -> NotificationCenterMonitor {
        NotificationCenterMonitor(
            interceptor: SystemNotificationInterceptor { model.add($0) },
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

    /// The app that sent the Apple Event currently being handled, such as the browser that opened a URL.
    public static func currentAppleEventSender() -> String? {
        guard let pid = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value
        else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
