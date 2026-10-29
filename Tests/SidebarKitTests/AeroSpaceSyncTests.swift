import AppKit
@testable import SidebarKit
import SidebarProtocol
import Testing

@MainActor
struct AeroSpaceSyncTests {
    let home: TemporaryDirectory
    let cli = FakeAeroSpaceCLI()
    let sidebar = SidebarSettings.Sidebar(side: .left, width: 250)

    init() throws {
        home = try TemporaryDirectory()
    }

    func sync(copy: @escaping @MainActor (String) -> Void = { _ in }) -> AeroSpaceSync {
        AeroSpaceSync(
            setup: AeroSpaceSetup.forTesting(home: home.url, environment: [:], cli: cli),
            sidebar: { [sidebar] in sidebar },
            copy: copy
        )
    }

    @Test func refreshesConfigState() throws {
        let sut = sync()
        #expect(sut.state == .notFound && !sut.isConfigured)

        try home.write("[gaps]\nouter.left = [{ monitor.main = 250 }, 0]\n\n\(AeroSpaceConfigEditor.floatRule)\n", to: ".aerospace.toml")
        sut.refresh()

        guard case .ready = sut.state else { Issue.record("expected ready"); return }
        #expect(sut.isConfigured)
    }

    @Test func updatesAeroSpaceForTheConfiguredSidebar() async throws {
        try home.write("[gaps]\nouter.right = [{ monitor.main = 305 }, 5]\n", to: ".config/aerospace/aerospace.toml")
        let sut = sync()
        guard case .ready(let before, _) = sut.state else { Issue.record("expected ready"); return }
        #expect(before.oppositeReservedWidth == 300 && before.reservedWidth == nil)

        await sut.update()

        #expect(sut.message?.hasPrefix("Updated and reloaded AeroSpace.") == true)
        #expect(!sut.isUpdating)
        guard case .ready(let analysis, _) = sut.state else { Issue.record("expected ready"); return }
        #expect(analysis.isConfigured)
        #expect(analysis.sidebar == sidebar)
    }

    @Test func syncLeavesMatchingConfigAlone() async throws {
        try home.write("[gaps]\nouter.left = [{ monitor.main = 250 }, 0]\n\n\(AeroSpaceConfigEditor.floatRule)\n", to: ".config/aerospace/aerospace.toml")
        let sut = sync()

        await sut.sync()

        #expect(cli.calls.isEmpty)
        #expect(sut.message == nil)
    }

    /// Write Again writes and reloads a config that already matches, which a sync leaves alone.
    @Test func writesMatchingConfigAgainOnRequest() async throws {
        try home.write("[gaps]\nouter.left = [{ monitor.main = 250 }, 0]\n\n\(AeroSpaceConfigEditor.floatRule)\n", to: ".config/aerospace/aerospace.toml")
        let sut = sync()

        await sut.update(rewritingBlock: true)

        #expect(cli.calls == [AeroSpaceSetup.check, AeroSpaceSetup.check, ["reload-config", "--no-gui"]])
        #expect(sut.message?.hasPrefix("Updated and reloaded AeroSpace.") == true)
        #expect(try String(contentsOf: home.url.appendingPathComponent(".config/aerospace/aerospace.toml"), encoding: .utf8).contains(AeroSpaceConfigEditor.blockStart))
        #expect(sut.isConfigured)
    }

    @Test func syncUpdatesAndReloadsMismatchedConfig() async throws {
        try home.write("[gaps]\nouter.right = [{ monitor.main = 305 }, 5]\n", to: ".config/aerospace/aerospace.toml")
        let sut = sync()

        await sut.sync()

        #expect(cli.calls == [AeroSpaceSetup.check, AeroSpaceSetup.check, ["reload-config", "--no-gui"]])
        #expect(sut.message?.hasPrefix("Updated and reloaded AeroSpace.") == true)
        guard case .ready(let analysis, _) = sut.state else { Issue.record("expected ready"); return }
        #expect(analysis.isConfigured)
    }

