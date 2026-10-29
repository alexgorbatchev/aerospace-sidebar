import Foundation
import Observation
import SidebarProtocol

/// One notification shown in the sidebar.
public struct SidebarNotification: Identifiable, Codable, Equatable, Sendable {
    public enum ClickAction: Codable, Equatable, Sendable {
        case open(URL)
        case run(command: String, workingDirectory: String)
        /// Brings the app that posted an intercepted system notification to the front. What a click does when
        /// none of the card's `nativeIdentifiers` can be opened any more.
        case activateApp(name: String)
    }

    /// A sketchybar-app-font icon (`AppIconFont`).
    public struct Icon: Codable, Equatable, Sendable {
        /// Icon id without the surrounding colons, such as `slack`.
        public let id: String

        /// The ligature that the font draws as the icon.
        var glyph: String { ":\(id):" }

        /// The id in words, such as "Google Chrome". Several apps can share an icon (`mail` stands for Mail,
        /// Spark, HEY and others), so the label names the icon rather than one of its apps.
        var accessibilityLabel: String { id.replacingOccurrences(of: "_", with: " ").capitalized }
    }

    /// A macOS notification that stays hidden while its card offers its choices: an alert's named actions
    /// (`NotificationBanners.choices(of:labels:)`), or the actions any notification's app declared
    /// (`SystemNotificationInterceptor`).
    public struct NativeChoices: Codable, Equatable, Sendable {
        /// The notification's `AXIdentifier`, a UUID that NotificationCenter keeps for its lifetime.
        public let identifier: String
        /// The actions it offers besides opening and closing it, such as "Allow…" or Reply.
        public let choices: [NativeChoice]

        public init(identifier: String, choices: [NativeChoice]) {
            self.identifier = identifier
            self.choices = choices
        }
    }

    public let id: UUID
    /// The app that posted the notification, or the process that pushed it.
    public let source: String
    public let title: String
    public let subtitle: String
    public let body: String
    public let severity: NotificationSeverity
    /// The severity it arrived with, when a rule changed it; nil when `severity` is its own. Changed rules
    /// start over from it.
    public let postedSeverity: NotificationSeverity?
    public let icon: Icon?
    /// The bundle identifier of the app that posted it, or that the CLI pushing it ran in, whose icon the card
    /// shows; nil for URL pushes and notifications macOS posts itself.
    public let bundleIdentifier: String?
    /// The icon id a push named that the font does not have; the card notes it under the text.
    public let invalidIcon: String?
    public let action: ClickAction?
    /// macOS kept presenting the original notification because it needs interaction.
    public let shownByMacOS: Bool
    /// The hidden macOS alert this entry stands for, whose choices the card offers while it exists.
    public let nativeChoices: NativeChoices?
    /// The NotificationCenter notifications this entry stands for, newest first: their `AXIdentifier`s, which
    /// are also their UUIDs in the notification database. A click opens the newest one that still exists, as
    /// clicking it in macOS would, so the posting app learns which notification was clicked.
    public let nativeIdentifiers: [String]
    /// When the most recent copy arrived.
    public let receivedAt: Date
    /// How many identical notifications this entry stands for (see `SidebarModel.add(_:)`).
    public let occurrences: Int

    public init(
        id: UUID = UUID(),
        source: String,
        title: String,
        subtitle: String = "",
        body: String = "",
        severity: NotificationSeverity = .normal,
        postedSeverity: NotificationSeverity? = nil,
        icon: Icon? = nil,
        bundleIdentifier: String? = nil,
        invalidIcon: String? = nil,
        action: ClickAction? = nil,
        shownByMacOS: Bool = false,
        nativeChoices: NativeChoices? = nil,
        nativeIdentifiers: [String] = [],
        receivedAt: Date = Date(),
        occurrences: Int = 1
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.severity = severity
        self.postedSeverity = postedSeverity
        self.icon = icon
        self.bundleIdentifier = bundleIdentifier
        self.invalidIcon = invalidIcon
        self.action = action
        self.shownByMacOS = shownByMacOS
        self.nativeChoices = nativeChoices
        self.nativeIdentifiers = nativeIdentifiers
        self.receivedAt = receivedAt
        self.occurrences = occurrences
    }

