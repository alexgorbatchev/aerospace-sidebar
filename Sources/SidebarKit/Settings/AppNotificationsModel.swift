import Foundation
import Observation

/// The apps whose notifications are switched off in System Settings › Notifications although they post
/// notifications, for Settings › Notifications.
///
/// macOS records their notifications in the notification database, where the sidebar finds them, but
/// NotificationCenter never shows them, so a card cannot open the message it stands for, as clicking a
/// notification would: it can only bring the app forward. A switched-off app is listed once a notification
/// from it arrived from macOS (`SidebarModel.received`), and Allow switches it back on in System Settings.
@MainActor
@Observable
public final class AppNotificationsModel {
    public struct App: Identifiable, Equatable, Sendable {
        public let bundleIdentifier: String
        /// The name its notifications show.
        public let name: String

        public var id: String { bundleIdentifier }
    }

    /// How long one read of the settings answers `notificationsAreOff(for:)`, which every card asks for its help.
    static let cacheDuration: TimeInterval = 2

    /// Sorted by name.
    public private(set) var appsWithNotificationsOff: [App] = []
    /// Whether the settings could be read, which takes Full Disk Access.
    public private(set) var canTell = false
    /// The app whose notifications are being switched on.
    public private(set) var allowing: String?
    /// The result of the last Allow.
    public private(set) var message: String?

    @ObservationIgnored private let preferences: NotificationPreferences
    @ObservationIgnored private let switcher: any AppNotificationSwitching
    @ObservationIgnored private let received: @MainActor () -> [SidebarNotification]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var cached: (allowed: [String: Bool]?, readAt: Date)?

    /// - Parameter received: Every notification received lately (`SidebarModel.received`).
    public init(
        preferences: NotificationPreferences,
        switcher: any AppNotificationSwitching = SystemSettingsNotificationSwitch(),
        received: @escaping @MainActor () -> [SidebarNotification],
        now: @escaping () -> Date = Date.init
    ) {
        self.preferences = preferences
        self.switcher = switcher
        self.received = received
        self.now = now
    }

    /// Reads the settings again and lists the switched-off apps that notified lately.
    public func refresh() {
        let allowed = read()
        canTell = allowed != nil
        var seen: Set<String> = []
        // Pushed notifications never pass through macOS, whatever app they name.
        appsWithNotificationsOff = received()
            .filter { !$0.nativeIdentifiers.isEmpty }
            .compactMap { notification -> App? in
                guard let identifier = notification.bundleIdentifier, allowed?[identifier] == false,
                      seen.insert(identifier).inserted
                else { return nil }
                return App(bundleIdentifier: identifier, name: notification.source)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether the app with `bundleIdentifier` has its notifications switched off; false when the settings
    /// cannot be read. Reads them at most every `cacheDuration` seconds.
    public func notificationsAreOff(for bundleIdentifier: String) -> Bool {
        let time = now()
        if let cached, time.timeIntervalSince(cached.readAt) < Self.cacheDuration {
            return cached.allowed?[bundleIdentifier] == false
        }
        return read()?[bundleIdentifier] == false
    }

    /// Switches the app's notifications on in System Settings, then lists the apps again.
    public func allow(_ app: App) async {
        guard allowing == nil else { return }
        allowing = app.bundleIdentifier
        let result = await switcher.allowNotifications(bundleIdentifier: app.bundleIdentifier, name: app.name)
        allowing = nil
        message = switch result {
        // Notification Center then lists the app's notifications it kept, so their cards open them too.
        case .switchedOn: "Switched on notifications from \(app.name); its cards open their notifications."
        case .alreadyOn: "Notifications from \(app.name) are on."
        case .pageNotShown, .refused: "Switch on Allow Notifications for \(app.name) in System Settings."
        case .needsAccessibility: "Without Accessibility, switch on Allow Notifications for \(app.name) in System Settings."
        }
        refresh()
    }

    private func read() -> [String: Bool]? {
        let allowed = try? preferences.allowedApps()
        cached = (allowed, now())
        return allowed
    }
}
