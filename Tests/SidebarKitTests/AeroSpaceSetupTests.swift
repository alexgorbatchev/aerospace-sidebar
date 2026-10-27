import AppKit
@testable import SidebarKit
import SidebarProtocol
import Testing

struct AeroSpaceConfigEditorTests {
    static let rule = AeroSpaceConfigEditor.floatRule
    static let ruleWithComment = AeroSpaceConfigEditor.floatRuleComment + "\n" + rule
    static let right = SidebarSettings.Sidebar()
    static let left = SidebarSettings.Sidebar(side: .left, width: 300)
    static let start = AeroSpaceConfigEditor.blockStart
    static let end = AeroSpaceConfigEditor.blockEnd

    /// The managed block with `prefix` keys.
    static func block(_ left: String, _ right: String, prefix: String = "outer.") -> String {
        "\(start)\n\(prefix)left = \(left)\n\(prefix)right = \(right)\n\(end)"
    }

    @Test func reportsConfiguredConfig() {
        let analysis = AeroSpaceConfigEditor.analyze("[gaps]\nouter.right = [{ monitor.main = 305 }, 5]\n\n\(Self.rule)\n", sidebar: Self.right)

        #expect(analysis == .init(sidebar: Self.right, reservedWidth: 300, oppositeReservedWidth: nil, missingFloatRule: false, warnings: []))
        #expect(analysis.isConfigured)
    }

    @Test(arguments: [
        // Wrong width.
        (SidebarSettings.Sidebar(width: 400), 300, nil as Int?),
        // Reserved on the other side.
        (SidebarSettings.Sidebar(side: .left, width: 300), nil, 300),
    ] as [(SidebarSettings.Sidebar, Int?, Int?)])
    func reportsGapThatDoesNotMatchSettings(sidebar: SidebarSettings.Sidebar, reserved: Int?, opposite: Int?) {
        let analysis = AeroSpaceConfigEditor.analyze("[gaps]\nouter.right = [{ monitor.main = 305 }, 5]\n\n\(Self.rule)\n", sidebar: sidebar)

        #expect(analysis.reservedWidth == reserved && analysis.oppositeReservedWidth == opposite)
        #expect(!analysis.gapMatches && !analysis.isConfigured)
    }

    @Test func reportsMissingPiecesAndWarnings() {
        let text = """
            # \(SidebarApp.bundleIdentifier) mentioned only in a comment
            [mode.main.binding]
            alt-f = 'fullscreen --no-outer-gaps'
            """

        let analysis = AeroSpaceConfigEditor.analyze(text, sidebar: Self.right)

        #expect(!analysis.gapMatches && analysis.missingFloatRule && analysis.reservedWidth == nil)
        #expect(analysis.warnings == ["A binding uses `fullscreen --no-outer-gaps`, which covers the sidebar; drop the flag."])
    }

    @Test(arguments: [
        // Both sides move into one block where the first was; other keys stay, and the comments above and
        // after the moved lines go above the block.
        (
            "[gaps]\ninner.horizontal = 10\n# sides\nouter.left = 5 # left\nouter.top = 5\n# strip\n# more\nouter.right = 5 # edge\n",
            "[gaps]\ninner.horizontal = 10\n# sides\n# left\n# strip\n# more\n# edge\n" + block("5", "[{ monitor.main = 305 }, 5]") + "\nouter.top = 5\n"
        ),
        // Other monitors keep their entries and order, after the main entry; regex patterns keep their backslashes.
        (
            "[gaps]\nouter.right = [{ monitor.secondary = 20 }, { monitor.'^LG\\d' = 7 }, 8]\n",
            "[gaps]\n" + block("0", "[{ monitor.main = 308 }, { monitor.secondary = 20 }, { monitor.'^LG\\d' = 7 }, 8]")
        ),
        // A main entry with the wrong width is replaced.
        (
            "[gaps]\nouter.right = [{ monitor.\"^LG.*\" = 50 }, { monitor.main = 5 }, 5]\n",
            "[gaps]\n" + block("0", "[{ monitor.main = 305 }, { monitor.'^LG.*' = 50 }, 5]")
        ),
        // Dotted keys at the root.
        ("gaps.outer.right = 4\n[mode.main.binding]\n", block("0", "[{ monitor.main = 304 }, 4]", prefix: "gaps.outer.") + "\n[mode.main.binding]\n"),
        // [gaps.outer] table.
        ("[gaps.outer]\nright = 2\n", "[gaps.outer]\n" + block("0", "[{ monitor.main = 302 }, 2]", prefix: "")),
        // [gaps] without outer sides.
        ("[gaps]\ninner.horizontal = 10\n", "[gaps]\n" + block("0", "[{ monitor.main = 300 }, 0]") + "\ninner.horizontal = 10\n"),
        // [gaps.outer] without sides.
        ("[gaps.outer]\ntop = 1\n", "[gaps.outer]\n" + block("0", "[{ monitor.main = 300 }, 0]", prefix: "") + "\ntop = 1\n"),
        // No gaps at all: root keys before the first table.
        ("start-at-login = true\n[mode.main.binding]\n", "start-at-login = true\n" + block("0", "[{ monitor.main = 300 }, 0]", prefix: "gaps.outer.") + "\n[mode.main.binding]\n"),
    ])
    func movesRightStripIntoBlock(original: String, expectedPrefix: String) throws {
        let result = try AeroSpaceConfigEditor.apply(to: original, sidebar: Self.right)

        #expect(result.hasPrefix(expectedPrefix))
        #expect(result.hasSuffix(Self.ruleWithComment + "\n"))
        #expect(AeroSpaceConfigEditor.analyze(result, sidebar: Self.right).isConfigured)
    }

