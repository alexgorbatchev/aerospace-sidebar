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

        #expect(cli.calls == [["reload-config", "--dry-run", "--no-gui"], ["reload-config", "--no-gui"]])
        #expect(sut.message?.hasPrefix("Updated and reloaded AeroSpace.") == true)
        #expect(try String(contentsOf: home.url.appendingPathComponent(".config/aerospace/aerospace.toml"), encoding: .utf8).contains(AeroSpaceConfigEditor.blockStart))
        #expect(sut.isConfigured)
    }

    @Test func syncUpdatesAndReloadsMismatchedConfig() async throws {
        try home.write("[gaps]\nouter.right = [{ monitor.main = 305 }, 5]\n", to: ".config/aerospace/aerospace.toml")
        let sut = sync()

        await sut.sync()

        #expect(cli.calls == [["reload-config", "--dry-run", "--no-gui"], ["reload-config", "--no-gui"]])
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

    @Test(arguments: [
        (AeroSpaceSetup.SetupError.notFound, "No AeroSpace config found"),
        (.unsupported("odd"), "automatically: odd"),
        (.rejected("bad"), "original config was restored: bad"),
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

    @Test func copyToPasteboardWritesString() {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }

        AeroSpaceSync.copyToPasteboard("snippet-\(getpid())")

        #expect(pasteboard.string(forType: .string) == "snippet-\(getpid())")
    }
}

@MainActor
final class SidebarBox {
    var value: SidebarSettings.Sidebar

    init(_ value: SidebarSettings.Sidebar) {
        self.value = value
    }
}
