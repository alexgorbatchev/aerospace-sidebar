import Foundation
@testable import SidebarKit
import SidebarProtocol
import Testing

@MainActor
struct SidebarModelTests {
    @Test func ordersBySeverityThenRecency() {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let names: [(String, NotificationSeverity)] = [
            ("normal-1", .normal), ("critical-1", .critical), ("low-1", .low), ("high-1", .high), ("normal-2", .normal), ("critical-2", .critical),
        ]

        for (title, severity) in names {
            model.add(SidebarNotification(source: "test", title: title, severity: severity))
        }

        #expect(model.notifications.map(\.title) == ["critical-2", "critical-1", "high-1", "normal-2", "normal-1", "low-1"])
    }

    @Test func dropsLeastSevereOldestBeyondCap() {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        model.add(SidebarNotification(source: "test", title: "critical", severity: .critical))
        for index in 0..<SidebarSettings.History().maxCount {
            model.add(SidebarNotification(source: "test", title: "low-\(index)", severity: .low))
        }

        #expect(model.notifications.count == SidebarSettings.History().maxCount)
        #expect(model.notifications.first?.title == "critical")
        #expect(!model.notifications.contains { $0.title == "low-0" })
    }

    @Test func stacksIdenticalNotificationsAsNewest() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let store = InMemoryStore()
        let model = SidebarModel(performer: RecordingPerformer(), store: store)
        let first = SidebarNotification(source: "ci", title: "Build failed", body: "main", receivedAt: start)
        model.add(first)
        model.add(SidebarNotification(source: "ci", title: "Deploy done", receivedAt: start.addingTimeInterval(1)))
        model.add(SidebarNotification(source: "ci", title: "Build failed", body: "main", receivedAt: start.addingTimeInterval(2)))
        model.add(SidebarNotification(source: "ci", title: "Build failed", body: "main", receivedAt: start.addingTimeInterval(3)))

