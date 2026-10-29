import Foundation

/// Each app's Allow Notifications switch in System Settings › Notifications, as usernoted keeps it.
///
/// usernoted stores every app's notification settings in its group container's preferences, which only Full
/// Disk Access opens: an `apps` array of dictionaries with the app's `bundle-id` and a `flags` bit field.
/// `allowNotificationsFlag` is Allow Notifications: flipping the switch changes only that bit, and every app
/// whose notifications are off lacks it (measured on macOS 26.6). macOS still records such an app's
/// notifications in the notification database, but NotificationCenter never shows them, as a banner or in
/// its history, so no card can open them. The format is private and may change with a macOS update.
public struct NotificationPreferences: Sendable {
    public static let allowNotificationsFlag: Int64 = 1 << 25

    public enum Failure: Error, Equatable, Sendable {
        /// The file does not open, which without Full Disk Access is macOS refusing access.
        case unreadable(String)
        /// The file holds no list of apps in the expected shape, as after a macOS update changed it.
        case unrecognized
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// usernoted's preferences in the user's home folder.
    public init(home: URL) {
        url = home.appendingPathComponent(
            "Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"
        )
    }

    /// Whether each app usernoted knows may post notifications, by bundle identifier.
    public func allowedApps() throws(Failure) -> [String: Bool] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let apps = plist["apps"] as? [[String: Any]]
        else { throw .unrecognized }
        var allowed: [String: Bool] = [:]
        for app in apps {
            guard let identifier = app["bundle-id"] as? String, let flags = (app["flags"] as? NSNumber)?.int64Value else { continue }
            allowed[identifier] = flags & Self.allowNotificationsFlag != 0
        }
        return allowed
    }
}
