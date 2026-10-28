import Foundation
import Observation
import SidebarProtocol

/// One notification shown in the sidebar.
public struct SidebarNotification: Identifiable, Codable, Equatable, Sendable {
    public enum ClickAction: Codable, Equatable, Sendable {
        case open(URL)
        case run(command: String, workingDirectory: String)
        /// Brings the app that posted an intercepted system notification to the front.
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

    /// A macOS alert that stays hidden while its card offers the alert's choices (see
    /// `NotificationBanners.choices(of:labels:)`).
    public struct NativeAlert: Codable, Equatable, Sendable {
        /// The alert's `AXIdentifier`, a UUID that NotificationCenter keeps for the alert's lifetime.
        public let identifier: String
        /// The actions it offers besides opening and closing it, such as "Allow…".
        public let choices: [String]

        public init(identifier: String, choices: [String]) {
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
    public let icon: Icon?
    /// The icon id a push named that the font does not have; the card notes it under the text.
    public let invalidIcon: String?
    public let action: ClickAction?
    /// macOS kept presenting the original notification because it needs interaction.
    public let shownByMacOS: Bool
    /// The hidden macOS alert this entry stands for, whose choices the card offers while it exists.
    public let nativeAlert: NativeAlert?
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
        icon: Icon? = nil,
        invalidIcon: String? = nil,
        action: ClickAction? = nil,
        shownByMacOS: Bool = false,
        nativeAlert: NativeAlert? = nil,
        receivedAt: Date = Date(),
        occurrences: Int = 1
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.severity = severity
        self.icon = icon
        self.invalidIcon = invalidIcon
        self.action = action
        self.shownByMacOS = shownByMacOS
        self.nativeAlert = nativeAlert
        self.receivedAt = receivedAt
        self.occurrences = occurrences
    }

    /// A pushed notification. An icon id that `icons` does not know is kept as `invalidIcon`.
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
            invalidIcon: icon == nil ? payload.icon : nil,
            action: action,
            receivedAt: receivedAt
        )
    }
}

extension SidebarNotification {
    /// Same sender, text, severity, icon, click action and presentation; only identity, time and count may
    /// differ. Two alerts are never the same content: each card answers its own alert.
    func hasSameContent(as other: SidebarNotification) -> Bool {
        source == other.source && title == other.title && subtitle == other.subtitle && body == other.body
            && severity == other.severity && icon == other.icon && invalidIcon == other.invalidIcon
            && action == other.action && shownByMacOS == other.shownByMacOS && nativeAlert == other.nativeAlert
    }

    /// This entry with `newer` folded in: it keeps its identity, takes `newer`'s time, and adds its count.
    func stacking(_ newer: SidebarNotification) -> SidebarNotification {
        SidebarNotification(
            id: id,
            source: source,
            title: title,
            subtitle: subtitle,
            body: body,
            severity: severity,
            icon: icon,
            invalidIcon: invalidIcon,
            action: action,
            shownByMacOS: shownByMacOS,
            nativeAlert: nativeAlert,
            receivedAt: max(receivedAt, newer.receivedAt),
            occurrences: occurrences + newer.occurrences
        )
    }

