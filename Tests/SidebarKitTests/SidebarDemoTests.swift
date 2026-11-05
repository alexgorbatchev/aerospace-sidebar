import AppKit
@testable import SidebarKit
import SidebarProtocol
import Testing

@MainActor
@Suite(.leavesDesktopAlone)
struct SidebarDemoTests {
    /// The fixture `just screenshot` captures.
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/screenshot", isDirectory: true)

    init() {
        _ = NSApplication.shared
    }

    func makeDelegate(_ demo: SidebarDemo = SidebarDemo(directory: Self.fixture)) -> SidebarAppDelegate {
        demo.makeDelegate(icons: .vendored) { model, settings, openSettings, setUp in
            SidebarPanelController.forTesting(
                model: model, settings: settings,
                targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
                notificationCenter: NotificationCenter(), openSettings: openSettings, setUp: setUp
            )
        }
    }

    @Test func readsTheDirectoryAfterTheDemoArgument() throws {
        #expect(SidebarDemo(arguments: ["app", "--demo", "/tmp/demo"])?.directory.path == "/tmp/demo")
        #expect(SidebarDemo(arguments: ["app", "-NSDocumentRevisionsDebugMode", "YES", "--demo", "/tmp/demo"])?.notificationsURL.path
            == "/tmp/demo/notifications.json")
        #expect(SidebarDemo(arguments: ["app", "--demo"]) == nil)
        #expect(SidebarDemo(arguments: ["app"]) == nil)
        let directory = try TemporaryDirectory()
        let lockPath = directory.url.appendingPathComponent("sidebar.lock").path
        #expect(SidebarAppDelegate.launching(arguments: ["app", "--demo", Self.fixture.path], lockPath: lockPath)?.isDemo == true)
    }

    /// One copy at a time: a launch while another holds the lock gets no delegate, the running copy keeps the
    /// lock for as long as its delegate lives, and the next launch after it gets one.
    @Test func launchesOnlyWhileNoOtherCopyRuns() throws {
        let directory = try TemporaryDirectory()
        let lockPath = directory.url.appendingPathComponent("sidebar.lock").path
        let arguments = ["app", "--demo", Self.fixture.path]

        var running = try #require(SidebarAppDelegate.launching(arguments: arguments, lockPath: lockPath))
        #expect(running.instanceLock?.path == lockPath)
        #expect(SidebarAppDelegate.launching(arguments: arguments, lockPath: lockPath) == nil)
        #expect(SidebarAppDelegate.launching(arguments: ["app"], lockPath: lockPath) == nil)

        running = try #require(SidebarAppDelegate.launching(arguments: arguments, lockPath: directory.url.appendingPathComponent("other.lock").path))
        #expect(SidebarAppDelegate.launching(arguments: arguments, lockPath: lockPath)?.isDemo == true)
        _ = running
    }

    /// A lock file that cannot be made leaves the sidebar running without the check rather than not at all.
    @Test func launchesWhenTheLockCannotBeTaken() {
        let delegate = SidebarAppDelegate.launching(arguments: ["app", "--demo", Self.fixture.path], lockPath: "/nonexistent-directory/sidebar.lock")
        #expect(delegate?.isDemo == true)
        #expect(delegate?.instanceLock == nil)
    }

    /// Every card in the fixture reads, under the fixture's settings, and none expires: the demo's clock stands at
    /// the newest card, whenever the screenshot is taken.
    @Test func listsEveryFixtureCardUnderItsSettings() throws {
        let entries = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: SidebarDemo(directory: Self.fixture).notificationsURL)) as? [Any])
        let delegate = makeDelegate()

        #expect(delegate.model.notifications.count == entries.count)
        #expect(delegate.settings.settings.sidebar.width == 340)
        #expect(delegate.settings.loadProblem == nil)
        delegate.model.pruneExpired()
        #expect(delegate.model.notifications.count == entries.count)
        #expect(delegate.model.notifications.first?.severity == .critical)
        #expect(delegate.model.notifications.contains { $0.occurrences > 1 })
        #expect(delegate.model.notifications.contains { $0.markdown })
        #expect(delegate.model.notifications.contains { !$0.pushedChoices.isEmpty })
    }

    /// The demo shows its panel and nothing else runs: no interception, no database, no URLs, and no note asks for a
    /// permission. Dismissing a card leaves the fixture as it was.
    @Test func launchesOnlyThePanel() throws {
        let directory = try TemporaryDirectory()
        let demo = SidebarDemo(directory: directory.url)
        let card = SidebarNotification(source: "cli", title: "Build", receivedAt: Date(timeIntervalSinceReferenceDate: 0))
        try JSONEncoder().encode([card]).write(to: demo.notificationsURL)
        let fixture = try Data(contentsOf: demo.notificationsURL)
        let delegate = makeDelegate(demo)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            delegate.controller?.panel.orderOut(nil)
        }

        #expect(delegate.isDemo)
        #expect(delegate.controller?.panel.isVisible == true)
        #expect(delegate.monitor == nil)
        #expect(delegate.databaseMonitor == nil)
        #expect(delegate.model.interception == .active)
        #expect(delegate.model.database == .stopped)
        #expect(delegate.model.notifications.map(\.title) == ["Build"])
        // No AeroSpace config lives in the demo directory, so nothing would be edited.
        delegate.aeroSpace.refresh()
        #expect(delegate.aeroSpace.configURL == nil)

        delegate.application(NSApplication.shared, open: [try #require(URL(string: "aerospace-sidebar://notification/push?title=Hello"))])
        #expect(delegate.model.notifications.map(\.title) == ["Build"])

        delegate.model.dismiss(delegate.model.notifications[0].id)
        #expect(delegate.model.notifications.isEmpty)
        #expect(try Data(contentsOf: demo.notificationsURL) == fixture)

        // The demo's settings still apply live.
        delegate.settings.update { $0.history.maxCount = 10 }
        #expect(delegate.model.history.maxCount == 10)
    }
}
