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
        /// The name its notifications show, which System Settings titles its page with.
        public let name: String
        /// The installed app's own name where it differs from `name`. An app and the helper it posts web
        /// notifications from have a switch each, and System Settings names both after the app (Vivaldi and
        /// Vivaldi Helper (Alerts) are both "Vivaldi").
        public let installedName: String?

        public init(bundleIdentifier: String, name: String, installedName: String? = nil) {
            self.bundleIdentifier = bundleIdentifier
            self.name = name
            self.installedName = installedName
        }

        public var id: String { bundleIdentifier }

        /// What tells this switch apart: the installed app's own name where it differs, else `name`.
        public var title: String { installedName ?? name }

        /// By name, then title, as Finder sorts names: an app before its helper, which notifies under the same name.
        static func precedes(_ one: App, _ other: App) -> Bool {
            let byName = one.name.localizedStandardCompare(other.name)
            guard byName == .orderedSame else { return byName == .orderedAscending }
            return one.title.localizedStandardCompare(other.title) == .orderedAscending
        }
    }

    /// How long one read of the settings answers `notificationsAreOff(for:)`, which every card asks for its help.
    static let cacheDuration: TimeInterval = 2

    /// Sorted by name, then title.
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
    @ObservationIgnored private let installedApp: @MainActor (String) -> InstalledApps.App?
    @ObservationIgnored private var cached: (apps: [String: Switch]?, readAt: Date)?
    /// Installed apps' names by bundle identifier, misses included: the list is read every second while shown.
    @ObservationIgnored private var installedNames: [String: String?] = [:]

    /// - Parameters:
    ///   - received: Every notification received lately (`SidebarModel.received`).
    ///   - installedApp: The installed app with a bundle identifier, for its own name.
    public init(
        preferences: NotificationPreferences,
        switcher: any AppNotificationSwitching = SystemSettingsNotificationSwitch(),
        installedApp: @escaping @MainActor (String) -> InstalledApps.App? = InstalledApps.app,
        received: @escaping @MainActor () -> [SidebarNotification],
        now: @escaping () -> Date = Date.init
    ) {
        self.preferences = preferences
        self.switcher = switcher
        self.installedApp = installedApp
        self.received = received
        self.now = now
    }

    /// One app's Allow Notifications switch, under the bundle identifier usernoted keeps it for.
    private struct Switch {
        let bundleIdentifier: String
        let allowed: Bool
    }

    /// Reads the settings again and lists the switched-off apps that notified lately.
    public func refresh() {
        let apps = read()
        canTell = apps != nil
        var seen: Set<String> = []
        // Pushed notifications never pass through macOS, whatever app they name.
        appsWithNotificationsOff = received()
            .filter { !$0.nativeIdentifiers.isEmpty }
            .compactMap { notification -> App? in
                guard let identifier = notification.bundleIdentifier, let app = apps?[Self.key(identifier)], !app.allowed,
                      seen.insert(app.bundleIdentifier).inserted
                else { return nil }
                // System Settings finds the app's page only by the identifier as usernoted keeps it.
                let installedName = installedName(of: app.bundleIdentifier)
                return App(
                    bundleIdentifier: app.bundleIdentifier,
                    name: notification.source,
                    installedName: installedName == notification.source ? nil : installedName
                )
            }
            .sorted(by: App.precedes)
    }

    /// Whether the app with `bundleIdentifier`, in any case, has its notifications switched off; false when the
    /// settings cannot be read. Reads them at most every `cacheDuration` seconds.
    public func notificationsAreOff(for bundleIdentifier: String) -> Bool {
        let time = now()
        let apps = if let cached, time.timeIntervalSince(cached.readAt) < Self.cacheDuration { cached.apps } else { read() }
        return apps?[Self.key(bundleIdentifier)]?.allowed == false
    }

    /// Switches the app's notifications on in System Settings, then lists the apps again.
    public func allow(_ app: App) async {
        guard allowing == nil else { return }
        allowing = app.bundleIdentifier
        let result = await switcher.allowNotifications(bundleIdentifier: app.bundleIdentifier, name: app.name)
        allowing = nil
        message = switch result {
        // Notification Center then lists the app's notifications it kept, so their cards open them too.
        case .switchedOn: "Switched on notifications from \(app.title); its cards open their notifications."
        case .alreadyOn: "Notifications from \(app.title) are on."
        case .pageNotShown, .refused: "Switch on Allow Notifications for \(app.title) in System Settings."
        case .needsAccessibility: "Without Accessibility, switch on Allow Notifications for \(app.title) in System Settings."
        }
        refresh()
    }

    private func installedName(of bundleIdentifier: String) -> String? {
        if let cached = installedNames[bundleIdentifier] { return cached }
        let name = installedApp(bundleIdentifier)?.name
        installedNames[bundleIdentifier] = name
        return name
    }

    /// The switches by `key(_:)` of their bundle identifiers.
    private func read() -> [String: Switch]? {
        var apps: [String: Switch]?
        if let allowed = try? preferences.allowedApps() {
            apps = [:]
            for (identifier, isAllowed) in allowed {
                apps?[Self.key(identifier)] = Switch(bundleIdentifier: identifier, allowed: isAllowed)
            }
        }
        cached = (apps, now())
        return apps
    }

    /// Bundle identifiers compare without regard to case, as LaunchServices compares them: the notification
    /// database, where cards listed from it get theirs, stores them in lowercase, and usernoted's preferences
    /// in the app's own case.
    private static func key(_ bundleIdentifier: String) -> String {
        bundleIdentifier.lowercased()
    }
}