    /// This entry with another severity, as a rule sets it.
    func with(severity: NotificationSeverity) -> SidebarNotification {
        SidebarNotification(
            id: id,
            source: source,
            title: title,
            subtitle: subtitle,
            body: body,
            severity: severity,
            icon: icon,
            invalidIcon: invalidIcon,
            action: action,
            shownByMacOS: shownByMacOS,
            nativeAlert: nativeAlert,
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
        case .activateApp(let name): "Click to switch to \(name)"
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
    func perform(_ action: SidebarNotification.ClickAction)
}

/// What the sidebar can do to a hidden macOS alert.
public enum AlertAction: Equatable, Sendable {
    /// What clicking the alert does, such as opening its app.
    case open
    /// One of the alert's `NativeAlert.choices`.
    case choice(String)
}

/// Acts on the macOS alerts that cards stand for; `NotificationCenterMonitor` is the real implementation.
@MainActor
public protocol NativeAlertControlling: AnyObject {
    /// Performs `action` on the alert; false when the alert is gone or refuses it.
    @discardableResult func perform(_ action: AlertAction, onAlert identifier: String) -> Bool
    /// The list dropped cards for alerts; the alerts that are still hidden are closed.
    func alertsReleased()
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
    public var interception: InterceptionStatus = .starting
    /// Identifiers of the hidden macOS alerts that still exist; only their cards offer choices.
    public var presentAlerts: Set<String> = []
    /// Performs alert choices and closes alerts whose cards are gone; set once interception is wired up.
    @ObservationIgnored public weak var alerts: (any NativeAlertControlling)?

    @ObservationIgnored private let performer: any NotificationActionPerforming
    @ObservationIgnored private let store: any NotificationStore
    @ObservationIgnored private let now: () -> Date
    /// How long and how many notifications are kept.
    @ObservationIgnored public private(set) var history: SidebarSettings.History
    /// Change or hide notifications as they arrive.
    @ObservationIgnored private var rules: NotificationRules
    /// The alerts listed after the last change, to tell when a change drops one.
    @ObservationIgnored private var listedAlerts: Set<String> = []

    public init(
        performer: any NotificationActionPerforming = WorkspaceActionPerformer(),
        store: any NotificationStore,
        history: SidebarSettings.History = SidebarSettings.History(),
        rules: [SidebarSettings.Rule] = [],
        now: @escaping () -> Date = Date.init
    ) {
        self.performer = performer
        self.store = store
        self.history = history
        self.rules = NotificationRules(rules)
        self.now = now
        let cutoff = now().addingTimeInterval(-history.retention)
        notifications = Array(store.load()
            .filter { $0.receivedAt >= cutoff }
            .sorted { ($0.severity, $0.receivedAt) > ($1.severity, $1.receivedAt) }
            .prefix(history.maxCount))
        listedAlerts = Self.alertIdentifiers(in: notifications)
    }

    /// Applies new history limits, dropping notifications they no longer allow.
    public func apply(history: SidebarSettings.History) {
        self.history = history
        pruneExpired()
        if notifications.count > history.maxCount {
            notifications.removeLast(notifications.count - history.maxCount)
            didChange()
        }
    }

    /// Applies new rules to notifications that arrive from now on; listed ones keep how earlier rules left them.
    public func apply(rules: [SidebarSettings.Rule]) {
        self.rules = NotificationRules(rules)
    }

    /// Inserts the notification by severity, then recency, after the first matching rule has changed its
    /// severity or hidden it. A notification with the same content as a listed one is stacked onto it
    /// instead: the entry counts both and moves up as the newest. Beyond `history.maxCount`, the least
    /// severe and oldest entries are dropped.
    public func add(_ notification: SidebarNotification) {
        guard var notification = rules.apply(to: notification) else { return }
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
        didChange()
    }

    public func dismiss(_ id: SidebarNotification.ID) {
        notifications.removeAll { $0.id == id }
        didChange()
    }

    public func clear() {
        notifications.removeAll()
        didChange()
    }

    /// Drops notifications older than `history.retention`.
    public func pruneExpired() {
        let cutoff = now().addingTimeInterval(-history.retention)
        guard notifications.contains(where: { $0.receivedAt < cutoff }) else { return }
        notifications.removeAll { $0.receivedAt < cutoff }
        didChange()
    }

    /// Runs the notification's click action, then dismisses it. A card whose alert is still present
    /// opens the alert, as clicking it in macOS would; if that fails, the card's own action runs instead.
    public func activate(_ id: SidebarNotification.ID) {
        guard let notification = notifications.first(where: { $0.id == id }) else { return }
        let openedAlert = presentAlert(of: notification).map { alerts?.perform(.open, onAlert: $0.identifier) == true } ?? false
        if !openedAlert, let action = notification.action {
            performer.perform(action)
        }
        dismiss(id)
    }

    /// Performs one of the alert's choices, then dismisses the card. The card stays when the alert is
    /// gone or refuses the choice.
    public func choose(_ choice: String, for id: SidebarNotification.ID) {
        guard let alert = notifications.first(where: { $0.id == id }).flatMap(presentAlert(of:)),
              alert.choices.contains(choice),
              alerts?.perform(.choice(choice), onAlert: alert.identifier) == true
        else { return }
        dismiss(id)
    }

    /// The notification's alert while it still exists in NotificationCenter.
    public func presentAlert(of notification: SidebarNotification) -> SidebarNotification.NativeAlert? {
        notification.nativeAlert.flatMap { presentAlerts.contains($0.identifier) ? $0 : nil }
    }

    /// Whether a card stands for the alert with `identifier`.
    public func lists(alert identifier: String) -> Bool {
        listedAlerts.contains(identifier)
    }

    /// Saves the list and reports alerts whose cards it no longer holds, so they do not stay hidden.
    private func didChange() {
        store.save(notifications)
        let listed = Self.alertIdentifiers(in: notifications)
        let released = !listedAlerts.isSubset(of: listed)
        listedAlerts = listed
        if released {
            alerts?.alertsReleased()
        }
    }

    private static func alertIdentifiers(in notifications: [SidebarNotification]) -> Set<String> {
        Set(notifications.compactMap(\.nativeAlert?.identifier))
    }
}
