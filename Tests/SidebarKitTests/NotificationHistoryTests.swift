import Foundation
@testable import SidebarKit
import SidebarProtocol
import Testing

@MainActor
struct NotificationHistoryTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func restoresUnexpiredNotificationsInDisplayOrder() {
        let store = InMemoryStore([
            SidebarNotification(source: "s", title: "old-normal", receivedAt: start.addingTimeInterval(-3600)),
            SidebarNotification(source: "s", title: "expired", severity: .critical, receivedAt: start.addingTimeInterval(-SidebarModel.retention - 1)),
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

        now = start.addingTimeInterval(SidebarModel.retention + 1)
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
            SidebarNotification(source: "cli", title: "t", subtitle: "s", body: "b", severity: .critical,
                                action: .run(command: "ls", workingDirectory: "/"), receivedAt: start),
            SidebarNotification(source: "Mail", title: "m", action: .activateApp(name: "Mail"), shownByMacOS: true, receivedAt: start),
            SidebarNotification(source: "URL", title: "u", action: .open(URL(string: "https://a.example")!), receivedAt: start),
        ]

        store.save(notifications)

        #expect(store.load() == notifications)
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
