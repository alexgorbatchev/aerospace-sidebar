import AppKit
import Foundation
@testable import SidebarKit
import Testing

@MainActor
struct SettingsFileTests {
    @Test func locatesConfigUnderXDGConfigHome() {
        let home = URL(fileURLWithPath: "/Users/dev")

        #expect(SettingsFile(home: home, environment: [:]).url.path == "/Users/dev/.config/aerospace-sidebar/config.toml")
        #expect(SettingsFile(home: home, environment: ["XDG_CONFIG_HOME": "/xdg"]).url.path == "/xdg/aerospace-sidebar/config.toml")
    }

    @Test func missingFileMeansDefaults() throws {
        let directory = try TemporaryDirectory()

        #expect(try SettingsFile(url: directory.url.appendingPathComponent("config.toml")).load() == SidebarSettings())
    }

    @Test func savesReadableTOMLWithHeaderAndRoundTrips() throws {
        let directory = try TemporaryDirectory()
        let file = SettingsFile(url: directory.url.appendingPathComponent("nested/config.toml"))
        let settings = SidebarSettings(
            sidebar: .init(side: .left, width: 420),
            notifications: .init(replaceSystem: false, actionableLeftToMacOS: false, appsLeftToMacOS: ["zoom.us", "Calendar"], listsSwitchedOffApps: true),
            history: .init(retentionHours: 48, maxCount: 500),
            font: .init(name: "Menlo", size: 14.5),
            background: .init(color: SidebarSettings.RGBColor(red: 0x1E, green: 0x2A, blue: 0x3B), opacity: 0.6)
        )

        try file.save(settings)
        let text = try String(contentsOf: file.url, encoding: .utf8)

        #expect(text.hasPrefix(SettingsFile.header))
        #expect(text.contains("[sidebar]") && text.contains("side = \"left\"") && text.contains("width = 420"))
        #expect(text.contains("[history]"))
        #expect(text.contains("retention_hours = 48"))
        #expect(text.contains("[font]") && text.contains("name = \"Menlo\""))
        #expect(text.contains("apps_left_to_macos = [") && text.contains("\"zoom.us\""))
        #expect(text.contains("actionable_left_to_macos = false"))
        #expect(text.contains("list_switched_off_apps = true"))
        #expect(text.contains("[background]") && text.contains("color = \"#1E2A3B\"") && text.contains("opacity = 0.6"))
        // Without rules there is no `rules = []` above the tables.
        #expect(!text.contains("rules"))
        #expect(try file.load() == settings)
    }

    @Test func partialFileKeepsDefaultsForMissingKeys() throws {
        let directory = try TemporaryDirectory()
        try directory.write("[history]\nmax_count = 50\n", to: "config.toml")

        let settings = try SettingsFile(url: directory.url.appendingPathComponent("config.toml")).load()

        #expect(settings == SidebarSettings(history: .init(retentionHours: 24, maxCount: 50)))
        #expect(settings.notifications.replaceSystem)
        #expect(settings.notifications.actionableLeftToMacOS)
        #expect(!settings.notifications.listsSwitchedOffApps)
    }

    @Test func fontSizeAcceptsIntegers() throws {
        let directory = try TemporaryDirectory()
        try directory.write("[font]\nsize = 16\n", to: "config.toml")

        let settings = try SettingsFile(url: directory.url.appendingPathComponent("config.toml")).load()

        #expect(settings.font == SidebarSettings.Font(name: "", size: 16))
    }

