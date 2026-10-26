import Foundation

/// Identity shared by the sidebar app and its clients.
public enum SidebarApp {
    public static let bundleIdentifier = "com.alexgorbatchev.aerospace-sidebar"
    /// Registered through `CFBundleURLTypes` in the app's Info.plist.
    public static let urlScheme = "aerospace-sidebar"

    /// Control socket for local clients. It lives in the per-user temporary directory
    /// (`confstr(_CS_DARWIN_USER_TEMP_DIR)`, mode 0700), which the app and a terminal
    /// resolve identically even when `TMPDIR` differs.
    public static var controlSocketPath: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let directory = length > 0
            ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : NSTemporaryDirectory()
        return URL(fileURLWithPath: directory).appendingPathComponent("\(bundleIdentifier).sock").path
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
    /// Runs `command` with the user's login shell (`$SHELL -lc`) in `workingDirectory`.
    case run(command: String, workingDirectory: String)
}

/// A notification pushed into the sidebar from outside the app.
public struct NotificationPayload: Codable, Equatable, Sendable {
    public static let maxTitleLength = 256
    public static let maxSubtitleLength = 256
    public static let maxBodyLength = 4096

    public let title: String
    public let subtitle: String
    public let body: String
    public let severity: NotificationSeverity
    public let action: NotificationAction?

    /// - Throws: `SidebarRequestError` when both title and body are empty or a field exceeds its limit.
    public init(
        title: String = "",
        subtitle: String = "",
        body: String = "",
        severity: NotificationSeverity = .normal,
        action: NotificationAction? = nil
    ) throws(SidebarRequestError) {
        guard !title.isEmpty || !body.isEmpty else {
            throw .emptyNotification
        }
        for (field, value, limit) in [
            ("title", title, Self.maxTitleLength),
            ("subtitle", subtitle, Self.maxSubtitleLength),
            ("body", body, Self.maxBodyLength),
        ] where value.count > limit {
            throw .fieldTooLong(field: field, limit: limit)
        }
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.severity = severity
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, body, severity, action
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            title: container.decodeIfPresent(String.self, forKey: .title) ?? "",
            subtitle: container.decodeIfPresent(String.self, forKey: .subtitle) ?? "",
            body: container.decodeIfPresent(String.self, forKey: .body) ?? "",
            severity: container.decodeIfPresent(NotificationSeverity.self, forKey: .severity) ?? .normal,
            action: container.decodeIfPresent(NotificationAction.self, forKey: .action)
        )
    }
}

public enum SidebarRequestError: Error, Equatable, Sendable {
    case unsupportedScheme(String?)
    case unknownRoute(String)
    case emptyNotification
    case fieldTooLong(field: String, limit: Int)
    case invalidOpenURL(String)
    case invalidSeverity(String)
    case actionNotAllowedInURL
}

extension SidebarRequestError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unsupportedScheme(let scheme):
            "unsupported URL scheme \(scheme.map { "'\($0)'" } ?? "(none)"), expected '\(SidebarApp.urlScheme)'"
        case .unknownRoute(let route): "unknown route '\(route)', expected 'notification/push'"
        case .emptyNotification: "a notification needs a title or a body"
        case .fieldTooLong(let field, let limit): "\(field) is longer than \(limit) characters"
        case .invalidOpenURL(let value): "'\(value)' is not an http or https URL"
        case .invalidSeverity(let value):
            "'\(value)' is not a severity, expected \(NotificationSeverity.allCases.map(\.rawValue).joined(separator: ", "))"
        case .actionNotAllowedInURL: "commands cannot be sent through a URL; use the aerospace-sidebar CLI"
        }
    }
}

/// A request carried by an `aerospace-sidebar://<subject>/<verb>?<query>` URL.
///
/// Any process, including a web page after the browser's confirmation prompt, can open these URLs,
/// so they never carry commands and only open `http`/`https` links on click.
///
/// Supported routes:
/// - `aerospace-sidebar://notification/push?title=…&subtitle=…&body=…&severity=high&open=https://…`
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
        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        let action = try query["open"].map { value throws(SidebarRequestError) in
            NotificationAction.open(try Self.webURL(value))
        }
        let severity = try query["severity"].map { value throws(SidebarRequestError) in
            guard let severity = NotificationSeverity(rawValue: value.lowercased()) else { throw .invalidSeverity(value) }
            return severity
        }
        self = .pushNotification(try NotificationPayload(
            title: query["title"] ?? "",
            subtitle: query["subtitle"] ?? "",
            body: query["body"] ?? "",
            severity: severity ?? .normal,
            action: action
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
            var components = URLComponents()
            components.scheme = SidebarApp.urlScheme
            components.host = "notification"
            components.path = "/push"
            components.queryItems = [
                ("title", payload.title), ("subtitle", payload.subtitle), ("body", payload.body),
                ("severity", payload.severity == .normal ? "" : payload.severity.rawValue), ("open", openValue ?? ""),
            ]
            .filter { !$0.1.isEmpty }
            .map { URLQueryItem(name: $0.0, value: $0.1) }
            // URLComponents leaves "+" unescaped, and many URL consumers read it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
            return components.url!
        }
    }

    private static func webURL(_ value: String) throws(SidebarRequestError) -> URL {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
            throw .invalidOpenURL(value)
        }
        return url
    }
}
