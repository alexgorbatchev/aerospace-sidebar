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
        public enum Display: String, Codable, CaseIterable, Sendable {
            case sidebar, jiggle, blackout

            var title: String {
                switch self {
                case .sidebar: "Sidebar only"
                case .jiggle: "Jiggle periodically"
                case .blackout: "Block screen"
                }
            }
        }
        /// The notification text a pattern is matched against.
        public enum Field: String, CaseIterable, Sendable {
            case source, title, subtitle, body

            /// A markdown body is matched as the card shows it, without its syntax (`displayedBody`).
            var keyPath: KeyPath<SidebarNotification, String> {
                switch self {
                case .source: \.source
                case .title: \.title
                case .subtitle: \.subtitle
                case .body: \.displayedBody
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
            case invalidInterval

            /// Completes "Rule 2 …".
            public var description: String {
                switch self {
                case .matchesEverything: "needs at least one pattern"
                case .invalidPattern(let field, let reason): "has an invalid \(field.rawValue) pattern: \(reason)"
                case .invalidInterval: "needs an interval from 1 to 1440 minutes"
                }
            }
        }

        public var source = ""
        public var title = ""
        public var subtitle = ""
        public var body = ""
        public var action = Action.severity(.high)
        public var display = Display.sidebar
        public var intervalMinutes = 5

        enum CodingKeys: String, CodingKey, CaseIterable {
            case source, title, subtitle, body, action
            case display
            case intervalMinutes = "interval_minutes"
        }

        public init(source: String = "", title: String = "", subtitle: String = "", body: String = "", action: Action = .severity(.high), display: Display = .sidebar, intervalMinutes: Int = 5) {
            self.source = source
            self.title = title
            self.subtitle = subtitle
            self.body = body
            self.action = action
            self.display = display
            self.intervalMinutes = intervalMinutes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
            for field in Field.allCases {
                self[field] = try container.decodeIfPresent(String.self, forKey: CodingKeys(rawValue: field.rawValue)!) ?? ""
            }
            let name = try container.decode(String.self, forKey: .action)
            guard let action = Action(name: name) else {
                let names = Action.allCases.map(\.name).formatted(.list(type: .or))
                throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: "action must be \(names)")
            }
            self.action = action
            display = try container.decodeIfPresent(Display.self, forKey: .display) ?? .sidebar
            intervalMinutes = try container.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 5
            guard (1...1440).contains(intervalMinutes) else {
                throw DecodingError.dataCorruptedError(forKey: .intervalMinutes, in: container, debugDescription: Problem.invalidInterval.description)
            }
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
            if display != .sidebar { try container.encode(display, forKey: .display) }
            if intervalMinutes != 5 { try container.encode(intervalMinutes, forKey: .intervalMinutes) }
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
            guard (1...1440).contains(rule.intervalMinutes) else { throw .invalidInterval }
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
