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
    /// Same sender, text, severity, icon, click action and presentation; only identity, time and count may differ.
    func hasSameContent(as other: SidebarNotification) -> Bool {
        source == other.source && title == other.title && subtitle == other.subtitle && body == other.body
            && severity == other.severity && icon == other.icon && invalidIcon == other.invalidIcon
            && action == other.action && shownByMacOS == other.shownByMacOS
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
            receivedAt: max(receivedAt, newer.receivedAt),
            occurrences: occurrences + newer.occurrences
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
    public static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    /// Most severe first, newest first within a severity.
    public private(set) var notifications: [SidebarNotification] = []
    public var interception: InterceptionStatus = .starting

    @ObservationIgnored private let performer: any NotificationActionPerforming
    @ObservationIgnored private let store: any NotificationStore
    @ObservationIgnored private let now: () -> Date
    /// How long and how many notifications are kept.
    @ObservationIgnored public private(set) var history: SidebarSettings.History

    public init(
        performer: any NotificationActionPerforming = WorkspaceActionPerformer(),
        store: any NotificationStore,
        history: SidebarSettings.History = SidebarSettings.History(),
        now: @escaping () -> Date = Date.init
    ) {
        self.performer = performer
        self.store = store
        self.history = history
        self.now = now
        let cutoff = now().addingTimeInterval(-history.retention)
        notifications = Array(store.load()
            .filter { $0.receivedAt >= cutoff }
            .sorted { ($0.severity, $0.receivedAt) > ($1.severity, $1.receivedAt) }
            .prefix(history.maxCount))
    }

    /// Applies new history limits, dropping notifications they no longer allow.
    public func apply(history: SidebarSettings.History) {
        self.history = history
        pruneExpired()
        if notifications.count > history.maxCount {
            notifications.removeLast(notifications.count - history.maxCount)
            store.save(notifications)
        }
    }

    /// Inserts the notification by severity, then recency. A notification with the same content as a
    /// listed one is stacked onto it instead: the entry counts both and moves up as the newest. Beyond
    /// `history.maxCount`, the least severe and oldest entries are dropped.
    public func add(_ notification: SidebarNotification) {
        var notification = notification
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
        store.save(notifications)
    }

    public func dismiss(_ id: SidebarNotification.ID) {
        notifications.removeAll { $0.id == id }
        store.save(notifications)
    }

    public func clear() {
        notifications.removeAll()
        store.save(notifications)
    }

    /// Drops notifications older than `history.retention`.
    public func pruneExpired() {
        let cutoff = now().addingTimeInterval(-history.retention)
        guard notifications.contains(where: { $0.receivedAt < cutoff }) else { return }
        notifications.removeAll { $0.receivedAt < cutoff }
        store.save(notifications)
    }

    /// Runs the notification's click action, then dismisses it.
    public func activate(_ id: SidebarNotification.ID) {
        guard let notification = notifications.first(where: { $0.id == id }) else { return }
        if let action = notification.action {
            performer.perform(action)
        }
        dismiss(id)
    }

}
