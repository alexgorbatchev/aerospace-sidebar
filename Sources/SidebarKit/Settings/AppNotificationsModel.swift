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

    /// How often the settings are tried again while they cannot be read, as without Full Disk Access.
    public static let retryInterval: Duration = .seconds(5)

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
    @ObservationIgnored private let installedApp: @MainActor (String) -> InstalledApps.App?
    @ObservationIgnored private let retryInterval: Duration
    /// Each app's switch by `key(_:)` of its bundle identifier, as last read; nil while the settings cannot be read.
    /// Cards read it through `notificationsAreOff(for:)` as they draw, so a switch that flips redraws them.
    private var switches: [String: Switch]?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// Installed apps' names by bundle identifier, misses included: the list is read every second while shown.
    @ObservationIgnored private var installedNames: [String: String?] = [:]

    /// - Parameters:
    ///   - received: Every notification received lately (`SidebarModel.received`).
    ///   - installedApp: The installed app with a bundle identifier, for its own name.
    public init(
        preferences: NotificationPreferences,
        switcher: any AppNotificationSwitching = SystemSettingsNotificationSwitch(),
        installedApp: @escaping @MainActor (String) -> InstalledApps.App? = InstalledApps.app,
        retryInterval: Duration = AppNotificationsModel.retryInterval,
        received: @escaping @MainActor () -> [SidebarNotification]
    ) {
        self.preferences = preferences
        self.switcher = switcher
        self.installedApp = installedApp
        self.retryInterval = retryInterval
        self.received = received
    }

    isolated deinit {
        watcher?.stop()
        retry?.cancel()
    }

    /// Reads the settings and reads them again whenever usernoted writes them, as when a switch flips in System
    /// Settings, or every `retryInterval` while they cannot be read.
    public func start() {
        watcher?.stop()
        let watcher = FileWatcher(url: preferences.url, delay: .milliseconds(200)) { [weak self] in self?.read() }
        watcher.start()
        self.watcher = watcher
        read()
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        retry?.cancel()
        retry = nil
    }

    /// One app's Allow Notifications switch, under the bundle identifier usernoted keeps it for.
    private struct Switch: Equatable {
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

    /// Whether the app with `bundleIdentifier`, in any case, has its notifications switched off, as last read; false
    /// when the settings cannot be read.
    public func notificationsAreOff(for bundleIdentifier: String) -> Bool {
        switches?[Self.key(bundleIdentifier)]?.allowed == false
    }

    /// Switches the app's notifications on in System Settings, then lists the apps again. Returns what System
    /// Settings did, nil while another app's are being switched on.
    @discardableResult
    public func allow(_ app: App) async -> AppNotificationSwitchResult? {
        guard allowing == nil else { return nil }
        allowing = app.bundleIdentifier
        let result = await switcher.allowNotifications(bundleIdentifier: app.bundleIdentifier, name: app.name)
        allowing = nil
        message = Self.message(for: result, of: app.title)
        refresh()
        return result
    }

    /// Switches on the notifications of the app with `bundleIdentifier`, in any case, and `name`, as a card names
    /// them, using the identifier as usernoted keeps it, which System Settings finds the app's page by. Returns
    /// what is left to the user when the switch did not move; nil once it is on, or while another app's are being
    /// switched on.
    public func switchOn(bundleIdentifier: String, name: String) async -> String? {
        let identifier = read()?[Self.key(bundleIdentifier)]?.bundleIdentifier ?? bundleIdentifier
        let installedName = installedName(of: identifier)
        let app = App(bundleIdentifier: identifier, name: name, installedName: installedName == name ? nil : installedName)
        switch await allow(app) {
        case let result? where result != .switchedOn && result != .alreadyOn: return Self.message(for: result, of: app.title)
        default: return nil
        }
    }

    /// What Allow did for the app titled `title`, and what is left to the user.
    public static func message(for result: AppNotificationSwitchResult, of title: String) -> String {
        switch result {
        // Notification Center then lists the app's notifications it kept, so their cards open them too.
        case .switchedOn: "Switched on notifications from \(title); its cards open their notifications."
        case .alreadyOn: "Notifications from \(title) are on."
        case .pageNotShown, .refused: "Switch on Allow Notifications for \(title) in System Settings."
        case .needsAccessibility: "Without Accessibility, switch on Allow Notifications for \(title) in System Settings."
        }
    }

    private func installedName(of bundleIdentifier: String) -> String? {
        if let cached = installedNames[bundleIdentifier] { return cached }
        let name = installedApp(bundleIdentifier)?.name
        installedNames[bundleIdentifier] = name
        return name
    }

    /// Reads the switches into `switches`, and while they cannot be read tries again after `retryInterval`
    /// while started.
    @discardableResult
    private func read() -> [String: Switch]? {
        var apps: [String: Switch]?
        if let allowed = try? preferences.allowedApps() {
            apps = [:]
            for (identifier, isAllowed) in allowed {
                apps?[Self.key(identifier)] = Switch(bundleIdentifier: identifier, allowed: isAllowed)
            }
        }
        // Reading them again unchanged would redraw every card for nothing.
        if apps != switches { switches = apps }
        retry?.cancel()
        retry = nil
        if apps == nil, watcher != nil {
            retry = Task { [weak self, retryInterval] in
                try? await Task.sleep(for: retryInterval)
                guard !Task.isCancelled else { return }
                // Access may have come with a new file the watcher could not open before.
                self?.start()
            }
        }
        return apps
    }

    /// Bundle identifiers compare without regard to case, as LaunchServices compares them: the notification
    /// database, where cards listed from it get theirs, stores them in lowercase, and usernoted's preferences
    /// in the app's own case.
    private static func key(_ bundleIdentifier: String) -> String {
        bundleIdentifier.lowercased()
    }
}