        #expect(model.notifications.map(\.title) == ["Build failed", "Deploy done"])
        #expect(model.notifications.map(\.occurrences) == [3, 1])
        #expect(model.notifications.first?.id == first.id)
        #expect(model.notifications.first?.receivedAt == start.addingTimeInterval(3))
        #expect(store.stored == model.notifications)
    }

    @Test(arguments: [
        SidebarNotification(source: "other", title: "t", body: "b"),
        SidebarNotification(source: "s", title: "other", body: "b"),
        SidebarNotification(source: "s", title: "t", subtitle: "other", body: "b"),
        SidebarNotification(source: "s", title: "t", body: "other"),
        SidebarNotification(source: "s", title: "t", body: "b", severity: .high),
        SidebarNotification(source: "s", title: "t", body: "b", icon: .init(id: "slack")),
        SidebarNotification(source: "s", title: "t", body: "b", invalidIcon: "nope"),
        SidebarNotification(source: "s", title: "t", body: "b", action: .activateApp(name: "s")),
        SidebarNotification(source: "s", title: "t", body: "b", shownByMacOS: true),
        SidebarNotification(source: "s", title: "t", body: "b", nativeAlert: .init(identifier: "a", choices: ["Allow…"])),
    ])
    func keepsNotificationsThatDifferApart(other: SidebarNotification) {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())

        model.add(SidebarNotification(source: "s", title: "t", body: "b"))
        model.add(other)

        #expect(model.notifications.map(\.occurrences) == [1, 1])
    }

    @Test func dismissingStackRemovesEveryOccurrence() {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        model.add(SidebarNotification(source: "s", title: "again"))
        model.add(SidebarNotification(source: "s", title: "again"))

        model.dismiss(model.notifications[0].id)

        #expect(model.notifications.isEmpty)
    }

    @Test func dismissAndClearRemoveNotifications() {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let first = SidebarNotification(source: "a", title: "first")
        let second = SidebarNotification(source: "b", title: "second")
        model.add(first)
        model.add(second)

        model.dismiss(first.id)
        #expect(model.notifications == [second])

        model.clear()
        #expect(model.notifications.isEmpty)
    }

    @Test func activatePerformsActionAndDismisses() {
        let performer = RecordingPerformer()
        let model = SidebarModel(performer: performer, store: InMemoryStore())
        let withAction = SidebarNotification(source: "cli", title: "run", action: .run(command: "make", workingDirectory: "/tmp"))
        let plain = SidebarNotification(source: "cli", title: "plain")
        model.add(withAction)
        model.add(plain)

        model.activate(withAction.id)
        model.activate(plain.id)
        model.activate(UUID())

        #expect(performer.actions == [.run(command: "make", workingDirectory: "/tmp")])
        #expect(model.notifications.isEmpty)
    }

    /// Two alerts with the same text still need their own cards, since each answers its own alert.
    @Test func neverStacksDifferentAlerts() {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())

        model.add(SidebarNotification(source: "s", title: "t", nativeAlert: .init(identifier: "a", choices: ["Allow…"])))
        model.add(SidebarNotification(source: "s", title: "t", nativeAlert: .init(identifier: "b", choices: ["Allow…"])))

        #expect(model.notifications.map(\.nativeAlert?.identifier) == ["b", "a"])
    }

    func alertModel(present: Set<String> = ["a"]) -> (SidebarModel, RecordingPerformer, RecordingAlerts, SidebarNotification) {
        let performer = RecordingPerformer()
        let alerts = RecordingAlerts()
        let model = SidebarModel(performer: performer, store: InMemoryStore())
        model.alerts = alerts
        model.presentAlerts = present
        let notification = SidebarNotification(
            source: "Calendar", title: "Standup", action: .activateApp(name: "Calendar"),
            nativeAlert: .init(identifier: "a", choices: ["Snooze", "Join"])
        )
        model.add(notification)
        return (model, performer, alerts, notification)
    }

    @Test func choosingPerformsTheChoiceOnTheAlertAndDismissesItsCard() {
        let (model, _, alerts, notification) = alertModel()

        #expect(model.presentAlert(of: notification) == notification.nativeAlert)
        model.choose("Join", for: notification.id)

        #expect(alerts.performed == ["Join a"])
        #expect(model.notifications.isEmpty)
        #expect(alerts.releases == 1)
    }

    /// Choices exist only while the alert does, and a refused choice keeps the card.
    @Test func keepsTheCardWhenAChoiceCannotBePerformed() {
        let (model, _, alerts, notification) = alertModel()

        model.choose("Delete", for: notification.id)
        alerts.succeeds = false
        model.choose("Join", for: notification.id)
        model.presentAlerts = []
        alerts.succeeds = true
        model.choose("Join", for: notification.id)

        #expect(model.presentAlert(of: notification) == nil)
        #expect(alerts.performed == ["Join a"])
        #expect(model.notifications.count == 1)
    }

    /// Clicking the card of a present alert clicks the alert; otherwise the card's own action runs.
    @Test func activatingOpensThePresentAlertInsteadOfTheCardsAction() {
        let (model, performer, alerts, notification) = alertModel()
        model.activate(notification.id)
        #expect(alerts.performed == ["open a"])
        #expect(performer.actions.isEmpty)
        #expect(model.notifications.isEmpty)

        let (refusing, refusingPerformer, refusingAlerts, refused) = alertModel()
        refusingAlerts.succeeds = false
        refusing.activate(refused.id)
        #expect(refusingPerformer.actions == [.activateApp(name: "Calendar")])

        let (gone, gonePerformer, goneAlerts, absent) = alertModel(present: [])
        gone.activate(absent.id)
        #expect(goneAlerts.performed.isEmpty)
        #expect(gonePerformer.actions == [.activateApp(name: "Calendar")])
    }

    /// Every way a card for an alert leaves the list lets its alert close; other changes do not.
    @Test func releasesAlertsWhenTheirCardsLeaveTheList() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let alerts = RecordingAlerts()
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(), now: { now })
        model.alerts = alerts
        func addAlert(_ identifier: String, title: String = "t") {
            model.add(SidebarNotification(source: "s", title: title, nativeAlert: .init(identifier: identifier, choices: ["Allow…"]), receivedAt: now))
        }

        addAlert("a")
        model.add(SidebarNotification(source: "s", title: "plain", receivedAt: now))
        model.dismiss(model.notifications.first { $0.title == "plain" }!.id)
        #expect(alerts.releases == 0)
        #expect(model.lists(alert: "a"))

        model.dismiss(model.notifications[0].id)
        #expect(alerts.releases == 1)
        #expect(!model.lists(alert: "a"))

        addAlert("b")
        model.clear()
        #expect(alerts.releases == 2)

        addAlert("c")
        now += SidebarSettings.History().retention + 1
        model.pruneExpired()
        #expect(alerts.releases == 3)

        addAlert("d")
        for index in 1...10 {
            model.add(SidebarNotification(source: "s", title: "n\(index)", receivedAt: now.addingTimeInterval(TimeInterval(index))))
        }
        #expect(alerts.releases == 3)
        model.apply(history: SidebarSettings.History(maxCount: 10))
        #expect(alerts.releases == 4)
    }

    @Test func listsAlertsRestoredFromTheSavedList() {
        let saved = SidebarNotification(source: "s", title: "t", nativeAlert: .init(identifier: "a", choices: ["Allow…"]))
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore([saved]))

        #expect(model.lists(alert: "a"))
        #expect(model.presentAlert(of: saved) == nil)
    }

    @Test func applyingHistoryLimitsDropsWhatTheyNoLongerAllow() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = InMemoryStore()
        let model = SidebarModel(performer: RecordingPerformer(), store: store, now: { now })
        for index in 0..<20 {
            model.add(SidebarNotification(source: "s", title: "n\(index)", receivedAt: now.addingTimeInterval(TimeInterval(-index * 3600))))
        }
        now = now.addingTimeInterval(60)

        model.apply(history: SidebarSettings.History(retentionHours: 12, maxCount: 10))

        #expect(model.notifications.map(\.title) == (0..<10).map { "n\($0)" })
        #expect(store.stored.count == 10)
        #expect(model.history.retentionHours == 12)
    }

    @Test func mapsPayloadActions() throws {
        let date = Date(timeIntervalSince1970: 1)
        let open = try NotificationPayload(title: "t", severity: .high, action: .open(URL(string: "https://a.example")!))
        let run = try NotificationPayload(body: "b", action: .run(command: "ls", workingDirectory: "/"))

        let opened = SidebarNotification(payload: open, source: "url", icons: .vendored, receivedAt: date)
        let ran = SidebarNotification(payload: run, source: "cli", icons: .vendored)

        #expect(opened.action == .open(URL(string: "https://a.example")!))
        #expect(opened.severity == .high)
        #expect(opened.receivedAt == date)
        #expect(ran.action == .run(command: "ls", workingDirectory: "/"))
        #expect(SidebarNotification(payload: try NotificationPayload(title: "t"), source: "x", icons: .vendored).action == nil)
    }

    @Test func resolvesPayloadIcon() throws {
        let notification = SidebarNotification(
            payload: try NotificationPayload(title: "t", body: "b", icon: ":Slack:"),
            source: "cli",
            icons: .vendored
        )

        #expect(notification.icon == SidebarNotification.Icon(id: "slack"))
        #expect(notification.invalidIcon == nil)
        #expect(notification.body == "b")
    }

    @Test func keepsUnknownIconApartFromTheText() throws {
        let notification = SidebarNotification(
            payload: try NotificationPayload(title: "t", body: "b", icon: ":nope:"),
            source: "cli",
            icons: .vendored
        )

        #expect(notification.icon == nil)
        #expect(notification.invalidIcon == ":nope:")
        #expect(notification.body == "b")
    }

    @Test(arguments: [
        (nil, "Click to dismiss"),
        (SidebarNotification.ClickAction.open(URL(string: "https://a.example")!), "Click to open https://a.example"),
        (.run(command: "make test", workingDirectory: "/repo"), "Click to run in /repo:\nmake test"),
        (.activateApp(name: "Mail"), "Click to switch to Mail"),
    ])
    func describesClickBeforeItHappens(action: SidebarNotification.ClickAction?, description: String) {
        #expect(SidebarNotification(source: "s", title: "t", action: action).clickDescription == description)
    }
}

@MainActor
struct WorkspaceActionPerformerTests {
    @Test func runsCommandInWorkingDirectory() throws {
        let directory = try TemporaryDirectory()

        let process = try WorkspaceActionPerformer.run("echo ran > marker.txt", in: directory.url.path)
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: directory.url.appendingPathComponent("marker.txt"), encoding: .utf8) == "ran\n")
    }

    @Test func runsWithLoginShell() {
        #expect(WorkspaceActionPerformer.loginShell == String(cString: getpwuid(getuid()).pointee.pw_shell))
    }

    @Test func performingRunStartsCommand() async throws {
        let directory = try TemporaryDirectory()
        let marker = directory.url.appendingPathComponent("performed.txt")

        WorkspaceActionPerformer().perform(.run(command: "touch performed.txt", workingDirectory: directory.url.path))

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func failingCommandsDoNotThrowFromPerform() throws {
        WorkspaceActionPerformer().perform(.run(command: "exit 3", workingDirectory: "/"))
        WorkspaceActionPerformer().perform(.run(command: "true", workingDirectory: "/nonexistent-directory"))
        WorkspaceActionPerformer().perform(.activateApp(name: "No Such App \(UUID())"))
    }
}