    /// A change saved while an update runs is applied after it rather than racing it.
    @Test func syncDuringAnUpdateRunsAfterIt() async throws {
        try home.write("", to: ".config/aerospace/aerospace.toml")
        let sidebar = SidebarBox(SidebarSettings.Sidebar(side: .right, width: 300))
        let cli = SuspendingAeroSpaceCLI()
        let sut = AeroSpaceSync(
            setup: AeroSpaceSetup.forTesting(home: home.url, environment: [:], cli: cli),
            sidebar: { sidebar.value }
        )

        let first = Task { await sut.sync() }
        await cli.waitForCall()
        sidebar.value = SidebarSettings.Sidebar(side: .left, width: 400)
        await sut.sync()
        cli.resumeAll()
        await first.value

        guard case .ready(let analysis, _) = sut.state else { Issue.record("expected ready"); return }
        #expect(analysis.sidebar == sidebar.value)
        #expect(analysis.isConfigured)
    }

    /// A change saved while Update Config runs is synced once it ends.
    @Test func syncDuringAManualUpdateRunsAfterIt() async throws {
        try home.write("", to: ".config/aerospace/aerospace.toml")
        let sidebar = SidebarBox(SidebarSettings.Sidebar(side: .right, width: 300))
        let cli = SuspendingAeroSpaceCLI()
        let sut = AeroSpaceSync(
            setup: AeroSpaceSetup.forTesting(home: home.url, environment: [:], cli: cli),
            sidebar: { sidebar.value }
        )

        let update = Task { await sut.update() }
        await cli.waitForCall()
        sidebar.value = SidebarSettings.Sidebar(side: .left, width: 400)
        await sut.sync()
        cli.resumeAll()
        await update.value

        guard case .ready(let analysis, _) = sut.state else { Issue.record("expected ready"); return }
        #expect(analysis.sidebar == sidebar.value)
        #expect(analysis.isConfigured)
    }

    /// AeroSpace would reject the same edit again, so neither the restored original nor the watcher's report
    /// of it starts another attempt; a changed sidebar or Update Config does.
    @Test(arguments: [Duration.zero, .milliseconds(150)])
    func rejectedEditWaitsForAChange(checkDuration: Duration) async throws {
        let configURL = home.url.appendingPathComponent(".config/aerospace/aerospace.toml")
        try home.write("[gaps]\nouter.right = 5\n", to: ".config/aerospace/aerospace.toml")
        // The check outlasting the watcher's delay lets the report of the edit arrive during the update.
        let cli = CheckingAeroSpaceCLI(config: configURL, problems: ["monitor.main": "[ERROR] gaps.outer.left: Unknown monitor pattern"], checkDuration: checkDuration)
        let sidebar = SidebarBox(self.sidebar)
        let sut = AeroSpaceSync(setup: AeroSpaceSetup.forTesting(home: home.url, environment: [:], cli: cli), sidebar: { sidebar.value })

        sut.start(delay: .milliseconds(20))
        defer { sut.stop() }
        try await waitUntil { sut.message != nil }
        try await Task.sleep(for: .milliseconds(400))
        #expect(sut.message?.hasPrefix("AeroSpace rejected the change, so the original config was restored") == true)
        #expect(cli.checks == 2)

        try "[gaps]\nouter.right = 5\n".write(to: configURL, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(200))
        #expect(cli.checks == 2)

        sidebar.value = SidebarSettings.Sidebar(side: .left, width: 260)
        await sut.sync()
        #expect(cli.checks == 4)

        await sut.update()
        #expect(cli.checks == 6)
        #expect(try String(contentsOf: configURL, encoding: .utf8) == "[gaps]\nouter.right = 5\n")
    }

    /// A rejection can pass, such as a check made while AeroSpace restarted. Once an edit is accepted, a
    /// config that returns to the rejected text, as after a regeneration that drops the block, is synced.
    @Test func acceptedEditForgetsTheRejection() async throws {
        let configURL = home.url.appendingPathComponent(".config/aerospace/aerospace.toml")
        let original = "[gaps]\nouter.right = 5\n"
        try home.write(original, to: ".config/aerospace/aerospace.toml")
        let cli = CheckingAeroSpaceCLI(config: configURL, problems: ["monitor.main": "[ERROR] Can't connect to AeroSpace server"])
        let sut = AeroSpaceSync(setup: AeroSpaceSetup.forTesting(home: home.url, environment: [:], cli: cli), sidebar: { [sidebar] in sidebar })
        await sut.sync()
        #expect(sut.message?.hasPrefix("AeroSpace rejected the change") == true)

        cli.problems = [:]
        await sut.update()
        #expect(sut.isConfigured)

        try original.write(to: configURL, atomically: true, encoding: .utf8)
        await sut.sync()

        #expect(cli.checks == 6)
        #expect(sut.isConfigured)
    }