    /// The layout of a config generated before the block existed, widened to 400 points.
    @Test func movesGeneratedGapIntoBlockKeepingItsComment() throws {
        let original = "[gaps]\nouter.left       = 5\nouter.bottom     = 5\n# 305 = strip + gap.\nouter.right      = [{ monitor.main = 305 }, 5]\n\n[exec]\n\n\(Self.rule)\n"

        let result = try AeroSpaceConfigEditor.apply(to: original, sidebar: SidebarSettings.Sidebar(width: 400))

        #expect(result == "[gaps]\n# 305 = strip + gap.\n" + Self.block("5", "[{ monitor.main = 405 }, 5]") + "\nouter.bottom     = 5\n\n[exec]\n\n\(Self.rule)\n")
    }

    @Test(arguments: [
        // Moving the strip: the right side keeps only its fallback.
        ("[gaps]\nouter.left = 5\nouter.right = [{ monitor.main = 305 }, 5]\n", "[gaps]\n" + block("[{ monitor.main = 305 }, 5]", "5")),
        // Other monitors' entries on the right survive.
        ("[gaps]\nouter.right = [{ monitor.main = 305 }, { monitor.secondary = 8 }, 5]\n", "[gaps]\n" + block("[{ monitor.main = 300 }, 0]", "[{ monitor.secondary = 8 }, 5]")),
        // A main entry on the right that reserves no strip is the user's own and stays.
        ("[gaps]\nouter.right = [{ monitor.main = 2 }, 5]\n", "[gaps]\n" + block("[{ monitor.main = 300 }, 0]", "[{ monitor.main = 2 }, 5]")),
    ])
    func movesStripToLeft(original: String, expectedPrefix: String) throws {
        let result = try AeroSpaceConfigEditor.apply(to: original, sidebar: Self.left)

        #expect(result.hasPrefix(expectedPrefix))
        #expect(AeroSpaceConfigEditor.analyze(result, sidebar: Self.left).isConfigured)
    }

    @Test func rewritesOnlyTheExistingBlock() throws {
        let original = "[gaps]\nouter.top = 5\n  " + Self.block("5", "[{ monitor.main = 305 }, 5]") + "\nouter.bottom = 5\n\n" + Self.rule + "\n"

        let result = try AeroSpaceConfigEditor.apply(to: original, sidebar: SidebarSettings.Sidebar(side: .left, width: 400))

        #expect(result == "[gaps]\nouter.top = 5\n" + Self.block("[{ monitor.main = 405 }, 5]", "5") + "\nouter.bottom = 5\n\n" + Self.rule + "\n")
    }

    @Test func emptyFileGetsRootBlockAndRule() throws {
        let result = try AeroSpaceConfigEditor.apply(to: "", sidebar: SidebarSettings.Sidebar(width: 250))

        #expect(result == Self.block("0", "[{ monitor.main = 250 }, 0]", prefix: "gaps.outer.") + "\n\n" + Self.ruleWithComment + "\n")
    }

    @Test func leavesConfiguredGapAlone() throws {
        let configured = "[gaps]\nouter.right = [{ monitor.main = 305 }, 5]\n"

        #expect(try AeroSpaceConfigEditor.apply(to: configured, sidebar: Self.right) == configured + "\n" + Self.ruleWithComment + "\n")
    }

    @Test func snippetConfiguresAnEmptyGapsTable() {
        let snippet = AeroSpaceConfigEditor.snippet(for: Self.left)

        #expect(snippet.hasPrefix("[gaps]\n" + Self.block("[{ monitor.main = 300 }, 0]", "0") + "\n"))
        #expect(AeroSpaceConfigEditor.analyze(snippet, sidebar: Self.left).isConfigured)
    }

