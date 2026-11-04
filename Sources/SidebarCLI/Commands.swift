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
            discussion: CommandTree.render(children: [AskCommand.self, PushCommand.self, URLCommand.self]),
            shouldDisplay: false,
            subcommands: [AskCommand.self, PushCommand.self, URLCommand.self]
        )
    }
}

/// What a notification says, shared by `notification push`, `notification ask` and `notification url`.
struct NotificationContent: ParsableArguments {
    @Option(help: "Bold first line.")
    var title = ""

    @Option(help: "Line under the title.")
    var subtitle = ""

    @Option(help: "Main text, up to 4096 characters.")
    var body = ""

    @Flag(help: "Render the body as markdown: bold, italic, code, strikethrough and http or https links.")
    var markdown = false

    @Option(help: "How important it is; more severe notifications are listed first.")
    var severity: NotificationSeverity = .normal

    @Option(help: ArgumentHelp(
        "App icon from sketchybar-app-font, such as slack or :slack:. An unknown id is noted on the notification.",
        valueName: "id"
    ))
    var icon: String?

    /// - Parameter defaultIcon: The icon when `--icon` names none.
    func payload(
        action: NotificationAction? = nil, choices: [PushedChoice] = [], bundleIdentifier: String? = nil, defaultIcon: String? = nil
    ) throws -> NotificationPayload {
        try NotificationPayload(
            title: title, subtitle: subtitle, body: body, markdown: markdown, severity: severity, icon: icon ?? defaultIcon,
            bundleIdentifier: bundleIdentifier, action: action, choices: choices
        )
    }

    /// The payload of a notification sent from this command's process: without `--icon` the card shows the app the
    /// command runs in, such as its terminal, else a terminal glyph.
    func payload(sentFrom context: CLIContext, action: NotificationAction? = nil, choices: [PushedChoice]) throws -> NotificationPayload {
        let hostApp = context.hostApp
        return try payload(
            action: action, choices: choices, bundleIdentifier: hostApp, defaultIcon: hostApp == nil ? PushCommand.fallbackIcon : nil
        )
    }
}

/// `--open`, shared by `notification push` and `notification url`.
struct OpenOption: ParsableArguments {
    @Option(name: .customLong("open"), help: ArgumentHelp("URL to open when the notification is clicked.", valueName: "url"))
    var openURL: String?

    func openAction() throws -> NotificationAction? {
        try openURL.map { value in
            guard let url = URL(string: value), url.scheme != nil else {
                throw ValidationError("--open needs an absolute URL such as https://example.com")
            }
            return .open(url)
        }
    }
}

/// `--choice-link`, shared by `notification push` and `notification url`.
struct LinkChoicesOption: ParsableArguments {
    @Option(name: .customLong("choice-link"), help: ArgumentHelp(
        "A button that opens an http or https link. Repeat for more buttons.",
        valueName: "title=url"
    ), transform: TitledValue.parse)
    var links: [TitledValue] = []

    func choices() throws -> [PushedChoice] {
        try links.map { link in try PushedChoice(title: link.title, action: .open(SidebarRequest.webURL(link.value))) }
    }
}

/// An option value written `TITLE=VALUE`, split at the first `=`, so the value may hold more.
struct TitledValue: Equatable {
    let title: String
    let value: String

