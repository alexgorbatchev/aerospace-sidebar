import Foundation
@testable import SidebarKit
import SidebarProtocol
import Testing

@MainActor
struct NotificationHistoryTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    /// Every arrival is received as it came, before rules, newest first with repeats stacked, and stays
    /// after its card is dismissed or cleared, or when a rule hides it.
    @Test func receivesEveryNotificationAsItArrived() {
        let received = InMemoryStore()
        let model = SidebarModel(
            performer: RecordingPerformer(), store: InMemoryStore(), receivedStore: received,
            rules: [SidebarSettings.Rule(source: "Slack", action: .hide), SidebarSettings.Rule(source: "ci", action: .severity(.critical))],
            now: { start }
        )

        model.add(SidebarNotification(source: "ci", title: "Build", receivedAt: start))
        model.add(SidebarNotification(source: "Slack", title: "Hi", receivedAt: start + 1))
        model.add(SidebarNotification(source: "Mail", title: "Lunch", receivedAt: start + 2))
        model.add(SidebarNotification(source: "ci", title: "Build", receivedAt: start + 3))
        model.dismiss(model.notifications.first { $0.title == "Lunch" }!.id)
        model.clear()

        #expect(model.notifications.isEmpty)
        #expect(model.received.map(\.title) == ["Build", "Lunch", "Hi"])
        #expect(model.received.map(\.occurrences) == [2, 1, 1])
        #expect(model.received.map(\.severity) == [.normal, .normal, .normal])
        #expect(received.stored == model.received)
    }

    /// The history limits apply to what was received too, when it loads, as time passes and when they change.
    @Test func receivedNotificationsFollowTheHistoryLimits() {
        var now = start
        let received = InMemoryStore([
            SidebarNotification(source: "s", title: "old", receivedAt: start - 25 * 3600),
            SidebarNotification(source: "s", title: "kept", receivedAt: start - 3600),
            SidebarNotification(source: "s", title: "newer", receivedAt: start - 60),
        ])
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(), receivedStore: received, now: { now })
        #expect(model.received.map(\.title) == ["newer", "kept"])

        now = start + 23.5 * 3600
        model.pruneExpired()
        #expect(model.received.map(\.title) == ["newer"])
        #expect(received.stored.map(\.title) == ["newer"])

        model.add(SidebarNotification(source: "s", title: "latest", receivedAt: now))
        model.apply(history: SidebarSettings.History(retentionHours: 24, maxCount: 1))
        #expect(model.received.map(\.title) == ["latest"])
        #expect(received.stored.map(\.title) == ["latest"])
        model.add(SidebarNotification(source: "s", title: "last", receivedAt: now + 1))
        #expect(model.received.map(\.title) == ["last"])
    }

    @Test func restoresUnexpiredNotificationsInDisplayOrder() {
        let store = InMemoryStore([
            SidebarNotification(source: "s", title: "old-normal", receivedAt: start.addingTimeInterval(-3600)),
            SidebarNotification(source: "s", title: "expired", severity: .critical, receivedAt: start.addingTimeInterval(-SidebarSettings.History().retention - 1)),
            SidebarNotification(source: "s", title: "new-normal", receivedAt: start),
            SidebarNotification(source: "s", title: "high", severity: .high, receivedAt: start.addingTimeInterval(-7200)),
        ])

        let model = SidebarModel(performer: RecordingPerformer(), store: store, now: { self.start })

        #expect(model.notifications.map(\.title) == ["high", "new-normal", "old-normal"])
    }

    @Test func savesEveryChange() {
        let store = InMemoryStore()
        let model = SidebarModel(performer: RecordingPerformer(), store: store)
        let first = SidebarNotification(source: "s", title: "first")

        model.add(first)
        model.add(SidebarNotification(source: "s", title: "second"))
        #expect(store.stored.map(\.title) == ["second", "first"])

        model.dismiss(first.id)
        #expect(store.stored.map(\.title) == ["second"])

        model.clear()
        #expect(store.stored.isEmpty)
        #expect(store.saves == 4)
    }

    @Test func pruneDropsExpiredNotifications() {
        var now = start
        let store = InMemoryStore()
        let model = SidebarModel(performer: RecordingPerformer(), store: store, now: { now })
        model.add(SidebarNotification(source: "s", title: "early", receivedAt: start))
        model.add(SidebarNotification(source: "s", title: "late", receivedAt: start.addingTimeInterval(3600)))

        now = start.addingTimeInterval(SidebarSettings.History().retention + 1)
        model.pruneExpired()
        let savesAfterPrune = store.saves
        model.pruneExpired()

        #expect(model.notifications.map(\.title) == ["late"])
        #expect(store.stored.map(\.title) == ["late"])
        #expect(store.saves == savesAfterPrune)
    }

    @Test func fileStoreRoundTripsEveryField() throws {
        let directory = try TemporaryDirectory()
        let store = FileNotificationStore(url: directory.url.appendingPathComponent("nested/notifications.json"))
        let notifications = [
            SidebarNotification(source: "cli", title: "t", subtitle: "s", body: "b", severity: .critical, postedSeverity: .low,
                                action: .run(command: "ls", workingDirectory: "/"), receivedAt: start),
            SidebarNotification(source: "Mail", title: "m", bundleIdentifier: "com.apple.mail", action: .activateApp(name: "Mail"),
                                shownByMacOS: true, receivedAt: start),
            SidebarNotification(source: "URL", title: "u", action: .open(URL(string: "https://a.example")!), receivedAt: start, occurrences: 4),
            SidebarNotification(source: "macOS", title: "a", nativeAlert: .init(identifier: "A-1", choices: ["Allow…"]),
                                nativeIdentifiers: ["A-1"], receivedAt: start),
        ]

        store.save(notifications)

        #expect(store.load() == notifications)
    }

    /// Entries for notifications that are not alerts have no `nativeAlert` key.
    @Test func fileStoreLoadsEntriesSavedWithoutAlerts() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("notifications.json")
        try Data("""
            [{"id": "05E8D885-F2D3-4170-902C-27F064B139F0", "source": "macOS", "title": "Privacy & Security", "subtitle": "",
              "body": "b", "severity": "normal", "shownByMacOS": true, "nativeIdentifiers": [], "receivedAt": 0, "occurrences": 1}]
            """.utf8).write(to: url)

        let loaded = FileNotificationStore(url: url).load()

        #expect(loaded.map(\.title) == ["Privacy & Security"])
        #expect(loaded.map(\.nativeAlert) == [nil])
    }

    @Test func fileStoreTreatsMissingOrCorruptFileAsEmpty() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("notifications.json")
        let store = FileNotificationStore(url: url)

        #expect(store.load().isEmpty)
        try directory.write("not json", to: "notifications.json")
        #expect(store.load().isEmpty)
    }

    @Test func fileStoreSurvivesUnwritableLocation() {
        let store = FileNotificationStore(url: URL(fileURLWithPath: "/nonexistent-root/notifications.json"))

        store.save([SidebarNotification(source: "s", title: "t")])

        #expect(store.load().isEmpty)
    }

    @Test func defaultLocationIsApplicationSupport() {
        #expect(FileNotificationStore.defaultURL.path.hasSuffix(
            "Library/Application Support/com.alexgorbatchev.aerospace-sidebar/notifications.json"
        ))
        #expect(FileNotificationStore().url == FileNotificationStore.defaultURL)
    }
}
