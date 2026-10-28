import Foundation
import SidebarProtocol

extension SidebarSettings {
    /// Changes the severity of incoming notifications whose texts match, or hides them.
    ///
    /// ```toml
    /// [[rules]]
    /// source = "^Slack$"
    /// action = "high"
    /// ```
    ///
    /// Each pattern is a case-insensitive regular expression searched anywhere in its field; an empty
    /// pattern matches anything, and a rule needs at least one. The first matching rule applies.
    public struct Rule: Codable, Equatable, Sendable {
        /// The notification text a pattern is matched against.
        public enum Field: String, CaseIterable, Sendable {
            case source, title, subtitle, body

            var keyPath: KeyPath<SidebarNotification, String> {
                switch self {
                case .source: \.source
                case .title: \.title
                case .subtitle: \.subtitle
                case .body: \.body
                }
            }
        }

        /// What a matching rule does.
        public enum Action: Hashable, Sendable {
            /// Drops the notification: it is not listed.
            case hide
            case severity(NotificationSeverity)

            public static let allCases: [Action] = [.hide] + NotificationSeverity.allCases.map(Action.severity)

            /// The value in `config.toml`.
            public var name: String {
                switch self {
                case .hide: "hide"
                case .severity(let severity): severity.rawValue
                }
            }

            public init?(name: String) {
                if name == "hide" {
                    self = .hide
                } else if let severity = NotificationSeverity(rawValue: name) {
                    self = .severity(severity)
                } else {
                    return nil
                }
            }
        }

        /// Why a rule cannot be used.
        public enum Problem: Error, Equatable, CustomStringConvertible {
            case matchesEverything
            case invalidPattern(Field, reason: String)

            /// Completes "Rule 2 …".
            public var description: String {
                switch self {
                case .matchesEverything: "needs at least one pattern"
                case .invalidPattern(let field, let reason): "has an invalid \(field.rawValue) pattern: \(reason)"
                }
            }
        }

        public var source = ""
        public var title = ""
        public var subtitle = ""
        public var body = ""
        public var action = Action.severity(.high)

        enum CodingKeys: String, CodingKey {
            case source, title, subtitle, body, action
        }

        public init(source: String = "", title: String = "", subtitle: String = "", body: String = "", action: Action = .severity(.high)) {
            self.source = source
            self.title = title
            self.subtitle = subtitle
            self.body = body
            self.action = action
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            for field in Field.allCases {
                self[field] = try container.decodeIfPresent(String.self, forKey: CodingKeys(rawValue: field.rawValue)!) ?? ""
            }
            let name = try container.decode(String.self, forKey: .action)
            guard let action = Action(name: name) else {
                let names = Action.allCases.map(\.name).formatted(.list(type: .or))
                throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: "action must be \(names)")
            }
            self.action = action
            do {
                _ = try Self.compile(self)
            } catch .invalidPattern(let field, let reason) {
                throw DecodingError.dataCorruptedError(
                    forKey: CodingKeys(rawValue: field.rawValue)!, in: container, debugDescription: "invalid regular expression: \(reason)"
                )
            } catch {
                throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: "a rule needs at least one pattern")
            }
        }

        /// Writes only the patterns that are set.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            for field in Field.allCases where !self[field].isEmpty {
                try container.encode(self[field], forKey: CodingKeys(rawValue: field.rawValue)!)
            }
            try container.encode(action.name, forKey: .action)
        }

        public subscript(field: Field) -> String {
            get {
                switch field {
                case .source: source
                case .title: title
                case .subtitle: subtitle
                case .body: body
                }
            }
            set {
                switch field {
                case .source: source = newValue
                case .title: title = newValue
                case .subtitle: subtitle = newValue
                case .body: body = newValue
                }
            }
        }

        /// The rule's patterns as case-insensitive regular expressions, by field.
        static func compile(_ rule: Rule) throws(Problem) -> [(Field, Regex<AnyRegexOutput>)] {
            var patterns: [(Field, Regex<AnyRegexOutput>)] = []
            for field in Field.allCases where !rule[field].isEmpty {
                do {
                    patterns.append((field, try Regex(rule[field]).ignoresCase()))
                } catch {
                    throw .invalidPattern(field, reason: String(describing: error))
                }
            }
            guard !patterns.isEmpty else { throw .matchesEverything }
            return patterns
        }

        /// Why the rule cannot be used, if it cannot.
        public var problem: Problem? {
            do {
                _ = try Self.compile(self)
                return nil
            } catch {
                return error
            }
        }
    }
}

/// `SidebarSettings.rules` ready to match: the first rule whose patterns all match a notification applies.
struct NotificationRules {
    private let rules: [(rule: SidebarSettings.Rule, patterns: [(SidebarSettings.Rule.Field, Regex<AnyRegexOutput>)])]

    /// Rules that cannot be used are left out; loading and saving settings refuse them.
    init(_ rules: [SidebarSettings.Rule]) {
        self.rules = rules.compactMap { rule in (try? SidebarSettings.Rule.compile(rule)).map { (rule, $0) } }
    }

    /// The first rule that matches `notification`.
    func firstMatch(for notification: SidebarNotification) -> SidebarSettings.Rule? {
        rules.first { _, patterns in
            patterns.allSatisfy { field, regex in notification[keyPath: field.keyPath].contains(regex) }
        }?.rule
    }

    /// `notification` as the first matching rule leaves it: unchanged, with another severity, or nil when hidden.
    func apply(to notification: SidebarNotification) -> SidebarNotification? {
        switch firstMatch(for: notification)?.action {
        case nil: notification
        case .hide: nil
        case .severity(let severity): notification.with(severity: severity)
        }
    }
}
