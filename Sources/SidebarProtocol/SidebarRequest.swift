import Foundation

/// Identity shared by the sidebar app and its clients.
public enum SidebarApp {
    public static let bundleIdentifier = "com.alexgorbatchev.aerospace-sidebar"
    /// Registered through `CFBundleURLTypes` in the app's Info.plist.
    public static let urlScheme = "aerospace-sidebar"

    /// Control socket for local clients, in the per-user temporary directory (`userTemporaryDirectory`).
    public static var controlSocketPath: String {
        userTemporaryDirectory.appendingPathComponent("\(bundleIdentifier).sock").path
    }

    /// The file whose lock the one running sidebar holds (`InstanceLock`), beside the control socket.
    public static var instanceLockPath: String {
        userTemporaryDirectory.appendingPathComponent("\(bundleIdentifier).lock").path
    }

    /// The per-user temporary directory (`confstr(_CS_DARWIN_USER_TEMP_DIR)`, mode 0700), which the app and a
    /// terminal resolve identically even when `TMPDIR` differs.
    static var userTemporaryDirectory: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let directory = length > 0
            ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : NSTemporaryDirectory()
        return URL(fileURLWithPath: directory)
    }
}

/// How important a notification is. More severe notifications sort above less severe ones.
public enum NotificationSeverity: String, Codable, CaseIterable, Comparable, Sendable {
    case low, normal, high, critical

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// What happens when the user clicks a notification.
public enum NotificationAction: Codable, Equatable, Sendable {
    /// Opens the URL with its default handler.
    case open(URL)
    /// Runs `command` with the user's login shell from the user database (`-lc`) in `workingDirectory`.
    case run(command: String, workingDirectory: String)
}

/// A button on a pushed notification's card, beside its click action.
public struct PushedChoice: Codable, Equatable, Hashable, Sendable {
    public enum Action: Codable, Equatable, Hashable, Sendable {
        /// Runs `command` with the user's login shell from the user database (`-lc`) in `workingDirectory`, with
        /// `AEROSPACE_SIDEBAR_CHOICE` set to the choice's title and, for a choice that asks for text,
        /// `AEROSPACE_SIDEBAR_REPLY` set to the text.
        case run(command: String, workingDirectory: String)
        /// Opens an `http` or `https` URL with its default handler.
        case open(URL)
        /// Answers the `notification ask` command waiting for the card (`ControlRequest.askNotification`).
        case answer
    }

    public static let maxTitleLength = 64
    /// The environment variable that names the choice a `run` choice's command was started for.
    public static let choiceVariable = "AEROSPACE_SIDEBAR_CHOICE"
    /// The environment variable that holds the text sent with a `run` choice that asks for text.
    public static let replyVariable = "AEROSPACE_SIDEBAR_REPLY"
    /// The most characters a reply may have, also in UTF-8 bytes per `NotificationPayload.maxBytesPerCharacter`.
    public static let maxReplyLength = 4096

    /// The button's title, unique among the notification's choices.
    public let title: String
    public let action: Action
    /// The button opens a field on the card, whose text is sent with the action; never for `open`.
    public let asksForText: Bool

    /// - Throws: `SidebarRequestError` for an empty or overlong title, a `run` action without a command or with
    ///   fields over their limits, an `open` action that is not an `http` or `https` URL, or one that asks for text.
    ///   A title, command or working directory holding a NUL character is refused too: the title goes into the
    ///   command's environment, and a process cannot be started with a NUL in its arguments or environment.
    public init(title: String, action: Action, asksForText: Bool = false) throws(SidebarRequestError) {
        guard !title.isEmpty else { throw .emptyChoiceTitle }
        try NotificationPayload.check("choice title", title, limit: Self.maxTitleLength, forProcess: true)
        switch action {
        case .run(let command, let workingDirectory):
            guard !command.isEmpty else { throw .missingChoiceCommand(title) }
            try NotificationPayload.check(
                "choice command", command, limit: NotificationPayload.maxCommandLength, forProcess: true
            )
            try NotificationPayload.check(
                "choice workingDirectory", workingDirectory, limit: NotificationPayload.maxWorkingDirectoryLength,
                forProcess: true
            )
        case .open(let url):
            guard !asksForText else { throw .linkChoiceAsksForText(title) }
            try NotificationPayload.check("choice URL", url.absoluteString, limit: NotificationPayload.maxOpenURLLength)
            _ = try SidebarRequest.webURL(url.absoluteString)
        case .answer:
            break
        }
        self.title = title
        self.action = action
        self.asksForText = asksForText
    }

