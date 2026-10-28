import AppKit
import os

/// Lists notifications from the notification database that no banner showed.
///
/// Each new record waits `grace` seconds for the accessibility path to report its banner, and is listed
/// only if it did not. The id of the newest record read is kept in `defaults`, so notifications delivered
/// while the sidebar was not running are listed at the next launch; the first launch starts from the
/// newest record rather than importing the whole history. Without Full Disk Access the database cannot be
/// read, and the monitor tries again every `accessRetryInterval` seconds.
@MainActor
public final class NotificationDatabaseMonitor {
    nonisolated static let logger = Logger(category: "database")
    static let recordIDKey = "notificationDatabaseRecordID"
    static let accessRetryInterval: TimeInterval = 5

    public private(set) var isReadable = false

    private let database: NotificationDatabase
    private let identities: NotificationIdentities
    private let defaults: UserDefaults
    private let grace: TimeInterval
    private let appName: @MainActor (String) -> String?
    private let now: () -> Date
    private let onNotification: @MainActor (SidebarNotification) -> Void
    private var watcher: FileWatcher?
    private var retryTimer: Timer?
    private var deliveryTimer: Timer?
    private var pending: [(notification: DeliveredNotification, readAt: Date)] = []
    private var lastError: NotificationDatabase.Failure?

    /// - Parameters:
    ///   - grace: How long a new record waits for its banner before it is listed. macOS writes a record 5–7 s
    ///     after delivering it, while a banner is reported within about a second, so a short grace suffices.
    ///   - appName: The display name of the app with a bundle identifier, or nil for none installed.
    public init(
        database: NotificationDatabase,
        identities: NotificationIdentities,
        defaults: UserDefaults = .standard,
        grace: TimeInterval = 1,
        appName: @escaping @MainActor (String) -> String? = InstalledApps.name,
        now: @escaping () -> Date = Date.init,
        onNotification: @escaping @MainActor (SidebarNotification) -> Void
    ) {
        self.database = database
        self.identities = identities
        self.defaults = defaults
        self.grace = grace
        self.appName = appName
        self.now = now
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
        isReadable = false
    }

    /// Whether the monitor is waiting for Full Disk Access.
    var isWaitingForAccess: Bool { retryTimer != nil }

    /// Starts reading once the database opens, or tries again later.
    func open() {
        let latest: Int64
        do {
            latest = try database.latestRecordID()
        } catch {
            log(error)
            isReadable = false
            if retryTimer == nil {
                retryTimer = Timer.scheduledTimer(withTimeInterval: Self.accessRetryInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.open() }
                }
            }
            return
        }
        retryTimer?.invalidate()
        retryTimer = nil
        isReadable = true
        lastError = nil
        Self.logger.info("Reading the notification database")
        // A recreated database starts its record ids over.
        if defaults.object(forKey: Self.recordIDKey) == nil || recordID > latest {
            recordID = latest
        }
        let watcher = FileWatcher(url: database.logURL, delay: .milliseconds(200)) { [weak self] in
            self?.readNewRecords()
        }
        watcher.start()
        self.watcher = watcher
        readNewRecords()
    }

    /// Queues the records added since the last read.
    func readNewRecords() {
        let records: [DeliveredNotification]
        do {
            records = try database.notifications(after: recordID, deliveredBy: now())
        } catch {
            log(error)
            return
        }
        guard let last = records.last else { return }
        recordID = last.recordID
        let readAt = now()
        // How late the read is after delivery, and after macOS wrote the log, shows whether a delay comes
        // from macOS or from watching the file.
        let deliveredAgo = readAt.timeIntervalSince(last.deliveredAt)
        let writtenAgo = FileWatcher.signature(of: database.logURL).map {
            readAt.timeIntervalSince1970 - (Double($0.modified) + Double($0.modifiedNanoseconds) / 1e9)
        }
        Self.logger.info("""
            Read \(records.map(\.identifier), privacy: .public); newest delivered \(deliveredAgo, format: .fixed(precision: 1), privacy: .public) s \
            ago, log written \(writtenAgo ?? -1, format: .fixed(precision: 1), privacy: .public) s ago
            """)
        pending += records.map { ($0, readAt) }
        scheduleDelivery()
    }

    /// Lists the queued records whose grace period is over and that no banner reported.
    func deliverPending() {
        let cutoff = now().addingTimeInterval(-grace)
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

    private var recordID: Int64 {
        get { (defaults.object(forKey: Self.recordIDKey) as? NSNumber)?.int64Value ?? 0 }
        set { defaults.set(NSNumber(value: newValue), forKey: Self.recordIDKey) }
    }

    /// Logs each distinct failure once, so a missing permission does not flood the log every retry.
    private func log(_ error: NotificationDatabase.Failure) {
        guard error != lastError else { return }
        lastError = error
        Self.logger.error("\(error.description, privacy: .public)")
    }
}