    /// AeroSpace looks for its config in two places; a config created in either, even in a directory that
    /// did not exist, is synced, and so is one moved from one place to the other.
    @Test func syncsConfigsCreatedOrMovedInAnyPlaceAeroSpaceLooks() async throws {
        let dotfile = home.url.appendingPathComponent(".aerospace.toml")
        let xdg = home.url.appendingPathComponent(".config/aerospace/aerospace.toml")
        let sut = sync()
        sut.start(delay: .milliseconds(20))
        defer { sut.stop() }

        try home.write("[gaps]\nouter.left = 5\n", to: ".config/aerospace/aerospace.toml")
        try await waitUntil { try String(contentsOf: xdg, encoding: .utf8).contains(AeroSpaceConfigEditor.blockStart) }

        try FileManager.default.removeItem(at: xdg.deletingLastPathComponent())
        try home.write("[gaps]\nouter.left = 5\n", to: ".aerospace.toml")
        // The file holds the edit before AeroSpace has checked it and the state is refreshed.
        try await waitUntil { sut.isConfigured && sut.configURL == dotfile }
        #expect(try String(contentsOf: dotfile, encoding: .utf8).contains(AeroSpaceConfigEditor.blockStart))
    }

    /// Edits at a symlinked config's target are synced, also once the target was removed and is created again
    /// later, which leaves the symlink's directory as it was; once the config is a file of its own, the old
    /// target no longer matters.
    @Test func followsTheTargetOfASymlinkedConfig() async throws {
        let target = home.url.appendingPathComponent("dotfiles/aerospace.toml")
        let xdg = home.url.appendingPathComponent(".config/aerospace/aerospace.toml")
        let configured = "[gaps]\nouter.left = [{ monitor.main = 250 }, 0]\n\n\(AeroSpaceConfigEditor.floatRule)\n"
        try home.write(configured, to: "dotfiles/aerospace.toml")
        try FileManager.default.createDirectory(at: xdg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: xdg, withDestinationURL: target)
        let sut = sync()
        sut.start(delay: .milliseconds(20))
        defer { sut.stop() }

        try "[gaps]\nouter.left = 5\n".write(to: target, atomically: true, encoding: .utf8)
        try await waitUntil { try String(contentsOf: target, encoding: .utf8).contains(AeroSpaceConfigEditor.blockStart) }

        try FileManager.default.removeItem(at: target)
        try await waitUntil { sut.state == .notFound }
        try "[gaps]\nouter.left = 5\n".write(to: target, atomically: true, encoding: .utf8)
        try await waitUntil { sut.isConfigured }
        #expect(try String(contentsOf: target, encoding: .utf8).contains(AeroSpaceConfigEditor.blockStart))

        try FileManager.default.removeItem(at: xdg)
        try configured.write(to: xdg, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(200))
        let calls = cli.calls.count
        try "[gaps]\nouter.left = 5\n".write(to: target, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(200))

        #expect(cli.calls.count == calls)
        #expect(sut.isConfigured)
    }

    @Test func explainsUpdateWithoutReload() async throws {
        try home.write("", to: ".config/aerospace/aerospace.toml")
        let sut = AeroSpaceSync(
            setup: AeroSpaceSetup.forTesting(home: home.url, environment: [:], cli: FakeAeroSpaceCLI(results: ["--dry-run": CommandResult(status: 127, output: "")])),
            sidebar: { [sidebar] in sidebar }
        )

        await sut.update()

        #expect(sut.message?.contains("Reload AeroSpace yourself") == true)
    }

    @Test func explainsUpdateWhileAeroSpaceIsStopped() async throws {
        try home.write("", to: ".config/aerospace/aerospace.toml")
        let sut = AeroSpaceSync(
            setup: AeroSpaceSetup.forTesting(home: home.url, environment: [:], cli: cli, isAeroSpaceRunning: false),
            sidebar: { [sidebar] in sidebar }
        )

        await sut.update()

        #expect(sut.message?.contains("AeroSpace is not running and reads it when it starts.") == true)
    }

    @Test func syncLeavesMissingConfigToSetup() async {
        let sut = sync()

        await sut.sync()

        #expect(sut.state == .notFound)
        #expect(sut.message == nil)
    }

