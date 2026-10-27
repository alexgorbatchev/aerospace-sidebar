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
            notifications: .init(replaceSystem: false, appsLeftToMacOS: ["zoom.us", "Calendar"]),
            history: .init(retentionHours: 48, maxCount: 500),
            font: .init(name: "Menlo", size: 14.5)
        )

        try file.save(settings)
        let text = try String(contentsOf: file.url, encoding: .utf8)

        #expect(text.hasPrefix(SettingsFile.header))
        #expect(text.contains("[history]"))
        #expect(text.contains("retention_hours = 48"))
        #expect(text.contains("[font]") && text.contains("name = \"Menlo\""))
        #expect(text.contains("apps_left_to_macos = [") && text.contains("\"zoom.us\""))
        #expect(try file.load() == settings)
    }

    @Test func partialFileKeepsDefaultsForMissingKeys() throws {
        let directory = try TemporaryDirectory()
        try directory.write("[history]\nmax_count = 50\n", to: "config.toml")

        let settings = try SettingsFile(url: directory.url.appendingPathComponent("config.toml")).load()

        #expect(settings == SidebarSettings(history: .init(retentionHours: 24, maxCount: 50)))
        #expect(settings.notifications.replaceSystem)
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
        ("[notifications]\nreplace_system = \"yes\"\n", "notifications.replace_system"),
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

    @Test func watchingFailsForUncreatableDirectory() {
        let store = SettingsStore(file: SettingsFile(url: URL(fileURLWithPath: "/nonexistent-root/x/config.toml")))

        #expect(throws: (any Error).self) { try store.startWatching() }
    }

    @Test func describesNonDecodingErrors() {
        #expect(SettingsStore.describe(CocoaError(.fileReadNoPermission)).contains("CocoaError"))
    }
}
