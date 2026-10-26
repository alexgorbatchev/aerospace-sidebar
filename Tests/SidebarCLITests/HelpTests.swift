import ArgumentParser
import Foundation
@testable import SidebarCLI
import Testing

struct HelpTests {
    static let helpPaths: [[String]] = [
        ["--help"], ["-h"], ["help"], ["notification", "--help"], ["help", "notification"],
        ["notification", "push", "-h"], ["help", "notification", "push"], ["notification", "url", "--help"], ["skill", "--help"],
    ]

    @Test func rootHelpDrawsCommandTree() async {
        let result = await invoke(["--help"])

        #expect(result.status == 0)
        #expect(result.output.contains("""
            Commands:
              notification  Show notifications in the sidebar.
              ├─ push       Show a notification in the sidebar, starting the app if needed.
              ╰─ url        Print an aerospace-sidebar:// link that shows a notification when opened.
              skill         Print how to install the aerospace-sidebar agent skill.
            """))
        #expect(!result.output.contains("ALERT"))
    }

    @Test func groupHelpDrawsItsSubtree() async {
        let result = await invoke(["notification", "--help"])

        #expect(result.output.contains("""
            Commands:
              push  Show a notification in the sidebar, starting the app if needed.
              url   Print an aerospace-sidebar:// link that shows a notification when opened.
            """))
    }

    @Test func humanHelpTrimsToTerminalWidth() async {
        let result = await invoke(["--help"], width: 50)
        let treeLines = result.output.split(separator: "\n").filter { $0.contains("─") }

        #expect(treeLines.allSatisfy { $0.count <= 49 })
        #expect(treeLines.contains { $0.hasSuffix("...") })
    }

    @Test(arguments: helpPaths)
    func agentHelpStartsWithSkillAlert(arguments: [String]) async {
        let result = await invoke(arguments, agent: true)

        #expect(result.status == 0)
        #expect(result.output.hasPrefix("ALERT: Agents must read `AGENT=1 aerospace-sidebar skill` before using this tool.\n"))
    }

    @Test func agentHelpListsUntrimmedBullets() async {
        let result = await invoke(["--help"], agent: true, width: 30)

        #expect(result.output.contains("""
            Commands:
            - notification: Show notifications in the sidebar.
              - push: Show a notification in the sidebar, starting the app if needed.
              - url: Print an aerospace-sidebar:// link that shows a notification when opened.
            - skill: Print how to install the aerospace-sidebar agent skill.
            """))
        #expect(!result.output.contains("─"))
    }

    @Test func jsonHelpDumpStaysValidJSON() async throws {
        let result = await invoke(["--experimental-dump-help"], agent: true)

        #expect(try JSONDecoder().decode(ToolInfo.self, from: Data(result.output.utf8)).command.commandName == "aerospace-sidebar")
    }

    /// Fails when a command or option is added without documenting it in the skill.
    @Test func skillDocumentsEveryCommandAndOption() async throws {
        let dump = await invoke(["--experimental-dump-help"])
        let tool = try JSONDecoder().decode(ToolInfo.self, from: Data(dump.output.utf8))
        let skill = try String(
            contentsOf: repositoryRoot.appendingPathComponent("skills/aerospace-sidebar/SKILL.md"),
            encoding: .utf8
        )

        func visit(_ command: ToolInfo.Command, path: [String]) {
            let fullPath = path + [command.commandName]
            if fullPath.count > 1 {
                #expect(skill.contains("### \(fullPath.dropFirst().joined(separator: " "))"), "missing section for \(fullPath)")
            }
            for argument in command.arguments ?? [] where argument.shouldDisplay {
                for name in argument.names ?? [] where name.kind == "long" {
                    #expect(skill.contains("--\(name.name)"), "missing --\(name.name) in \(fullPath)")
                }
            }
            for subcommand in command.subcommands ?? [] where subcommand.commandName != "help" {
                visit(subcommand, path: fullPath)
            }
        }
        visit(tool.command, path: [])
    }
}

struct CLIContextTests {
    func context(home: String = "/Users/dev", environment: [String: String] = [:], width: Int? = nil) -> CLIContext {
        CLIContext(environment: environment, homeDirectory: home, terminalWidth: width)
    }

    @Test(arguments: [
        ("/Users/dev", "~"),
        ("/Users/dev/projects/app", "~/projects/app"),
        ("/Users/developer/app", "/Users/developer/app"),
        ("/var/folders/x", "/var/folders/x"),
    ])
    func foldsHomeDirectory(path: String, display: String) {
        #expect(context().displayPath(path) == display)
        #expect(context(home: "/Users/dev/").displayPath(path) == display)
    }

    @Test(arguments: [("1", true), ("true", true), ("YES", true), ("0", false), ("", false)])
    func detectsAgentMode(value: String, isAgent: Bool) {
        #expect(context(environment: ["AGENT": value]).isAgent == isAgent)
    }

    @Test func helpWidthPrefersColumnsThenTerminal() {
        #expect(context(environment: ["COLUMNS": "72"], width: 120).helpWidth == 72)
        #expect(context(width: 120).helpWidth == 120)
        #expect(context().helpWidth == 80)
    }

    @Test func standardOutputWidthMatchesTerminalState() {
        #expect((CLIContext.standardOutputWidth() == nil) == (isatty(STDOUT_FILENO) == 0))
    }

    @Test func fileHandleOutputWritesAndReportsFailures() throws {
        let pipe = Pipe()
        try FileHandleOutput(pipe.fileHandleForWriting).write("hello")
        try pipe.fileHandleForWriting.close()

        #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "hello")
        #expect(throws: (any Error).self) { try FileHandleOutput(pipe.fileHandleForWriting).write("late") }
    }
}

/// The parts of ArgumentParser's `--experimental-dump-help` JSON (ToolInfoV0) the tests read.
struct ToolInfo: Decodable {
    struct Command: Decodable {
        let commandName: String
        let subcommands: [Command]?
        let arguments: [Argument]?
    }

    struct Argument: Decodable {
        struct Name: Decodable {
            let kind: String
            let name: String
        }

        let names: [Name]?
        let shouldDisplay: Bool
    }

    let command: Command
}
