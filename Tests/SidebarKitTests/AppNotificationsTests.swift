import ApplicationServices
import Foundation
@testable import SidebarKit
import SwiftUI
import Synchronization
import Testing
import ViewInspector

/// usernoted's preferences in a temporary home folder, shaped like the real file.
final class NotificationPreferencesFixture {
    let directory: TemporaryDirectory
    let preferences: NotificationPreferences

    convenience init() throws {
        self.init(directory: try TemporaryDirectory())
    }

    /// usernoted's preferences in the home folder `directory` stands for.
    init(directory: TemporaryDirectory) {
        self.directory = directory
        preferences = NotificationPreferences(home: directory.url)
    }

    /// Writes one entry per app; `allowed` sets Allow Notifications among other flags usernoted keeps.
    func write(_ apps: [String: Bool]) throws {
        let entries: [[String: Any]] = apps.map { identifier, allowed in
            let otherFlags: Int64 = 0x0100_400E
            return [
                "bundle-id": identifier,
                "flags": NSNumber(value: allowed ? otherFlags | NotificationPreferences.allowNotificationsFlag : otherFlags),
                "auth": 7,
                "path": "/Applications/\(identifier).app",
            ]
        }
        try write(PropertyListSerialization.data(fromPropertyList: ["apps": entries, "version": 1], format: .binary, options: 0))
    }

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: preferences.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: preferences.url)
    }
}

@MainActor
struct NotificationPreferencesTests {
    let fixture: NotificationPreferencesFixture

    init() throws {
        fixture = try NotificationPreferencesFixture()
    }

    @Test func readsEachAppsAllowNotificationsSwitch() throws {
        try fixture.write(["com.tinyspeck.slackmacgap": false, "com.openai.codex": true])

        #expect(try fixture.preferences.allowedApps() == ["com.tinyspeck.slackmacgap": false, "com.openai.codex": true])
        #expect(fixture.preferences.url.path.hasSuffix(
            "Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"
        ))
    }

    @Test func skipsEntriesWithoutAnIdentifierOrFlags() throws {
        let apps: [[String: Any]] = [["bundle-id": "a"], ["flags": NSNumber(value: 0)], ["bundle-id": "b", "flags": NSNumber(value: 0)]]
        try fixture.write(PropertyListSerialization.data(fromPropertyList: ["apps": apps], format: .binary, options: 0))

        #expect(try fixture.preferences.allowedApps() == ["b": false])
    }

    /// Without Full Disk Access the file does not open; a macOS update may change its shape.
    @Test func reportsUnreadableAndUnrecognizedSettings() throws {
        let missing = #expect(throws: NotificationPreferences.Failure.self) { try fixture.preferences.allowedApps() }
        #expect(missing.map { if case .unreadable = $0 { true } else { false } } == true)

        try fixture.write(PropertyListSerialization.data(fromPropertyList: ["apps": "changed"], format: .binary, options: 0))
        #expect(throws: NotificationPreferences.Failure.unrecognized) { try fixture.preferences.allowedApps() }
        try fixture.write(Data("not a plist".utf8))
        #expect(throws: NotificationPreferences.Failure.unrecognized) { try fixture.preferences.allowedApps() }
    }
}

@MainActor
struct AppNotificationsModelTests {
    let fixture: NotificationPreferencesFixture
    let switcher = FakeAppNotificationSwitch()

    init() throws {
        fixture = try NotificationPreferencesFixture()
    }

    func model(
        received: [SidebarNotification],
        installedApp: @escaping @MainActor (String) -> InstalledApps.App? = { _ in nil },
        retryInterval: Duration = AppNotificationsModel.retryInterval
    ) -> AppNotificationsModel {
        AppNotificationsModel(
            preferences: fixture.preferences, switcher: switcher, installedApp: installedApp, retryInterval: retryInterval, received: { received }
        )
    }

    static func fromMacOS(_ source: String, _ bundleIdentifier: String?) -> SidebarNotification {
        SidebarNotification(
            source: source, title: "t", bundleIdentifier: bundleIdentifier,
            action: .activateApp(name: source), nativeIdentifiers: [UUID().uuidString]
        )
    }

