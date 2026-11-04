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

    /// `--markdown` marks the body as markdown; without it the body is plain text, asterisks and all.
    @Test func marksTheBodyAsMarkdownOnRequest() async throws {
        let sender = RecordingSender()

        #expect(await invoke(["notification", "push", "--body", "**done**", "--markdown"], sender: sender).status == 0)
        #expect(await invoke(["notification", "push", "--body", "**done**"], sender: sender).status == 0)

        #expect(sender.payloads.map(\.markdown) == [true, false])
        #expect(sender.payloads.map(\.body) == ["**done**", "**done**"])
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

    /// Agents read failures as one `ERR: <code>: <detail>` line; the usage block is for people.
    @Test(arguments: [
        (["notification", "push", "--title", "t", "--open", "https://a.b", "--run", "ls"], "ERR: usage: Use either --open or --run, not both.\n"),
        (["notification", "push", "--title", "t", "--open", "example.com"], "ERR: usage: --open needs an absolute URL such as https://example.com\n"),
        (["notification", "push", "--bogus"], "ERR: usage: Unknown option '--bogus'. Did you mean '--body'?\n"),
    ])
    func reportsUsageErrorsOnOneLineForAgents(arguments: [String], message: String) async {
        let result = await invoke(arguments, agent: true)

        #expect(result.status == 64)
        #expect(result.errorOutput == message)
        #expect(result.output.isEmpty)
    }

    @Test(arguments: [false, true])
    func reportsUnexpectedErrors(agent: Bool) async {
        let failure = CocoaError(.fileReadNoSuchFile)

        let result = await invoke(["notification", "push", "--title", "t"], agent: agent, sender: RecordingSender(error: failure))

        #expect(result.status == 1)
        #expect(result.errorOutput == (agent ? "ERR: failed: " : "Error: ") + failure.localizedDescription + "\n")
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
        #expect(result.errorOutput == (agent ? "ERR: invalid: " : "[ERROR] ") + "a notification needs a title or a body\n")
    }

    /// A command over its limit is refused before anything is sent, not cut off by the socket.
    @Test func rejectsOverlongCommandBeforeSending() async {
        let sender = RecordingSender()

        let result = await invoke(
            ["notification", "push", "--title", "t", "--run", String(repeating: "x", count: NotificationPayload.maxCommandLength + 1)],
            agent: true, sender: sender
        )

        #expect(result.status == 1)
        #expect(result.errorOutput == "ERR: invalid: command is longer than 4096 characters (or 16384 bytes in UTF-8)\n")
        #expect(sender.payloads.isEmpty)
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
        (.launchFailed("It is damaged."), false, "[ERROR] Cannot launch the sidebar app: It is damaged.\n"),
        (.launchFailed("It is damaged."), true, "ERR: launch_failed: It is damaged.\n"),
        (.noReply("late"), false, "[ERROR] The sidebar app did not confirm the notification (late). It may still show it, so sending it again could list it twice.\n"),
        (.noReply("late"), true, "ERR: no_reply: sent but not confirmed (late); it may still show, do not send it again\n"),
        (.tooLarge(size: 70000), false, "[ERROR] The notification is too large to send: 70000 bytes encoded, at most 65536.\n"),
        (.tooLarge(size: 70000), true, "ERR: too_large: request is 70000 bytes encoded, the socket takes at most 65536\n"),
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

    /// A consumer that exited before reading, like `| (exit 0)`, leaves a pipe without a reader. Writing to it
    /// raises SIGPIPE, which would kill the process with status 141; the CLI reports the failed write instead.
    /// Ignoring the signal applies to the whole process, so the CLI runs in a child process of its own.
    @Test func reportsOutputToAPipeWithoutReader() async throws {
        let result = await #expect(processExitsWith: .exitCode(EX_IOERR), observing: [\.standardErrorContent]) {
            // Start from the disposition that kills the process, whatever the test runner's is.
            signal(SIGPIPE, SIG_DFL)
            let pipe = Pipe()
            try pipe.fileHandleForReading.close()
            let context = CLIContext(
                environment: ["AGENT": "1"],
                output: FileHandleOutput(pipe.fileHandleForWriting),
                sender: RecordingSender(),
                isInstalledApp: { _ in false }
            )

            exit(await SidebarCLI.runProcess(arguments: ["notification", "push", "--title", "t"], context: context))
        }

        let errorOutput = String(decoding: try #require(result).standardErrorContent, as: UTF8.self)
        #expect(errorOutput.hasPrefix("ERR: output_write_failed: "))
    }
}

struct ChoiceOptionTests {
    /// Each option adds buttons in the order given: commands, then replies, then links. A value splits at its
    /// first `=`, so a command may hold more.
    @Test func pushesChoicesBesideTheClickAction() async throws {
        let sender = RecordingSender()

        let result = await invoke([
            "notification", "push", "--title", "Deploy ready", "--open", "https://ci.example/1",
            "--choice", "Deploy=make deploy ENV=prod", "--choice", "Skip=true",
            "--reply", "Note=echo \"$AEROSPACE_SIDEBAR_REPLY\" >> notes.txt",
            "--choice-link", "Logs=https://ci.example/1/logs?a=b",
        ], sender: sender)

        #expect(result.status == 0)
        let directory = "/Users/dev/project"
        #expect(sender.payloads.first?.action == .open(URL(string: "https://ci.example/1")!))
        #expect(sender.payloads.first?.choices == [
            try PushedChoice(title: "Deploy", action: .run(command: "make deploy ENV=prod", workingDirectory: directory)),
            try PushedChoice(title: "Skip", action: .run(command: "true", workingDirectory: directory)),
            try PushedChoice(title: "Note", action: .run(command: "echo \"$AEROSPACE_SIDEBAR_REPLY\" >> notes.txt", workingDirectory: directory), asksForText: true),
            try PushedChoice(title: "Logs", action: .open(URL(string: "https://ci.example/1/logs?a=b")!)),
        ])
    }

    @Test(arguments: [
        (["--choice", "Deploy"], "ERR: usage: The value 'Deploy' is invalid for '--choice <title=command>': expected TITLE=VALUE with a title before the first '='\n"),
        (["--reply", "=echo"], "ERR: usage: The value '=echo' is invalid for '--reply <title=command>': expected TITLE=VALUE with a title before the first '='\n"),
    ])
    func rejectsValuesWithoutTitle(arguments: [String], message: String) async {
        let result = await invoke(["notification", "push", "--title", "t"] + arguments, agent: true)

        #expect(result.status == 64)
        #expect(result.errorOutput == message)
    }

    @Test(arguments: [
        (["--choice", "A=ls", "--choice-link", "A=https://a.example"], "ERR: invalid: two choices are titled 'A'\n"),
        (["--choice", "A="], "ERR: invalid: choice 'A' needs a command\n"),
        (["--choice-link", "Docs=file:///etc/hosts"], "ERR: invalid: 'file:///etc/hosts' is not an http or https URL\n"),
        (["--choice-link", "Docs=not a url"], "ERR: invalid: 'not a url' is not an http or https URL\n"),
    ])
    func rejectsInvalidChoices(arguments: [String], message: String) async {
        let sender = RecordingSender()

        let result = await invoke(["notification", "push", "--title", "t"] + arguments, agent: true, sender: sender)

        #expect(result.status == 1)
        #expect(result.errorOutput == message)
        #expect(sender.payloads.isEmpty)
    }
}

