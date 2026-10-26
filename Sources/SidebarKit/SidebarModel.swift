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

    public let id: UUID
    /// The app that posted the notification, or the process that pushed it.
    public let source: String
    public let title: String
    public let subtitle: String
    public let body: String
    public let severity: NotificationSeverity
    public let action: ClickAction?
    /// macOS kept presenting the original notification because it needs interaction.
    public let shownByMacOS: Bool
    public let receivedAt: Date

    public init(
        id: UUID = UUID(),
        source: String,
        title: String,
        subtitle: String = "",
        body: String = "",
        severity: NotificationSeverity = .normal,
        action: ClickAction? = nil,
        shownByMacOS: Bool = false,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.severity = severity
        self.action = action
        self.shownByMacOS = shownByMacOS
        self.receivedAt = receivedAt
    }

    public init(payload: NotificationPayload, source: String, receivedAt: Date = Date()) {
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
            action: action,
            receivedAt: receivedAt
        )
    }
}

extension SidebarNotification {
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

/// State rendered by the sidebar. Every change is saved to the store, and notifications older than
/// `retention` are dropped, so a relaunch restores the list as it was.
@MainActor
@Observable
public final class SidebarModel {
    public static let maxNotifications = 200
    public static let retention: TimeInterval = 24 * 60 * 60
    public static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    /// Most severe first, newest first within a severity.
    public private(set) var notifications: [SidebarNotification] = []
    public var interception: InterceptionStatus = .starting

    @ObservationIgnored private let performer: any NotificationActionPerforming
    @ObservationIgnored private let store: any NotificationStore
    @ObservationIgnored private let now: () -> Date

    public init(
        performer: any NotificationActionPerforming = WorkspaceActionPerformer(),
        store: any NotificationStore,
        now: @escaping () -> Date = Date.init
    ) {
        self.performer = performer
        self.store = store
        self.now = now
        let cutoff = now().addingTimeInterval(-Self.retention)
        notifications = Array(store.load()
            .filter { $0.receivedAt >= cutoff }
            .sorted { ($0.severity, $0.receivedAt) > ($1.severity, $1.receivedAt) }
            .prefix(Self.maxNotifications))
    }

    /// Inserts the notification by severity, then recency. Beyond `maxNotifications`, the least
    /// severe and oldest notifications are dropped.
    public func add(_ notification: SidebarNotification) {
        let index = notifications.firstIndex {
            ($0.severity, $0.receivedAt) <= (notification.severity, notification.receivedAt)
        } ?? notifications.endIndex
        notifications.insert(notification, at: index)
        if notifications.count > Self.maxNotifications {
            notifications.removeLast(notifications.count - Self.maxNotifications)
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

    /// Drops notifications older than `retention`.
    public func pruneExpired() {
        let cutoff = now().addingTimeInterval(-Self.retention)
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

    public func openAccessibilitySettings() {
        performer.perform(.open(Self.accessibilitySettingsURL))
    }
}