    /// A pushed notification. An icon id that `icons` does not know is kept as `invalidIcon`; the sender's app,
    /// when it names one, provides the card's icon instead.
    public init(payload: NotificationPayload, source: String, icons: AppIconFont, receivedAt: Date = Date()) {
        let icon = payload.icon.flatMap(icons.icon(for:))
        let action: ClickAction? = switch payload.action {
        case nil: nil
        case .open(let url): .open(url)
        case .run(let command, let workingDirectory): .run(command: command, workingDirectory: workingDirectory)
        }
        self.init(
            source: source,
            title: payload.title,
            subtitle: payload.subtitle,
            body: payload.body,
            severity: payload.severity,
            icon: icon,
            bundleIdentifier: payload.bundleIdentifier,
            invalidIcon: icon == nil ? payload.icon : nil,
            action: action,
            receivedAt: receivedAt
        )
    }
}

extension SidebarNotification {
    /// Same sender and its app, text, severity, icon, click action and presentation as shown; only identity, time,
    /// count and the native notifications it stands for may differ. Two alerts with choices are never the same
    /// content: each card answers its own alert. A stack keeps the severity its first card arrived with
    /// (`postedSeverity`).
    func hasSameContent(as other: SidebarNotification) -> Bool {
        source == other.source && bundleIdentifier == other.bundleIdentifier && title == other.title
            && subtitle == other.subtitle && body == other.body
            && severity == other.severity && icon == other.icon && invalidIcon == other.invalidIcon
            && action == other.action && shownByMacOS == other.shownByMacOS && nativeChoices == other.nativeChoices
    }

    /// The most native notifications one entry stands for. A click opens the newest one NotificationCenter
    /// still has, so the oldest of an app that keeps repeating itself would only grow the saved lists without
    /// bound; they are released like those of a dismissed card, which closes them if they are still hidden.
    static let maxNativeIdentifiers = 20

    /// This entry with `newer` folded in: it keeps its identity, takes `newer`'s time, adds its count, and
    /// stands for `newer`'s native notifications too, newest first, up to `maxNativeIdentifiers`.
    func stacking(_ newer: SidebarNotification) -> SidebarNotification {
        SidebarNotification(
            id: id,
            source: source,
            title: title,
            subtitle: subtitle,
            body: body,
            severity: severity,
            postedSeverity: postedSeverity,
            icon: icon,
            bundleIdentifier: bundleIdentifier,
            invalidIcon: invalidIcon,
            action: action,
            shownByMacOS: shownByMacOS,
            nativeChoices: nativeChoices,
            nativeIdentifiers: Array((newer.nativeIdentifiers + nativeIdentifiers.filter { !newer.nativeIdentifiers.contains($0) })
                .prefix(Self.maxNativeIdentifiers)),
            receivedAt: max(receivedAt, newer.receivedAt),
            occurrences: occurrences + newer.occurrences
        )
    }

    /// The severity it arrived with, before any rule.
    var ownSeverity: NotificationSeverity { postedSeverity ?? severity }

    /// This entry with the severity a rule sets, remembering its own; with its own severity, as it arrived.
    func with(severity: NotificationSeverity) -> SidebarNotification {
        SidebarNotification(
            id: id,
            source: source,
            title: title,
            subtitle: subtitle,
            body: body,
            severity: severity,
            postedSeverity: severity == ownSeverity ? nil : ownSeverity,
            icon: icon,
            bundleIdentifier: bundleIdentifier,
            invalidIcon: invalidIcon,
            action: action,
            shownByMacOS: shownByMacOS,
            nativeChoices: nativeChoices,
            nativeIdentifiers: nativeIdentifiers,
            receivedAt: receivedAt,
            occurrences: occurrences
        )
    }

    /// What a click does, shown before it happens; includes the full command for `run` actions.
    public var clickDescription: String {
        switch action {
        case nil: "Click to dismiss"
        case .open(let url): "Click to open \(url.absoluteString)"
        case .run(let command, let directory): "Click to run in \(directory):\n\(command)"
        case .activateApp(let name) where nativeIdentifiers.isEmpty: "Click to switch to \(name)"
        case .activateApp(let name): "Click to open in \(name)"
        }
    }
}

/// Whether native macOS notification banners are being replaced.
public enum InterceptionStatus: Equatable, Sendable {
    case starting
    /// Turned off in settings.
    case disabled
    case active
    /// The app lacks the Accessibility permission needed to read and hide banners.
    case needsAccessibility
    /// The NotificationCenter process is not running or refused the observer.
    case notificationCenterUnavailable
}

/// Performs a notification's click action; `WorkspaceActionPerformer` is the real implementation.
@MainActor
public protocol NotificationActionPerforming {
    /// Performs `action` for a notification from the app with `bundleIdentifier` (the notification's own),
    /// which `activateApp` brings forward; the app's name in the action serves only without one.
    func perform(_ action: SidebarNotification.ClickAction, bundleIdentifier: String?)
}

