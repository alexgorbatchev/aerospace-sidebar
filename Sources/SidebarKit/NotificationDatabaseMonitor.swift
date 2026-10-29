import AppKit
import os

/// Whether `NotificationDatabaseMonitor` lists notifications that showed no banner.
public enum NotificationDatabaseStatus: Equatable, Sendable {
    /// Not started, or stopped because macOS notifications are left to macOS.
    case stopped
    case reading
    /// macOS refuses access until Full Disk Access is granted; the monitor tries again meanwhile.
    case needsFullDiskAccess
    /// The database cannot be read for another reason, such as a macOS update changing it.
    case unreadable
}

/// Lists notifications from the notification database that no banner showed.
///
/// Each new record waits `grace` seconds for the accessibility path to report its banner, and is listed
/// only if it did not. Records are read by delivery date, each read starting `lookback` before the newest
/// record read; `identities` tells which of them were listed or showed a banner already. The read position
/// is kept in `defaults`, never past a record still waiting for its banner, so notifications delivered while
/// the sidebar was not running, or still waiting when it quit, are listed at the next launch; the first
/// launch starts from the newest delivered record rather than importing the whole history. Without Full Disk
/// Access the database cannot be read, and the monitor tries again every `accessRetryInterval` seconds;
/// access taken away while reading shows when the next read fails, or at once through `checkAccess()`.
@MainActor
public final class NotificationDatabaseMonitor {
    nonisolated static let logger = Logger(category: "database")
    static let readPositionKey = "notificationDatabaseDeliveredAfter"
    static let accessRetryInterval: TimeInterval = 5
    /// How far before the newest record read the next read starts. usernoted writes records 5–7 s after
    /// delivering them, several at a time, and fills in a scheduled notification's delivery date only when it
    /// delivers it, so a record can reach the database after one delivered later than it.
    static let lookback: TimeInterval = 60
    /// The app macOS posts its requests to let an app send notifications as. Such a request is macOS's
    /// question, not a notification; listing it would offer a click that answers it.
    static let permissionRequestApp = "com.apple.notificationcenter.askpermissions"

    public private(set) var status = NotificationDatabaseStatus.stopped {
        didSet {
            if status != oldValue {
                onStatus(status)
            }
        }
    }

    private let database: NotificationDatabase
    private let identities: NotificationIdentities
    private let defaults: UserDefaults
    private let grace: TimeInterval
    private let appName: @MainActor (String) -> String?
    private let now: () -> Date
    private let onStatus: @MainActor (NotificationDatabaseStatus) -> Void
    private let onNotification: @MainActor (SidebarNotification) -> Void
    private var watcher: FileWatcher?
    private var retryTimer: Timer?
    private var deliveryTimer: Timer?
    private var pending: [(notification: DeliveredNotification, readAt: Date)] = []
    /// When the newest record read was delivered.
    private var newestDelivery: Date?
    private var lastError: NotificationDatabase.Failure?

    /// - Parameters:
    ///   - grace: How long a new record waits for its banner before it is listed. macOS writes a record 5–7 s
    ///     after delivering it, while a banner is reported within about a second, so a short grace suffices.
    ///   - appName: The display name of the app with a bundle identifier, or nil for none installed.
    ///   - onStatus: Called with each change of `status`.
    public init(
        database: NotificationDatabase,
        identities: NotificationIdentities,
        defaults: UserDefaults = .standard,
        grace: TimeInterval = 1,
        appName: @escaping @MainActor (String) -> String? = InstalledApps.name,
        now: @escaping () -> Date = Date.init,
        onStatus: @escaping @MainActor (NotificationDatabaseStatus) -> Void = { _ in },
        onNotification: @escaping @MainActor (SidebarNotification) -> Void
    ) {
        self.database = database
        self.identities = identities
        self.defaults = defaults
        self.grace = grace
        self.appName = appName
        self.now = now
        self.onStatus = onStatus
        self.onNotification = onNotification
    }

    isolated deinit {
        retryTimer?.invalidate()
        deliveryTimer?.invalidate()
    }

    public func start() {
        guard watcher == nil, retryTimer == nil else { return }
        open()
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        retryTimer?.invalidate()
        retryTimer = nil
        deliveryTimer?.invalidate()
        deliveryTimer = nil
        pending = []
        status = .stopped
    }

    /// Checks the database now rather than at the next retry or change, such as after Full Disk Access was
    /// removed.
    public func checkAccess() {
        guard status != .stopped else { return }
        if watcher == nil {
            open()
        } else {
            readNewRecords()
        }
    }

    /// Whether the monitor is waiting for Full Disk Access.
    var isWaitingForAccess: Bool { retryTimer != nil }

    /// Starts reading once the database opens, or tries again later.
    func open() {
        let latest: Date?
        do {
            latest = try database.latestDelivery(by: now())
        } catch {
            failed(error)
            retryLater()
            return
        }
        retryTimer?.invalidate()
        retryTimer = nil
        status = .reading
        lastError = nil
        Self.logger.info("Reading the notification database")
        if readPosition == nil {
            readPosition = latest ?? .distantPast
        }
        let watcher = FileWatcher(url: database.logURL, delay: .milliseconds(200)) { [weak self] in
            self?.readNewRecords()
        }
        watcher.start()
        self.watcher = watcher
        readNewRecords()
    }

