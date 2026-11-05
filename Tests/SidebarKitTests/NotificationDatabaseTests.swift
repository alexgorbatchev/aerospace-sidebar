import Foundation
@testable import SidebarKit
import SQLite3
import Testing

/// A notification database shaped like macOS's, in a temporary directory, with memory-only preferences.
final class NotificationDatabaseFixture {
    let directory: TemporaryDirectory
    let database: NotificationDatabase
    let defaults = InMemoryPreferences()

    init() throws {
        directory = try TemporaryDirectory()
        database = NotificationDatabase(url: directory.url.appendingPathComponent("db2/db"))
    }

    func create() throws {
        try FileManager.default.createDirectory(at: database.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR);
            CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, request_date REAL, delivered_date REAL);
            INSERT INTO app VALUES (1, 'com.apple.scripteditor2'), (2, 'com.example.missing');
            """)
    }

    /// Adds a record the way usernoted stores one: the request texts in a binary property list, with the category
    /// the app declared for it or, as for an NSUserNotification, its own actions.
    @discardableResult
    func insert(
        identifier: UUID = UUID(),
        app: Int = 1,
        title: String = "Title",
        subtitle: String? = nil,
        body: String = "Body",
        delivered: Date? = Date(timeIntervalSinceReferenceDate: 800_000_000),
        category: String? = nil,
        actions: [[String: Any]]? = nil,
        data: Data? = nil
    ) throws -> UUID {
        var request: [String: Any] = ["titl": title, "body": body]
        request["subt"] = subtitle
        request["cate"] = category
        request["scat"] = actions.map { ["id": "LEGACY", "acts": $0] }
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

    /// Records the categories an app declared, as usernoted keeps them.
    func declare(_ categories: [[String: Any]], app: Int = 1) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: categories, format: .binary, options: 0)
        try execute("""
            CREATE TABLE IF NOT EXISTS categories (app_id INTEGER PRIMARY KEY, categories BLOB);
            INSERT INTO categories VALUES (\(app), x'\(data.map { String(format: "%02x", $0) }.joined())');
            """)
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

    /// Records come by delivery, whatever order they were added in; a scheduled one only once it is due, and
    /// one without a delivery date or any text never.
    @Test func readsNotificationsDeliveredAfterADate() throws {
        try fixture.create()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try fixture.insert(title: "Old", delivered: start)
        let scheduled = try fixture.insert(title: "Scheduled", delivered: now.addingTimeInterval(60))
        let later = try fixture.insert(app: 2, title: "Later", delivered: start + 20)
        let new = try fixture.insert(title: "New", subtitle: "Sub", body: "Text", delivered: start + 10)
        try fixture.insert(title: "Undelivered", delivered: nil)
        try fixture.insert(title: "Unset", delivered: Date(timeIntervalSinceReferenceDate: 0))
        try fixture.insert(title: "", body: "", delivered: start + 30)
        try fixture.insert(delivered: start + 30, data: Data("not a property list".utf8))

        #expect(try fixture.database.notifications(deliveredAfter: start, by: now) == [
            DeliveredNotification(
                identifier: new.uuidString, bundleIdentifier: "com.apple.scripteditor2",
                title: "New", subtitle: "Sub", body: "Text", deliveredAt: start + 10
            ),
            DeliveredNotification(
                identifier: later.uuidString, bundleIdentifier: "com.example.missing",
                title: "Later", subtitle: "", body: "Body", deliveredAt: start + 20
            ),
        ])
        #expect(try fixture.database.notifications(deliveredAfter: .distantPast, by: now).map(\.title) == ["Old", "New", "Later"])
        let due = try fixture.database.notifications(deliveredAfter: start + 20, by: now.addingTimeInterval(60))
        #expect(due.map(\.identifier) == [scheduled.uuidString])
        #expect(try fixture.database.latestDelivery(by: now) == start + 30)
        #expect(try fixture.database.latestDelivery(by: now.addingTimeInterval(60)) == now.addingTimeInterval(60))
    }

    @Test func emptyDatabaseHasNoRecords() throws {
        try fixture.create()

        #expect(try fixture.database.latestDelivery(by: now) == nil)
        #expect(try fixture.database.notifications(deliveredAfter: .distantPast, by: now).isEmpty)
    }

    @Test func reportsAnUnreadableDatabase() throws {
        #expect(throws: NotificationDatabase.Failure.self) { try fixture.database.latestDelivery(by: now) }
        #expect(throws: NotificationDatabase.Failure.self) { try fixture.database.notifications(deliveredAfter: .distantPast, by: now) }

        try FileManager.default.createDirectory(at: fixture.database.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: fixture.database.url)
        let error = try #require(throws: NotificationDatabase.Failure.self) { try fixture.database.latestDelivery(by: now) }
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
        var statuses: [NotificationDatabaseStatus] = []
        /// The choices reported for notifications listed before.
        var choices: [SidebarNotification.NativeChoices] = []
    }

    func makeMonitor(_ harness: Harness, grace: TimeInterval = 3, readRetryDelay: TimeInterval = 1) -> NotificationDatabaseMonitor {
        NotificationDatabaseMonitor(
            database: fixture.database,
            identities: identities,
            defaults: fixture.defaults,
            grace: grace,
            installedApp: { $0 == "com.apple.scripteditor2" ? InstalledApps.App(name: "Script Editor", bundleIdentifier: "com.apple.ScriptEditor2") : nil },
            now: { harness.now },
            readRetryDelay: readRetryDelay,
            onStatus: { harness.statuses.append($0) },
            onChoices: { harness.choices.append(.init(identifier: $0, choices: $1)) }
        ) { harness.received.append($0) }
    }

    /// The first launch starts after the newest delivered record; later records wait out the grace period,
    /// and those a banner already reported are skipped. Cards name the installed app by its own bundle
    /// identifier, not the lowercase one the database stores.
    @Test func listsRecordsNoBannerReported() throws {
        try fixture.create()
        let harness = Harness()
        let delivered = harness.now - 5
        try fixture.insert(title: "History", delivered: delivered - 5)
        let monitor = makeMonitor(harness)
        monitor.start()
        defer { monitor.stop() }
        #expect(monitor.status == .reading)

        let focus = try fixture.insert(title: "During Focus", subtitle: "Sub", delivered: delivered)
        identities.insert(try fixture.insert(title: "Shown as a banner", delivered: delivered).uuidString)
        let system = try fixture.insert(app: 2, title: "From macOS", delivered: delivered + 1)
        monitor.readNewRecords()
        monitor.deliverPending()
        #expect(harness.received.isEmpty)

        harness.now += 3
        monitor.deliverPending()

        #expect(harness.received.map(\.title) == ["During Focus", "From macOS"])
        #expect(harness.received.map(\.source) == ["Script Editor", SystemNotificationInterceptor.systemSource])
        #expect(harness.received.map(\.action) == [.activateApp(name: "Script Editor"), nil])
        #expect(harness.received.map(\.bundleIdentifier) == ["com.apple.ScriptEditor2", nil])
        // A card opens its notification from the history, which knows it by the record's UUID.
        #expect(harness.received.map(\.nativeIdentifiers) == [[focus.uuidString], [system.uuidString]])
        #expect(harness.received.first?.subtitle == "Sub")
        #expect(harness.received.first?.receivedAt == delivered)
    }

    /// A record no banner showed, such as one delivered during Focus, is listed with the choices it names: an
    /// NSUserNotification's own, its actions menu's header left out, or those of the category its app declared.
    /// Its card performs them on the notification in the history, by the record's UUID.
    @Test func listsRecordsWithTheChoicesTheyName() throws {
        try fixture.create()
        try fixture.declare([NativeChoicesTests.slackCategory])
        let harness = Harness()
        let monitor = makeMonitor(harness, grace: 0)
        monitor.start()
        defer { monitor.stop() }

        let menu = try fixture.insert(title: "Menu", delivered: harness.now - 3, actions: NativeChoicesTests.menuActions)
        let reply = try fixture.insert(title: "Reply", delivered: harness.now - 2, category: "CATEGORY_1")
        try fixture.insert(title: "Plain", delivered: harness.now - 1)
        monitor.readNewRecords()
        monitor.deliverPending()

        #expect(harness.received.map(\.nativeChoices) == [
            .init(identifier: menu.uuidString, choices: ["Now", "Later today", NativeChoice(title: "Tomorrow", isDestructive: true)]),
            .init(identifier: reply.uuidString, choices: [
                NativeChoice(title: "Reply", textInput: NativeChoice.TextInput(placeholder: "Message", sendTitle: "Reply")),
            ]),
            nil,
        ])
        #expect(harness.choices.isEmpty)
    }

    /// A record whose notification a banner reported, before the record was read or while it waited for its
    /// banner, is not listed again; the choices it names are reported once instead, since that card may lack them.
    /// Records naming none, records whose choices do not read (the app's categories are missing here), and
    /// permission requests report nothing.
    @Test func reportsTheChoicesOfRecordsListedBefore() throws {
        try fixture.create()
        try fixture.execute("INSERT INTO app VALUES (3, '\(NotificationDatabaseMonitor.permissionRequestApp)')")
        let harness = Harness()
        let monitor = makeMonitor(harness)
        monitor.start()
        defer { monitor.stop() }

        let shown = try fixture.insert(title: "Shown", delivered: harness.now - 5, actions: NativeChoicesTests.menuActions)
        identities.insert(shown.uuidString)
        identities.insert(try fixture.insert(title: "Plain", delivered: harness.now - 5).uuidString)
        identities.insert(try fixture.insert(title: "Unreadable", delivered: harness.now - 5, category: "reply").uuidString)
        identities.insert(try fixture.insert(app: 3, title: "Asks", delivered: harness.now - 5, actions: [["id": "ACTION", "ti": "Allow"]]).uuidString)
        let waiting = try fixture.insert(title: "Waiting", delivered: harness.now - 4, actions: [["id": "ACTION", "ti": "Approve"]])
        monitor.readNewRecords()
        #expect(harness.choices.map(\.identifier) == [shown.uuidString])

        identities.insert(waiting.uuidString)
        monitor.readNewRecords()
        harness.now += 3
        monitor.deliverPending()
        let reported: [SidebarNotification.NativeChoices] = [
            .init(identifier: shown.uuidString, choices: ["Now", "Later today", NativeChoice(title: "Tomorrow", isDestructive: true)]),
            .init(identifier: waiting.uuidString, choices: ["Approve"]),
        ]
        #expect(harness.choices == reported)

        monitor.readNewRecords()
        #expect(harness.received.isEmpty)
        #expect(harness.choices == reported)
    }

    /// macOS's request to let an app post notifications is its question, not a notification: a card for it
    /// would answer it when clicked, so it is never listed.
    @Test func skipsPermissionRequests() throws {
        try fixture.create()
        try fixture.execute("INSERT INTO app VALUES (3, '\(NotificationDatabaseMonitor.permissionRequestApp)')")
        let harness = Harness()
        let monitor = makeMonitor(harness, grace: 0)
        monitor.start()
        defer { monitor.stop() }

        let request = try fixture.insert(app: 3, title: "“Slack” Notifications")
        try fixture.insert(title: "After")
        monitor.readNewRecords()
        monitor.deliverPending()

        #expect(harness.received.map(\.title) == ["After"])
        #expect(identities.insert(request.uuidString))
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

    /// usernoted gives a new record the id of a newest record it deleted (an app withdrew its notification),
    /// and a rewritten store starts its ids over; records are read by delivery date, so neither hides one.
    @Test func listsRecordsWhateverTheirIDs() throws {
        try fixture.create()
        let harness = Harness()
        let monitor = makeMonitor(harness, grace: 0)
        monitor.start()
        defer { monitor.stop() }

        try fixture.insert(title: "Read", delivered: harness.now - 6)
        try fixture.insert(title: "Withdrawn", delivered: harness.now - 5)
        monitor.readNewRecords()
        monitor.deliverPending()
        harness.now += 10
        try fixture.execute("DELETE FROM record WHERE rec_id = 2")
        // Takes id 2 again.
        try fixture.insert(title: "Reusing its id", delivered: harness.now - 5)
        monitor.readNewRecords()
        monitor.deliverPending()
        harness.now += 10
        try fixture.execute("DELETE FROM record")
        try fixture.insert(title: "In a rewritten store", delivered: harness.now - 5)
        monitor.readNewRecords()
        monitor.deliverPending()

        #expect(harness.received.map(\.title) == ["Read", "Withdrawn", "Reusing its id", "In a rewritten store"])
    }

    /// A scheduled notification's record waits, without a delivery date or with one still ahead, while later
    /// records are read, and is listed once usernoted delivers it, also when it was the newest record at the
    /// first launch.
    @Test func listsScheduledNotificationsOnceDelivered() throws {
        try fixture.create()
        let harness = Harness()
        try fixture.insert(title: "History", delivered: harness.now - 60)
        let meeting = try fixture.insert(title: "Meeting", delivered: nil)
        let monitor = makeMonitor(harness, grace: 0)
        monitor.start()
        defer { monitor.stop() }

        try fixture.insert(title: "Reminder", delivered: harness.now + 1800)
        harness.now += 600
        try fixture.insert(title: "Chat", delivered: harness.now - 5)
        monitor.readNewRecords()
        monitor.deliverPending()
        harness.now += 3600
        try fixture.execute("""
            UPDATE record SET delivered_date = \(harness.now.timeIntervalSinceReferenceDate - 5)
            WHERE hex(uuid) = '\(meeting.uuidString.replacingOccurrences(of: "-", with: ""))'
            """)
        monitor.readNewRecords()
        monitor.deliverPending()

        #expect(harness.received.map(\.title) == ["Chat", "Reminder", "Meeting"])
    }

    /// usernoted writes records seconds after delivering them, several at a time, so one can arrive after a
    /// record delivered later; reads look back far enough to list it, and list every record once.
    @Test func listsRecordsWrittenAfterLaterOnes() throws {
        try fixture.create()
        let harness = Harness()
        let monitor = makeMonitor(harness, grace: 0)
        monitor.start()
        defer { monitor.stop() }

        try fixture.insert(title: "Later", delivered: harness.now - 2)
        monitor.readNewRecords()
        monitor.deliverPending()
        try fixture.insert(title: "Earlier", delivered: harness.now - 8)
        monitor.readNewRecords()
        monitor.readNewRecords()
        monitor.deliverPending()
        monitor.readNewRecords()
        monitor.deliverPending()

        #expect(harness.received.map(\.title) == ["Later", "Earlier"])
    }

    /// A record still waiting for its banner when the monitor stops, or when the app quits or crashes, is
    /// read again when it starts, also one delivered more than `lookback` before the newest record read with it.
    @Test func listsRecordsStillWaitingWhenStopped() throws {
        try fixture.create()
        let harness = Harness()
        let monitor = makeMonitor(harness)
        monitor.start()
        try fixture.insert(title: "Stopped earlier", delivered: harness.now - 120)
        try fixture.insert(title: "Stopped", delivered: harness.now - 5)
        monitor.readNewRecords()
        monitor.stop()

        monitor.start()
        harness.now += 3
        monitor.deliverPending()
        monitor.stop()
        #expect(harness.received.map(\.title) == ["Stopped earlier", "Stopped"])

        harness.now += 600
        do {
            let crashed = makeMonitor(harness)
            crashed.start()
            try fixture.insert(title: "Crashed earlier", delivered: harness.now - 120)
            try fixture.insert(title: "Crashed", delivered: harness.now - 5)
            crashed.readNewRecords()
        }
        let relaunched = makeMonitor(harness)
        relaunched.start()
        defer { relaunched.stop() }
        harness.now += 3
        relaunched.deliverPending()

        #expect(harness.received.map(\.title) == ["Stopped earlier", "Stopped", "Crashed earlier", "Crashed"])
    }

    /// A read position ahead of a clock set back while the sidebar was not running moves back to `lookback`
    /// before the clock, so records delivered just before the launch, and after it, are listed.
    @Test func readsOnAfterTheClockIsSetBack() throws {
        try fixture.create()
        let harness = Harness()
        fixture.defaults.set(harness.now + 3600, forKey: NotificationDatabaseMonitor.readPositionKey)
        try fixture.insert(title: "Before launch", delivered: harness.now - 30)
        let monitor = makeMonitor(harness, grace: 0)
        monitor.start()
        defer { monitor.stop() }
        monitor.deliverPending()

        harness.now += 10
        try fixture.insert(title: "After", delivered: harness.now - 5)
        monitor.readNewRecords()
        monitor.deliverPending()

        #expect(harness.received.map(\.title) == ["Before launch", "After"])
    }

    /// A clock set back while the monitor reads lists the record whose write woke the read and the one still
    /// waiting for its banner from before, and leaves the read position behind the clock, so records delivered
    /// while the sidebar is quit are listed at the next launch.
    @Test func readsOnWhenTheClockIsSetBackWhileRunning() throws {
        try fixture.create()
        let harness = Harness()
        let monitor = makeMonitor(harness)
        monitor.start()
        try fixture.insert(title: "Before", delivered: harness.now - 5)
        monitor.readNewRecords()
        harness.now += 3
        monitor.deliverPending()
        try fixture.insert(title: "Waiting", delivered: harness.now - 5)
        monitor.readNewRecords()

        harness.now -= 3600
        try fixture.insert(title: "After", delivered: harness.now - 5)
        monitor.readNewRecords()
        harness.now += 3
        monitor.deliverPending()
        harness.now += 3
        monitor.deliverPending()
        monitor.stop()
        #expect(harness.received.map(\.title) == ["Before", "After", "Waiting"])

        harness.now += 600
        try fixture.insert(title: "While quit", delivered: harness.now - 300)
        let relaunched = makeMonitor(harness)
        relaunched.start()
        defer { relaunched.stop() }
        harness.now += 3
        relaunched.deliverPending()

        #expect(harness.received.map(\.title) == ["Before", "After", "Waiting", "While quit"])
    }

    /// A clock set back by little more than `lookback` can stay ahead of the read position while falling
    /// behind the newest record read; a record delivered between the two is still listed.
    @Test func noticesAClockSetBackBehindTheNewestRecordRead() throws {
        try fixture.create()
        let harness = Harness()
        let monitor = makeMonitor(harness, grace: 0)
        monitor.start()
        defer { monitor.stop() }
        try fixture.insert(title: "Before", delivered: harness.now - 5)
        monitor.readNewRecords()
        monitor.deliverPending()

        harness.now -= 60
        try fixture.insert(title: "After", delivered: harness.now - 6)
        monitor.readNewRecords()
        monitor.deliverPending()

        #expect(harness.received.map(\.title) == ["Before", "After"])
    }

    /// A database that cannot be opened is tried again until it opens; one that fails a read is reported but
    /// still watched, since only missing access stops reading.
    @Test func waitsForTheDatabase() throws {
        let harness = Harness()
        let monitor = makeMonitor(harness)

        monitor.start()
        monitor.open()
        #expect(monitor.status == .unreadable)
        #expect(monitor.isWaitingForAccess)

        try fixture.create()
        monitor.open()
        #expect(monitor.status == .reading)
        #expect(!monitor.isWaitingForAccess)

        try fixture.execute("DROP TABLE app")
        monitor.readNewRecords()
        #expect(monitor.status == .unreadable)
        #expect(!monitor.isWaitingForAccess)

        monitor.stop()
        #expect(harness.statuses == [.unreadable, .reading, .unreadable, .stopped])
    }

    /// `checkAccess` opens a database it waits for at once, and reads one it watches.
    @Test func checksAccessOnRequest() throws {
        let harness = Harness()
        let monitor = makeMonitor(harness, grace: 0)
        monitor.checkAccess()
        #expect(monitor.status == .stopped)

        monitor.start()
        defer { monitor.stop() }
        try fixture.create()
        monitor.checkAccess()
        #expect(monitor.status == .reading)

        try fixture.insert(title: "Checked")
        monitor.checkAccess()
        monitor.deliverPending()
        #expect(harness.received.map(\.title) == ["Checked"])
    }

    /// Only SQLite's `SQLITE_AUTH`, which macOS returns while Full Disk Access is missing, asks for it.
    @Test func tellsMissingAccessFromOtherFailures() {
        let denied = NotificationDatabase.Failure.sqlite(SQLITE_AUTH, message: "authorization denied")
        let missing = NotificationDatabase.Failure.sqlite(SQLITE_CANTOPEN, message: "unable to open database file")

        #expect(denied == .accessDenied("authorization denied") && denied.isAccessDenied)
        #expect(missing == .unreadable("unable to open database file") && !missing.isAccessDenied)
        #expect(denied.description == "Cannot read the notification database: authorization denied")
    }

    /// A read that fails other than for missing access, such as while the database cannot be opened for a moment,
    /// is tried once more shortly after, which lists the record whose write woke it without another write; the
    /// failure is then over and would be logged again. The test runs the retry itself once the database opens
    /// again: racing a short delay failed on a busy machine, when the retry ran before the database was back.
    @Test func retriesAReadThatFailed() async throws {
        try fixture.create()
        let harness = Harness()
        let monitor = NotificationDatabaseMonitor(
            database: fixture.database, identities: identities, defaults: fixture.defaults, grace: 0,
            installedApp: { InstalledApps.App(name: "App", bundleIdentifier: $0) }, readRetryDelay: 3600
        ) { harness.received.append($0) }
        monitor.start()
        defer { monitor.stop() }
        let path = fixture.database.url.path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)

        try fixture.insert(title: "Retried", delivered: Date() - 1)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes(attributes, ofItemAtPath: path) }
        for _ in 0..<1000 where !monitor.isWaitingToRetryRead {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(monitor.status == .unreadable)
        #expect(monitor.lastError != nil)
        try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
        monitor.retryReadNow()
        #expect(!monitor.isWaitingToRetryRead)
        for _ in 0..<300 where harness.received.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(harness.received.map(\.title) == ["Retried"])
        #expect(monitor.status == .reading)
        #expect(monitor.lastError == nil)
    }

    /// A read that keeps failing is tried once more, then left to the next write rather than tried again and
    /// again, and a read that fails while that retry waits adds no retry of its own.
    @Test func triesAFailedReadOnlyOnceMore() async throws {
        try fixture.create()
        fixture.defaults.set(Date.distantPast, forKey: NotificationDatabaseMonitor.readPositionKey)
        // Not started, so nothing but these reads asks the time: no watcher, and no record waits for its banner.
        var reads = 0
        let monitor = NotificationDatabaseMonitor(
            database: fixture.database, identities: identities, defaults: fixture.defaults,
            now: { reads += 1; return Date() }, readRetryDelay: 0.05
        ) { _ in }
        defer { monitor.stop() }
        let path = fixture.database.url.path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes(attributes, ofItemAtPath: path) }

        monitor.readNewRecords()
        monitor.readNewRecords()
        #expect(monitor.status == .unreadable)
        #expect(monitor.isWaitingToRetryRead)
        for _ in 0..<300 where monitor.isWaitingToRetryRead {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Several retry delays: a retry of the retry, or a second retry, would have read by now.
        try await Task.sleep(for: .milliseconds(250))

        #expect(reads == 3)
        #expect(!monitor.isWaitingToRetryRead)
        #expect(monitor.status == .unreadable)
    }

    /// A read waits for a lock another connection holds for a moment, as usernoted does while it checkpoints its
    /// log, rather than failing at once.
    @Test func waitsForALockHeldForAMoment() throws {
        try fixture.create()
        try fixture.insert(title: "Locked")
        let path = fixture.database.url.path
        let locked = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var handle: OpaquePointer?
            sqlite3_open(path, &handle)
            sqlite3_exec(handle, "PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE;", nil, nil, nil)
            locked.signal()
            Thread.sleep(forTimeInterval: Double(Connection.busyTimeout) / 4000)
            sqlite3_exec(handle, "COMMIT;", nil, nil, nil)
            sqlite3_close(handle)
            released.signal()
        }
        locked.wait()

        let records = try fixture.database.notifications(deliveredAfter: .distantPast, by: Date())

        #expect(records.map(\.title) == ["Locked"])
        released.wait()
    }

    /// A write to the database wakes the monitor, which lists the record once its grace period ends.
    @Test func watchesTheDatabaseForNewRecords() async throws {
        try fixture.create()
        let harness = Harness()
        let monitor = NotificationDatabaseMonitor(
            database: fixture.database, identities: identities, defaults: fixture.defaults, grace: 0.05,
            installedApp: { InstalledApps.App(name: "App", bundleIdentifier: $0) }
        ) { harness.received.append($0) }
        monitor.start()
        defer { monitor.stop() }

        try fixture.insert(title: "Live")
        for _ in 0..<300 where harness.received.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(harness.received.map(\.title) == ["Live"])
    }
}

@MainActor
struct NotificationIdentitiesTests {
    /// Saved identities come back in a new instance, oldest first, up to `capacity`.
    @Test func keepsIdentitiesAcrossLaunchesInDefaults() throws {
        let fixture = try NotificationDatabaseFixture()
        let first = NotificationIdentities(defaults: fixture.defaults)
        first.insert("a")
        first.insert("b")

        let relaunched = NotificationIdentities(defaults: fixture.defaults)
        #expect(relaunched.contains("A"))
        #expect(!relaunched.insert("b"))

        fixture.defaults.set((0...NotificationIdentities.capacity).map { "ID-\($0)" }, forKey: NotificationIdentities.defaultsKey)
        let trimmed = NotificationIdentities(defaults: fixture.defaults)
        #expect(!trimmed.contains("id-0"))
        #expect(trimmed.contains("id-\(NotificationIdentities.capacity)"))
        #expect(!NotificationIdentities().contains("a"))
    }

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