struct AskCommandTests {
    @Test func asksWithChoicesAndRepliesAndPrintsTheChoice() async throws {
        let sender = RecordingSender(answer: .answered(choice: "Ship it", reply: nil))

        let result = await invoke(
            ["notification", "ask", "--title", "Deploy?", "--severity", "high", "--choice", "Ship it", "--choice", "Wait", "--reply", "Why?"],
            environment: ["__CFBundleIdentifier": "com.mitchellh.ghostty"], installedApps: ["com.mitchellh.ghostty"], sender: sender
        )

        #expect(result.status == 0)
        #expect(result.output == "Ship it\n")
        #expect(sender.payloads == [try NotificationPayload(
            title: "Deploy?", severity: .high, bundleIdentifier: "com.mitchellh.ghostty", choices: [
                PushedChoice(title: "Ship it", action: .answer),
                PushedChoice(title: "Wait", action: .answer),
                PushedChoice(title: "Why?", action: .answer, asksForText: true),
            ]
        )])
        #expect(sender.timeouts == [nil])
    }

    @Test func asksWithAMarkdownBody() async throws {
        let sender = RecordingSender(answer: .answered(choice: "Yes", reply: nil))

        let result = await invoke(["notification", "ask", "--body", "Ship `v2`?", "--markdown", "--choice", "Yes"], sender: sender)

        #expect(result.status == 0)
        #expect(sender.payloads.first?.markdown == true)
    }

    /// People get the reply text for a choice that asks for it as the command's output.
    @Test func printsTheReplyText() async {
        let sender = RecordingSender(answer: .answered(choice: "Reply", reply: "on my way\nsoon"))

        let result = await invoke(["notification", "ask", "--title", "t", "--reply", "Reply"], sender: sender)

        #expect(result.output == "on my way\nsoon\n")
        #expect(sender.payloads.first?.icon == PushCommand.fallbackIcon)
    }

    /// Agents get one `OK:` line with the answer as JSON, which tells a title from a reply that may span lines.
    @Test(arguments: [
        (AskAnswer.answered(choice: "Reply", reply: "on my way\nsoon"), #"OK: {"choice":"Reply","reply":"on my way\nsoon"}"#),
        (.answered(choice: "Yes", reply: nil), #"OK: {"choice":"Yes","reply":null}"#),
    ])
    func printsAnOKLineForAgents(answer: AskAnswer, line: String) async {
        let result = await invoke(
            ["notification", "ask", "--title", "t", "--choice", "Yes", "--reply", "Reply"], agent: true, sender: RecordingSender(answer: answer)
        )

        #expect(result.output == line + "\n")
    }

    @Test(arguments: [
        (AskAnswer.answered(choice: "Reply", reply: "a \"b\" / c"), #"{"choice":"Reply","reply":"a \"b\" / c"}"#),
        (.answered(choice: "Yes", reply: nil), #"{"choice":"Yes","reply":null}"#),
    ])
    func printsJSON(answer: AskAnswer, json: String) async {
        for agent in [false, true] {
            let result = await invoke(
                ["notification", "ask", "--title", "t", "--choice", "Yes", "--reply", "Reply", "--json"],
                agent: agent, sender: RecordingSender(answer: answer)
            )

            #expect(result.output == json + "\n")
        }
    }

    @Test func passesTheTimeout() async {
        let sender = RecordingSender(answer: .answered(choice: "Yes", reply: nil))

        _ = await invoke(["notification", "ask", "--title", "t", "--choice", "Yes", "--timeout", "1.5"], sender: sender)

        #expect(sender.timeouts == [.milliseconds(1500)])
    }

    /// No answer is an outcome of its own, exit status 2, apart from failing to ask.
    @Test(arguments: [
        (CLIError.dismissed, false, 2, "[ERROR] The notification was dismissed without an answer.\n"),
        (.dismissed, true, 2, "ERR: dismissed: the card went without an answer\n"),
        (.timedOut, false, 2, "[ERROR] No answer came in time, so the notification was withdrawn.\n"),
        (.timedOut, true, 2, "ERR: timeout: no answer within --timeout; the card was withdrawn\n"),
        (.noAnswer("closed"), false, 1, "[ERROR] The sidebar app stopped waiting for an answer (closed).\n"),
        (.noAnswer("closed"), true, 1, "ERR: no_answer: the connection ended without an answer (closed)\n"),
        (.askNotConfirmed("late"), false, 1, "[ERROR] The sidebar app did not confirm the question (late). It removes a question whose command stopped waiting, so you can ask again.\n"),
        (.askNotConfirmed("late"), true, 1, "ERR: no_reply: sent but not confirmed (late); the connection is closed, so no card stays, ask again\n"),
    ])
    func reportsAsksWithoutAnswer(error: CLIError, agent: Bool, status: Int32, message: String) async {
        let result = await invoke(["notification", "ask", "--title", "t", "--choice", "Yes"], agent: agent, sender: RecordingSender(error: error))

        #expect(result.status == status)
        #expect(result.errorOutput == message)
        #expect(result.output.isEmpty)
    }

    @Test func reportsDismissedCards() async {
        let result = await invoke(["notification", "ask", "--title", "t", "--choice", "Yes"], agent: true, sender: RecordingSender(answer: .dismissed))

        #expect(result.status == 2)
        #expect(result.errorOutput == "ERR: dismissed: the card went without an answer\n")
    }

    @Test(arguments: [
        (["--title", "t"], "ERR: usage: Give at least one --choice or --reply.\n"),
        (["--title", "t", "--choice", "Yes", "--timeout", "0"], "ERR: usage: --timeout needs a number of seconds above 0 and at most 31536000.\n"),
        (["--title", "t", "--choice", "Yes", "--timeout", "inf"], "ERR: usage: --timeout needs a number of seconds above 0 and at most 31536000.\n"),
        (["--title", "t", "--choice", "Yes", "--run", "ls"], "ERR: usage: Unknown option '--run'. Did you mean '--icon'?\n"),
    ])
    func rejectsInvalidAsks(arguments: [String], message: String) async {
        let result = await invoke(["notification", "ask"] + arguments, agent: true)

        #expect(result.status == 64)
        #expect(result.errorOutput == message)
    }

    @Test func rejectsDuplicateTitles() async {
        let result = await invoke(["notification", "ask", "--title", "t", "--choice", "Yes", "--reply", "Yes"], agent: true)

        #expect(result.status == 1)
        #expect(result.errorOutput == "ERR: invalid: two choices are titled 'Yes'\n")
    }

    @Test func reportsUnwritableAnswers() async {
        let result = await invoke(
            ["notification", "ask", "--title", "t", "--choice", "Yes"], agent: true,
            sender: RecordingSender(answer: .answered(choice: "Yes", reply: nil)), output: BufferOutput(fails: true)
        )

        #expect(result.status == EX_IOERR)
    }
}

struct URLCommandTests {
    @Test func carriesLinkChoices() async throws {
        let result = await invoke(["notification", "url", "--title", "t", "--choice-link", "Docs=https://example.com/docs"])
        let url = try #require(URL(string: result.output.trimmingCharacters(in: .newlines)))

        #expect(try SidebarRequest(url: url) == .pushNotification(NotificationPayload(
            title: "t", choices: [PushedChoice(title: "Docs", action: .open(URL(string: "https://example.com/docs")!))]
        )))
    }

    @Test func carriesTheMarkdownFlag() async throws {
        let result = await invoke(["notification", "url", "--body", "**done**", "--markdown"])
        let url = try #require(URL(string: result.output.trimmingCharacters(in: .newlines)))

        #expect(try SidebarRequest(url: url) == .pushNotification(NotificationPayload(body: "**done**", markdown: true)))
    }

    @Test func urlCommandHasNoCommandOrReplyChoices() async {
        #expect(await invoke(["notification", "url", "--title", "t", "--choice", "A=ls"]).status == 64)
        #expect(await invoke(["notification", "url", "--title", "t", "--reply", "A=ls"]).status == 64)
    }

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
        #expect(result.errorOutput == "ERR: invalid: 'file:///etc/hosts' is not an http or https URL\n")
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