    /// Queues the records delivered since the last read that are neither listed, reported by a banner nor
    /// queued already. Nothing is read before `open()` sets the read position.
    func readNewRecords() {
        let readAt = now()
        guard var position = readPosition else { return }
        // A clock that runs forward stays ahead of the read position and the newest record read. Once it is set
        // back behind either, records delivered since carry earlier dates and would be skipped until it caught
        // up, the one whose write woke this read included, so reading starts over `lookback` before the clock.
        if position > readAt || newestDelivery.map({ $0 > readAt }) == true {
            position = min(position, readAt.addingTimeInterval(-Self.lookback))
            readPosition = position
            newestDelivery = nil
        }
        let records: [DeliveredNotification]
        do {
            records = try database.notifications(deliveredAfter: position, by: readAt)
        } catch {
            failed(error)
            // Without access, a change to the database would only fail again; opening it is what tells
            // when access is back.
            if error.isAccessDenied {
                retryLater()
            }
            return
        }
        status = .reading
        guard let newest = records.last?.deliveredAt else { return }
        newestDelivery = max(newestDelivery ?? newest, newest)
        defer { advance() }
        // Reads look back, so most records were read before: those listed or reported by a banner are in
        // `identities`, those waiting for their banner in `pending`.
        let new = records.filter { record in
            record.bundleIdentifier != Self.permissionRequestApp && !identities.contains(record.identifier)
                && !pending.contains { $0.notification.identifier == record.identifier }
        }
        guard let last = new.last else { return }
        // How late the read is after delivery, and after macOS wrote the log, shows whether a delay comes
        // from macOS or from watching the file.
        let deliveredAgo = readAt.timeIntervalSince(last.deliveredAt)
        let writtenAgo = FileWatcher.signature(of: database.logURL).map {
            readAt.timeIntervalSince1970 - (Double($0.modified) + Double($0.modifiedNanoseconds) / 1e9)
        }
        Self.logger.info("""
            Read \(new.map(\.identifier), privacy: .public); newest delivered \(deliveredAgo, format: .fixed(precision: 1), privacy: .public) s \
            ago, log written \(writtenAgo ?? -1, format: .fixed(precision: 1), privacy: .public) s ago
            """)
        pending += new.map { ($0, readAt) }
        scheduleDelivery()
    }

    /// Lists the queued records whose grace period is over and that no banner reported.
    func deliverPending() {
        let time = now()
        // A record read before the clock was set back would wait until the clock caught up; it waits from now.
        pending = pending.map { (notification: $0.notification, readAt: min($0.readAt, time)) }
        let cutoff = time.addingTimeInterval(-grace)
        let ready = pending.filter { $0.readAt <= cutoff }.map(\.notification)
        pending.removeAll { $0.readAt <= cutoff }
        for notification in ready where identities.insert(notification.identifier) {
            Self.logger.info("Listing \(notification.identifier, privacy: .public), which showed no banner")
            let name = appName(notification.bundleIdentifier)
            onNotification(SidebarNotification(
                source: name ?? SystemNotificationInterceptor.systemSource,
                title: notification.title,
                subtitle: notification.subtitle,
                body: notification.body,
                bundleIdentifier: name == nil ? nil : notification.bundleIdentifier,
                action: name.map { .activateApp(name: $0) },
                nativeIdentifiers: [notification.identifier],
                receivedAt: notification.deliveredAt
            ))
        }
        advance()
        scheduleDelivery()
    }

    private func scheduleDelivery() {
        guard deliveryTimer == nil, let first = pending.first else { return }
        let delay = max(0, first.readAt.addingTimeInterval(grace).timeIntervalSince(now()))
        deliveryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deliveryTimer = nil
                self?.deliverPending()
            }
        }
    }

    /// Records delivered after this date are read; nil until the first launch opens the database.
    private var readPosition: Date? {
        get { defaults.object(forKey: Self.readPositionKey) as? Date }
        set { defaults.set(newValue, forKey: Self.readPositionKey) }
    }

    /// Moves the read position up to `lookback` before the newest record read, but not past a record still
    /// waiting for its banner, so a relaunch, or a crash, reads that one again. A record still waiting from
    /// before the clock was set back can be dated after the newest record read, which then sets the limit.
    private func advance() {
        guard let newestDelivery, let readPosition else { return }
        let oldest = pending.map(\.notification.deliveredAt).reduce(newestDelivery, min)
        let position = oldest.addingTimeInterval(-Self.lookback)
        if position > readPosition {
            self.readPosition = position
        }
    }

    /// Stops watching the database and tries to open it again every `accessRetryInterval` seconds.
    private func retryLater() {
        watcher?.stop()
        watcher = nil
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: Self.accessRetryInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.open() }
        }
    }

    /// Reports the failure, logging each distinct one once so a missing permission does not flood the log
    /// every retry.
    private func failed(_ error: NotificationDatabase.Failure) {
        status = error.isAccessDenied ? .needsFullDiskAccess : .unreadable
        guard error != lastError else { return }
        lastError = error
        Self.logger.error("\(error.description, privacy: .public)")
    }
}
