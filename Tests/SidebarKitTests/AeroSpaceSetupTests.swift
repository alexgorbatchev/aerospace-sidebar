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

        #expect(analysis == .init(sidebar: Self.right, reservedWidth: 300, mainEntryWidth: 300, oppositeReservedWidth: nil, missingFloatRule: false, warnings: []))
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

    /// AeroSpace uses the first entry whose pattern matches a monitor, so a `monitor.main` entry behind
    /// another pattern that may match the main monitor does not reserve the strip, and the update moves it
    /// first. On the other side, the same entry may reserve a strip there.
    @Test func countsTheStripOnlyWhenTheMainEntryComesFirst() throws {
        let text = "[gaps]\nouter.right = [{ monitor.\"built-in\" = 10 }, { monitor.main = 305 }, 5]\n\n\(Self.rule)\n"

        let analysis = AeroSpaceConfigEditor.analyze(text, sidebar: Self.right)
        #expect(analysis.reservedWidth == nil && analysis.mainEntryWidth == 300 && !analysis.isConfigured)
        #expect(AeroSpaceConfigEditor.analyze(text, sidebar: Self.left).oppositeReservedWidth == 300)

        let result = try AeroSpaceConfigEditor.apply(to: text, sidebar: Self.right)
        #expect(result.hasPrefix("[gaps]\n" + Self.block("0", "[{ monitor.main = 305 }, { monitor.built-in = 10 }, 5]")))
        #expect(AeroSpaceConfigEditor.analyze(result, sidebar: Self.right).isConfigured)
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

    /// Write Again puts a matching gap that is not in the managed block back into one.
    @Test func rewritesConfiguredGapIntoBlockOnRequest() throws {
        let configured = "[gaps]\nouter.right = [{ monitor.main = 305 }, 5]\n\n\(Self.rule)\n"

        let result = try AeroSpaceConfigEditor.apply(to: configured, sidebar: Self.right, rewritingBlock: true)

        #expect(result.contains(AeroSpaceConfigEditor.blockStart))
        #expect(AeroSpaceConfigEditor.analyze(result, sidebar: Self.right).isConfigured)
        #expect(try AeroSpaceConfigEditor.apply(to: result, sidebar: Self.right, rewritingBlock: true) == result)
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

    func setup(_ cli: any AeroSpaceCommandRunning = FakeAeroSpaceCLI(), isAeroSpaceRunning: Bool = true) -> AeroSpaceSetup {
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

    /// AeroSpace checks the config before and after the edit, then reloads it.
    @Test func appliesValidatesAndReloads() async throws {
        try home.write("[gaps]\nouter.right = 5\n", to: ".config/aerospace/aerospace.toml")
        let cli = FakeAeroSpaceCLI()

        let outcome = try await setup(cli).apply(sidebar: Self.sidebar)

        #expect(outcome == .updated(backup: backupURL))
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "[gaps]\nouter.right = 5\n")
        #expect(try isConfigured(configURL))
        #expect(cli.calls == [AeroSpaceSetup.check, AeroSpaceSetup.check, ["reload-config", "--no-gui"]])
    }

    /// A config only its owner may read keeps its permissions through the edit and a restore, and its backup, which
    /// replaces an older one others could read, takes them too.
    @Test func keepsTheConfigsPermissions() async throws {
        let original = "[gaps]\nouter.right = 5\n"
        try home.write(original, to: ".config/aerospace/aerospace.toml")
        try home.write("old", to: ".config/aerospace/aerospace.toml.bak")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: backupURL.path)
        func permissions(_ url: URL) throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        }

        _ = try await setup().apply(sidebar: Self.sidebar)

        #expect(try isConfigured(configURL))
        #expect(try permissions(configURL) == 0o600)
        #expect(try permissions(backupURL) == 0o600)
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == original)

        let cli = CheckingAeroSpaceCLI(config: configURL, problems: ["monitor.main = 205": "bad key"])
        await #expect(throws: AeroSpaceSetup.SetupError.self) {
            try await setup(cli).apply(sidebar: SidebarSettings.Sidebar(side: .right, width: 200))
        }
        #expect(try isConfigured(configURL))
        #expect(try permissions(configURL) == 0o600)
    }

    @Test func restoresOriginalWhenAeroSpaceRejectsTheEdit() async throws {
        let original = "[gaps]\nouter.right = 5\n"
        try home.write(original, to: ".config/aerospace/aerospace.toml")
        let cli = CheckingAeroSpaceCLI(config: configURL, problems: ["monitor.main = 305": "bad key"])

        await #expect(throws: AeroSpaceSetup.SetupError.rejected("bad key", original: original)) { try await setup(cli).apply(sidebar: Self.sidebar) }

        #expect(try String(contentsOf: configURL, encoding: .utf8) == original)
        #expect(cli.calls == [AeroSpaceSetup.check, AeroSpaceSetup.check])
    }

    /// AeroSpace loads a config with a key it does not know, while reporting it; an edit that adds no problem
    /// of its own is kept.
    @Test func keepsAnEditThatAddsNoProblems() async throws {
        try home.write("unknown-key = 1\n[gaps]\nouter.right = 5\n", to: ".config/aerospace/aerospace.toml")
        let cli = CheckingAeroSpaceCLI(config: configURL, problems: ["unknown-key": "[ERROR] unknown-key: Unknown key"])

        let outcome = try await setup(cli).apply(sidebar: Self.sidebar)

        #expect(outcome == .updatedWithExistingProblems(backup: backupURL, problems: "[ERROR] unknown-key: Unknown key"))
        #expect(try isConfigured(configURL))
        #expect(cli.calls == [AeroSpaceSetup.check, AeroSpaceSetup.check, ["reload-config", "--no-gui"]])
    }

    @Test func rejectsAnEditForTheProblemsItAdds() async throws {
        let original = "unknown-key = 1\n[gaps]\nouter.right = 5\n"
        try home.write(original, to: ".config/aerospace/aerospace.toml")
        let cli = CheckingAeroSpaceCLI(config: configURL, problems: [
            "unknown-key": "[ERROR] unknown-key: Unknown key",
            "monitor.main = 305": "[ERROR] gaps.outer.right: Unknown monitor pattern",
        ])

        await #expect(throws: AeroSpaceSetup.SetupError.rejected("[ERROR] gaps.outer.right: Unknown monitor pattern", original: original)) {
            try await setup(cli).apply(sidebar: Self.sidebar)
        }

        #expect(try String(contentsOf: configURL, encoding: .utf8) == original)
    }

    /// A version saved while AeroSpace checks the edit is not overwritten by restoring the original.
    @Test func keepsAVersionSavedWhileAeroSpaceChecksTheEdit() async throws {
        try home.write("[gaps]\nouter.right = 5\n", to: ".config/aerospace/aerospace.toml")
        let saved = "# Saved meanwhile\n"
        let cli = CheckingAeroSpaceCLI(config: configURL, problems: ["monitor.main = 305": "bad key"]) { [configURL] check in
            if check == 1 { try? saved.write(to: configURL, atomically: true, encoding: .utf8) }
        }

        await #expect(throws: AeroSpaceSetup.SetupError.rejectedAndReplaced("bad key")) { try await setup(cli).apply(sidebar: Self.sidebar) }

        #expect(try String(contentsOf: configURL, encoding: .utf8) == saved)
    }

    /// A version saved while AeroSpace checks the original is the one edited, rather than overwritten.
    @Test func editsAVersionSavedWhileAeroSpaceChecksTheOriginal() async throws {
        try home.write("[gaps]\nouter.right = 5\n", to: ".config/aerospace/aerospace.toml")
        let cli = CheckingAeroSpaceCLI(config: configURL, problems: [:]) { [configURL] check in
            if check == 0 { try? "[gaps]\nouter.right = 7\n".write(to: configURL, atomically: true, encoding: .utf8) }
        }

        _ = try await setup(cli).apply(sidebar: Self.sidebar)

        #expect(try String(contentsOf: configURL, encoding: .utf8).contains("outer.right = [{ monitor.main = 307 }, 7]"))
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == "[gaps]\nouter.right = 7\n")
    }

    @Test(arguments: [
        // The edited config passes.
        (CommandResult(status: 1, output: "a\n"), CommandResult(status: 0, output: ""), nil as String?),
        // The original passed, so whatever the edited config reports is the edit's.
        (CommandResult(status: 0, output: ""), CommandResult(status: 1, output: "a\n"), "a"),
        // Only problems the original did not have count, in the order AeroSpace reports them.
        (CommandResult(status: 1, output: "a\n\nb\n"), CommandResult(status: 1, output: "c\n\na\n\nd\n"), "c\n\nd"),
        (CommandResult(status: 1, output: "a\n\nb\n"), CommandResult(status: 1, output: "b\n\na"), nil),
        // The main entry inserted first moves an entry's problem to the next index.
        (
            CommandResult(status: 1, output: "[ERROR] gaps.outer.right[0].monitor.^LG(: Can't parse regex\n"),
            CommandResult(status: 1, output: "[ERROR] gaps.outer.right[1].monitor.^LG(: Can't parse regex\n"),
            nil
        ),
        // Each problem of the original accounts for one problem of the edited config.
        (CommandResult(status: 1, output: "x[0]: a\n"), CommandResult(status: 1, output: "x[1]: a\n\nx[2]: a\n"), "x[2]: a"),
    ])
    func countsOnlyProblemsTheEditAdds(before: CommandResult, validation: CommandResult, added: String?) {
        #expect(AeroSpaceSetup.problems(addedBy: validation, to: before) == added)
    }

    @Test func keepsEditWhenAeroSpaceCommandIsMissing() async throws {
        try home.write("", to: ".config/aerospace/aerospace.toml")
        let cli = FakeAeroSpaceCLI(results: ["--dry-run": CommandResult(status: 127, output: "command not found")])

        let outcome = try await setup(cli).apply(sidebar: Self.sidebar)

        #expect(outcome == .updatedWithoutReload(backup: backupURL))
        #expect(try isConfigured(configURL))
        #expect(cli.calls == [AeroSpaceSetup.check])
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

    /// Every place AeroSpace looks is watched, whether or not a config is there yet, and so is the file a
    /// symlinked config points to, through relative and chained links, also while that file is missing.
    @Test func watchesEveryConfigLocationAndSymlinkTargets() throws {
        let dotfile = home.url.appendingPathComponent(".aerospace.toml")
        let target = home.url.appendingPathComponent("dotfiles/aerospace.toml")
        #expect(setup().configsToWatch() == [dotfile, configURL])

        try home.write("", to: "dotfiles/aerospace.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.url.appendingPathComponent("dotfiles/current.toml").path, withDestinationPath: "aerospace.toml")
        try FileManager.default.createSymbolicLink(atPath: configURL.path, withDestinationPath: "../../dotfiles/current.toml")
        #expect(setup().configsToWatch() == [dotfile, configURL, target])

        try FileManager.default.removeItem(at: target)
        #expect(setup().configsToWatch() == [dotfile, configURL, target])
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

/// Checks the config like `aerospace reload-config --dry-run`: reads it from disk and reports, separated by
/// blank lines, each problem whose marker the config contains, failing when there is any. Other commands
/// succeed.
final class CheckingAeroSpaceCLI: AeroSpaceCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var reported: [String: String]
    let config: URL
    let checkDuration: Duration
    /// Runs during each check, after the config was read, with the number of checks before it.
    let duringCheck: @Sendable (Int) -> Void

    init(
        config: URL,
        problems: [String: String],
        checkDuration: Duration = .zero,
        duringCheck: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.config = config
        reported = problems
        self.checkDuration = checkDuration
        self.duringCheck = duringCheck
    }

    var calls: [[String]] { lock.withLock { recorded } }
    /// Each problem by the marker that reports it; changing it makes later checks report others.
    var problems: [String: String] {
        get { lock.withLock { reported } }
        set { lock.withLock { reported = newValue } }
    }
    var checks: Int { calls.count(where: { $0 == AeroSpaceSetup.check }) }

    func run(_ arguments: [String]) async -> CommandResult {
        let index = lock.withLock {
            recorded.append(arguments)
            return recorded.count(where: { $0 == AeroSpaceSetup.check }) - 1
        }
        guard arguments == AeroSpaceSetup.check else { return CommandResult(status: 0, output: "") }
        try? await Task.sleep(for: checkDuration)
        let text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        duringCheck(index)
        let found = problems.filter { text.contains($0.key) }.map(\.value).sorted()
        return CommandResult(status: found.isEmpty ? 0 : 1, output: found.map { $0 + "\n" }.joined(separator: "\n"))
    }
}