    @Test(arguments: [
        ("[history]\nretention_hours = 0\n", "retention_hours must be between 1 and 720"),
        ("[history]\nmax_count = 5\n", "max_count must be between 10 and 2000"),
        ("[font]\nsize = 4\n", "font.size: size must be between 8 and 32"),
        ("[sidebar]\nwidth = 100\n", "sidebar.width: width must be between 150 and 1000"),
        ("[sidebar]\nside = \"top\"\n", "sidebar.side"),
        ("[notifications]\nreplace_system = \"yes\"\n", "notifications.replace_system"),
        ("[notifications]\nlist_switched_off_apps = 1\n", "notifications.list_switched_off_apps"),
        ("[background]\nopacity = 1.5\n", "background.opacity: opacity must be between 0 and 1"),
        ("[background]\ncolor = \"red\"\n", "background.color: color must be written #RRGGBB, not red"),
        ("[background]\ncolor = \"#+12345\"\n", "background.color: color must be written #RRGGBB, not #+12345"),
    ])
    func rejectsInvalidValues(toml: String, fragment: String) throws {
        let directory = try TemporaryDirectory()
        try directory.write(toml, to: "config.toml")

        #expect {
            try SettingsFile(url: directory.url.appendingPathComponent("config.toml")).load()
        } throws: { error in
            SettingsStore.describe(error).contains(fragment)
        }
    }

    /// A misspelled key or table would otherwise be ignored and leave its setting at the default.
    @Test(arguments: [
        ("[notification]\nreplace_system = false\n", "unknown key notification; expected sidebar, notifications, history, font, background, or rules"),
        ("replace_system = false\n", "unknown key replace_system; expected sidebar, notifications, history, font, background, or rules"),
        ("[background]\nalpha = 0.5\n", "background: unknown key alpha; expected color or opacity"),
        ("[notifications]\nreplace_sytem = false\n", "notifications: unknown key replace_sytem; expected replace_system, actionable_left_to_macos, apps_left_to_macos, or list_switched_off_apps"),
        ("[sidebar]\nwdth = 300\nsid = \"left\"\n", "sidebar: unknown keys sid and wdth; expected side or width"),
        ("sidebar.wide = 300\n", "sidebar: unknown key wide; expected side or width"),
        ("[history]\nmax = 50\n", "history: unknown key max; expected retention_hours or max_count"),
        ("[font]\nfamily = \"Menlo\"\n", "font: unknown key family; expected name or size"),
    ])
    func rejectsUnknownKeys(toml: String, message: String) throws {
        let directory = try TemporaryDirectory()
        try directory.write(toml, to: "config.toml")

        #expect {
            try SettingsFile(url: directory.url.appendingPathComponent("config.toml")).load()
        } throws: { error in
            SettingsStore.describe(error) == message
        }
    }

    /// Every key the app writes is one it reads back, with every table and pattern set.
    @Test func writtenConfigLoadsAgain() throws {
        let directory = try TemporaryDirectory()
        let file = SettingsFile(url: directory.url.appendingPathComponent("config.toml"))
        let settings = SidebarSettings(
            sidebar: .init(side: .left, width: 420),
            notifications: .init(replaceSystem: false, actionableLeftToMacOS: false, appsLeftToMacOS: ["zoom.us"]),
            history: .init(retentionHours: 48, maxCount: 500),
            font: .init(name: "Menlo", size: 14),
            rules: [SidebarSettings.Rule(source: "^Slack$", title: "deploy", subtitle: "prod", body: "failed", action: .hide)]
        )
        let store = SettingsStore(file: file)

        store.update { $0 = settings }
        store.reload()

        #expect(store.loadError == nil)
        #expect(try file.load() == settings)
    }

    @Test func matchesAppsLeftToMacOSCaseInsensitively() {
        let notifications = SidebarSettings.Notifications(appsLeftToMacOS: ["Zoom.us"])

        #expect(notifications.leavesToMacOS("zoom.US"))
        #expect(!notifications.leavesToMacOS("Mail"))
    }
}

@MainActor
struct SettingsStoreTests {
    let directory: TemporaryDirectory
    let file: SettingsFile

    init() throws {
        directory = try TemporaryDirectory()
        file = SettingsFile(url: directory.url.appendingPathComponent("config.toml"))
    }

    @Test func fontPreviewShowsUntilClearedWithoutWritingTheFile() throws {
        let store = SettingsStore(file: file)
        var fonts: [SidebarSettings.Font] = []
        store.observeFont { fonts.append($0) }
        let menlo = SidebarSettings.Font(name: "Menlo", size: 16)

        store.preview(font: menlo)
        store.preview(font: menlo)
        store.update { $0.history.maxCount = 300 }

        #expect(store.font == menlo)
        #expect(store.settings.font == SidebarSettings.Font())
        #expect(!(try String(contentsOf: file.url, encoding: .utf8)).contains("Menlo"))

        store.preview(font: nil)

        #expect(store.font == SidebarSettings.Font())
        #expect(fonts == [menlo, SidebarSettings.Font()])
    }

    @Test func backgroundPreviewShowsUntilClearedWithoutWritingTheFile() throws {
        let store = SettingsStore(file: file)
        var backgrounds: [SidebarSettings.Background] = []
        store.observeBackground { backgrounds.append($0) }
        let gray = SidebarSettings.Background(color: SidebarSettings.RGBColor(red: 40, green: 40, blue: 40), opacity: 0.5)

        store.preview(background: gray)
        store.preview(background: gray)
        store.update { $0.history.maxCount = 300 }

        #expect(store.background == gray)
        #expect(store.settings.background == SidebarSettings.Background())
        #expect(!(try String(contentsOf: file.url, encoding: .utf8)).contains("#282828"))

        store.preview(background: nil)
        store.update { $0.background.opacity = 0.2 }

        #expect(backgrounds == [gray, SidebarSettings.Background(), SidebarSettings.Background(opacity: 0.2)])
    }

