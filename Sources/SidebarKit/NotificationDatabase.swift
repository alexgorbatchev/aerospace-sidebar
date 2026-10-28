import Foundation
import SQLite3

/// A notification as macOS recorded it in its notification database.
public struct DeliveredNotification: Equatable, Sendable {
    /// Increases with every notification the database records.
    public let recordID: Int64
    /// The notification's UUID, the same one NotificationCenter shows as the notification's `AXIdentifier`.
    public let identifier: String
    public let bundleIdentifier: String
    public let title: String
    public let subtitle: String
    public let body: String
    public let deliveredAt: Date
}

/// Reads the database in which macOS keeps every delivered notification
/// (`~/Library/Group Containers/group.com.apple.usernoted/db2/db`).
///
/// It also holds notifications that never showed a banner: those posted during Focus or Do Not Disturb,
/// those dropped when several arrive within milliseconds (SignalLadder), and those delivered while the
/// sidebar was not running. Reading it requires Full Disk Access. The schema is Apple's private one,
/// as AriSweedler/dotfiles' notif-center and OmniWM read it on macOS 26:
/// - `app`: `app_id`, `identifier` (the bundle identifier).
/// - `record`: `rec_id`, `app_id`, `uuid` (16 bytes), `delivered_date` (seconds since 2001, empty or in
///   the future for notifications scheduled but not yet delivered), and `data`, a binary property list
///   whose `req` dictionary holds `titl`, `subt` and `body`.
public struct NotificationDatabase: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// macOS refused access because Full Disk Access is not granted; SQLite reports `SQLITE_AUTH`
        /// ("authorization denied").
        case accessDenied(String)
        /// The database is missing or not in the expected shape.
        case unreadable(String)

        /// The failure a SQLite result code stands for.
        static func sqlite(_ result: Int32, message: String) -> Failure {
            result == SQLITE_AUTH ? .accessDenied(message) : .unreadable(message)
        }

        /// Whether Full Disk Access is what is missing.
        public var isAccessDenied: Bool {
            if case .accessDenied = self { true } else { false }
        }

        public var description: String {
            switch self {
            case .accessDenied(let message), .unreadable(let message): "Cannot read the notification database: \(message)"
            }
        }
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(home: URL) {
        self.init(url: home.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db"))
    }

    /// The write-ahead log that grows with every notification macOS records.
    public var logURL: URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + "-wal")
    }

    /// The newest record's id, or 0 when the database is empty.
    public func latestRecordID() throws(Failure) -> Int64 {
        let connection = try Connection(url: url)
        let statement = try connection.prepare("SELECT COALESCE(MAX(rec_id), 0) FROM record")
        return try statement.step() ? statement.int64(0) : 0
    }

    /// Notifications recorded after `recordID` and delivered by `now`, oldest first. Notifications without
    /// a title or body are skipped.
    public func notifications(after recordID: Int64, deliveredBy now: Date) throws(Failure) -> [DeliveredNotification] {
        let connection = try Connection(url: url)
        let statement = try connection.prepare("""
            SELECT record.rec_id, record.uuid, app.identifier, record.data, record.delivered_date
            FROM record JOIN app ON app.app_id = record.app_id
            WHERE record.rec_id > ? AND record.delivered_date > 0 AND record.delivered_date <= ?
            ORDER BY record.rec_id
            """)
        statement.bind(recordID, at: 1)
        statement.bind(now.timeIntervalSinceReferenceDate, at: 2)
        var notifications: [DeliveredNotification] = []
        while try statement.step() {
            let request = Self.request(in: statement.blob(3))
            let title = request["titl"] as? String ?? ""
            let body = request["body"] as? String ?? ""
            guard let identifier = Self.uuid(statement.blob(1)), !(title.isEmpty && body.isEmpty) else { continue }
            notifications.append(DeliveredNotification(
                recordID: statement.int64(0),
                identifier: identifier,
                bundleIdentifier: statement.text(2) ?? "",
                title: title,
                subtitle: request["subt"] as? String ?? "",
                body: body,
                deliveredAt: Date(timeIntervalSinceReferenceDate: statement.double(4))
            ))
        }
        return notifications
    }

    private static func request(in data: Data?) -> [String: Any] {
        guard let data,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return root["req"] as? [String: Any] ?? [:]
    }

    private static func uuid(_ data: Data?) -> String? {
        guard let data, data.count == 16 else { return nil }
        let bytes = Array(data)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )).uuidString
    }
}

/// A read-only SQLite connection.
private final class Connection {
    let handle: OpaquePointer

    init(url: URL) throws(NotificationDatabase.Failure) {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(result))
            sqlite3_close(handle)
            throw .sqlite(result, message: message)
        }
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }

    func prepare(_ sql: String) throws(NotificationDatabase.Failure) -> Statement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw .sqlite(result, message: String(cString: sqlite3_errmsg(handle)))
        }
        return Statement(connection: self, handle: statement)
    }
}

private final class Statement {
    let connection: Connection
    let handle: OpaquePointer

    init(connection: Connection, handle: OpaquePointer) {
        self.connection = connection
        self.handle = handle
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func bind(_ value: Int64, at index: Int32) {
        sqlite3_bind_int64(handle, index, value)
    }

    func bind(_ value: Double, at index: Int32) {
        sqlite3_bind_double(handle, index, value)
    }

    /// Whether a row is available.
    func step() throws(NotificationDatabase.Failure) -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        case let result: throw .sqlite(result, message: String(cString: sqlite3_errmsg(connection.handle)))
        }
    }

    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }

    func text(_ column: Int32) -> String? {
        sqlite3_column_text(handle, column).map { String(cString: $0) }
    }

    func blob(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(handle, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, column)))
    }
}