/// What the sidebar can do to a macOS notification a card stands for, on screen, hidden or in the history.
public enum NativeAction: Equatable, Sendable {
    /// What clicking the notification does, such as opening its app.
    case open
    /// One of the alert's `NativeChoices.choices`, by title.
    case choice(String)
    /// Answers a choice that asks for text (`NativeChoice.textInput`) with `text`, sent with the field's send
    /// action `send` (`NativeChoice.TextInput.sendTitle`; empty when the app named none).
    case reply(choice: String, text: String, send: String)
}

/// Acts on the macOS notifications that cards stand for; `NotificationCenterMonitor` is the real implementation.
@MainActor
public protocol NativeNotificationControlling: AnyObject {
    /// Performs `action` on the first of the notifications, newest first, that NotificationCenter still has, on
    /// screen or in its history, as the same action on it in macOS would; `source` names the app that posted
    /// them. `completion` receives whether it was performed; it may run before this returns.
    func perform(_ action: NativeAction, on identifiers: [String], from source: String, completion: @escaping @MainActor (Bool) -> Void)
    /// The list dropped cards for hidden notifications; those that are still hidden are closed.
    func notificationsReleased()
}

/// Persists the notification list between launches.
@MainActor
public protocol NotificationStore {
    func load() -> [SidebarNotification]
    func save(_ notifications: [SidebarNotification])
}

/// State rendered by the sidebar. Every change is saved to the store, and notifications beyond the
/// history limits are dropped, so a relaunch restores the list as it was.
@MainActor
@Observable
public final class SidebarModel {
    /// Most severe first, newest first within a severity.
    public private(set) var notifications: [SidebarNotification] = []
    /// Every notification as it arrived, before any rule, newest first, also after its card was dismissed or a
    /// rule hid it: what Settings › Rules tests rules against. Repeats stack, and the history limits apply.
    public private(set) var received: [SidebarNotification] = []
    public var interception: InterceptionStatus = .starting
    /// Whether notifications that showed no banner are listed from the notification database.
    public var database: NotificationDatabaseStatus = .stopped
    /// Whether the user dismissed the sidebar's note asking for Full Disk Access; Settings › Permissions
    /// still offers it.
    public private(set) var fullDiskAccessNoteDismissed: Bool
    /// Identifiers of the macOS notifications with choices that still exist, hidden or in the history; only
    /// their cards offer choices.
    public var presentChoices: Set<String> = []
    /// Cards one of whose choices is being performed, which can take a moment in the history; their other
    /// choices wait for it.
    public private(set) var answering: Set<SidebarNotification.ID> = []
    /// Opens native notifications, performs alert choices and closes hidden notifications whose cards are gone;
    /// set once interception is wired up.
    @ObservationIgnored public weak var nativeNotifications: (any NativeNotificationControlling)?
    /// Whether an app, by bundle identifier, has its notifications switched off in System Settings. macOS then
    /// keeps them out of NotificationCenter, so its cards can only bring the app forward.
    @ObservationIgnored public var notificationsAreOff: @MainActor (String) -> Bool = { _ in false }

    @ObservationIgnored private let performer: any NotificationActionPerforming
    @ObservationIgnored private let store: any NotificationStore
    /// Where `received` is kept; without one it lasts until the app quits.
    @ObservationIgnored private let receivedStore: (any NotificationStore)?
    /// Where choices such as `fullDiskAccessNoteDismissed` are kept; without one they last until the app quits.
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let now: () -> Date
    /// How long and how many notifications are kept.
    @ObservationIgnored public private(set) var history: SidebarSettings.History
    /// Change or hide notifications as they arrive.
    @ObservationIgnored private var rules: NotificationRules
    /// The native notifications listed after the last change, to tell when a change drops one.
    @ObservationIgnored private var listedNotifications: Set<String> = []

    public init(
        performer: any NotificationActionPerforming = WorkspaceActionPerformer(),
        store: any NotificationStore,
        receivedStore: (any NotificationStore)? = nil,
        defaults: UserDefaults? = nil,
        history: SidebarSettings.History = SidebarSettings.History(),
        rules: [SidebarSettings.Rule] = [],
        now: @escaping () -> Date = Date.init
    ) {
        self.performer = performer
        self.store = store
        self.receivedStore = receivedStore
        self.defaults = defaults
        fullDiskAccessNoteDismissed = defaults?.bool(forKey: Self.fullDiskAccessNoteDismissedKey) ?? false
        self.history = history
        self.rules = NotificationRules(rules)
        self.now = now
        let cutoff = now().addingTimeInterval(-history.retention)
        notifications = Array(store.load()
            .filter { $0.receivedAt >= cutoff }
            .sorted { ($0.severity, $0.receivedAt) > ($1.severity, $1.receivedAt) }
            .prefix(history.maxCount))
        received = Array((receivedStore?.load() ?? [])
            .filter { $0.receivedAt >= cutoff }
            .sorted { $0.receivedAt > $1.receivedAt }
            .prefix(history.maxCount))
        listedNotifications = Self.nativeIdentifiers(in: notifications)
    }

