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

    /// A macOS notification whose card offers its choices, kept hidden while NotificationCenter shows it: an
    /// alert's named actions (`NotificationBanners.choices(of:labels:)`), the actions any notification's app
    /// declared (`SystemNotificationInterceptor`), or those its record in the notification database names
    /// (`NotificationDatabaseMonitor`).
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
    /// The body is markdown (`NotificationPayload.markdown`); only pushes set it.
    public let markdown: Bool
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
    /// The macOS notification this entry stands for, whose choices the card offers (`SidebarModel.offeredChoices(of:)`).
    public let nativeChoices: NativeChoices?
    /// Buttons a push put on the card besides its click action (`SidebarModel.cardChoices(of:)`).
    public let pushedChoices: [PushedChoice]
    /// The key a push named (`NotificationPayload.key`): a later push from the same source with the same key
    /// replaces this entry's content and stacks onto it (`stacks(with:)`).
    public let key: String?
    /// The NotificationCenter notifications this entry stands for, newest first: their `AXIdentifier`s, which
    /// are also their UUIDs in the notification database. A click opens the newest one that still exists, as
    /// clicking it in macOS would, so the posting app learns which notification was clicked.
    public let nativeIdentifiers: [String]
    /// When the most recent copy arrived.
    public let receivedAt: Date
    /// How many identical notifications, or pushes with its key, this entry stands for (see `SidebarModel.add(_:)`).
    public let occurrences: Int

    /// Reads a saved entry. An entry without pushed choices, a markdown body or a key may leave out their keys, like
    /// `nativeChoices`: every entry in a list saved before cards carried them does, and none of those has either.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            source: try container.decode(String.self, forKey: .source),
            title: try container.decode(String.self, forKey: .title),
            subtitle: try container.decode(String.self, forKey: .subtitle),
            body: try container.decode(String.self, forKey: .body),
            markdown: try container.decodeIfPresent(Bool.self, forKey: .markdown) ?? false,
            severity: try container.decode(NotificationSeverity.self, forKey: .severity),
            postedSeverity: try container.decodeIfPresent(NotificationSeverity.self, forKey: .postedSeverity),
            icon: try container.decodeIfPresent(Icon.self, forKey: .icon),
            bundleIdentifier: try container.decodeIfPresent(String.self, forKey: .bundleIdentifier),
            invalidIcon: try container.decodeIfPresent(String.self, forKey: .invalidIcon),
            action: try container.decodeIfPresent(ClickAction.self, forKey: .action),
            shownByMacOS: try container.decode(Bool.self, forKey: .shownByMacOS),
            nativeChoices: try container.decodeIfPresent(NativeChoices.self, forKey: .nativeChoices),
            pushedChoices: try container.decodeIfPresent([PushedChoice].self, forKey: .pushedChoices) ?? [],
            key: try container.decodeIfPresent(String.self, forKey: .key),
            nativeIdentifiers: try container.decode([String].self, forKey: .nativeIdentifiers),
            receivedAt: try container.decode(Date.self, forKey: .receivedAt),
            occurrences: try container.decode(Int.self, forKey: .occurrences)
        )
    }

    public init(
        id: UUID = UUID(),
        source: String,
        title: String,
        subtitle: String = "",
        body: String = "",
        markdown: Bool = false,
        severity: NotificationSeverity = .normal,
        postedSeverity: NotificationSeverity? = nil,
        icon: Icon? = nil,
        bundleIdentifier: String? = nil,
        invalidIcon: String? = nil,
        action: ClickAction? = nil,
        shownByMacOS: Bool = false,
        nativeChoices: NativeChoices? = nil,
        pushedChoices: [PushedChoice] = [],
        key: String? = nil,
        nativeIdentifiers: [String] = [],
        receivedAt: Date = Date(),
        occurrences: Int = 1
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.markdown = markdown
        self.severity = severity
        self.postedSeverity = postedSeverity
        self.icon = icon
        self.bundleIdentifier = bundleIdentifier
        self.invalidIcon = invalidIcon
        self.action = action
        self.shownByMacOS = shownByMacOS
        self.nativeChoices = nativeChoices
        self.pushedChoices = pushedChoices
        self.key = key
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
            markdown: payload.markdown,
            severity: payload.severity,
            icon: icon,
            bundleIdentifier: payload.bundleIdentifier,
            invalidIcon: icon == nil ? payload.icon : nil,
            action: action,
            pushedChoices: payload.choices,
            key: payload.key,
            receivedAt: receivedAt
        )
    }
}

