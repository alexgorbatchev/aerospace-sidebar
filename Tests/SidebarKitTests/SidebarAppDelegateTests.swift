import AppKit
@testable import SidebarKit
import SidebarProtocol
import Testing

@MainActor
struct SidebarAppDelegateTests {
    init() {
        _ = NSApplication.shared
    }

    func makeDelegate(socketPath: String, platform: FakePlatform = FakePlatform(), sender: String? = "Safari") -> SidebarAppDelegate {
        SidebarAppDelegate(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            makeController: { model in
                SidebarPanelController(
                    model: model,
                    targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
                    notificationCenter: NotificationCenter()
                )
            },
            makeMonitor: { model in
                NotificationCenterMonitor(
                    platform: platform,
                    interceptor: SystemNotificationInterceptor { model.add($0) },
                    workspaceCenter: NotificationCenter(),
                    onStatus: { model.interception = $0 }
                )
            },
            makeServer: { SidebarAppDelegate.makeServer(model: $0, path: socketPath) },
            urlSender: { sender }
        )
    }

    @Test func launchingPinsSidebarStartsInterceptionAndControlSocket() async throws {
        let path = ControlServerTests.socketPath()
        let platform = FakePlatform()
        platform.windowsByPID[42] = [FakeElement.window(FakeElement.banner(app: "Mail"))]
        let delegate = makeDelegate(socketPath: path, platform: platform)

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let payload = try NotificationPayload(title: "from cli", severity: .critical)
        let response = try await UnixSocket.exchange(.pushNotification(payload), path: path)

        #expect(try #require(delegate.controller).panel.isVisible)
        #expect(delegate.model.interception == .active)
        #expect(response == ControlResponse(error: nil))
        #expect(delegate.model.notifications.map(\.source) == ["aerospace-sidebar", "Mail"])
        #expect(delegate.model.notifications.first?.severity == .critical)

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(!FileManager.default.fileExists(atPath: path))
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

    @Test func urlsPushNotificationsLabeledWithSender() throws {
        let delegate = makeDelegate(socketPath: ControlServerTests.socketPath())
        let url = try SidebarRequest.pushNotification(NotificationPayload(title: "From a page", severity: .high)).url()

        delegate.application(NSApplication.shared, open: [url, URL(string: "aerospace-sidebar://bogus")!])

        #expect(delegate.model.notifications.map(\.title) == ["From a page"])
        #expect(delegate.model.notifications.first?.source == "Safari")
        #expect(delegate.model.notifications.first?.severity == .high)
    }

    @Test func urlsWithoutKnownSenderAreLabeledURL() throws {
        let delegate = makeDelegate(socketPath: ControlServerTests.socketPath(), sender: nil)

        delegate.application(NSApplication.shared, open: [try SidebarRequest.pushNotification(NotificationPayload(body: "b")).url()])

        #expect(delegate.model.notifications.first?.source == "URL")
    }

    @Test func noAppleEventMeansNoSender() {
        #expect(SidebarAppDelegate.currentAppleEventSender() == nil)
    }

    @Test func defaultMonitorReportsIntoModel() {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())

        _ = SidebarAppDelegate.makeMonitor(model: model)

        #expect(model.interception == .starting)
    }
}
