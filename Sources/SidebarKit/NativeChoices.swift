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
    /// Marks an item of an NSUserNotification's actions menu in the actions its record carries (`scat`).
    static let menuItemOption = 1 << 6
    /// The action usernoted records for an NSUserNotification's action button, which heads its actions menu
    /// when it has one.
    static let actionButtonIdentifier = "ACTION"

    /// The choices a category's declared actions offer, in order, as usernoted stores them: dictionaries with
    /// the title `ti`, options `op`, and for text input `st` 1 with the placeholder `tip` and send title `tia`.
    /// An NSUserNotification's record carries its actions the same way, its actions menu's items marked with
    /// `menuItemOption`; the menu's header, the action button without that option, only closes the notification
    /// unanswered, so it is no choice. Neither is an action without a title, which names no accessibility action.
    static func choices(declaredBy actions: [[String: Any]]) -> [NativeChoice] {
        let hasMenu = actions.contains { options(of: $0) & menuItemOption != 0 }
        return actions.compactMap { action in
            let options = options(of: action)
            guard let title = action["ti"] as? String, !title.isEmpty,
                  !(hasMenu && action["id"] as? String == actionButtonIdentifier && options & menuItemOption == 0)
            else { return nil }
            let textInput = (action["st"] as? NSNumber)?.intValue == 1
                ? TextInput(placeholder: action["tip"] as? String ?? "", sendTitle: action["tia"] as? String ?? "")
                : nil
            return NativeChoice(title: title, textInput: textInput, isDestructive: options & destructiveOption != 0)
        }
    }

    private static func options(of action: [String: Any]) -> Int {
        (action["op"] as? NSNumber)?.intValue ?? 0
    }
}

/// The choices each app declared to macOS, read from the notification database (`declaredChoices(ofApp:)`)
/// and kept for `lifetime`: an app declares them at launch, while sweeps ask several times a second. A read
/// that fails, such as without Full Disk Access, keeps what was read before and is tried again after
/// `retryInterval`; until one succeeds, nothing is known about the app (`declaresNone(ofApp:)`).
@MainActor
public final class DeclaredChoices {
    static let lifetime: TimeInterval = 60
    static let retryInterval: TimeInterval = 5

    private let read: @MainActor (String) -> [String: [NativeChoice]]?
    private let now: () -> Date
    private var cache: [String: (categories: [String: [NativeChoice]], isRead: Bool, until: Date)] = [:]

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

    /// Whether the app with `bundleIdentifier` is known to have declared no categories at all, as an app posting
    /// through NSUserNotification has (Chromium browsers' web notifications, alerter): its notifications carry
    /// their actions themselves, which only their records name. False while its categories cannot be read.
    public func declaresNone(ofApp bundleIdentifier: String) -> Bool {
        let entry = entry(ofApp: bundleIdentifier)
        return entry.isRead && entry.categories.isEmpty
    }

    private func categories(ofApp bundleIdentifier: String) -> [String: [NativeChoice]] {
        entry(ofApp: bundleIdentifier).categories
    }

    private func entry(ofApp bundleIdentifier: String) -> (categories: [String: [NativeChoice]], isRead: Bool) {
        let time = now()
        if let cached = cache[bundleIdentifier], time < cached.until {
            return (cached.categories, cached.isRead)
        }
        guard let categories = read(bundleIdentifier) else {
            let kept = cache[bundleIdentifier]
            cache[bundleIdentifier] = (kept?.categories ?? [:], kept?.isRead ?? false, time.addingTimeInterval(Self.retryInterval))
            return (kept?.categories ?? [:], kept?.isRead ?? false)
        }
        cache[bundleIdentifier] = (categories, true, time.addingTimeInterval(Self.lifetime))
        return (categories, true)
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

    /// The choices a delivered notification offers, as its record names them: the actions an NSUserNotification
    /// carries itself, else those of the category its app declared for it, read now rather than from a cache,
    /// since an app declares its categories when it launches, just before it posts. Nil when it offers none.
    public func choices(ofNotification notification: DeliveredNotification) throws(Failure) -> [NativeChoice]? {
        if let own = notification.ownChoices { return own }
        guard let category = notification.category,
              let choices = try declaredChoices(ofApp: notification.bundleIdentifier)[category], !choices.isEmpty
        else { return nil }
        return choices
    }
}

extension Statement {
    func bind(_ value: String, at index: Int32) {
        sqlite3_bind_text(handle, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