    /// A generator that rewrites the config in place drops the block; the sidebar puts it back.
    @Test func restoresBlockAfterTheConfigIsRewritten() async throws {
        let configURL = home.url.appendingPathComponent(".config/aerospace/aerospace.toml")
        try home.write("[gaps]\nouter.left = 5\n", to: ".config/aerospace/aerospace.toml")
        let sut = sync()

        sut.start(delay: .milliseconds(50))
        defer { sut.stop() }
        try await waitUntil { sut.message != nil }
        #expect(sut.message?.hasPrefix("Updated and reloaded AeroSpace.") == true)

        let handle = try FileHandle(forWritingTo: configURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("# Generated\n[gaps]\nouter.left = 5\n".utf8))
        try handle.close()
        try await waitUntil { try String(contentsOf: configURL, encoding: .utf8).contains(AeroSpaceConfigEditor.blockStart) }

        let config = try String(contentsOf: configURL, encoding: .utf8)
        #expect(config.hasPrefix("# Generated\n[gaps]\n" + AeroSpaceConfigEditor.blockStart))
        #expect(AeroSpaceConfigEditor.analyze(config, sidebar: sidebar).isConfigured)
    }

    func waitUntil(_ condition: () throws -> Bool) async throws {
        for _ in 0..<300 where try !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try condition())
    }

    @Test func reportsUpdateFailure() async {
        let sut = sync()

        await sut.update()

        #expect(sut.message?.hasPrefix("No AeroSpace config found") == true)
    }

    @Test func explainsProblemsTheConfigAlreadyHad() async throws {
        let configURL = home.url.appendingPathComponent(".config/aerospace/aerospace.toml")
        try home.write("unknown-key = 1\n", to: ".config/aerospace/aerospace.toml")
        let cli = CheckingAeroSpaceCLI(config: configURL, problems: ["unknown-key": "[ERROR] unknown-key: Unknown key"])
        let sut = AeroSpaceSync(setup: AeroSpaceSetup.forTesting(home: home.url, environment: [:], cli: cli), sidebar: { [sidebar] in sidebar })

        await sut.sync()

        #expect(sut.isConfigured)
        #expect(sut.message?.hasSuffix("AeroSpace reports problems the config already had: [ERROR] unknown-key: Unknown key") == true)
    }

    @Test(arguments: [
        (AeroSpaceSetup.SetupError.notFound, "No AeroSpace config found"),
        (.unsupported("odd"), "automatically: odd"),
        (.rejected("bad", original: ""), "original config was restored: bad"),
        (.rejectedAndReplaced("bad"), "saved again meanwhile, so that version was kept: bad"),
        (.io("disk"), "Cannot update the config: disk"),
    ])
    func describesSetupErrors(error: AeroSpaceSetup.SetupError, fragment: String) {
        #expect(AeroSpaceSync.describe(error).contains(fragment))
    }

    @Test func copiesSnippetThatConfiguresAnEmptyConfig() throws {
        var copied: [String] = []
        let sut = sync(copy: { copied.append($0) })

        sut.copySnippet()

        let snippet = try #require(copied.first)
        #expect(copied.count == 1)
        #expect(snippet == AeroSpaceConfigEditor.snippet(for: sidebar))
        #expect(snippet.contains("outer.left = [{ monitor.main = 250 }, 0]"))
        #expect(sut.message?.hasPrefix("Copied") == true)
    }

    @Test func reportsConfigURLOnlyWhenReadable() throws {
        let sut = sync()
        #expect(sut.configURL == nil)

        try home.write("", to: ".aerospace.toml")
        sut.refresh()
        #expect(sut.configURL == home.url.appendingPathComponent(".aerospace.toml"))

        try home.write("", to: ".config/aerospace/aerospace.toml")
        sut.refresh()
        #expect(sut.configURL == nil)
    }

    /// Copy Settings replaces whatever the pasteboard held with the snippet. The test copies to a private
    /// pasteboard, never the user's clipboard.
    @Test func copiesSnippetToThePasteboardReplacingItsContents() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data([1, 2, 3]), forType: .png)
        let sut = sync(copy: AeroSpaceSync.copying(to: pasteboard))

        sut.copySnippet()

        #expect(pasteboard.data(forType: .png) == nil)
        #expect(pasteboard.string(forType: .string) == AeroSpaceConfigEditor.snippet(for: sidebar))
    }
}

@MainActor
final class SidebarBox {
    var value: SidebarSettings.Sidebar

    init(_ value: SidebarSettings.Sidebar) {
        self.value = value
    }
}
