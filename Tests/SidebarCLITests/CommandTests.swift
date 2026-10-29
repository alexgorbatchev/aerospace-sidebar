import ArgumentParser
import Foundation
@testable import SidebarCLI
import SidebarProtocol
import Testing

struct PushCommandTests {
    @Test func pushesPayloadWithRunActionInWorkingDirectory() async throws {
        let sender = RecordingSender()

        let result = await invoke([
            "notification", "push", "--title", "Build", "--subtitle", "main", "--body", "passed",
            "--severity", "high", "--icon", "ghostty", "--run", "open .",
        ], sender: sender)

        #expect(result.status == 0)
        #expect(result.output == "[OK] Notification sent to the sidebar.\n")
        #expect(sender.payloads == [try NotificationPayload(
            title: "Build", subtitle: "main", body: "passed", severity: .high, icon: "ghostty",
            action: .run(command: "open .", workingDirectory: "/Users/dev/project")
        )])
    }

    @Test func pushesOpenActionAndReportsCompactlyForAgents() async throws {
        let sender = RecordingSender()

        let result = await invoke(["notification", "push", "--body", "b", "--open", "file:///tmp/report.html"], agent: true, sender: sender)

        #expect(result.output == "OK: pushed\n")
        #expect(sender.payloads.first?.action == .open(URL(string: "file:///tmp/report.html")!))
        #expect(sender.payloads.first?.severity == .normal)
    }

    @Test func showsTheAppItRunsInWhenNoIconIsNamed() async throws {
        let sender = RecordingSender()

        _ = await invoke(
            ["notification", "push", "--title", "t", "--run", "ls"],
            environment: ["__CFBundleIdentifier": "com.mitchellh.ghostty", "TERM_PROGRAM": "Apple_Terminal"],
            installedApps: ["com.mitchellh.ghostty", "com.apple.Terminal"],
            sender: sender
        )

        let payload = try #require(sender.payloads.first)
        #expect(payload.bundleIdentifier == "com.mitchellh.ghostty")
        #expect(payload.icon == nil)
    }

    @Test func keepsTheNamedIconBesideTheAppItRunsIn() async throws {
        let sender = RecordingSender()

        _ = await invoke(
            ["notification", "push", "--title", "t", "--icon", "slack"],
            environment: ["__CFBundleIdentifier": "com.mitchellh.ghostty"],
            installedApps: ["com.mitchellh.ghostty"],
            sender: sender
        )

        let payload = try #require(sender.payloads.first)
        #expect(payload.icon == "slack")
        #expect(payload.bundleIdentifier == "com.mitchellh.ghostty")
    }

    /// Commands run from a card inherit the sidebar's own identifier; one that names no installed app
    /// says nothing either. The terminal is then the one `TERM_PROGRAM` names.
    @Test(arguments: [SidebarApp.bundleIdentifier, "com.example.uninstalled"])
    func fallsBackToTheTerminalProgram(bundleIdentifier: String) async throws {
        let sender = RecordingSender()

        _ = await invoke(
            ["notification", "push", "--title", "t"],
            environment: ["__CFBundleIdentifier": bundleIdentifier, "TERM_PROGRAM": "iTerm.app"],
            installedApps: [SidebarApp.bundleIdentifier, "com.googlecode.iterm2"],
            sender: sender
        )

        #expect(sender.payloads.first?.bundleIdentifier == "com.googlecode.iterm2")
    }

    /// tmux sets `TERM_PROGRAM` to itself, and a terminal that is not installed has no icon to show.
    @Test(arguments: [
        ["TERM_PROGRAM": "tmux"], ["TERM_PROGRAM": "WezTerm"], [:],
    ])
    func showsATerminalOutsideAnyKnownApp(environment: [String: String]) async throws {
        let sender = RecordingSender()

        _ = await invoke(["notification", "push", "--title", "t"], environment: environment, sender: sender)

        let payload = try #require(sender.payloads.first)
        #expect(payload.icon == PushCommand.fallbackIcon)
        #expect(payload.bundleIdentifier == nil)
    }

    @Test func checksInstalledAppsWithLaunchServices() {
        #expect(CLIContext.isInstalledApp("com.apple.finder"))
        #expect(!CLIContext.isInstalledApp("com.example.uninstalled"))
    }

    @Test func rejectsOpenTogetherWithRun() async {
        let result = await invoke(["notification", "push", "--title", "t", "--open", "https://a.b", "--run", "ls"])

        #expect(result.status == 64)
        #expect(result.errorOutput.contains("Use either --open or --run, not both."))
    }

    @Test func rejectsRelativeOpenURL() async {
        let result = await invoke(["notification", "push", "--title", "t", "--open", "example.com"])

        #expect(result.status == 64)
        #expect(result.errorOutput.contains("--open needs an absolute URL"))
    }

    @Test func rejectsUnknownSeverity() async {
        let result = await invoke(["notification", "push", "--title", "t", "--severity", "urgent"])

        #expect(result.status == 64)
        #expect(result.errorOutput.contains("urgent"))
    }

    @Test(arguments: [false, true])
    func reportsEmptyNotification(agent: Bool) async {
        let result = await invoke(["notification", "push"], agent: agent)

        #expect(result.status == 1)
        #expect(result.errorOutput == (agent ? "ERR: " : "[ERROR] ") + "a notification needs a title or a body\n")
    }

    @Test(arguments: [
        (CLIError.appNotInstalled, false, "[ERROR] The sidebar app is not installed. Build and launch it once with `just run`.\n"),
        (.appNotInstalled, true, "ERR: app_not_installed: no app registered for bundle id com.alexgorbatchev.aerospace-sidebar\n"),
        (.appDidNotStart(socketPath: "/Users/dev/tmp/s.sock"), false, "[ERROR] The sidebar app did not start in time. Launch it and try again.\n"),
        (.appDidNotStart(socketPath: "/Users/dev/tmp/s.sock"), true, "ERR: app_did_not_start: no listener on ~/tmp/s.sock after launch\n"),
        (.rejected("bad"), false, "[ERROR] The sidebar refused the notification: bad.\n"),
        (.rejected("bad"), true, "ERR: rejected: bad\n"),
        (.unreachable(socketPath: "/var/s.sock", reason: "boom"), false, "[ERROR] Cannot reach the sidebar app: boom.\n"),
        (.unreachable(socketPath: "/var/s.sock", reason: "boom"), true, "ERR: unreachable: /var/s.sock: boom\n"),
    ])
    func reportsDeliveryFailures(error: CLIError, agent: Bool, message: String) async {
        let result = await invoke(["notification", "push", "--title", "t"], agent: agent, sender: RecordingSender(error: error))

        #expect(result.status == 1)
        #expect(result.errorOutput == message)
        #expect(result.output.isEmpty)
    }

    @Test(arguments: [false, true])
    func reportsUnwritableOutput(agent: Bool) async {
        let result = await invoke(["notification", "push", "--title", "t"], agent: agent, output: BufferOutput(fails: true))

        #expect(result.status == EX_IOERR)
        #expect(result.errorOutput.hasPrefix(agent ? "ERR: output_write_failed: " : "[ERROR] Cannot write output: "))
    }

    @Test func helpThatCannotBeWrittenExitsWithIOError() async {
        #expect(await invoke(["--help"], output: BufferOutput(fails: true)).status == EX_IOERR)
    }
}