extension SidebarNotification {
    /// Same sender and its app, text, severity, icon, click action, choices and presentation as shown; only
    /// identity, time, count and the native notifications it stands for may differ. Two alerts with choices are
    /// never the same content: each card answers its own alert. Neither are two asks: each card answers its own
    /// asker. A stack keeps the severity its first card arrived with (`postedSeverity`).
    func hasSameContent(as other: SidebarNotification) -> Bool {
        source == other.source && bundleIdentifier == other.bundleIdentifier && title == other.title
            && subtitle == other.subtitle && body == other.body && markdown == other.markdown
            && severity == other.severity && icon == other.icon && invalidIcon == other.invalidIcon
            && action == other.action && shownByMacOS == other.shownByMacOS && nativeChoices == other.nativeChoices
            && pushedChoices == other.pushedChoices && !asks && !other.asks
    }

    /// Whether `other` stacks onto this entry, or this one onto it: two pushes from one source with the same key,
    /// whatever their content, or two entries without a key and with the same content. Asks never stack: each card
    /// answers its own asker.
    func stacks(with other: SidebarNotification) -> Bool {
        guard key == other.key else { return false }
        guard key != nil else { return hasSameContent(as: other) }
        return source == other.source && !asks && !other.asks
    }

    /// Whether a choice answers the `notification ask` command waiting for the card.
    var asks: Bool { pushedChoices.contains { $0.action == .answer } }

    /// This entry without the choices that answer an ask, whose asker a relaunch lost.
    var withoutAnswers: SidebarNotification {
        guard asks else { return self }
        return SidebarNotification(
            id: id,
            source: source,
            title: title,
            subtitle: subtitle,
            body: body,
            markdown: markdown,
            severity: severity,
            postedSeverity: postedSeverity,
            icon: icon,
            bundleIdentifier: bundleIdentifier,
            invalidIcon: invalidIcon,
            action: action,
            shownByMacOS: shownByMacOS,
            nativeChoices: nativeChoices,
            pushedChoices: pushedChoices.filter { $0.action != .answer },
            key: key,
            nativeIdentifiers: nativeIdentifiers,
            receivedAt: receivedAt,
            occurrences: occurrences
        )
    }

    /// The most native notifications one entry stands for. A click opens the newest one NotificationCenter
    /// still has, so the oldest of an app that keeps repeating itself would only grow the saved lists without
    /// bound; they are released like those of a dismissed card, which closes them if they are still hidden.
    static let maxNativeIdentifiers = 20

    /// This entry with `newer` folded in: it keeps its identity, takes `newer`'s time, adds its count, and
    /// stands for `newer`'s native notifications too, newest first, up to `maxNativeIdentifiers`. A keyed entry
    /// also takes `newer`'s content, which may differ from its own.
    func stacking(_ newer: SidebarNotification) -> SidebarNotification {
        let content = key == nil ? self : newer
        return SidebarNotification(
            id: id,
            source: content.source,
            title: content.title,
            subtitle: content.subtitle,
            body: content.body,
            markdown: content.markdown,
            severity: content.severity,
            postedSeverity: content.postedSeverity,
            icon: content.icon,
            bundleIdentifier: content.bundleIdentifier,
            invalidIcon: content.invalidIcon,
            action: content.action,
            shownByMacOS: content.shownByMacOS,
            nativeChoices: content.nativeChoices,
            pushedChoices: content.pushedChoices,
            key: key,
            nativeIdentifiers: Array((newer.nativeIdentifiers + nativeIdentifiers.filter { !newer.nativeIdentifiers.contains($0) })
                .prefix(Self.maxNativeIdentifiers)),
            receivedAt: max(receivedAt, newer.receivedAt),
            occurrences: occurrences + newer.occurrences
        )
    }