    /// Whether a reply of `text` fits `maxReplyLength` and holds no NUL character, which a command's environment
    /// cannot carry.
    public static func fits(reply text: String) -> Bool {
        text.count <= maxReplyLength && text.utf8.count <= maxReplyLength * NotificationPayload.maxBytesPerCharacter
            && !text.utf8.contains(0)
    }

    private enum CodingKeys: String, CodingKey {
        case title, action, asksForText
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            title: container.decode(String.self, forKey: .title),
            action: container.decode(Action.self, forKey: .action),
            asksForText: container.decodeIfPresent(Bool.self, forKey: .asksForText) ?? false
        )
    }
}

/// A notification pushed into the sidebar from outside the app.
public struct NotificationPayload: Codable, Equatable, Sendable {
    public static let maxTitleLength = 256
    public static let maxSubtitleLength = 256
    public static let maxBodyLength = 4096
    public static let maxIconLength = 64
    public static let maxBundleIdentifierLength = 255
    public static let maxOpenURLLength = 8192
    public static let maxCommandLength = 4096
    public static let maxWorkingDirectoryLength = Int(PATH_MAX)
    public static let maxChoices = 8
    public static let maxKeyLength = 128
    /// UTF-8 bytes a field may take per character of its limit: four, the most one code point takes. A character
    /// can stack any number of code points, such as a letter with combining marks, so a character count alone
    /// bounds neither the text kept nor the request carrying it.
    public static let maxBytesPerCharacter = 4

    public let title: String
    public let subtitle: String
    public let body: String
    /// The body is markdown: the card shows its inline styles and http and https links (bold, italic, code,
    /// strikethrough), and everything else as written. Field limits apply to the markdown itself.
    public let markdown: Bool
    public let severity: NotificationSeverity
    /// sketchybar-app-font icon id, such as `slack` or `:slack:`. The app resolves it; an unknown id is
    /// noted on the notification rather than rejected.
    public let icon: String?
    /// Bundle identifier of the app the sender runs in, such as its terminal; the card shows that app's icon
    /// when `icon` names none. URLs do not carry it.
    public let bundleIdentifier: String?
    public let action: NotificationAction?
    /// Buttons on the card besides its click action, in order.
    public let choices: [PushedChoice]
    /// Names the card: a later push from the same source with the same key replaces the card's content and stacks
    /// onto it, whatever either says. Asks take none.
    public let key: String?

    /// - Throws: `SidebarRequestError` when both title and body are empty, a field, the action's included,
    ///   exceeds its limit in characters or `maxBytesPerCharacter` times that in UTF-8 bytes, `key` holds a NUL or
    ///   only whitespace, or there are more than `maxChoices` choices or two with one title.
    public init(
        title: String = "",
        subtitle: String = "",
        body: String = "",
        markdown: Bool = false,
        severity: NotificationSeverity = .normal,
        icon: String? = nil,
        bundleIdentifier: String? = nil,
        action: NotificationAction? = nil,
        choices: [PushedChoice] = [],
        key: String? = nil
    ) throws(SidebarRequestError) {
        guard !title.isEmpty || !body.isEmpty else {
            throw .emptyNotification
        }
        guard choices.count <= Self.maxChoices else { throw .tooManyChoices(limit: Self.maxChoices) }
        var titles = Set<String>()
        for choice in choices where !titles.insert(choice.title).inserted {
            throw .duplicateChoice(choice.title)
        }
        // A command and its directory go to a process, which cannot be started with a NUL in them.
        let actionFields: [(String, String, Int, Bool)] = switch action {
        case nil: []
        case .open(let url): [("open", url.absoluteString, Self.maxOpenURLLength, false)]
        case .run(let command, let workingDirectory):
            [
                ("command", command, Self.maxCommandLength, true),
                ("workingDirectory", workingDirectory, Self.maxWorkingDirectoryLength, true),
            ]
        }
        for (field, value, limit, forProcess) in [
            ("title", title, Self.maxTitleLength, false),
            ("subtitle", subtitle, Self.maxSubtitleLength, false),
            ("body", body, Self.maxBodyLength, false),
            ("icon", icon ?? "", Self.maxIconLength, false),
            ("bundleIdentifier", bundleIdentifier ?? "", Self.maxBundleIdentifierLength, false),
        ] + actionFields {
            try Self.check(field, value, limit: limit, forProcess: forProcess)
        }
        let key = key?.isEmpty == false ? key : nil
        if let key {
            try Self.check("key", key, limit: Self.maxKeyLength, forProcess: true)
            guard !key.allSatisfy(\.isWhitespace) else { throw .blankKey }
        }
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.markdown = markdown
        self.severity = severity
        self.icon = icon?.isEmpty == false ? icon : nil
        self.bundleIdentifier = bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil
        self.action = action
        self.choices = choices
        self.key = key
    }