    @Test func savedFontChangesNotifyFontObservers() {
        let store = SettingsStore(file: file)
        var fonts: [SidebarSettings.Font] = []
        store.observeFont { fonts.append($0) }

        store.update { $0.font.size = 15 }

        #expect(fonts == [SidebarSettings.Font(size: 15)])
    }

    @Test func updateSavesAndNotifiesObservers() throws {
        let store = SettingsStore(file: file)
        var observed: [SidebarSettings] = []
        store.observe { observed.append($0) }

        store.update { $0.history.maxCount = 300 }
        store.update { $0.history.maxCount = 300 }

        #expect(observed.map(\.history.maxCount) == [200, 300])
        #expect(try file.load().history.maxCount == 300)
        #expect(store.saveError == nil)
    }

    @Test func reportsSaveFailuresButKeepsTheChange() {
        let store = SettingsStore(file: SettingsFile(url: URL(fileURLWithPath: "/nonexistent-root/config.toml")))

        store.update { $0.notifications.replaceSystem = false }

        #expect(store.saveError != nil)
        #expect(!store.settings.notifications.replaceSystem)
    }

    /// Settings a failed save left unwritten are written by the next update, although it changes nothing.
    @Test func writesSettingsAFailedSaveLeftUnwritten() throws {
        let store = SettingsStore(file: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.url.path) }
        store.update { $0.history.maxCount = 300 }
        #expect(store.saveError != nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.url.path)
        store.update { $0.history.maxCount = 300 }

