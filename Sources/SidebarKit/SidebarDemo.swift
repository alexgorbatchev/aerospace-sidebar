import Foundation
import os
import PermissionFlow
import SidebarProtocol

/// A sidebar that shows a fixed set of notifications for screenshots (`just screenshot`): the app launched with
/// `--demo <directory>` lists the cards in the directory's `notifications.json` (the format
/// `FileNotificationStore` writes) under the settings in its `config.toml`. It intercepts nothing, opens no control
/// socket, handles no URLs, leaves the AeroSpace config alone and writes nothing but a Settings save to that
/// `config.toml`, so it can run beside nothing else and leaves the user's sidebar state untouched.
public struct SidebarDemo: Equatable, Sendable {
    public static let argument = "--demo"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The demo the launch arguments name, if any: the path after `--demo`.
    public init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: Self.argument), arguments.indices.contains(index + 1) else { return nil }
        self.init(directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
    }

    public var notificationsURL: URL { directory.appendingPathComponent("notifications.json") }
    public var settingsURL: URL { directory.appendingPathComponent("config.toml") }

    /// The delegate for the demo: the fixture's cards, never saved, on a clock stopped at the newest of them, so
    /// that no card expires and each shows the time the fixture gives it.
    /// - Parameter makeController: Makes the panel; tests pass one that shows nothing on the desktop.
    @MainActor
    public func makeDelegate(
        icons: AppIconFont = .bundled(),
        makeController: @escaping @MainActor (SidebarModel, SettingsStore, _ openSettings: @escaping @MainActor (SettingsGroup) -> Void, _ setUp: @escaping @MainActor (PermissionFlowPane, CGRect?) -> Void) -> SidebarPanelController = {
            SidebarPanelController(model: $0, settings: $1, escapeKey: .system, openSettings: $2, setUp: $3)
        }
    ) -> SidebarAppDelegate {
        let store = FixtureStore(notifications: FileNotificationStore(url: notificationsURL).load())
        let now = store.notifications.map(\.receivedAt).max() ?? Date()
        return SidebarAppDelegate(
            settings: SettingsStore(file: SettingsFile(url: settingsURL)),
            makeModel: {
                SidebarModel(
                    store: store, history: $0.history, rules: $0.rules,
                    listsSwitchedOffApps: $0.notifications.listsSwitchedOffApps, now: { now }
                )
            },
            icons: icons,
            identities: NotificationIdentities(),
            notificationDatabase: NotificationDatabase(home: directory),
            makeController: makeController,
            makeAeroSpaceSync: { settings in
                // No AeroSpace config under the demo directory, so nothing is ever edited.
                AeroSpaceSync(
                    setup: AeroSpaceSetup(home: directory, environment: [:], isAeroSpaceRunning: { false }),
                    sidebar: { settings.settings.sidebar },
                    copy: { _ in }
                )
            },
            demo: true
        )
    }

    /// Lists the fixture's notifications and keeps every change in memory.
    struct FixtureStore: NotificationStore {
        let notifications: [SidebarNotification]

        func load() -> [SidebarNotification] { notifications }
        func save(_ notifications: [SidebarNotification]) {}
    }
}

extension SidebarAppDelegate {
    /// The delegate the app launches with: the demo the arguments name (`SidebarDemo`), else the sidebar. Nil while
    /// another sidebar or demo runs: only one copy at a time, whichever build it is, because two would stack their
    /// panels on one strip, fight over NotificationCenter's windows and write the same saved list. The delegate keeps
    /// the lock (`InstanceLock` at `lockPath`) for the life of the process. A lock that cannot be taken at all lets
    /// the sidebar run, logged, rather than leave the user without one.
    public static func launching(arguments: [String], lockPath: String = SidebarApp.instanceLockPath) -> SidebarAppDelegate? {
        let lock: InstanceLock?
        do throws(InstanceLock.ClaimError) {
            lock = try InstanceLock.claim(at: lockPath)
        } catch {
            switch error {
            case .held(let pid):
                let holder = pid.map { "pid \($0)" } ?? "another process"
                logger.error("Another sidebar is running (\(holder, privacy: .public)), so this copy quits")
                return nil
            case .unavailable(let path, let code):
                logger.error("Cannot lock \(path, privacy: .public): \(String(cString: strerror(code)), privacy: .public); running without the one-copy check")
                lock = nil
            }
        }
        let delegate = SidebarDemo(arguments: arguments)?.makeDelegate() ?? SidebarAppDelegate()
        delegate.instanceLock = lock
        return delegate
    }
}