    /// - Parameter forProcess: The value goes into a process's arguments or environment, which cannot hold NUL.
    /// - Throws: `SidebarRequestError.fieldTooLong` when `value` exceeds `limit` characters or `maxBytesPerCharacter`
    ///   times that in UTF-8 bytes, and `.nulCharacter` for a NUL in a value for a process.
    static func check(_ field: String, _ value: String, limit: Int, forProcess: Bool = false) throws(SidebarRequestError) {
        if value.utf8.count > limit * maxBytesPerCharacter || value.count > limit {
            throw .fieldTooLong(field: field, limit: limit)
        }
        if forProcess, value.utf8.contains(0) {
            throw .nulCharacter(field: field)
        }
    }

    /// Whether a choice answers the `notification ask` command waiting for the card.
    public var asks: Bool { choices.contains { $0.action == .answer } }

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, body, markdown, severity, icon, bundleIdentifier, action, choices, key
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            title: container.decodeIfPresent(String.self, forKey: .title) ?? "",
            subtitle: container.decodeIfPresent(String.self, forKey: .subtitle) ?? "",
            body: container.decodeIfPresent(String.self, forKey: .body) ?? "",
            markdown: container.decodeIfPresent(Bool.self, forKey: .markdown) ?? false,
            severity: container.decodeIfPresent(NotificationSeverity.self, forKey: .severity) ?? .normal,
            icon: container.decodeIfPresent(String.self, forKey: .icon),
            bundleIdentifier: container.decodeIfPresent(String.self, forKey: .bundleIdentifier),
            action: container.decodeIfPresent(NotificationAction.self, forKey: .action),
            choices: container.decodeIfPresent([PushedChoice].self, forKey: .choices) ?? [],
            key: container.decodeIfPresent(String.self, forKey: .key)
        )
    }
}

public enum SidebarRequestError: Error, Equatable, Sendable {
    case unsupportedScheme(String?)
    case unknownRoute(String)
    case emptyNotification
    case fieldTooLong(field: String, limit: Int)
    /// A value that goes to a process, such as a command or a choice's title, holds a NUL character.
    case nulCharacter(field: String)
    case invalidOpenURL(String)
    case invalidSeverity(String)
    /// A URL's `markdown` is neither `1`/`true` nor `0`/`false`.
    case invalidMarkdownFlag(String)
    case actionNotAllowedInURL
    case emptyChoiceTitle
    case duplicateChoice(String)
    case tooManyChoices(limit: Int)
    case missingChoiceCommand(String)
    case linkChoiceAsksForText(String)
    /// A choice in a `choice=TITLE=URL` query item without the `=` between title and URL.
    case invalidChoiceItem(String)
    /// A URL choice's title ends at its first `=`, so a title holding one cannot go into a URL.
    case equalsInURLChoiceTitle(String)
    /// An ask needs at least one choice, and only choices that answer it.
    case askNeedsAnswers
    /// Only an ask's choices answer it.
    case answerOutsideAsk
    /// A key holds only whitespace.
    case blankKey
    /// Asks never stack, so they take no key.
    case keyOnAsk
}

extension SidebarRequestError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unsupportedScheme(let scheme):
            "unsupported URL scheme \(scheme.map { "'\($0)'" } ?? "(none)"), expected '\(SidebarApp.urlScheme)'"
        case .unknownRoute(let route): "unknown route '\(route)', expected 'notification/push'"
        case .emptyNotification: "a notification needs a title or a body"
        case .fieldTooLong(let field, let limit):
            "\(field) is longer than \(limit) characters (or \(limit * NotificationPayload.maxBytesPerCharacter) bytes in UTF-8)"
        case .nulCharacter(let field): "\(field) holds a NUL character"
        case .invalidOpenURL(let value): "'\(value)' is not an http or https URL"
        case .invalidSeverity(let value):
            "'\(value)' is not a severity, expected \(NotificationSeverity.allCases.map(\.rawValue).joined(separator: ", "))"
        case .invalidMarkdownFlag(let value): "'\(value)' is not a markdown flag, expected 1, true, 0 or false"
        case .actionNotAllowedInURL:
            "commands, reply fields and asks cannot be sent through a URL; use the aerospace-sidebar CLI"
        case .emptyChoiceTitle: "a choice needs a title"
        case .duplicateChoice(let title): "two choices are titled '\(title)'"
        case .tooManyChoices(let limit): "a notification takes at most \(limit) choices"
        case .missingChoiceCommand(let title): "choice '\(title)' needs a command"
        case .linkChoiceAsksForText(let title): "choice '\(title)' opens a link and cannot ask for text"
        case .invalidChoiceItem(let value): "'\(value)' is not a choice, expected TITLE=URL"
        case .equalsInURLChoiceTitle(let title): "choice title '\(title)' holds '=', which ends a title in a URL"
        case .askNeedsAnswers: "an ask needs at least one choice, and every choice must answer it"
        case .answerOutsideAsk: "only an ask's choices can answer it"
        case .blankKey: "a key needs more than whitespace"
        case .keyOnAsk: "an ask takes no key: asks never stack"
        }
    }
}

