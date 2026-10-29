import Foundation
import SQLite3

/// One action a native notification offers besides opening and closing it, such as Reply or Snooze, as its
/// app declared it to macOS.
public struct NativeChoice: Codable, Equatable, Hashable, Sendable {
    /// An action that asks for text before it is sent, such as Reply.
    public struct TextInput: Codable, Equatable, Hashable, Sendable {
        /// The field's placeholder.
        public var placeholder: String
        /// The button that sends the text; once the field is open, NotificationCenter names an accessibility
        /// action after it.
        public var sendTitle: String

        public init(placeholder: String = "", sendTitle: String = "") {
            self.placeholder = placeholder
            self.sendTitle = sendTitle
        }
    }

    /// The title NotificationCenter shows, which names its accessibility action.
    public var title: String
    public var textInput: TextInput?
    /// The app marked it destructive, such as Delete.
    public var isDestructive = false

    public init(title: String, textInput: TextInput? = nil, isDestructive: Bool = false) {
        self.title = title
        self.textInput = textInput
        self.isDestructive = isDestructive
    }

    /// `UNNotificationActionOptions.destructive`.
    static let destructiveOption = 1 << 1

    /// The choices a category's declared actions offer, in order, as usernoted stores them: dictionaries with
    /// the title `ti`, options `op`, and for text input `st` 1 with the placeholder `tip` and send title `tia`.
    static func choices(declaredBy actions: [[String: Any]]) -> [NativeChoice] {
        actions.compactMap { action in
            guard let title = action["ti"] as? String else { return nil }
            let textInput = (action["st"] as? NSNumber)?.intValue == 1
                ? TextInput(placeholder: action["tip"] as? String ?? "", sendTitle: action["tia"] as? String ?? "")
                : nil
            let options = (action["op"] as? NSNumber)?.intValue ?? 0
            return NativeChoice(title: title, textInput: textInput, isDestructive: options & destructiveOption != 0)
        }
    }
}

/// The choices each app declared to macOS, read from the notification database (`declaredChoices(ofApp:)`)
/// and kept for `lifetime`: an app declares them at launch, while sweeps ask several times a second. A read
/// that fails, such as without Full Disk Access, keeps what was read before and is tried again after
/// `retryInterval`.
@MainActor
public final class DeclaredChoices {
    static let lifetime: TimeInterval = 60
    static let retryInterval: TimeInterval = 5

    private let read: @MainActor (String) -> [String: [NativeChoice]]?
    private let now: () -> Date
    private var cache: [String: (categories: [String: [NativeChoice]], until: Date)] = [:]

    public convenience init(database: NotificationDatabase, now: @escaping () -> Date = Date.init) {
        self.init(now: now) { try? database.declaredChoices(ofApp: $0) }
    }

    /// - Parameter read: The categories the app with a bundle identifier declared, keyed by identifier; nil when
    ///   they cannot be read.
    init(now: @escaping () -> Date = Date.init, read: @escaping @MainActor (String) -> [String: [NativeChoice]]?) {
        self.now = now
        self.read = read
    }

    /// What the app with `bundleIdentifier` declared for a notification whose choices NotificationCenter
    /// titles `titles`: the choices of the category with exactly those titles, in the order the app declared
    /// them. Nil when no category has them, or several do with different choices, such as one asking for text
    /// and one not.
    public func choices(ofApp bundleIdentifier: String, titled titles: [String]) -> [NativeChoice]? {
        let wanted = Set(titles)
        let matches = Set(categories(ofApp: bundleIdentifier).values.filter {
            $0.count == titles.count && Set($0.map(\.title)) == wanted
        })
        return matches.count == 1 ? matches.first : nil
    }

    private func categories(ofApp bundleIdentifier: String) -> [String: [NativeChoice]] {
        let time = now()
        if let cached = cache[bundleIdentifier], time < cached.until {
            return cached.categories
        }
        guard let categories = read(bundleIdentifier) else {
            let kept = cache[bundleIdentifier]?.categories ?? [:]
            cache[bundleIdentifier] = (kept, time.addingTimeInterval(Self.retryInterval))
            return kept
        }
        cache[bundleIdentifier] = (categories, time.addingTimeInterval(Self.lifetime))
        return categories
    }
}

extension NotificationDatabase {
    /// The choices each category the app with `bundleIdentifier` registered offers (UNNotificationCategory),
    /// keyed by category identifier; empty for an app that registered none, such as one posting through
    /// NSUserNotification, whose notifications carry their actions themselves.
    public func declaredChoices(ofApp bundleIdentifier: String) throws(Failure) -> [String: [NativeChoice]] {
        let connection = try Connection(url: url)
        let statement = try connection.prepare("""
            SELECT c.categories FROM categories c JOIN app a ON a.app_id = c.app_id WHERE a.identifier = ? COLLATE NOCASE
            """)
        statement.bind(bundleIdentifier, at: 1)
        guard try statement.step(), let data = statement.blob(0),
              let categories = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return [:] }
        var choices: [String: [NativeChoice]] = [:]
        for category in categories {
            guard let identifier = category["id"] as? String else { continue }
            choices[identifier] = NativeChoice.choices(declaredBy: category["acts"] as? [[String: Any]] ?? [])
        }
        return choices
    }
}

extension Statement {
    func bind(_ value: String, at index: Int32) {
        sqlite3_bind_text(handle, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
