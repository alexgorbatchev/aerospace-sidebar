import Foundation
@testable import SidebarKit
import SQLite3
import Testing

/// A notification database shaped like macOS's, in a temporary directory, with its own defaults domain.
final class NotificationDatabaseFixture {
    let directory: TemporaryDirectory
    let database: NotificationDatabase
    let defaults: UserDefaults
    private let suiteName = "aerospace-sidebar-tests-\(UUID().uuidString)"

    init() throws {
        directory = try TemporaryDirectory()
        database = NotificationDatabase(url: directory.url.appendingPathComponent("db2/db"))
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func create() throws {
        try FileManager.default.createDirectory(at: database.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR);
            CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, request_date REAL, delivered_date REAL);
            INSERT INTO app VALUES (1, 'com.apple.ScriptEditor2'), (2, 'com.example.missing');
            """)
    }

    /// Adds a record the way usernoted stores one: the request texts in a binary property list.
    @discardableResult
    func insert(
        identifier: UUID = UUID(),
        app: Int = 1,
        title: String = "Title",
        subtitle: String? = nil,
        body: String = "Body",
        delivered: Date? = Date(timeIntervalSinceReferenceDate: 800_000_000),
        data: Data? = nil
    ) throws -> UUID {
        var request: [String: String] = ["titl": title, "body": body]
        request["subt"] = subtitle
        let plist = try data ?? PropertyListSerialization.data(fromPropertyList: ["req": request], format: .binary, options: 0)
        try withConnection { handle in
            var statement: OpaquePointer?
            sqlite3_prepare_v2(handle, "INSERT INTO record (app_id, uuid, data, delivered_date) VALUES (?, ?, ?, ?)", -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_int64(statement, 1, Int64(app))
            withUnsafeBytes(of: identifier.uuid) { _ = sqlite3_bind_blob(statement, 2, $0.baseAddress, 16, transient) }
            plist.withUnsafeBytes { _ = sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(plist.count), transient) }
            if let delivered {
                sqlite3_bind_double(statement, 4, delivered.timeIntervalSinceReferenceDate)
            }
            #expect(sqlite3_step(statement) == SQLITE_DONE)
        }
        return identifier
    }

    func execute(_ sql: String) throws {
        try withConnection { #expect(sqlite3_exec($0, sql, nil, nil, nil) == SQLITE_OK) }
    }

    private func withConnection(_ body: (OpaquePointer?) throws -> Void) throws {
        var handle: OpaquePointer?
        try #require(sqlite3_open(database.url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        try body(handle)
    }
}

struct NotificationDatabaseTests {
    let fixture: NotificationDatabaseFixture
    let now = Date(timeIntervalSinceReferenceDate: 900_000_000)

    init() throws {
        fixture = try NotificationDatabaseFixture()
    }

    @Test func readsDeliveredNotificationsAfterARecord() throws {
        try fixture.create()
        try fixture.insert(title: "Old")
        let identifier = try fixture.insert(title: "New", subtitle: "Sub", body: "Text")
        try fixture.insert(title: "Scheduled", delivered: now.addingTimeInterval(60))
        try fixture.insert(title: "Undelivered", delivered: nil)
        try fixture.insert(title: "", body: "")
        try fixture.insert(data: Data("not a property list".utf8))
        try fixture.insert(app: 2, title: "Elsewhere")

        let notifications = try fixture.database.notifications(after: 1, deliveredBy: now)

        #expect(try fixture.database.latestRecordID() == 7)
        #expect(notifications == [
            DeliveredNotification(
                recordID: 2, identifier: identifier.uuidString, bundleIdentifier: "com.apple.ScriptEditor2",
                title: "New", subtitle: "Sub", body: "Text", deliveredAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
            ),
            DeliveredNotification(
                recordID: 7, identifier: notifications.last?.identifier ?? "", bundleIdentifier: "com.example.missing",
                title: "Elsewhere", subtitle: "", body: "Body", deliveredAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
            ),
        ])
    }

    @Test func emptyDatabaseHasNoRecords() throws {
        try fixture.create()

        #expect(try fixture.database.latestRecordID() == 0)
        #expect(try fixture.database.notifications(after: 0, deliveredBy: now).isEmpty)
    }

    @Test func reportsAnUnreadableDatabase() throws {
        #expect(throws: NotificationDatabase.Failure.self) { try fixture.database.latestRecordID() }
        #expect(throws: NotificationDatabase.Failure.self) { try fixture.database.notifications(after: 0, deliveredBy: now) }

        try FileManager.default.createDirectory(at: fixture.database.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: fixture.database.url)
        let error = try #require(throws: NotificationDatabase.Failure.self) { try fixture.database.latestRecordID() }
        #expect(error.description.hasPrefix("Cannot read the notification database: "))
    }

    @Test func locatesTheDatabaseInTheHomeDirectory() {
        let database = NotificationDatabase(home: URL(fileURLWithPath: "/Users/someone"))

        #expect(database.url.path == "/Users/someone/Library/Group Containers/group.com.apple.usernoted/db2/db")
        #expect(database.logURL.lastPathComponent == "db-wal")
    }
}

@MainActor
struct NotificationDatabaseMonitorTests {
    let fixture: NotificationDatabaseFixture
    let identities = NotificationIdentities()

    init() throws {
        fixture = try NotificationDatabaseFixture()
    }

    final class Harness {
        var now = Date(timeIntervalSinceReferenceDate: 900_000_000)
        var received: [SidebarNotification] = []
    }

    func makeMonitor(_ harness: Harness, grace: TimeInterval = 3) -> NotificationDatabaseMonitor {
        NotificationDatabaseMonitor(
            database: fixture.database,
            identities: identities,
            defaults: fixture.defaults,
            grace: grace,
            appName: { $0 == "com.apple.ScriptEditor2" ? "Script Editor" : nil },
            now: { harness.now }
        ) { harness.received.append($0) }
    }

    /// The first launch starts after the newest record; later records wait out the grace period, and those
    /// a banner already reported are skipped.
    @Test func listsRecordsNoBannerReported() throws {
        try fixture.create()
        try fixture.insert(title: "History")
        let harness = Harness()
        let monitor = makeMonitor(harness)
        monitor.start()
        defer { monitor.stop() }
        #expect(monitor.isReadable)

        try fixture.insert(title: "During Focus", subtitle: "Sub")
        identities.insert(try fixture.insert(title: "Shown as a banner").uuidString)
        try fixture.insert(app: 2, title: "From macOS")
        monitor.readNewRecords()
        monitor.deliverPending()
        #expect(harness.received.isEmpty)

        harness.now += 3
        monitor.deliverPending()

        #expect(harness.received.map(\.title) == ["During Focus", "From macOS"])
        #expect(harness.received.map(\.source) == ["Script Editor", SystemNotificationInterceptor.systemSource])
        #expect(harness.received.map(\.action) == [.activateApp(name: "Script Editor"), nil])
        #expect(harness.received.first?.subtitle == "Sub")
        #expect(harness.received.first?.receivedAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    /// Records added while the sidebar was not running are listed at the next launch.
    @Test func catchesUpOnRecordsFromBeforeLaunch() throws {
        try fixture.create()
        let harness = Harness()
        makeMonitor(harness).start()
        try fixture.insert(title: "While quit")

        let monitor = makeMonitor(harness, grace: 0)
        monitor.start()
        defer { monitor.stop() }
        monitor.deliverPending()

        #expect(harness.received.map(\.title) == ["While quit"])
    }

    @Test func startsOverWhenTheDatabaseIsRecreated() throws {
        try fixture.create()
        fixture.defaults.set(NSNumber(value: 50), forKey: NotificationDatabaseMonitor.recordIDKey)
        try fixture.insert(title: "Before")
        let harness = Harness()
        let monitor = makeMonitor(harness, grace: 0)
        monitor.start()
        defer { monitor.stop() }

        try fixture.insert(title: "After")
        monitor.readNewRecords()
        monitor.deliverPending()

        #expect(harness.received.map(\.title) == ["After"])
    }

    @Test func waitsForFullDiskAccess() throws {
        let harness = Harness()
        let monitor = makeMonitor(harness)

        monitor.start()
        monitor.open()
        #expect(!monitor.isReadable)
        #expect(monitor.isWaitingForAccess)

        try fixture.create()
        monitor.open()
        #expect(monitor.isReadable)
        #expect(!monitor.isWaitingForAccess)

        try FileManager.default.removeItem(at: fixture.database.url.deletingLastPathComponent())
        monitor.readNewRecords()
        monitor.stop()
        #expect(!monitor.isReadable)
    }

    /// A write to the database wakes the monitor, which lists the record once its grace period ends.
    @Test func watchesTheDatabaseForNewRecords() async throws {
        try fixture.create()
        let harness = Harness()
        let monitor = NotificationDatabaseMonitor(
            database: fixture.database, identities: identities, defaults: fixture.defaults, grace: 0.05,
            appName: { _ in "App" }
        ) { harness.received.append($0) }
        monitor.start()
        defer { monitor.stop() }

        try fixture.insert(title: "Live")
        for _ in 0..<300 where harness.received.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(harness.received.map(\.title) == ["Live"])
    }

    @Test func findsInstalledAppNames() {
        #expect(NotificationDatabaseMonitor.installedAppName(bundleIdentifier: "com.apple.finder") == "Finder")
        #expect(NotificationDatabaseMonitor.installedAppName(bundleIdentifier: "com.apple.ScriptEditor2") == "Script Editor")
        #expect(NotificationDatabaseMonitor.installedAppName(bundleIdentifier: "com.example.not-installed") == nil)
    }
}

@MainActor
struct NotificationIdentitiesTests {
    @Test func remembersIdentifiersCaseInsensitivelyUpToCapacity() {
        let identities = NotificationIdentities()

        #expect(identities.insert("abc"))
        #expect(!identities.insert("ABC"))
        #expect(identities.contains("Abc"))
        for index in 0..<NotificationIdentities.capacity {
            identities.insert("id-\(index)")
        }

        #expect(!identities.contains("abc"))
        #expect(identities.contains("id-0"))
    }
}