    static let fullDiskAccessNoteDismissedKey = "fullDiskAccessNoteDismissed"

    /// Stops asking for Full Disk Access in the sidebar, also after a relaunch.
    public func dismissFullDiskAccessNote() {
        fullDiskAccessNoteDismissed = true
        defaults?.set(true, forKey: Self.fullDiskAccessNoteDismissedKey)
    }

    /// Applies new history limits, dropping notifications they no longer allow.
    public func apply(history: SidebarSettings.History) {
        self.history = history
        pruneExpired()
        if notifications.count > history.maxCount {
            notifications.removeLast(notifications.count - history.maxCount)
            didChange()
        }
        if received.count > history.maxCount {
            received.removeLast(received.count - history.maxCount)
            receivedStore?.save(received)
        }
    }

    /// Applies new rules to arriving notifications and to the listed ones, which start over from the
    /// severity they arrived with: a card the rules now hide goes, the others move to their new severity
    /// and stack with cards that now have the same content, as if they had just arrived.
    public func apply(rules: [SidebarSettings.Rule]) {
        self.rules = NotificationRules(rules)
        let listed = notifications
        notifications = []
        for notification in listed.sorted(by: { $0.receivedAt < $1.receivedAt }) {
            insert(notification.with(severity: notification.ownSeverity))
        }
        if notifications != listed {
            didChange()
        }
    }

    /// Inserts the notification by severity, then recency, after the first matching rule has changed its
    /// severity or hidden it. A notification with the same content as a listed one is stacked onto it
    /// instead: the entry counts both and moves up as the newest. Beyond `history.maxCount`, the least
    /// severe and oldest entries are dropped.
    ///
    /// A notification older than `history.retention`, such as one the notification database lists after a
    /// relaunch, is not added at all: the next prune would drop it, after it had pushed newer notifications
    /// past `history.maxCount`.
    public func add(_ notification: SidebarNotification) {
        guard notification.receivedAt >= now().addingTimeInterval(-history.retention) else { return }
        record(notification)
        guard insert(notification) else { return }
        didChange()
    }

    /// Adds an arriving notification to `received`, as the newest, stacked onto a copy with the same content.
    private func record(_ notification: SidebarNotification) {
        var notification = notification
        if let existing = received.firstIndex(where: { $0.hasSameContent(as: notification) }) {
            notification = received.remove(at: existing).stacking(notification)
        }
        // Newest first by arrival: the database lists a notification seconds after a newer banner may have.
        let index = received.firstIndex { $0.receivedAt <= notification.receivedAt } ?? received.endIndex
        received.insert(notification, at: index)
        if received.count > history.maxCount {
            received.removeLast(received.count - history.maxCount)
        }
        receivedStore?.save(received)
    }

    /// `add(_:)` without saving; false when a rule hides the notification.
    @discardableResult
    private func insert(_ notification: SidebarNotification) -> Bool {
        guard var notification = rules.apply(to: notification) else { return false }
        if let existing = notifications.firstIndex(where: { $0.hasSameContent(as: notification) }) {
            notification = notifications.remove(at: existing).stacking(notification)
        }
        let index = notifications.firstIndex {
            ($0.severity, $0.receivedAt) <= (notification.severity, notification.receivedAt)
        } ?? notifications.endIndex
        notifications.insert(notification, at: index)
        if notifications.count > history.maxCount {
            notifications.removeLast(notifications.count - history.maxCount)
        }
        return true
    }

    public func dismiss(_ id: SidebarNotification.ID) {
        notifications.removeAll { $0.id == id }
        didChange()
    }

    public func clear() {
        notifications.removeAll()
        didChange()
    }

    /// Drops notifications older than `history.retention`, listed and received alike.
    public func pruneExpired() {
        let cutoff = now().addingTimeInterval(-history.retention)
        if received.contains(where: { $0.receivedAt < cutoff }) {
            received.removeAll { $0.receivedAt < cutoff }
            receivedStore?.save(received)
        }
        guard notifications.contains(where: { $0.receivedAt < cutoff }) else { return }
        notifications.removeAll { $0.receivedAt < cutoff }
        didChange()
    }