/// A request carried by an `aerospace-sidebar://<subject>/<verb>?<query>` URL.
///
/// Any process, including a web page after the browser's confirmation prompt, can open these URLs,
/// so they never carry commands and only open `http`/`https` links on click.
///
/// Supported routes:
/// - `aerospace-sidebar://notification/push?title=…&subtitle=…&body=…&markdown=1&severity=high&icon=slack&open=https://…&choice=Docs=https://…&key=build`
///
/// `markdown=1` (or `true`) renders the body as markdown (`NotificationPayload.markdown`). `key` names the card, so
/// a later URL push with that key replaces it (`NotificationPayload.key`). `choice` repeats, one
/// link button each: its title, then `=`, then the `http` or `https` URL it opens.
public enum SidebarRequest: Equatable, Sendable {
    case pushNotification(NotificationPayload)

    public init(url: URL) throws(SidebarRequestError) {
        guard url.scheme?.lowercased() == SidebarApp.urlScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw .unsupportedScheme(url.scheme)
        }
        let route = "\(components.host ?? "")\(components.path)"
        guard route == "notification/push" else {
            throw .unknownRoute(route)
        }
        let items = components.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let choices = try items.filter { $0.name == "choice" }.map { item throws(SidebarRequestError) in
            let value = item.value ?? ""
            guard let separator = value.firstIndex(of: "=") else { throw .invalidChoiceItem(value) }
            return try PushedChoice(
                title: String(value[..<separator]),
                action: .open(Self.webURL(String(value[value.index(after: separator)...])))
            )
        }
        let action = try query["open"].map { value throws(SidebarRequestError) in
            NotificationAction.open(try Self.webURL(value))
        }
        let severity = try query["severity"].map { value throws(SidebarRequestError) in
            guard let severity = NotificationSeverity(rawValue: value.lowercased()) else { throw .invalidSeverity(value) }
            return severity
        }
        let markdown = try query["markdown"].map { value throws(SidebarRequestError) in
            switch value.lowercased() {
            case "1", "true": return true
            case "0", "false": return false
            default: throw .invalidMarkdownFlag(value)
            }
        }
        self = .pushNotification(try NotificationPayload(
            title: query["title"] ?? "",
            subtitle: query["subtitle"] ?? "",
            body: query["body"] ?? "",
            markdown: markdown ?? false,
            severity: severity ?? .normal,
            icon: query["icon"],
            action: action,
            choices: choices,
            key: query["key"]
        ))
    }

    /// The URL form of the request.
    /// - Throws: `SidebarRequestError.actionNotAllowedInURL` for actions URLs cannot carry.
    public func url() throws(SidebarRequestError) -> URL {
        switch self {
        case .pushNotification(let payload):
            var openValue: String?
            switch payload.action {
            case nil: break
            case .open(let target): openValue = try Self.webURL(target.absoluteString).absoluteString
            case .run: throw .actionNotAllowedInURL
            }
            let choices = try payload.choices.map { choice throws(SidebarRequestError) in
                guard case .open(let target) = choice.action, !choice.asksForText else { throw .actionNotAllowedInURL }
                guard !choice.title.contains("=") else { throw .equalsInURLChoiceTitle(choice.title) }
                return ("choice", "\(choice.title)=\(try Self.webURL(target.absoluteString).absoluteString)")
            }
            var components = URLComponents()
            components.scheme = SidebarApp.urlScheme
            components.host = "notification"
            components.path = "/push"
            components.queryItems = ([
                ("title", payload.title), ("subtitle", payload.subtitle), ("body", payload.body),
                ("markdown", payload.markdown ? "1" : ""),
                ("severity", payload.severity == .normal ? "" : payload.severity.rawValue), ("icon", payload.icon ?? ""),
                ("open", openValue ?? ""),
            ] + choices + [("key", payload.key ?? "")])
            .filter { !$0.1.isEmpty }
            .map { URLQueryItem(name: $0.0, value: $0.1) }
            // URLComponents leaves "+" unescaped, and many URL consumers read it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
            return components.url!
        }
    }

    /// `value` as an absolute `http` or `https` URL with a host, the only links URLs and link choices open.
    /// - Throws: `SidebarRequestError.invalidOpenURL` for anything else.
    public static func webURL(_ value: String) throws(SidebarRequestError) -> URL {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
            throw .invalidOpenURL(value)
        }
        return url
    }
}
