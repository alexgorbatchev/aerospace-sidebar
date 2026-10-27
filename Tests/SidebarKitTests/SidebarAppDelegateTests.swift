import AppKit
@testable import SidebarKit
import SidebarProtocol
import Testing

@MainActor
struct SidebarAppDelegateTests {
    let directory: TemporaryDirectory
    let settings: SettingsStore
    let platform = FakePlatform()

    init() throws {
        _ = NSApplication.shared
        directory = try TemporaryDirectory()
        settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
    }

    func makeDelegate(socketPath: String = ControlServerTests.socketPath(), sender: String? = "Safari") -> SidebarAppDelegate {
        SidebarAppDelegate(
            settings: settings,
            makeModel: { SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(), history: $0.history) },
            makeController: { model, settings, openSettings in
                SidebarPanelController(
                    model: model,
                    settings: settings,
                    targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
                    notificationCenter: NotificationCenter(),
                    openSettings: openSettings
                )
            },
            makeMonitor: { [platform] model, settings in
                NotificationCenterMonitor(
                    platform: platform,
                    interceptor: SystemNotificationInterceptor(
                        leavesToMacOS: { settings.settings.notifications.leavesToMacOS($0) },
                        onNotification: { model.add($0) }
                    ),
                    workspaceCenter: NotificationCenter(),
                    onStatus: { model.interception = $0 }
                )
            },
            makeServer: { SidebarAppDelegate.makeServer(model: $0, path: socketPath) },
            makeSettingsWindow: { [directory] settings, onAeroSpaceUpdated in
                SettingsWindowController(store: settings, onboarding: OnboardingModel(
                    accessibility: FakePlatform(),
                    loginItems: FakeLoginItems(),
                    setup: AeroSpaceSetup(home: directory.url, environment: [:], cli: FakeAeroSpaceCLI()),
                    performer: RecordingPerformer(),
                    copy: { _ in },
                    onAeroSpaceUpdated: onAeroSpaceUpdated
                ), reveal: { _ in })
            },
            urlSender: { sender }
        )
    }

    @Test func launchingPinsSidebarStartsInterceptionAndControlSocket() async throws {
        let path = ControlServerTests.socketPath()
        platform.windowsByPID[42] = [FakeElement.window(FakeElement.banner(app: "Mail"))]
        let delegate = makeDelegate(socketPath: path)

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let payload = try NotificationPayload(title: "from cli", severity: .critical)
        let response = try await UnixSocket.exchange(.pushNotification(payload), path: path)

        #expect(try #require(delegate.controller).panel.isVisible)
        #expect(delegate.model.interception == .active)
        #expect(response == ControlResponse(error: nil))
        #expect(delegate.model.notifications.map(\.source) == ["aerospace-sidebar", "Mail"])

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(delegate.monitor?.isRunning == false)
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

    @Test func settingsButtonOpensOneSettingsWindow() throws {
        let delegate = makeDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        delegate.showSettings()
        let first = try #require(delegate.settingsWindow)
        delegate.showSettings()

        #expect(delegate.settingsWindow === first)
        #expect(first.window.isVisible)
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
            makeController: { model, settings, _ in
                SidebarPanelController(model: model, settings: settings, targetVisibleFrame: { nil }, notificationCenter: NotificationCenter())
            },
            makeMonitor: { [platform] model, _ in
                NotificationCenterMonitor(platform: platform, interceptor: SystemNotificationInterceptor { model.add($0) },
                                          workspaceCenter: NotificationCenter(), onStatus: { _ in })
            },
            makeServer: { SidebarAppDelegate.makeServer(model: $0, path: ControlServerTests.socketPath()) }
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        #expect(delegate.controller != nil)
    }

    @Test func urlsPushNotificationsLabeledWithSender() throws {
        let delegate = makeDelegate()
        let url = try SidebarRequest.pushNotification(NotificationPayload(title: "From a page", severity: .high)).url()

        delegate.application(NSApplication.shared, open: [url, URL(string: "aerospace-sidebar://bogus")!])

        #expect(delegate.model.notifications.map(\.title) == ["From a page"])
        #expect(delegate.model.notifications.first?.source == "Safari")
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
        let window = SidebarAppDelegate.makeSettingsWindow(settings: settings, onAeroSpaceUpdated: {})

        #expect(!monitor.isRunning)
        #expect(model.interception == .starting)
        #expect(!window.window.isVisible)
    }
}
