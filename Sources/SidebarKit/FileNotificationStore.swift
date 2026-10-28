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

    /// Returns no notifications when the file is missing or unreadable; the latter is logged.
    public func load() -> [SidebarNotification] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try JSONDecoder().decode([SidebarNotification].self, from: Data(contentsOf: url))
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
}