        #expect(store.saveError == nil)
        #expect(try file.load().history.maxCount == 300)
    }

    @Test func savingReplacesAnInvalidFile() throws {
        try directory.write("[history\n", to: "config.toml")
        let store = SettingsStore(file: file)
        #expect(store.loadError != nil)

        store.update { $0.history.maxCount = 300 }

        #expect(store.loadError == nil)
        #expect(try file.load().history.maxCount == 300)
    }

    /// A file that does not load holds none of the settings in effect, so saving them unchanged writes them.
    @Test func savingUnchangedSettingsReplacesAnInvalidFile() throws {
        let store = SettingsStore(file: file)
        store.update { $0.history.maxCount = 300 }
        try directory.write("[history\n", to: "config.toml")
        store.reload()
        #expect(store.loadError != nil)

        store.update { _ in }

        #expect(store.loadError == nil)
        #expect(try file.load().history.maxCount == 300)
    }

    @Test func invalidFileAtLaunchUsesDefaultsAndReportsIt() throws {
        try directory.write("[history\n", to: "config.toml")

        let store = SettingsStore(file: file)

        #expect(store.settings == SidebarSettings())
        #expect(store.loadError != nil)
    }

    @Test func reloadAppliesValidEditsAndKeepsPreviousOnInvalidOnes() throws {
        let store = SettingsStore(file: file)
        try directory.write("[history]\nretention_hours = 6\n", to: "config.toml")
        store.reload()
        #expect(store.settings.history.retentionHours == 6)
        #expect(store.loadError == nil)

        try directory.write("[history]\nretention_hours = 9999\n", to: "config.toml")
        store.reload()
        #expect(store.settings.history.retentionHours == 6)
        #expect(store.loadError?.contains("retention_hours") == true)
    }

    /// A rule with a misspelled pattern key would hide every notification from its source; the store refuses
    /// the file instead, at launch and on reload.
    @Test func refusesAFileWithAnUnknownKey() throws {
        let rule = SidebarSettings.Rule(source: "Slack", title: "deploy failed", action: .hide)
        let typo = "[[rules]]\nsource = \"Slack\"\ntitel = \"deploy failed\"\naction = \"hide\"\n"
        let message = "rules[0]: unknown key titel; expected source, title, subtitle, body, or action"
        try directory.write(typo, to: "config.toml")

        let launched = SettingsStore(file: file)

        #expect(launched.settings == SidebarSettings())
        #expect(launched.loadError == message)
        #expect(launched.loadProblem == "config.toml is invalid, so the default settings are in effect: \(message)")
        launched.reload()
        #expect(launched.loadProblem == "config.toml is invalid, so the default settings are in effect: \(message)")

        launched.update { $0.rules = [rule] }
        #expect(launched.loadProblem == nil)
        try directory.write(typo, to: "config.toml")
        launched.reload()

        #expect(launched.settings.rules == [rule])
        #expect(launched.loadError == message)
        #expect(launched.loadProblem == "config.toml is invalid, so the previous settings stay in effect: \(message)")
    }

    @Test func watchingAppliesExternalEdits() async throws {
        let store = SettingsStore(file: file)
        try store.startWatching()
        defer { store.stopWatching() }

        try "[history]\nmax_count = 70\n".write(to: file.url, atomically: true, encoding: .utf8)
        for _ in 0..<100 where store.settings.history.maxCount != 70 {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.settings.history.maxCount == 70)
    }

    /// Writing in place, as `echo … > config.toml` does, leaves the directory untouched.
    @Test func watchingAppliesEditsWrittenInPlace() async throws {
        try "[history]\nmax_count = 60\n".write(to: file.url, atomically: true, encoding: .utf8)
        let store = SettingsStore(file: file)
        try store.startWatching()
        defer { store.stopWatching() }

        let handle = try FileHandle(forWritingTo: file.url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("[history]\nmax_count = 80\n".utf8))
        try handle.close()
        for _ in 0..<150 where store.settings.history.maxCount != 80 {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.settings.history.maxCount == 80)
    }

    /// A config.toml kept elsewhere, such as in a dotfiles repository, and linked in, through relative and chained
    /// links, stays a link when saved: the write goes to its target, also when that is missing.
    @Test func savingASymlinkedFileWritesItsTarget() throws {
        let link = directory.url.appendingPathComponent("linked/config.toml")
        let target = directory.url.appendingPathComponent("dotfiles/sidebar/config.toml")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "current.toml")
        try FileManager.default.createSymbolicLink(
            atPath: link.deletingLastPathComponent().appendingPathComponent("current.toml").path,
            withDestinationPath: "../dotfiles/sidebar/config.toml"
        )
        let file = SettingsFile(url: link)
        let settings = SidebarSettings(history: .init(retentionHours: 12, maxCount: 40))

        try file.save(settings)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "current.toml")
        #expect(try SettingsFile(url: target).load() == settings)
        try file.save(SidebarSettings())
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "current.toml")
        #expect(try file.load() == SidebarSettings())
    }

    /// Edits at a symlinked file's target apply, also once the target was removed and created again, which leaves
    /// the link's directory as it was; once the file is one of its own, its old target no longer matters.
    @Test func watchingFollowsTheTargetOfASymlinkedFile() async throws {
        let target = directory.url.appendingPathComponent("dotfiles/config.toml")
        try directory.write("[history]\nmax_count = 50\n", to: "dotfiles/config.toml")
        try FileManager.default.createSymbolicLink(at: file.url, withDestinationURL: target)
        let store = SettingsStore(file: file)
        try store.startWatching()
        defer { store.stopWatching() }
        func waitFor(_ maxCount: Int) async throws {
            for _ in 0..<150 where store.settings.history.maxCount != maxCount {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(store.settings.history.maxCount == maxCount)
        }
        #expect(store.settings.history.maxCount == 50)

        try "[history]\nmax_count = 60\n".write(to: target, atomically: true, encoding: .utf8)
        try await waitFor(60)

        try FileManager.default.removeItem(at: target)
        try await waitFor(200)
        try "[history]\nmax_count = 70\n".write(to: target, atomically: true, encoding: .utf8)
        try await waitFor(70)

        try FileManager.default.removeItem(at: file.url)
        try "[history]\nmax_count = 80\n".write(to: file.url, atomically: true, encoding: .utf8)
        try await waitFor(80)
        try "[history]\nmax_count = 90\n".write(to: target, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.settings.history.maxCount == 80)
    }

    @Test func watchingFailsForUncreatableDirectory() {
        let store = SettingsStore(file: SettingsFile(url: URL(fileURLWithPath: "/nonexistent-root/x/config.toml")))

        #expect(throws: (any Error).self) { try store.startWatching() }
    }

    @Test func describesNonDecodingErrors() {
        #expect(SettingsStore.describe(CocoaError(.fileReadNoPermission)).contains("CocoaError"))
    }
}

struct RGBColorTests {
    @Test(arguments: [("#1e2A3b", "#1E2A3B"), ("#000000", "#000000"), ("#FFFFFF", "#FFFFFF")])
    func readsAndWritesHex(hex: String, written: String) throws {
        #expect(try #require(SidebarSettings.RGBColor(hex: hex)).description == written)
    }

    @Test(arguments: ["", "#12345", "#1234567", "123456#", "#12345G", "#+12345", "#-12345", "#１２３４５６"])
    func refusesOtherText(hex: String) {
        #expect(SidebarSettings.RGBColor(hex: hex) == nil)
    }

    /// Colors from the color panel come in any color space; settings keep them as sRGB.
    @Test @MainActor func convertsToAndFromAppKitColors() {
        let color = SidebarSettings.RGBColor(red: 0x1E, green: 0x2A, blue: 0x3B)

        #expect(SidebarSettings.RGBColor(color.nsColor) == color)
        #expect(SidebarSettings.RGBColor(NSColor(deviceWhite: 1, alpha: 0.5)) == SidebarSettings.RGBColor(red: 255, green: 255, blue: 255))
        #expect(SidebarSettings.RGBColor(NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)) == SidebarSettings.RGBColor(red: 255, green: 0, blue: 0))
    }
}