    static func parse(_ argument: String) throws -> TitledValue {
        guard let separator = argument.firstIndex(of: "="), separator != argument.startIndex else {
            throw ValidationError("expected TITLE=VALUE with a title before the first '='")
        }
        return TitledValue(title: String(argument[..<separator]), value: String(argument[argument.index(after: separator)...]))
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

    /// The sketchybar-app-font icon of a push that names none from outside any app.
    static let fallbackIcon = "terminal"

    @OptionGroup var content: NotificationContent
    @OptionGroup var open: OpenOption

    @Option(name: .customLong("run"), help: ArgumentHelp(
        "Shell command to run in the current directory when the notification is clicked.",
        valueName: "command"
    ))
    var command: String?

    @Option(name: .customLong("choice"), help: ArgumentHelp(
        "A button that runs a shell command in the current directory. Repeat for more buttons.",
        valueName: "title=command"
    ), transform: TitledValue.parse)
    var commandChoices: [TitledValue] = []

    @Option(name: .customLong("reply"), help: ArgumentHelp(
        "A button that opens a text field; sending the text runs a shell command in the current directory. Repeat for more buttons.",
        valueName: "title=command"
    ), transform: TitledValue.parse)
    var replyChoices: [TitledValue] = []

    @OptionGroup var links: LinkChoicesOption

    func validate() throws {
        if open.openURL != nil, command != nil {
            throw ValidationError("Use either --open or --run, not both.")
        }
    }

    func run() async throws {
        let context = CLIContext.current
        let directory = context.workingDirectory
        let action = try command.map { NotificationAction.run(command: $0, workingDirectory: directory) } ?? open.openAction()
        let choices = try commandChoices.map { choice in
            try PushedChoice(title: choice.title, action: .run(command: choice.value, workingDirectory: directory))
        } + replyChoices.map { choice in
            try PushedChoice(title: choice.title, action: .run(command: choice.value, workingDirectory: directory), asksForText: true)
        } + links.choices()
        try await context.sender.push(content.payload(sentFrom: context, action: action, choices: choices))
        try context.emit(context.isAgent ? "OK: pushed\n" : "[OK] Notification sent to the sidebar.\n")
    }
}

struct AskCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "ask",
            abstract: "Show a notification with buttons and wait for the user's answer.",
            shouldDisplay: false
        )
    }

    /// The longest `--timeout`, a year.
    static let maxTimeout: Double = 365 * 24 * 60 * 60

    @OptionGroup var content: NotificationContent

    @Option(name: .customLong("choice"), help: ArgumentHelp(
        "A button; choosing it prints its title. Repeat for more buttons.",
        valueName: "title"
    ))
    var choices: [String] = []

    @Option(name: .customLong("reply"), help: ArgumentHelp(
        "A button that opens a text field; sending it prints the text. Repeat for more buttons.",
        valueName: "title"
    ))
    var replies: [String] = []

    @Option(help: ArgumentHelp("Seconds to wait for an answer; waits as long as it takes without it.", valueName: "seconds"))
    var timeout: Double?

    @Flag(help: "Print the answer as JSON with the choice's title and the reply text, or null.")
    var json = false

    func validate() throws {
        guard !choices.isEmpty || !replies.isEmpty else {
            throw ValidationError("Give at least one --choice or --reply.")
        }
        if let timeout, !(timeout > 0 && timeout <= Self.maxTimeout) {
            throw ValidationError("--timeout needs a number of seconds above 0 and at most \(Int(Self.maxTimeout)).")
        }
    }

    func run() async throws {
        let context = CLIContext.current
        let choices = try choices.map { try PushedChoice(title: $0, action: .answer) }
            + replies.map { try PushedChoice(title: $0, action: .answer, asksForText: true) }
        let answer = try await context.sender.ask(
            content.payload(sentFrom: context, choices: choices),
            timeout: timeout.map { .milliseconds(Int64(($0 * 1000).rounded(.up))) }
        )
        guard case .answered(let choice, let reply) = answer else { throw CLIError.dismissed }
        // Agents get one `OK:` line that tells a title from a reply, which may span lines.
        let encoded = String(decoding: try Self.encoder.encode(Answer(choice: choice, reply: reply)), as: UTF8.self)
        if json {
            try context.emit(encoded + "\n")
        } else if context.isAgent {
            try context.emit("OK: \(encoded)\n")
        } else {
            try context.emit((reply ?? choice) + "\n")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// `--json` output; `reply` is null rather than missing for a choice that asks for no text.
    struct Answer: Encodable {
        let choice: String
        let reply: String?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(choice, forKey: .choice)
            try container.encode(reply, forKey: .reply)
        }

        private enum CodingKeys: String, CodingKey {
            case choice, reply
        }
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

    @OptionGroup var content: NotificationContent
    @OptionGroup var open: OpenOption
    @OptionGroup var links: LinkChoicesOption

    func run() async throws {
        let url = try SidebarRequest.pushNotification(content.payload(action: open.openAction(), choices: links.choices())).url()
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