    /// Only apps that notified through macOS count, once each, by name; pushed notifications name the app
    /// they were pushed from, which never went through macOS.
    @Test func listsSwitchedOffAppsThatNotifiedLately() throws {
        try fixture.write(["com.tinyspeck.slackmacgap": false, "com.vivaldi.Vivaldi": false, "com.openai.codex": true, "com.mitchellh.ghostty": false])
        let received = [
            Self.fromMacOS("Vivaldi", "com.vivaldi.Vivaldi"),
            Self.fromMacOS("Slack", "com.tinyspeck.slackmacgap"),
            Self.fromMacOS("Slack", "com.tinyspeck.slackmacgap"),
            Self.fromMacOS("Codex", "com.openai.codex"),
            Self.fromMacOS("Unknown", "com.example.unlisted"),
            Self.fromMacOS("macOS", nil),
            SidebarNotification(source: "aerospace-sidebar", title: "Pushed", bundleIdentifier: "com.mitchellh.ghostty"),
        ]
        let model = model(received: received)

        model.refresh()

        #expect(model.canTell)
        #expect(model.appsWithNotificationsOff == [
            AppNotificationsModel.App(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack"),
            AppNotificationsModel.App(bundleIdentifier: "com.vivaldi.Vivaldi", name: "Vivaldi"),
        ])
        #expect(model.appsWithNotificationsOff.map(\.id) == ["com.tinyspeck.slackmacgap", "com.vivaldi.Vivaldi"])
    }

    /// Cards the notification database listed before carry its lowercase identifiers, while usernoted's
    /// preferences keep the app's own case. They still count as switched off, and Allow opens System Settings
    /// with the identifier as usernoted keeps it.
    @Test func comparesBundleIdentifiersInAnyCase() async throws {
        try fixture.write(["com.vivaldi.Vivaldi": false, "com.openai.codex": true])
        let model = model(received: [
            Self.fromMacOS("Vivaldi", "com.vivaldi.vivaldi"),
            Self.fromMacOS("Vivaldi", "com.vivaldi.Vivaldi"),
            Self.fromMacOS("Codex", "COM.openai.codex"),
        ])

        model.refresh()

        #expect(model.notificationsAreOff(for: "com.vivaldi.vivaldi"))
        #expect(model.notificationsAreOff(for: "com.vivaldi.Vivaldi"))
        #expect(!model.notificationsAreOff(for: "COM.openai.codex"))
        #expect(model.appsWithNotificationsOff == [AppNotificationsModel.App(bundleIdentifier: "com.vivaldi.Vivaldi", name: "Vivaldi")])
        await model.allow(model.appsWithNotificationsOff[0])
        #expect(switcher.requests.map(\.bundleIdentifier) == ["com.vivaldi.Vivaldi"])
    }

    /// An app and the helper it posts web notifications from have a switch each, and both notify under the app's
    /// name; the helper's own name tells its row apart, and Allow's message names it. System Settings titles both
    /// pages with the app's name, so Allow checks the page against that.
    @Test func namesHelpersThatNotifyUnderTheirAppsName() async throws {
        let helper = "com.vivaldi.Vivaldi.framework.AlertNotificationService"
        try fixture.write(["com.vivaldi.Vivaldi": false, helper: false])
        var lookups: [String] = []
        let installed = [
            "com.vivaldi.Vivaldi": InstalledApps.App(name: "Vivaldi", bundleIdentifier: "com.vivaldi.Vivaldi"),
            helper: InstalledApps.App(name: "Vivaldi Helper (Alerts)", bundleIdentifier: helper),
        ]
        let model = model(
            // The helper notified last, so it comes first; the list puts the app first all the same.
            received: [Self.fromMacOS("Vivaldi", helper.lowercased()), Self.fromMacOS("Vivaldi", "com.vivaldi.vivaldi")],
            installedApp: { lookups.append($0); return installed[$0] }
        )

        model.refresh()
        model.refresh()

        let app = AppNotificationsModel.App(bundleIdentifier: "com.vivaldi.Vivaldi", name: "Vivaldi")
        let alerts = AppNotificationsModel.App(bundleIdentifier: helper, name: "Vivaldi", installedName: "Vivaldi Helper (Alerts)")
        #expect(model.appsWithNotificationsOff == [app, alerts])
        #expect(model.appsWithNotificationsOff.map(\.title) == ["Vivaldi", "Vivaldi Helper (Alerts)"])
        // Each name is looked up once, however often the list is read.
        #expect(lookups == [helper, "com.vivaldi.Vivaldi"])

        switcher.result = .switchedOn
        await model.allow(alerts)
        #expect(switcher.requests.map(\.name) == ["Vivaldi"])
        #expect(model.message == "Switched on notifications from Vivaldi Helper (Alerts); its cards open their notifications.")
    }

    /// A card's badge names its app as the card does, in the database's lowercase; switching it on uses usernoted's
    /// identifier, and an app usernoted does not list is tried as named. What is left to the user comes back, naming
    /// a helper by its own name; nothing comes back once the switch is on.
    @Test(arguments: [
        (AppNotificationSwitchResult.switchedOn, nil),
        (.alreadyOn, nil),
        (.pageNotShown, "Switch on Allow Notifications for Vivaldi Helper (Alerts) in System Settings."),
        (.refused, "Switch on Allow Notifications for Vivaldi Helper (Alerts) in System Settings."),
        (.needsAccessibility, "Without Accessibility, switch on Allow Notifications for Vivaldi Helper (Alerts) in System Settings."),
    ])
    func switchesOnTheAppACardNames(result: AppNotificationSwitchResult, problem: String?) async throws {
        let helper = "com.vivaldi.Vivaldi.framework.AlertNotificationService"
        try fixture.write([helper: false])
        let model = model(received: [], installedApp: { InstalledApps.App(name: $0 == helper ? "Vivaldi Helper (Alerts)" : "Unlisted", bundleIdentifier: $0) })
        switcher.result = result

        #expect(await model.switchOn(bundleIdentifier: helper.lowercased(), name: "Vivaldi") == problem)
        _ = await model.switchOn(bundleIdentifier: "com.example.Unlisted", name: "Unlisted")

        #expect(switcher.requests.map(\.bundleIdentifier) == [helper, "com.example.Unlisted"])
        #expect(switcher.requests.map(\.name) == ["Vivaldi", "Unlisted"])
    }

    /// While one app's notifications are being switched on, another card's badge gets no answer.
    @Test func switchesOnOneAppAtATime() async throws {
        try fixture.write(["com.vivaldi.Vivaldi": false, "com.tinyspeck.slackmacgap": false])
        let model = model(received: [])
        switcher.result = .refused
        var second: String?? = .none
        switcher.whileSwitching = { second = await model.switchOn(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack") }

        #expect(await model.switchOn(bundleIdentifier: "com.vivaldi.Vivaldi", name: "Vivaldi") != nil)
        #expect(second == .some(nil))
        #expect(switcher.requests.map(\.bundleIdentifier) == ["com.vivaldi.Vivaldi"])
    }

    @Test func cannotTellWithoutTheSettings() {
        let model = model(received: [Self.fromMacOS("Slack", "com.tinyspeck.slackmacgap")])

        model.refresh()

        #expect(!model.canTell)
        #expect(model.appsWithNotificationsOff.isEmpty)
        #expect(!model.notificationsAreOff(for: "com.tinyspeck.slackmacgap"))
    }

    /// Cards follow a switch that flips while the sidebar runs, in System Settings or through Allow: the model
    /// reads usernoted's preferences again whenever they are written, and cards that read it redraw.
    @Test func followsSwitchesAsTheyFlip() async throws {
        try fixture.write(["com.vivaldi.Vivaldi": false])
        let model = model(received: [])
        model.start()
        defer { model.stop() }
        #expect(model.notificationsAreOff(for: "com.vivaldi.vivaldi"))
        #expect(!model.notificationsAreOff(for: "com.openai.codex"))

        let redrawn = Mutex(false)
        withObservationTracking { _ = model.notificationsAreOff(for: "com.vivaldi.vivaldi") } onChange: { redrawn.withLock { $0 = true } }
        try fixture.write(["com.vivaldi.Vivaldi": true])
        for _ in 0..<300 where model.notificationsAreOff(for: "com.vivaldi.vivaldi") {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!model.notificationsAreOff(for: "com.vivaldi.vivaldi"))
        #expect(redrawn.withLock { $0 })
    }

    /// Without Full Disk Access the settings do not open, and nothing tells when access comes, so they are tried
    /// again until they open.
    @Test func triesTheSettingsAgainUntilTheyOpen() async throws {
        let model = model(received: [], retryInterval: .milliseconds(50))
        model.start()
        defer { model.stop() }
        #expect(!model.notificationsAreOff(for: "com.vivaldi.Vivaldi"))

        try fixture.write(["com.vivaldi.Vivaldi": false])
        for _ in 0..<300 where !model.notificationsAreOff(for: "com.vivaldi.Vivaldi") {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.notificationsAreOff(for: "com.vivaldi.Vivaldi"))
    }

    @Test(arguments: [
        (AppNotificationSwitchResult.switchedOn, "Switched on notifications from Slack; its cards open their notifications."),
        (.alreadyOn, "Notifications from Slack are on."),
        (.pageNotShown, "Switch on Allow Notifications for Slack in System Settings."),
        (.refused, "Switch on Allow Notifications for Slack in System Settings."),
        (.needsAccessibility, "Without Accessibility, switch on Allow Notifications for Slack in System Settings."),
    ])
    func allowSwitchesTheAppOnAndListsAgain(result: AppNotificationSwitchResult, message: String) async throws {
        try fixture.write(["com.tinyspeck.slackmacgap": false])
        let model = model(received: [Self.fromMacOS("Slack", "com.tinyspeck.slackmacgap")])
        model.refresh()
        let slack = try #require(model.appsWithNotificationsOff.first)
        switcher.result = result
        switcher.whileSwitching = { [fixture] in
            #expect(model.allowing == "com.tinyspeck.slackmacgap")
            if result == .switchedOn {
                try? fixture.write(["com.tinyspeck.slackmacgap": true])
            }
        }

        await model.allow(slack)

        #expect(switcher.requests.map(\.bundleIdentifier) == ["com.tinyspeck.slackmacgap"])
        #expect(switcher.requests.map(\.name) == ["Slack"])
        #expect(model.allowing == nil)
        #expect(model.message == message)
        #expect(model.appsWithNotificationsOff.isEmpty == (result == .switchedOn))
    }

    /// One app is switched on at a time; System Settings shows one page.
    @Test func allowsOneAppAtATime() async throws {
        try fixture.write(["com.tinyspeck.slackmacgap": false, "com.vivaldi.Vivaldi": false])
        let model = model(received: [Self.fromMacOS("Slack", "com.tinyspeck.slackmacgap"), Self.fromMacOS("Vivaldi", "com.vivaldi.Vivaldi")])
        model.refresh()
        let vivaldi = AppNotificationsModel.App(bundleIdentifier: "com.vivaldi.Vivaldi", name: "Vivaldi")
        switcher.whileSwitching = { await model.allow(vivaldi) }

        await model.allow(model.appsWithNotificationsOff[0])

        #expect(switcher.requests.map(\.bundleIdentifier) == ["com.tinyspeck.slackmacgap"])
    }
}

/// System Settings as the switch sees it: a window per page, titled with the app on an app's page.
@MainActor
final class FakeSystemSettings {
    var windows: [FakeElement] = []
    var opened: [URL] = []
    var sleeps = 0
    /// What a URL with a bundle identifier shows; nil keeps the current page, as for an unknown identifier.
    var pages: [String: FakeElement] = [:]
    /// Sleeps before a newly opened page shows.
    var loadDelay = 0
    private var pendingPage: (window: FakeElement?, at: Int)?

    /// An app's page with its Allow Notifications switch, nested as deep as on macOS 26.
    static func page(title: String, allowed: Bool, accepts: Bool = true) -> FakeElement {
        let toggle = FakeElement([kAXRoleAttribute: kAXCheckBoxRole, kAXIdentifierAttribute: SystemSettingsNotificationSwitch.switchIdentifier])
        toggle.flags[kAXValueAttribute] = allowed
        toggle.onPerform = { if accepts { $0.flags[kAXValueAttribute] = true } }
        var element = toggle
        for _ in 0..<8 {
            element = FakeElement(children: [element])
        }
        return FakeElement([kAXTitleAttribute: title], children: [element])
    }

    func toggle(in window: FakeElement) -> FakeElement {
        var element = window
        while let child = element.childElements.first { element = child }
        return element
    }

    func open(_ url: URL) {
        opened.append(url)
        let identifier = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
        let page = identifier.flatMap { pages[$0] }
        pendingPage = (page, sleeps + loadDelay)
        showPendingPage()
    }

    func sleep() {
        sleeps += 1
        showPendingPage()
    }

    private func showPendingPage() {
        guard let pending = pendingPage, sleeps >= pending.at else { return }
        pendingPage = nil
        if let window = pending.window { windows = [window] }
    }

    func makeSwitch(trusted: Bool = true) -> SystemSettingsNotificationSwitch {
        SystemSettingsNotificationSwitch(
            isTrusted: { trusted },
            open: { [self] in open($0) },
            windows: { [self] in windows },
            sleep: { [self] _ in sleep() }
        )
    }
}

@MainActor
struct SystemSettingsNotificationSwitchTests {
    let settings = FakeSystemSettings()

    @Test func opensNotificationSettingsByURL() {
        #expect(SystemSettingsNotificationSwitch.pageURL(bundleIdentifier: "com.tinyspeck.slackmacgap").absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.tinyspeck.slackmacgap")
    }

    /// While another app's page still shows, it waits for the app's own page and presses the switch there.
    @Test func switchesOnThroughTheAppsOwnPage() async {
        let vivaldi = FakeSystemSettings.page(title: "Vivaldi", allowed: false)
        let slack = FakeSystemSettings.page(title: "Slack", allowed: false)
        settings.windows = [vivaldi]
        settings.pages = ["com.tinyspeck.slackmacgap": slack]
        settings.loadDelay = 3

        let result = await settings.makeSwitch().allowNotifications(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")

        #expect(result == .switchedOn)
        #expect(settings.opened == [SystemSettingsNotificationSwitch.pageURL(bundleIdentifier: "com.tinyspeck.slackmacgap")])
        #expect(settings.toggle(in: vivaldi).performed.isEmpty)
        #expect(settings.toggle(in: slack).performed == [kAXPressAction])
    }

    @Test func leavesASwitchThatIsOnAlone() async {
        let slack = FakeSystemSettings.page(title: "Slack", allowed: true)
        settings.pages = ["com.tinyspeck.slackmacgap": slack]

        #expect(await settings.makeSwitch().allowNotifications(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack") == .alreadyOn)
        #expect(settings.toggle(in: slack).performed.isEmpty)
    }

    /// An identifier System Settings does not know leaves another app's page in place, and a page titled with
    /// another name is not the app's.
    @Test(arguments: [nil, "Vivaldi"])
    func pressesNothingOnAnotherPage(title: String?) async {
        settings.windows = [FakeSystemSettings.page(title: "Vivaldi", allowed: false)]
        if let title {
            settings.pages = ["com.tinyspeck.slackmacgap": FakeSystemSettings.page(title: title, allowed: false)]
        }

        let result = await settings.makeSwitch().allowNotifications(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")

        #expect(result == .pageNotShown)
        #expect(settings.windows.allSatisfy { settings.toggle(in: $0).performed.isEmpty })
        #expect(settings.sleeps == SystemSettingsNotificationSwitch.attempts)
    }

    @Test func reportsASwitchThatStaysOff() async {
        let slack = FakeSystemSettings.page(title: "Slack", allowed: false, accepts: false)
        settings.pages = ["com.tinyspeck.slackmacgap": slack]

        #expect(await settings.makeSwitch().allowNotifications(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack") == .refused)
        #expect(settings.toggle(in: slack).performed == [kAXPressAction])
    }

    /// Without Accessibility only the app's page opens, for the user to switch on.
    @Test func onlyOpensThePageWithoutAccessibility() async {
        let result = await settings.makeSwitch(trusted: false).allowNotifications(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")

        #expect(result == .needsAccessibility)
        #expect(settings.opened == [SystemSettingsNotificationSwitch.pageURL(bundleIdentifier: "com.tinyspeck.slackmacgap")])
    }
}

@MainActor
struct SwitchedOffAppsRowsTests {
    let fixture: NotificationPreferencesFixture
    let switcher = FakeAppNotificationSwitch()

    init() throws {
        fixture = try NotificationPreferencesFixture()
    }

    func rows(_ model: AppNotificationsModel) -> some View {
        Grid { SwitchedOffAppsRows(model: model) }.environment(\.appIcon, { _ in nil })
    }

    /// A helper's row adds its own name, which the Allow button's VoiceOver label uses too.
    @Test func showsTheInstalledNameOfHelpers() throws {
        let helper = "com.vivaldi.Vivaldi.framework.AlertNotificationService"
        try fixture.write([helper: false])
        let model = AppNotificationsModel(
            preferences: fixture.preferences, switcher: switcher,
            installedApp: { InstalledApps.App(name: "Vivaldi Helper (Alerts)", bundleIdentifier: $0) }
        ) {
            [AppNotificationsModelTests.fromMacOS("Vivaldi", helper)]
        }
        model.refresh()
        let sut = try rows(model).inspect()

        let name = try sut.find(text: "Vivaldi Helper (Alerts)")
        #expect(try name.attributes().font() == Typography(SidebarSettings.Font()).font(.subheadline))
        #expect(throws: Never.self) { try sut.find(viewWithAccessibilityLabel: "Allow notifications from Vivaldi Helper (Alerts)") }
    }

    @Test func listsSwitchedOffAppsWithAllowButtons() async throws {
        try fixture.write(["com.tinyspeck.slackmacgap": false])
        let model = AppNotificationsModel(preferences: fixture.preferences, switcher: switcher) {
            [AppNotificationsModelTests.fromMacOS("Slack", "com.tinyspeck.slackmacgap")]
        }
        model.refresh()
        let sut = try rows(model).inspect()

        #expect(throws: Never.self) { try sut.find(text: "Slack") }
        #expect(throws: Never.self) { try sut.find(text: "Their cards can switch to the app but not open the message.") }
        try sut.find(button: "Allow").tap()
        // The button starts the request in a task.
        for _ in 0..<1000 where switcher.requests.isEmpty { await Task.yield() }
        #expect(switcher.requests.map(\.bundleIdentifier) == ["com.tinyspeck.slackmacgap"])
    }

    @Test func saysWhenNoAppIsSwitchedOffOrItCannotTell() throws {
        try fixture.write(["com.openai.codex": true])
        let allowed = AppNotificationsModel(preferences: fixture.preferences, switcher: switcher) {
            [AppNotificationsModelTests.fromMacOS("Codex", "com.openai.codex")]
        }
        allowed.refresh()
        let unknown = AppNotificationsModel.fake()
        unknown.refresh()

        #expect(throws: Never.self) { try rows(allowed).inspect().find(text: "None") }
        #expect(throws: Never.self) { try rows(allowed).inspect().find(text: "Apps that notify with notifications off in macOS show here.") }
        #expect(throws: Never.self) { try rows(unknown).inspect().find(text: "Unknown") }
        #expect(throws: Never.self) { try rows(unknown).inspect().find(text: "Needs Full Disk Access to read macOS's notification settings.") }
    }
}
