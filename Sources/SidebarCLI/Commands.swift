import ArgumentParser
import Foundation
import SidebarProtocol

/// `aerospace-sidebar`: drives the aerospace-sidebar app.
public struct RootCommand: AsyncParsableCommand {
    public static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "aerospace-sidebar",
            abstract: "Control the aerospace-sidebar app.",
            discussion: CommandTree.render(children: [NotificationCommand.self, SkillCommand.self]),
            subcommands: [NotificationCommand.self, SkillCommand.self]
        )
    }

    public init() {}
}

struct NotificationCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "notification",
            abstract: "Show notifications in the sidebar.",
            discussion: CommandTree.render(children: [PushCommand.self, URLCommand.self]),
            shouldDisplay: false,
            subcommands: [PushCommand.self, URLCommand.self]
        )
    }
}

/// Fields shared by `notification push` and `notification url`.
struct NotificationFields: ParsableArguments {
    @Option(help: "Bold first line.")
    var title = ""

    @Option(help: "Line under the title.")
    var subtitle = ""

    @Option(help: "Main text, up to 4096 characters.")
    var body = ""

    @Option(help: "How important it is; more severe notifications are listed first.")
    var severity: NotificationSeverity = .normal

    @Option(name: .customLong("open"), help: ArgumentHelp("URL to open when the notification is clicked.", valueName: "url"))
    var openURL: String?

    func payload(action: NotificationAction?) throws -> NotificationPayload {
        try NotificationPayload(title: title, subtitle: subtitle, body: body, severity: severity, action: action)
    }

    func openAction() throws -> NotificationAction? {
        try openURL.map { value in
            guard let url = URL(string: value), url.scheme != nil else {
                throw ValidationError("--open needs an absolute URL such as https://example.com")
            }
            return .open(url)
        }
    }
}

struct PushCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "push",
            abstract: "Show a notification in the sidebar, starting the app if needed.",
            shouldDisplay: false
        )
    }

    @OptionGroup var fields: NotificationFields

    @Option(name: .customLong("run"), help: ArgumentHelp(
        "Shell command to run in the current directory when the notification is clicked.",
        valueName: "command"
    ))
    var command: String?

    func validate() throws {
        if fields.openURL != nil, command != nil {
            throw ValidationError("Use either --open or --run, not both.")
        }
    }

    func run() async throws {
        let context = CLIContext.current
        let action = try command.map { NotificationAction.run(command: $0, workingDirectory: context.workingDirectory) }
            ?? fields.openAction()
        try await context.sender.push(fields.payload(action: action))
        try context.emit(context.isAgent ? "OK: pushed\n" : "[OK] Notification sent to the sidebar.\n")
    }
}

struct URLCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "url",
            abstract: "Print an aerospace-sidebar:// link that shows a notification when opened.",
            shouldDisplay: false
        )
    }

    @OptionGroup var fields: NotificationFields

    func run() async throws {
        let url = try SidebarRequest.pushNotification(fields.payload(action: fields.openAction())).url()
        try CLIContext.current.emit(url.absoluteString + "\n")
    }
}

struct SkillCommand: AsyncParsableCommand {
    static let text = """
        Install the aerospace-sidebar skill using the Skills CLI:

          npx skills add alexgorbatchev/aerospace-sidebar --skill aerospace-sidebar

        Skill:

          https://github.com/alexgorbatchev/aerospace-sidebar/tree/main/skills/aerospace-sidebar

        """

    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "skill",
            abstract: "Print how to install the aerospace-sidebar agent skill.",
            shouldDisplay: false
        )
    }

    func run() async throws {
        try CLIContext.current.emit(Self.text)
    }
}

extension NotificationSeverity: ExpressibleByArgument {}