    @Test(arguments: [
        ("a", "a"),
        ("main", "main"),
        ("^LG.*", "'^LG.*'"),
        ("it's", "\"it's\""),
        ("a\\b'\"\n\r", "\"a\\\\b'\\\"\\n\\r\""),
    ])
    func quotesKeysOnlyWhenNeeded(key: String, quoted: String) {
        #expect(AeroSpaceConfigEditor.tomlKey(key) == quoted)
    }

    @Test(arguments: [
        ("[gaps]\nouter.right = [\n  { monitor.secondary = 1 },\n  5,\n]\n", "spans several lines"),
        ("[gaps]\nouter.right = [{ monitor.secondary = 20 }]\n", "gaps.outer.right has a form this editor does not recognize"),
        ("[gaps]\nouter.left = [{ monitor = { main = 1, secondary = 2 } }, 0]\n", "gaps.outer.left has a form this editor does not recognize"),
        ("on-window-detected = []\n", "edited config does not parse"),
        ("[gaps\n", "the config does not parse"),
        ("[gaps]\n\(start)\nouter.right = 1\n", "has no end line"),
        ("[gaps]\n\(end)\n", "has no start line"),
        ("[gaps]\n\(start)\n\(end)\n\(start)\n\(end)\n", "more than one aerospace-sidebar block"),
        ("[gaps]\n\(start)\n[mode]\n\(end)\n", "contains a table header"),
        ("[mode]\n\(start)\n\(end)\n", "is in [mode] instead of [gaps]"),
        ("gaps.outer.left = 1\n[gaps.outer]\nright = 1\n", "the config does not parse"),
    ])
    func refusesLayoutsItCannotEditSafely(original: String, reason: String) {
        #expect {
            try AeroSpaceConfigEditor.apply(to: original, sidebar: Self.right)
        } throws: { error in
            guard case AeroSpaceConfigEditor.EditError.unsupported(let message) = error else { return false }
            return message.contains(reason)
        }
    }
}

struct AeroSpaceSetupTests {
    let home: TemporaryDirectory

    init() throws {
        home = try TemporaryDirectory()
    }

    func setup(_ cli: FakeAeroSpaceCLI = FakeAeroSpaceCLI(), isAeroSpaceRunning: Bool = true) -> AeroSpaceSetup {
        .forTesting(home: home.url, environment: [:], cli: cli, isAeroSpaceRunning: isAeroSpaceRunning)
    }

    var configURL: URL { home.url.appendingPathComponent(".config/aerospace/aerospace.toml") }
    var backupURL: URL { configURL.appendingPathExtension("bak") }
    static let sidebar = SidebarSettings.Sidebar()

    func isConfigured(_ url: URL) throws -> Bool {
        AeroSpaceConfigEditor.analyze(try String(contentsOf: url, encoding: .utf8), sidebar: Self.sidebar).isConfigured
    }

    @Test func reportsState() throws {
        #expect(setup().state(for: Self.sidebar) == .notFound)

        try home.write("[gaps]\nouter.left = 5\n", to: ".config/aerospace/aerospace.toml")
        guard case .ready(let analysis, let url) = setup().state(for: Self.sidebar) else { Issue.record("not ready"); return }
        #expect(!analysis.gapMatches)
        #expect(url == configURL)

        try home.write("", to: ".aerospace.toml")
        guard case .unreadable(let reason) = setup().state(for: Self.sidebar) else { Issue.record("not unreadable"); return }
        #expect(reason.contains("ambiguous"))
    }