    /// The severity it arrived with, before any rule.
    var ownSeverity: NotificationSeverity { postedSeverity ?? severity }

    /// This entry offering `nativeChoices`, so no longer shown by macOS for its buttons.
    func offering(_ nativeChoices: NativeChoices) -> SidebarNotification {
        SidebarNotification(
            id: id,
            source: source,
            title: title,
            subtitle: subtitle,
            body: body,
            markdown: markdown,
            severity: severity,
            postedSeverity: postedSeverity,
            icon: icon,
            bundleIdentifier: bundleIdentifier,
            invalidIcon: invalidIcon,
            action: action,
            shownByMacOS: false,
            nativeChoices: nativeChoices,
            pushedChoices: pushedChoices,
            key: key,
            nativeIdentifiers: nativeIdentifiers,
            receivedAt: receivedAt,
            occurrences: occurrences
        )
    }

    /// This entry with the severity a rule sets, remembering its own; with its own severity, as it arrived.
    func with(severity: NotificationSeverity) -> SidebarNotification {
        SidebarNotification(
            id: id,
            source: source,
            title: title,
            subtitle: subtitle,
            body: body,
            markdown: markdown,
            severity: severity,
            postedSeverity: severity == ownSeverity ? nil : ownSeverity,
            icon: icon,
            bundleIdentifier: bundleIdentifier,
            invalidIcon: invalidIcon,
            action: action,
            shownByMacOS: shownByMacOS,
            nativeChoices: nativeChoices,
            pushedChoices: pushedChoices,
            key: key,
            nativeIdentifiers: nativeIdentifiers,
            receivedAt: receivedAt,
            occurrences: occurrences
        )
    }

    /// What a click does, shown before it happens, then what each pushed choice does; includes the full command
    /// for `run` actions and choices.
    public var clickDescription: String {
        let click = switch action {
        case nil where asks: "Click to dismiss without answering"
        case nil: "Click to dismiss"
        case .open(let url): "Click to open \(url.absoluteString)"
        case .run(let command, let directory): "Click to run in \(directory):\n\(command)"
        case .activateApp(let name) where nativeIdentifiers.isEmpty: "Click to switch to \(name)"
        case .activateApp(let name): "Click to open in \(name)"
        }
        return ([click] + pushedChoices.compactMap(\.description)).joined(separator: "\n")
    }
}

extension PushedChoice {
    /// What the choice's button does, for a card's help; nil for a choice that only answers an ask, whose
    /// button says it all.
    var description: String? {
        switch action {
        case .run(let command, let directory) where asksForText: "\(title) asks for text, then runs in \(directory):\n\(command)"
        case .run(let command, let directory): "\(title) runs in \(directory):\n\(command)"
        case .open(let url): "\(title) opens \(url.absoluteString)"
        case .answer: nil
        }
    }

    /// The choice as the card shows it: a choice that asks for text opens a field whose placeholder is its title
    /// and whose send button reads Send.
    var shown: NativeChoice {
        NativeChoice(title: title, textInput: asksForText ? NativeChoice.TextInput(sendTitle: "Send") : nil)
    }
}

/// Whether native macOS notification banners are being replaced.
public enum InterceptionStatus: Equatable, Sendable {
    case starting
    /// Turned off in settings.
    case disabled
    case active
    /// Stopped until it starts again, as while Settings removes the Accessibility permission; nothing could
    /// perform a card's choices meanwhile.
    case stopped
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
    /// Runs a pushed choice's `command` with the user's login shell in `workingDirectory`, with `environment`
    /// added to the sidebar's own.
    func run(_ command: String, in workingDirectory: String, environment: [String: String])
}