    /// Runs the notification's click action, then dismisses it. A card that stands for native notifications
    /// opens the newest one NotificationCenter still has, as clicking it in macOS would, which tells the posting
    /// app which notification it was (a browser then shows the page that posted it); the card's own action
    /// runs only when none can be opened, and at once for an app whose notifications are switched off, which
    /// NotificationCenter never holds.
    public func activate(_ id: SidebarNotification.ID) {
        guard let notification = notifications.first(where: { $0.id == id }) else { return }
        let action = notification.action
        let bundleIdentifier = notification.bundleIdentifier
        let performer = performer
        if let nativeNotifications, canOpen(notification) {
            nativeNotifications.perform(.open, on: notification.nativeIdentifiers, from: notification.source) { opened in
                if !opened, let action {
                    performer.perform(action, bundleIdentifier: bundleIdentifier)
                }
            }
        } else if let action {
            performer.perform(action, bundleIdentifier: bundleIdentifier)
        }
        dismiss(id)
    }

    /// What clicking the notification's card does, shown before it happens.
    public func clickDescription(of notification: SidebarNotification) -> String {
        guard case .activateApp(let name) = notification.action, !notification.nativeIdentifiers.isEmpty, !canOpen(notification) else {
            return notification.clickDescription
        }
        return "Click to switch to \(name)\nIts notifications are off in System Settings, so this one cannot open"
    }

    /// Whether the card stands for a native notification that NotificationCenter may still hold.
    private func canOpen(_ notification: SidebarNotification) -> Bool {
        guard !notification.nativeIdentifiers.isEmpty else { return false }
        return !(notification.bundleIdentifier.map(notificationsAreOff) ?? false)
    }

    /// Opens a link from a notification's text. The card stays: the link is part of what it says, not
    /// the notification's action.
    public func openLink(_ url: URL) {
        performer.perform(.open(url), bundleIdentifier: nil)
    }

    /// Performs one of the notification's choices, then dismisses the card. The card stays when the notification
    /// is gone or refuses the choice.
    public func choose(_ choice: String, for id: SidebarNotification.ID) {
        answer(id) { alert in
            alert.choices.contains { $0.title == choice && $0.textInput == nil } ? .choice(choice) : nil
        }
    }

    /// Answers a choice that asks for text, such as Reply, with `text`, then dismisses the card. The card stays
    /// when the notification is gone or refuses the reply.
    public func reply(_ choice: String, text: String, for id: SidebarNotification.ID) {
        answer(id) { alert in
            guard !text.isEmpty, let input = alert.choices.first(where: { $0.title == choice })?.textInput else { return nil }
            return .reply(choice: choice, text: text, send: input.sendTitle)
        }
    }

    /// Performs what `action` makes of the card's notification, one answer at a time per card
    /// (`answering`), and dismisses the card once it was performed.
    private func answer(_ id: SidebarNotification.ID, _ action: (SidebarNotification.NativeChoices) -> NativeAction?) {
        guard !answering.contains(id), let nativeNotifications,
              let notification = notifications.first(where: { $0.id == id }),
              let alert = offeredChoices(of: notification), let action = action(alert)
        else { return }
        answering.insert(id)
        nativeNotifications.perform(action, on: [alert.identifier], from: notification.source) { [weak self] performed in
            self?.answering.remove(id)
            if performed { self?.dismiss(id) }
        }
    }

    /// The notification's alert while it still exists in NotificationCenter.
    public func offeredChoices(of notification: SidebarNotification) -> SidebarNotification.NativeChoices? {
        notification.nativeChoices.flatMap { presentChoices.contains($0.identifier) ? $0 : nil }
    }

    /// Whether a card stands for the native notification with `identifier`.
    public func lists(notification identifier: String) -> Bool {
        listedNotifications.contains(identifier)
    }

    /// Whether a card offers the choices of the native alert with `identifier`. A card the notification
    /// database listed, or one listing the alert as shown by macOS, stands for it without them.
    public func lists(choicesOf identifier: String) -> Bool {
        notifications.contains { $0.nativeChoices?.identifier == identifier }
    }

    /// Saves the list and reports native notifications whose cards it no longer holds, so they do not stay
    /// hidden.
    private func didChange() {
        store.save(notifications)
        let listed = Self.nativeIdentifiers(in: notifications)
        let released = !listedNotifications.isSubset(of: listed)
        listedNotifications = listed
        if released {
            nativeNotifications?.notificationsReleased()
        }
    }

    private static func nativeIdentifiers(in notifications: [SidebarNotification]) -> Set<String> {
        Set(notifications.flatMap(\.nativeIdentifiers))
    }
}