    @Test func appliesValidatesAndReloads() async throws {
        try home.write("[gaps]\nouter.right = 5\n", to: ".config/aerospace/aerospace.toml")
        let cli = FakeAeroSpaceCLI()

        let outcome = try await setup(cli).apply(sidebar: Self.sidebar)

        #expect(outcome == .updated(backup: backupURL))
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "[gaps]\nouter.right = 5\n")
        #expect(try isConfigured(configURL))
        #expect(cli.calls == [["reload-config", "--dry-run", "--no-gui"], ["reload-config", "--no-gui"]])
    }

    @Test func restoresOriginalWhenAeroSpaceRejectsTheEdit() async throws {
        try home.write("[gaps]\nouter.right = 5\n", to: ".config/aerospace/aerospace.toml")
        let cli = FakeAeroSpaceCLI(results: ["--dry-run": CommandResult(status: 1, output: "bad key\n")])

        await #expect(throws: AeroSpaceSetup.SetupError.rejected("bad key")) { try await setup(cli).apply(sidebar: Self.sidebar) }

        #expect(try String(contentsOf: configURL, encoding: .utf8) == "[gaps]\nouter.right = 5\n")
        #expect(cli.calls.count == 1)
    }

    @Test func keepsEditWhenAeroSpaceCommandIsMissing() async throws {
        try home.write("", to: ".config/aerospace/aerospace.toml")
        let cli = FakeAeroSpaceCLI(results: ["--dry-run": CommandResult(status: 127, output: "command not found")])

        let outcome = try await setup(cli).apply(sidebar: Self.sidebar)

        #expect(outcome == .updatedWithoutReload(backup: backupURL))
        #expect(try isConfigured(configURL))
    }

    /// The CLI cannot reach a stopped AeroSpace, so a failed check would wrongly undo the edit.
    @Test func keepsEditWithoutCheckingWhileAeroSpaceIsStopped() async throws {
        try home.write("", to: ".config/aerospace/aerospace.toml")
        let cli = FakeAeroSpaceCLI(results: ["--dry-run": CommandResult(status: 1, output: "Can't connect to AeroSpace server")])

        let outcome = try await setup(cli, isAeroSpaceRunning: false).apply(sidebar: Self.sidebar)

        #expect(outcome == .updatedWhileStopped(backup: backupURL))
        #expect(cli.calls.isEmpty)
        #expect(try isConfigured(configURL))
    }

    /// A generator overwrites its output, so the sidebar edits it anyway and puts its block back afterwards.
    @Test func editsGeneratedConfigsKeepingOneBackup() async throws {
        try home.write("# Generated from base.toml\n", to: ".config/aerospace/aerospace.toml")
        _ = try await setup().apply(sidebar: Self.sidebar)
        #expect(try isConfigured(configURL))

        _ = try await setup().apply(sidebar: SidebarSettings.Sidebar(side: .left, width: 200))

        #expect(try String(contentsOf: backupURL, encoding: .utf8).contains("monitor.main = 300"))
        let backups = try FileManager.default.contentsOfDirectory(atPath: configURL.deletingLastPathComponent().path).filter { $0.contains(".bak") }
        #expect(backups == ["aerospace.toml.bak"])
    }

    @Test func watchesTheLoadedConfigOrTheXDGLocation() throws {
        #expect(setup().configToWatch() == configURL.resolvingSymlinksInPath())

        try home.write("", to: ".aerospace.toml")
        #expect(setup().configToWatch() == home.url.appendingPathComponent(".aerospace.toml").resolvingSymlinksInPath())
    }

    @Test func realAeroSpaceCheckMatchesRunningApps() {
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == AeroSpaceSetup.aeroSpaceBundleIdentifier }

        #expect(AeroSpaceSetup.aeroSpaceAppIsRunning() == running)
    }

    @Test func editsSymlinkTargets() async throws {
        try home.write("", to: "dotfiles/aerospace.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: home.url.appendingPathComponent("dotfiles/aerospace.toml"))

        _ = try await setup().apply(sidebar: Self.sidebar)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: configURL.path).hasSuffix("dotfiles/aerospace.toml"))
        #expect(try isConfigured(home.url.appendingPathComponent("dotfiles/aerospace.toml")))
    }

    @Test func refusesMissingOrUnsupportedConfigs() async throws {
        await #expect(throws: AeroSpaceSetup.SetupError.notFound) { try await setup().apply(sidebar: Self.sidebar) }

        try home.write("[gaps]\nouter.right = [{ monitor.secondary = 1 }]\n", to: ".config/aerospace/aerospace.toml")
        await #expect { try await setup().apply(sidebar: Self.sidebar) } throws: { error in
            if case AeroSpaceSetup.SetupError.unsupported = error { return true }
            return false
        }

        try home.write("", to: ".aerospace.toml")
        await #expect { try await setup().apply(sidebar: Self.sidebar) } throws: { error in
            if case AeroSpaceSetup.SetupError.io = error { return true }
            return false
        }
    }

    @Test func reportsUnreadableAndUnwritableConfigs() async throws {
        try home.write("x", to: ".config/aerospace/aerospace.toml")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: configURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configURL.path) }

        await #expect { try await setup().apply(sidebar: Self.sidebar) } throws: { error in
            if case AeroSpaceSetup.SetupError.io = error { return true }
            return false
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configURL.path)
        try "".write(to: configURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: configURL.deletingLastPathComponent().path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: configURL.deletingLastPathComponent().path) }
        await #expect { try await setup().apply(sidebar: Self.sidebar) } throws: { error in
            if case AeroSpaceSetup.SetupError.io = error { return true }
            return false
        }
    }

    @Test func loginShellRunnerFindsHomebrewAeroSpace() async {
        let installed = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }

        let result = await LoginShellAeroSpaceCLI().run(["--version"])

        #expect(result.status == (installed ? 0 : 127))
        if installed {
            #expect(result.output.contains("aerospace CLI client version"))
        }
    }
}