/// The client waiting for the answer to an asked notification; `AskConnection` is the real implementation.
public protocol NotificationAsking: AnyObject, Sendable {
    /// Sends the answer; only the first one counts.
    func answer(_ answer: AskAnswer)
    /// Calls `handler` on the main actor once the client stops waiting before an answer.
    func onHangUp(_ handler: @escaping @MainActor @Sendable () -> Void)
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
    /// The notifications that arrived and were listed, whose cards the sidebar scrolls into view. Only `add(_:)`
    /// changes it, and only for a notification that no rule hides and the history limits keep, so restoring the
    /// list at launch, applying rules, pruning and dismissals scroll nothing.
    public private(set) var arrivals = Arrivals()
    public var interception: InterceptionStatus = .starting
    /// Whether notifications that showed no banner are listed from the notification database.
    public var database: NotificationDatabaseStatus = .stopped
    /// Whether the user dismissed the sidebar's note asking for Full Disk Access; Settings › Permissions
    /// still offers it.
    public private(set) var fullDiskAccessNoteDismissed: Bool
    /// Identifiers of the macOS notifications whose cards list their choices although the notifications are
    /// known not to offer them any more (`SystemNotificationInterceptor`); those cards offer none. It is not
    /// saved: after a relaunch every card offers its choices until performing one finds its notification gone.
    public var unavailableChoices: Set<String> = []
    /// Cards one of whose choices is being performed, which can take a moment in the history; their other
    /// choices wait for it.
    public private(set) var answering: Set<SidebarNotification.ID> = []
    /// Opens native notifications, performs alert choices and closes hidden notifications whose cards are gone;
    /// set once interception is wired up.
    @ObservationIgnored public weak var nativeNotifications: (any NativeNotificationControlling)?
    /// Whether an app, by bundle identifier, has its notifications switched off in System Settings. macOS then
    /// keeps them out of NotificationCenter, so its cards can only bring the app forward.
    @ObservationIgnored public var notificationsAreOff: @MainActor (String) -> Bool = { _ in false }
    /// Switches on the notifications of an app, by bundle identifier and the name its notifications show, in
    /// System Settings (`AppNotificationsModel.switchOn(bundleIdentifier:name:)`), and returns what is left to
    /// the user when the switch did not move.
    @ObservationIgnored public var allowAppNotifications: @MainActor (_ bundleIdentifier: String, _ name: String) async -> String? = { _, _ in nil }
    /// The app, by bundle identifier, whose notifications a card is switching on; the others wait for it.
    public private(set) var allowingAppNotifications: String?
    /// What is left to the user after a card could not switch its app's notifications on, shown until dismissed.
    public private(set) var appNotificationsProblem: String?

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
    /// Whether notifications from apps whose notifications are switched off (`notificationsAreOff`) are listed.
    /// macOS never shows them; while this is off they are only recorded in `received`, which Settings ›
    /// Notifications lists the apps from.
    @ObservationIgnored public private(set) var listsSwitchedOffApps: Bool
    /// The native notifications listed after the last change, to tell when a change drops one.
    @ObservationIgnored private var listedNotifications: Set<String> = []
    /// Cards on which the user is typing a reply. Nothing stacks onto them, nor they onto another card: a stack
    /// gets a new card (`SidebarView`), which would drop the open field and its text.
    @ObservationIgnored private var composing: Set<SidebarNotification.ID> = []
    /// The clients waiting for the answers to asked notifications, by card. A card that goes without an answer
    /// answers `dismissed` (`settleAsks()`).
    @ObservationIgnored private var askers: [SidebarNotification.ID: any NotificationAsking] = [:]

