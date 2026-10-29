import Foundation
import os

/// Stores notifications as JSON in Application Support.
@MainActor
public struct FileNotificationStore: NotificationStore {
    private static let logger = Logger(category: "store")

    public let url: URL

    public init(url: URL = FileNotificationStore.defaultURL) {
        self.url = url
    }

    /// `~/Library/Application Support/com.alexgorbatchev.aerospace-sidebar/notifications.json`: the list.
    public nonisolated static var defaultURL: URL { directory.appendingPathComponent("notifications.json") }

    /// `received.json` beside it: every notification as it arrived (`SidebarModel.received`).
    public nonisolated static var receivedURL: URL { directory.appendingPathComponent("received.json") }

    private nonisolated static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("com.alexgorbatchev.aerospace-sidebar", isDirectory: true)
    }

    /// Returns no notifications when the file is missing or unreadable, and leaves out those that do not read,
    /// such as ones another version of the sidebar wrote; both are logged. The next save drops them for good.
    public func load() -> [SidebarNotification] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
            let notifications = entries.compactMap(\.notification)
            if notifications.count < entries.count {
                Self.logger.error("Left out \(entries.count - notifications.count) unreadable notifications from \(url.path, privacy: .public)")
            }
            return notifications
        } catch {
            Self.logger.error("Cannot read \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    public func save(_ notifications: [SidebarNotification]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(notifications).write(to: url, options: [.atomic])
        } catch {
            Self.logger.error("Cannot write \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// One saved notification; nil when it does not read, so that one entry does not lose the whole list.
    private struct Entry: Decodable {
        let notification: SidebarNotification?

        init(from decoder: any Decoder) throws {
            notification = try? SidebarNotification(from: decoder)
        }
    }
}
