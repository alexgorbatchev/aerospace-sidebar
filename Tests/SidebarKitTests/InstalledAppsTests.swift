import AppKit
@testable import SidebarKit
import Testing

@MainActor
struct InstalledAppsTests {
    let temporary: TemporaryDirectory
    var directory: URL { temporary.url }

    init() throws {
        temporary = try TemporaryDirectory()
    }

    /// Writes an app bundle at `path` below the test directory.
    @discardableResult
    func makeApp(_ path: String, identifier: String, name: String? = nil, displayName: String? = nil) throws -> URL {
        let app = directory.appendingPathComponent(path)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"]
        info["CFBundleName"] = name
        info["CFBundleDisplayName"] = displayName
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    func makeApps(running: [(name: String?, bundleIdentifier: String?)] = []) -> InstalledApps {
        InstalledApps(applicationDirectories: [directory], runningApplications: { running }, applicationURL: { _ in nil })
    }

    /// The app that posted is usually running, so a running app with the name wins over an installed one.
    @Test func findsARunningAppByName() throws {
        try makeApp("Slack.app", identifier: "com.example.installed-slack")
        let apps = makeApps(running: [("Mail", "com.apple.mail"), ("Slack", "com.tinyspeck.slackmacgap")])

        #expect(apps.bundleIdentifier(named: "Slack") == "com.tinyspeck.slackmacgap")
    }

    /// An app that is not running is found by its file name or the names in its Info.plist, also one
    /// folder down, but not deeper.
    @Test func findsInstalledAppsByAnyOfTheirNames() throws {
        try makeApp("Calendar.app", identifier: "com.apple.iCal")
        try makeApp("zoom.us.app", identifier: "us.zoom.xos", name: "zoom.us")
        try makeApp("Teams.app", identifier: "com.microsoft.teams2", displayName: "Microsoft Teams")
        try makeApp("Setapp/Bartender.app", identifier: "com.surteesstudios.Bartender")
        try makeApp("Vendor/Nested/Deep.app", identifier: "com.example.deep")
        let apps = makeApps()

        #expect(apps.bundleIdentifier(named: "Calendar") == "com.apple.iCal")
        #expect(apps.bundleIdentifier(named: "zoom.us") == "us.zoom.xos")
        #expect(apps.bundleIdentifier(named: "Microsoft Teams") == "com.microsoft.teams2")
        #expect(apps.bundleIdentifier(named: "Bartender") == "com.surteesstudios.Bartender")
        #expect(apps.bundleIdentifier(named: "Deep") == nil)
        #expect(apps.bundleIdentifier(named: "Not Installed") == nil)
    }

    /// Each name scans the application directories once; a miss is remembered too.
    @Test func remembersEachNameItLookedUp() throws {
        let slack = try makeApp("Slack.app", identifier: "com.tinyspeck.slackmacgap")
        let apps = makeApps()

        #expect(apps.bundleIdentifier(named: "Slack") == "com.tinyspeck.slackmacgap")
        #expect(apps.bundleIdentifier(named: "Later") == nil)
        try FileManager.default.removeItem(at: slack)
        try makeApp("Later.app", identifier: "com.example.later")

        #expect(apps.bundleIdentifier(named: "Slack") == "com.tinyspeck.slackmacgap")
        #expect(apps.bundleIdentifier(named: "Later") == nil)
    }

    /// The icon is the one Finder shows for the installed app, looked up once per bundle identifier.
    @Test func loadsTheIconOfTheInstalledApp() throws {
        let slack = try makeApp("Slack.app", identifier: "com.tinyspeck.slackmacgap")
        var lookups: [String] = []
        let apps = InstalledApps(applicationDirectories: [], runningApplications: { [] }) {
            lookups.append($0)
            return $0 == "com.tinyspeck.slackmacgap" ? slack : nil
        }

        let icon = try #require(apps.icon(bundleIdentifier: "com.tinyspeck.slackmacgap"))

        #expect(icon.size.width > 0)
        #expect(apps.icon(bundleIdentifier: "com.tinyspeck.slackmacgap") === icon)
        #expect(apps.icon(bundleIdentifier: "com.example.removed") == nil)
        #expect(apps.icon(bundleIdentifier: "com.example.removed") == nil)
        #expect(lookups == ["com.tinyspeck.slackmacgap", "com.example.removed"])
    }

    /// The notification database stores bundle identifiers in lowercase; the app is found all the same, under
    /// the identifier it declares, which running apps and usernoted's preferences go by.
    @Test func findsInstalledAppsInAnyCase() {
        let scriptEditor = InstalledApps.App(name: "Script Editor", bundleIdentifier: "com.apple.ScriptEditor2")
        #expect(InstalledApps.app(bundleIdentifier: "com.apple.finder") == InstalledApps.App(name: "Finder", bundleIdentifier: "com.apple.finder"))
        #expect(InstalledApps.app(bundleIdentifier: "com.apple.ScriptEditor2") == scriptEditor)
        #expect(InstalledApps.app(bundleIdentifier: "com.apple.scripteditor2") == scriptEditor)
        #expect(InstalledApps.app(bundleIdentifier: "com.example.not-installed") == nil)
    }

    /// The real lookups find the apps macOS ships.
    @Test func findsSystemAppsAndTheirIcons() throws {
        let apps = InstalledApps()

        #expect(apps.bundleIdentifier(named: "Script Editor") == "com.apple.ScriptEditor2")
        #expect(apps.icon(bundleIdentifier: "com.apple.ScriptEditor2") != nil)
    }
}