struct URLCommandTests {
    @Test func printsDecodableURL() async throws {
        let result = await invoke([
            "notification", "url", "--title", "a+b", "--body", "c & d", "--severity", "critical", "--icon", ":slack:",
            "--open", "https://example.com",
        ])
        let url = try #require(URL(string: result.output.trimmingCharacters(in: .newlines)))

        #expect(result.status == 0)
        #expect(try SidebarRequest(url: url) == .pushNotification(NotificationPayload(
            title: "a+b", body: "c & d", severity: .critical, icon: ":slack:", action: .open(URL(string: "https://example.com")!)
        )))
    }

    /// The URL is opened elsewhere, by whatever app opens it, so the terminal running this has no say.
    @Test func leavesTheIconToTheURL() async throws {
        let result = await invoke(
            ["notification", "url", "--title", "t"],
            environment: ["__CFBundleIdentifier": "com.mitchellh.ghostty"],
            installedApps: ["com.mitchellh.ghostty"]
        )
        let url = try #require(URL(string: result.output.trimmingCharacters(in: .newlines)))

        #expect(try SidebarRequest(url: url) == .pushNotification(NotificationPayload(title: "t")))
    }

    @Test func rejectsNonWebOpenURL() async {
        let result = await invoke(["notification", "url", "--title", "t", "--open", "file:///etc/hosts"], agent: true)

        #expect(result.status == 1)
        #expect(result.errorOutput == "ERR: 'file:///etc/hosts' is not an http or https URL\n")
    }

    @Test func urlCommandHasNoRunOption() async {
        let result = await invoke(["notification", "url", "--title", "t", "--run", "ls"])

        #expect(result.status == 64)
    }
}

struct SkillCommandTests {
    static let expected = """
        Install the aerospace-sidebar skill using the Skills CLI:

          npx skills add alexgorbatchev/aerospace-sidebar --skill aerospace-sidebar

        Skill:

          https://github.com/alexgorbatchev/aerospace-sidebar/tree/main/skills/aerospace-sidebar

        """

    @Test(arguments: [false, true])
    func printsIdenticalTextInBothModes(agent: Bool) async {
        let result = await invoke(["skill"], agent: agent)

        #expect(result.status == 0)
        #expect(result.output == Self.expected)
        #expect(result.output.hasSuffix("aerospace-sidebar\n") && !result.output.hasSuffix("\n\n"))
    }

    @Test func rejectsArguments() async {
        let result = await invoke(["skill", "extra"])

        #expect(result.status == 64)
        #expect(result.output.isEmpty)
    }

    @Test func reportsUnwritableOutput() async {
        #expect(await invoke(["skill"], output: BufferOutput(fails: true)).status == EX_IOERR)
    }

    @Test func printedSkillPathHoldsMatchingSkill() throws {
        let link = try #require(Self.expected.split(separator: "\n").first { $0.contains("/tree/main/") })
        let relativePath = String(link[link.range(of: "/tree/main/")!.upperBound...])
        let skill = try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath).appendingPathComponent("SKILL.md"), encoding: .utf8)
        let installName = try #require(Self.expected.split(separator: " ").last { $0.hasPrefix("aerospace-sidebar\n") })

        #expect(skill.hasPrefix("---\nname: aerospace-sidebar\n"))
        #expect(installName.hasPrefix("aerospace-sidebar"))
        #expect(Self.expected.contains("--skill aerospace-sidebar\n"))
    }
}

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