    public init(
        performer: any NotificationActionPerforming = WorkspaceActionPerformer(),
        store: any NotificationStore,
        receivedStore: (any NotificationStore)? = nil,
        defaults: UserDefaults? = nil,
        history: SidebarSettings.History = SidebarSettings.History(),
        rules: [SidebarSettings.Rule] = [],
        listsSwitchedOffApps: Bool = false,
        now: @escaping () -> Date = Date.init
    ) {
        self.performer = performer
        self.store = store
        self.receivedStore = receivedStore
        self.defaults = defaults
        fullDiskAccessNoteDismissed = defaults?.bool(forKey: Self.fullDiskAccessNoteDismissedKey) ?? false
        self.history = history
        self.rules = NotificationRules(rules)
        self.listsSwitchedOffApps = listsSwitchedOffApps
        self.now = now
        let cutoff = now().addingTimeInterval(-history.retention)
        // A relaunch lost the clients waiting for asks, so their cards no longer offer the choices that answer them.
        notifications = Array(store.load()
            .map(\.withoutAnswers)
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

    /// Lists notifications from apps whose notifications are switched off as they arrive, or stops listing them
    /// and drops the listed cards of apps that are switched off now.
    public func apply(listsSwitchedOffApps: Bool) {
        self.listsSwitchedOffApps = listsSwitchedOffApps
        guard !listsSwitchedOffApps, notifications.contains(where: appNotificationsAreOff) else { return }
        notifications.removeAll(where: appNotificationsAreOff)
        didChange()
    }

    /// Inserts the notification by severity, then recency, after the first matching rule has changed its
    /// severity or hidden it. A notification with the same content as a listed one, or a push with the key of a
    /// listed push from its source, is stacked onto it instead: the entry counts both, shows the newer content
    /// for a key, and moves up as the newest. A rule that hides a keyed push leaves the listed card as it was. Beyond `history.maxCount`, the least
    /// severe and oldest entries are dropped.
    ///
    /// A notification older than `history.retention`, such as one the notification database lists after a
    /// relaunch, is not added at all: the next prune would drop it, after it had pushed newer notifications
    /// past `history.maxCount`. One from an app whose notifications are switched off is only recorded in
    /// `received` unless `listsSwitchedOffApps`.
    public func add(_ notification: SidebarNotification) {
        guard notification.receivedAt >= now().addingTimeInterval(-history.retention) else { return settleAsks() }
        record(notification)
        guard let card = insert(notification) else { return settleAsks() }
        arrivals.record(card, listed: notifications)
        didChange()
    }

    /// Adds a notification whose choices answer `asker`, like `add(_:)`. Its card goes once it is answered;
    /// when it goes without an answer, or never shows because a rule hides it, `asker` gets `dismissed`; when
    /// `asker` stops waiting first, the card goes.
    public func ask(_ notification: SidebarNotification, asker: any NotificationAsking) {
        let id = notification.id
        askers[id] = asker
        asker.onHangUp { [weak self] in self?.withdraw(id) }
        add(notification)
    }

    /// Removes the card of an ask whose client stopped waiting, without answering it.
    private func withdraw(_ id: SidebarNotification.ID) {
        guard askers.removeValue(forKey: id) != nil, notifications.contains(where: { $0.id == id }) else { return }
        dismiss(id)
    }

    /// Answers `dismissed` to every asker whose card is gone.
    private func settleAsks() {
        let listed = Set(notifications.map(\.id))
        for (id, asker) in askers where !listed.contains(id) {
            askers[id] = nil
            asker.answer(.dismissed)
        }
    }

    /// Adds an arriving notification to `received`, as the newest, stacked onto a copy with the same content, or
    /// with the same key, whose entry then holds the newest push's content.
    private func record(_ notification: SidebarNotification) {
        var notification = notification
        if let existing = received.firstIndex(where: { $0.stacks(with: notification) }) {
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

    /// `add(_:)` without saving: the card the notification was listed on, which the history limits may have
    /// dropped at once; nil when a rule hides the notification or its app's notifications are switched off
    /// while `listsSwitchedOffApps` is off.
    @discardableResult
    private func insert(_ notification: SidebarNotification) -> SidebarNotification.ID? {
        guard listsSwitchedOffApps || !appNotificationsAreOff(for: notification),
              var notification = rules.apply(to: notification)
        else { return nil }
        if !composing.contains(notification.id), let existing = notifications.firstIndex(where: {
            $0.stacks(with: notification) && !composing.contains($0.id)
        }) {
            notification = notifications.remove(at: existing).stacking(notification)
        }
        let index = notifications.firstIndex {
            ($0.severity, $0.receivedAt) <= (notification.severity, notification.receivedAt)
        } ?? notifications.endIndex
        notifications.insert(notification, at: index)
        if notifications.count > history.maxCount {
            notifications.removeLast(notifications.count - history.maxCount)
        }
        return notification.id
    }

    /// Tells whether the user is typing a reply on the card, which keeps it from stacking (`composing`).
    public func setComposing(_ isComposing: Bool, on id: SidebarNotification.ID) {
        if isComposing {
            composing.insert(id)
        } else {
            composing.remove(id)
        }
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
        if let nativeNotifications, !notification.nativeIdentifiers.isEmpty, !appNotificationsAreOff(for: notification) {
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
        guard case .activateApp(let name) = notification.action, appNotificationsAreOff(for: notification) else {
            return notification.clickDescription
        }
        return "Click to switch to \(name)\nIts notifications are off in System Settings, so this one cannot open"
    }

    /// Switches on the notifications of the app the card's notification came from, while they are off and no
    /// other app's are being switched on. Its cards can then open their notifications.
    public func allowAppNotifications(for id: SidebarNotification.ID) {
        guard allowingAppNotifications == nil, let notification = notifications.first(where: { $0.id == id }),
              let bundleIdentifier = notification.bundleIdentifier, appNotificationsAreOff(for: notification)
        else { return }
        allowingAppNotifications = bundleIdentifier
        appNotificationsProblem = nil
        Task {
            appNotificationsProblem = await allowAppNotifications(bundleIdentifier, notification.source)
            allowingAppNotifications = nil
        }
    }

    public func dismissAppNotificationsProblem() {
        appNotificationsProblem = nil
    }

    /// Whether the card stands for a macOS notification from an app whose notifications are switched off, which
    /// NotificationCenter keeps out of sight: the card can neither open it nor perform its choices.
    public func appNotificationsAreOff(for notification: SidebarNotification) -> Bool {
        guard !notification.nativeIdentifiers.isEmpty else { return false }
        return notification.bundleIdentifier.map(notificationsAreOff) ?? false
    }

    /// Opens a link from a notification's text. The card stays: the link is part of what it says, not
    /// the notification's action.
    public func openLink(_ url: URL) {
        performer.perform(.open(url), bundleIdentifier: nil)
    }

    /// Performs one of the notification's choices, then dismisses the card. The card stays when the notification
    /// is gone or refuses the choice.
    public func choose(_ choice: String, for id: SidebarNotification.ID) {
        if let pushed = pushedChoice(choice, of: id), !pushed.asksForText {
            return perform(pushed, reply: nil, for: id)
        }
        answer(id) { alert in
            alert.choices.contains { $0.title == choice && $0.textInput == nil } ? .choice(choice) : nil
        }
    }

    /// Answers a choice that asks for text, such as Reply, with `text`, then dismisses the card. The card stays
    /// when the notification is gone or refuses the reply.
    public func reply(_ choice: String, text: String, for id: SidebarNotification.ID) {
        if let pushed = pushedChoice(choice, of: id) {
            guard pushed.asksForText, !text.isEmpty, PushedChoice.fits(reply: text) else { return }
            return perform(pushed, reply: text, for: id)
        }
        answer(id) { alert in
            guard !text.isEmpty, let input = alert.choices.first(where: { $0.title == choice })?.textInput else { return nil }
            return .reply(choice: choice, text: text, send: input.sendTitle)
        }
    }

    /// The pushed choice titled `title` on the card. Pushed choices are performed at once, so a card never waits
    /// for one (`answering`).
    private func pushedChoice(_ title: String, of id: SidebarNotification.ID) -> PushedChoice? {
        notifications.first { $0.id == id }?.pushedChoices.first { $0.title == title }
    }

    /// Performs a pushed choice, with `reply` for one that asks for text, then dismisses the card: runs its
    /// command with the choice (and the reply) in its environment, opens its link, or answers the asker.
    private func perform(_ choice: PushedChoice, reply: String?, for id: SidebarNotification.ID) {
        switch choice.action {
        case .run(let command, let workingDirectory):
            var environment = [PushedChoice.choiceVariable: choice.title]
            environment[PushedChoice.replyVariable] = reply
            performer.run(command, in: workingDirectory, environment: environment)
        case .open(let url):
            performer.perform(.open(url), bundleIdentifier: nil)
        case .answer:
            askers.removeValue(forKey: id)?.answer(.answered(choice: choice.title, reply: reply))
        }
        dismiss(id)
    }

    /// The choices the card shows: those of the macOS notification it stands for (`offeredChoices(of:)`), else
    /// those pushed with it.
    public func cardChoices(of notification: SidebarNotification) -> [NativeChoice] {
        offeredChoices(of: notification)?.choices ?? notification.pushedChoices.map(\.shown)
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

    /// The choices the card offers: those of the macOS notification it stands for, while notifications are
    /// intercepted, its app's notifications are on (NotificationCenter keeps none of a switched-off app's to act
    /// on), and the notification is not known to have lost them (`unavailableChoices`).
    public func offeredChoices(of notification: SidebarNotification) -> SidebarNotification.NativeChoices? {
        guard interception == .active, let choices = notification.nativeChoices, !unavailableChoices.contains(choices.identifier),
              !appNotificationsAreOff(for: notification)
        else { return nil }
        return choices
    }

    /// Whether the card lists choices its macOS notification is known not to offer any more (`unavailableChoices`),
    /// so it shows none: the notification left NotificationCenter, returned to macOS for a control only macOS
    /// presents, or its history entry is gone. Its app being switched off is told apart by its badge.
    public func hasLostChoices(_ notification: SidebarNotification) -> Bool {
        guard let choices = notification.nativeChoices, !appNotificationsAreOff(for: notification) else { return false }
        return unavailableChoices.contains(choices.identifier)
    }

    /// Lets the card that stands for the native notification with `identifier` alone, and lists it without its
    /// choices, offer `choices`, which the notification database named after the card was listed: an
    /// NSUserNotification's actions menu, which NotificationCenter shows with its header as one more choice, or
    /// a category its app declared under the same titles as another. The card keeps its place and identity, and
    /// no longer counts as shown by macOS: the next sweep hands the notification over to it. False when no such
    /// card exists.
    @discardableResult
    public func offer(_ choices: [NativeChoice], forNotification identifier: String) -> Bool {
        guard let index = notifications.firstIndex(where: { $0.nativeIdentifiers == [identifier] && $0.nativeChoices == nil }) else {
            return false
        }
        notifications[index] = notifications[index].offering(SidebarNotification.NativeChoices(identifier: identifier, choices: choices))
        didChange()
        return true
    }

    /// Whether a card stands for the native notification with `identifier`.
    public func lists(notification identifier: String) -> Bool {
        listedNotifications.contains(identifier)
    }

    /// Whether a card lists the choices of the native alert with `identifier`. A card the notification
    /// database listed from a record that names no choices, or one listing the alert as shown by macOS that the
    /// database has not given choices (`offer(_:forNotification:)`), stands for it without them.
    public func lists(choicesOf identifier: String) -> Bool {
        notifications.contains { $0.nativeChoices?.identifier == identifier }
    }

    /// Saves the list and reports native notifications whose cards it no longer holds, so they do not stay
    /// hidden.
    private func didChange() {
        settleAsks()
        composing.formIntersection(notifications.map(\.id))
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
