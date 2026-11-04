import Foundation
@testable import SidebarKit
import SidebarProtocol
import Testing

@MainActor
struct SidebarModelTests {
    /// The dismissed Full Disk Access note stays dismissed after a relaunch.
    @Test func remembersTheDismissedFullDiskAccessNote() throws {
        let fixture = try NotificationDatabaseFixture()
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(), defaults: fixture.defaults)
        #expect(!model.fullDiskAccessNoteDismissed)

        model.dismissFullDiskAccessNote()

        #expect(model.fullDiskAccessNoteDismissed)
        #expect(SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(), defaults: fixture.defaults).fullDiskAccessNoteDismissed)
        let inMemory = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        inMemory.dismissFullDiskAccessNote()
        #expect(inMemory.fullDiskAccessNoteDismissed)
    }

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
        let model = SidebarModel(performer: RecordingPerformer(), store: store, now: { start })
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
        SidebarNotification(source: "s", title: "t", body: "b", bundleIdentifier: "com.example.s"),
        SidebarNotification(source: "s", title: "t", body: "b", invalidIcon: "nope"),
        SidebarNotification(source: "s", title: "t", body: "b", action: .activateApp(name: "s")),
        SidebarNotification(source: "s", title: "t", body: "b", shownByMacOS: true),
        SidebarNotification(source: "s", title: "t", body: "b", nativeChoices: .init(identifier: "a", choices: ["Allow…"])),
    ])
    func keepsNotificationsThatDifferApart(other: SidebarNotification) {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())

        model.add(SidebarNotification(source: "s", title: "t", body: "b"))
        model.add(other)

        #expect(model.notifications.map(\.occurrences) == [1, 1])
    }

    static let repoURL = URL(string: "https://example.com/repo")!

    /// A push with the key of a listed push from its source takes over that card: it keeps its identity, shows the
    /// newer content, counts both and moves up as the newest; `received` keeps one entry per key the same way.
    @Test func keyedPushesReplaceTheirCardAndStack() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let store = InMemoryStore()
        let model = SidebarModel(performer: RecordingPerformer(), store: store, now: { start })
        func push(_ body: String, key: String?, source: String = "aerospace-sidebar", at offset: TimeInterval) -> SidebarNotification {
            SidebarNotification(source: source, title: "repo", body: body, markdown: true, key: key, receivedAt: start + offset)
        }
        let first = push("Turn one", key: "herdr:w1:p1", at: 0)
        model.add(first)
        model.add(push("Other pane", key: "herdr:w1:p2", at: 1))
        model.add(SidebarNotification(source: "aerospace-sidebar", title: "repo", body: "Turn **two**", severity: .high,
                                      icon: .init(id: "codex"), action: .open(Self.repoURL), key: "herdr:w1:p1", receivedAt: start + 2))

        #expect(model.notifications.map(\.body) == ["Turn **two**", "Other pane"])
        let card = model.notifications[0]
        #expect(card.id == first.id)
        #expect(card.occurrences == 2)
        #expect(card.receivedAt == start + 2)
        #expect((card.severity, card.icon, card.action, card.markdown) == (.high, .init(id: "codex"), .open(Self.repoURL), false))
        #expect(store.stored == model.notifications)
        #expect(model.received.map(\.body) == ["Turn **two**", "Other pane"])
        #expect(model.received.map(\.occurrences) == [2, 1])
    }

    /// Keys stack only pushes from one source, so a web page's URL cannot take over a CLI card; a keyed push and an
    /// unkeyed one with the same content stay apart too.
    @Test func keysStackOnlyPushesFromOneSource() {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())

        model.add(SidebarNotification(source: "aerospace-sidebar", title: "t", key: "build"))
        model.add(SidebarNotification(source: "Vivaldi", title: "t", key: "build"))
        model.add(SidebarNotification(source: "aerospace-sidebar", title: "t"))
        model.add(SidebarNotification(source: "aerospace-sidebar", title: "t"))

        #expect(model.notifications.map(\.source) == ["aerospace-sidebar", "Vivaldi", "aerospace-sidebar"])
        #expect(model.notifications.map(\.key) == [nil, "build", "build"])
        #expect(model.notifications.map(\.occurrences) == [2, 1, 1])
    }

    /// A card on which a reply is typed takes no keyed push either; once the reply is done, saved rules restack the
    /// two like arriving pushes. A rule that hides a keyed push leaves the listed card as it was.
    @Test func keyedPushesSpareCardsBeingRepliedOnAndHiddenPushes() throws {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        model.add(SidebarNotification(source: "cli", title: "one", key: "k"))
        let composing = model.notifications[0].id

        model.setComposing(true, on: composing)
        model.add(SidebarNotification(source: "cli", title: "two", key: "k"))
        #expect(model.notifications.map(\.title) == ["two", "one"])
        model.setComposing(false, on: composing)

        model.apply(rules: [SidebarSettings.Rule(title: "secret", action: .hide)])
        #expect(model.notifications.map(\.title) == ["two"])
        #expect(model.notifications.map(\.occurrences) == [2])
        model.add(SidebarNotification(source: "cli", title: "secret", key: "k"))
        #expect(model.notifications.map(\.title) == ["two"])
        #expect(model.received.first?.title == "secret")
    }

    /// The key is saved with the card, so a relaunch keeps stacking onto it; lists saved before keys load without one.
    @Test func savesTheKey() throws {
        let card = SidebarNotification(source: "cli", title: "t", key: "herdr:w1:p1")
        let decoded = try JSONDecoder().decode(SidebarNotification.self, from: JSONEncoder().encode(card))
        #expect(decoded == card)

        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? [String: Any])
        object["key"] = nil
        let legacy = try JSONDecoder().decode(SidebarNotification.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.key == nil)

        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore([decoded]))
        model.add(SidebarNotification(source: "cli", title: "again", key: "herdr:w1:p1"))
        #expect(model.notifications.map(\.title) == ["again"])
        #expect(model.notifications.first?.id == card.id)
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

        model.add(SidebarNotification(source: "s", title: "t", nativeChoices: .init(identifier: "a", choices: ["Allow…"])))
        model.add(SidebarNotification(source: "s", title: "t", nativeChoices: .init(identifier: "b", choices: ["Allow…"])))

        #expect(model.notifications.map(\.nativeChoices?.identifier) == ["b", "a"])
    }

    func alertModel() -> (SidebarModel, RecordingPerformer, RecordingNativeNotifications, SidebarNotification) {
        let performer = RecordingPerformer()
        let alerts = RecordingNativeNotifications()
        let model = SidebarModel(performer: performer, store: InMemoryStore())
        model.nativeNotifications = alerts
        model.interception = .active
        let notification = SidebarNotification(
            source: "Calendar", title: "Standup", bundleIdentifier: "com.apple.iCal", action: .activateApp(name: "Calendar"),
            nativeChoices: .init(identifier: "a", choices: ["Snooze", "Join"]), nativeIdentifiers: ["a"]
        )
        model.add(notification)
        return (model, performer, alerts, notification)
    }

    @Test func choosingPerformsTheChoiceOnTheAlertAndDismissesItsCard() {
        let (model, _, alerts, notification) = alertModel()

        #expect(model.offeredChoices(of: notification) == notification.nativeChoices)
        model.choose("Join", for: notification.id)

        #expect(alerts.performed == ["Join a"])
        #expect(model.notifications.isEmpty)
        #expect(alerts.releases == 1)
    }

    /// A refused choice keeps the card, and a notification known to have lost its choices offers none.
    @Test func keepsTheCardWhenAChoiceCannotBePerformed() {
        let (model, _, alerts, notification) = alertModel()

        model.choose("Delete", for: notification.id)
        alerts.succeeds = false
        model.choose("Join", for: notification.id)
        model.unavailableChoices = ["a"]
        alerts.succeeds = true
        model.choose("Join", for: notification.id)

        #expect(model.offeredChoices(of: notification) == nil)
        #expect(alerts.performed == ["Join a"])
        #expect(model.notifications.count == 1)
    }

    /// A card offers its notification's choices unless they are known gone; never while notifications are not
    /// intercepted, nor for an app whose notifications are switched off, which NotificationCenter keeps nowhere to
    /// act on.
    @Test func offersChoicesUnlessTheyCannotWork() {
        let (model, _, _, notification) = alertModel()
        #expect(model.offeredChoices(of: notification) == notification.nativeChoices)
        #expect(model.offeredChoices(of: SidebarNotification(source: "cli", title: "Plain")) == nil)

        model.unavailableChoices = ["other"]
        #expect(model.offeredChoices(of: notification) == notification.nativeChoices)

        for status in [InterceptionStatus.starting, .disabled, .stopped, .needsAccessibility, .notificationCenterUnavailable] {
            model.interception = status
            #expect(model.offeredChoices(of: notification) == nil)
        }
        model.interception = .active

        model.notificationsAreOff = { $0 == "com.apple.iCal" }
        #expect(model.offeredChoices(of: notification) == nil)
        model.notificationsAreOff = { $0 == "com.example.other" }
        #expect(model.offeredChoices(of: notification) == notification.nativeChoices)
    }

    /// The notification database can name the choices of a notification after its card was listed without them;
    /// that card then offers them where it is, no longer as shown by macOS. Cards with choices, cards standing for
    /// several notifications and notifications without a card are left as they are.
    @Test func offersChoicesTheDatabaseNamedOnTheCardThatLacksThem() throws {
        let store = InMemoryStore()
        let alerts = RecordingNativeNotifications()
        let model = SidebarModel(performer: RecordingPerformer(), store: store)
        model.nativeNotifications = alerts
        model.interception = .active
        model.add(SidebarNotification(source: "alerter", title: "When?", shownByMacOS: true, nativeIdentifiers: ["menu"]))
        for identifier in ["old", "new"] {
            model.add(SidebarNotification(source: "Vivaldi", title: "Alex", nativeIdentifiers: [identifier]))
        }
        model.add(SidebarNotification(source: "Calendar", title: "Standup", nativeChoices: .init(identifier: "a", choices: ["Join"]), nativeIdentifiers: ["a"]))
        let before = model.notifications
        let menu = try #require(before.last)
        let choices: [NativeChoice] = ["Now", "Later today", "Tomorrow"]

        #expect(!model.offer(choices, forNotification: "missing"))
        #expect(!model.offer(choices, forNotification: "new"))
        #expect(!model.offer(choices, forNotification: "a"))
        #expect(model.notifications == before)

        #expect(model.offer(choices, forNotification: "menu"))
        let offered = try #require(model.notifications.last)
        #expect(model.notifications.map(\.id) == before.map(\.id))
        #expect(offered.id == menu.id && offered.receivedAt == menu.receivedAt && offered.title == menu.title)
        #expect(!offered.shownByMacOS)
        #expect(model.offeredChoices(of: offered) == .init(identifier: "menu", choices: choices))
        #expect(store.load() == model.notifications)
        #expect(alerts.releases == 0)
        #expect(!model.offer(["Later"], forNotification: "menu"))

        model.choose("Later today", for: offered.id)
        #expect(alerts.performed == ["Later today menu"])
    }

    /// A choice that asks for text is answered with the text and the app's send button, never as a plain
    /// choice and never empty; while one answer runs, the card takes no other.
    @Test func repliesWithTheTextOneAnswerAtATime() {
        let reply = NativeChoice(title: "Reply", textInput: NativeChoice.TextInput(placeholder: "Message", sendTitle: "Send"))
        let alerts = RecordingNativeNotifications()
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        model.nativeNotifications = alerts
        model.interception = .active
        model.add(SidebarNotification(source: "Slack", title: "Ada", nativeChoices: .init(identifier: "r", choices: [reply, "Later"]), nativeIdentifiers: ["r"]))
        let card = model.notifications[0]

        model.choose("Reply", for: card.id)
        model.reply("Later", text: "x", for: card.id)
        model.reply("Reply", text: "", for: card.id)
        #expect(alerts.performed.isEmpty)

        alerts.heldCompletions = []
        model.reply("Reply", text: "On my way", for: card.id)
        model.choose("Later", for: card.id)
        #expect(alerts.performed == ["Reply r: On my way [Send]"])
        #expect(model.answering == [card.id])

        alerts.heldCompletions?.removeFirst()(true)
        #expect(model.answering.isEmpty)
        #expect(model.notifications.isEmpty)
    }

    /// Clicking the card of a native notification opens the notification, newest first; the card's own
    /// action runs only when none can be opened, whenever that is known. The card goes at once either way.
    @Test func activatingOpensTheNativeNotificationInsteadOfTheCardsAction() {
        let (model, performer, alerts, notification) = alertModel()
        model.activate(notification.id)
        #expect(alerts.performed == ["open a from Calendar"])
        #expect(performer.actions.isEmpty)
        #expect(model.notifications.isEmpty)

        let (refusing, refusingPerformer, refusingAlerts, refused) = alertModel()
        refusingAlerts.heldCompletions = []
        refusing.activate(refused.id)
        #expect(refusing.notifications.isEmpty)
        #expect(refusingPerformer.actions.isEmpty)
        refusingAlerts.heldCompletions?.forEach { $0(false) }
        #expect(refusingPerformer.actions == [.activateApp(name: "Calendar")])
        #expect(refusingPerformer.bundleIdentifiers == ["com.apple.iCal"])

        let performerOnly = RecordingPerformer()
        let unwired = SidebarModel(performer: performerOnly, store: InMemoryStore())
        unwired.add(notification)
        unwired.activate(unwired.notifications[0].id)
        #expect(performerOnly.actions == [.activateApp(name: "Calendar")])

        let repeats = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let opener = RecordingNativeNotifications()
        repeats.nativeNotifications = opener
        for identifier in ["old", "new"] {
            repeats.add(SidebarNotification(source: "Vivaldi", title: "Alex", nativeIdentifiers: [identifier]))
        }
        #expect(repeats.notifications.map(\.nativeIdentifiers) == [["new", "old"]])
        repeats.activate(repeats.notifications[0].id)
        #expect(opener.performed == ["open new old from Vivaldi"])
    }

    /// A card that keeps repeating stands for its newest `maxNativeIdentifiers` notifications only, in the list
    /// and in `received`; the older ones are released, so the next sweep closes those that are still hidden.
    @Test func keepsTheNewestNativeNotificationsOfARepeatingCard() {
        let alerts = RecordingNativeNotifications()
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        model.nativeNotifications = alerts
        let count = SidebarNotification.maxNativeIdentifiers
        for index in 0..<count {
            model.add(SidebarNotification(source: "Vivaldi", title: "Alex", nativeIdentifiers: ["\(index)"]))
        }
        #expect(alerts.releases == 0)

        model.add(SidebarNotification(source: "Vivaldi", title: "Alex", nativeIdentifiers: ["\(count)"]))

        let newest = (1...count).reversed().map(String.init)
        #expect(model.notifications.map(\.nativeIdentifiers) == [newest])
        #expect(model.notifications.map(\.occurrences) == [count + 1])
        #expect(model.received.map(\.nativeIdentifiers) == [newest])
        #expect(!model.lists(notification: "0"))
        #expect(model.lists(notification: "1"))
        #expect(alerts.releases == 1)
    }

    /// Every way a card for an alert leaves the list lets its alert close; other changes do not.
    @Test func releasesAlertsWhenTheirCardsLeaveTheList() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let alerts = RecordingNativeNotifications()
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(), now: { now })
        model.nativeNotifications = alerts
        func addAlert(_ identifier: String, title: String = "t") {
            model.add(SidebarNotification(
                source: "s", title: title, nativeChoices: .init(identifier: identifier, choices: ["Allow…"]),
                nativeIdentifiers: [identifier], receivedAt: now
            ))
        }

        addAlert("a")
        model.add(SidebarNotification(source: "s", title: "plain", receivedAt: now))
        model.dismiss(model.notifications.first { $0.title == "plain" }!.id)
        #expect(alerts.releases == 0)
        #expect(model.lists(notification: "a"))
        model.add(SidebarNotification(source: "s", title: "banner", nativeIdentifiers: ["banner"], receivedAt: now))
        #expect(model.lists(notification: "banner"))
        model.dismiss(model.notifications.first { $0.title == "banner" }!.id)
        #expect(alerts.releases == 1)
        alerts.releases = 0

        model.dismiss(model.notifications[0].id)
        #expect(alerts.releases == 1)
        #expect(!model.lists(notification: "a"))

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

    /// Only a card made with an alert's choices offers them; a card the notification database listed stands
    /// for the same kind of alert without them.
    @Test func tellsCardsThatOfferAnAlertsChoicesFromOthers() {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        model.add(SidebarNotification(
            source: "s", title: "with", nativeChoices: .init(identifier: "a", choices: ["Allow…"]), nativeIdentifiers: ["a"]
        ))
        model.add(SidebarNotification(source: "s", title: "without", nativeIdentifiers: ["b"]))

        #expect(model.lists(choicesOf: "a"))
        #expect(model.lists(notification: "b"))
        #expect(!model.lists(choicesOf: "b"))

        model.dismiss(model.notifications.first { $0.title == "with" }!.id)
        #expect(!model.lists(choicesOf: "a"))
    }

    /// A card restored after a relaunch stands for its notification, and offers its choices once notifications are
    /// intercepted again: nothing saved tells whether they still work.
    @Test func listsAlertsRestoredFromTheSavedList() {
        let saved = SidebarNotification(source: "s", title: "t", nativeChoices: .init(identifier: "a", choices: ["Allow…"]), nativeIdentifiers: ["a"])
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore([saved]))

        #expect(model.lists(notification: "a"))
        #expect(model.offeredChoices(of: saved) == nil)
        model.interception = .active
        #expect(model.offeredChoices(of: saved) == saved.nativeChoices)
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

    @Test func takesTheSendersAppFromThePayload() throws {
        let notification = SidebarNotification(
            payload: try NotificationPayload(title: "t", bundleIdentifier: "com.mitchellh.ghostty"),
            source: "cli",
            icons: .vendored
        )

        #expect(notification.bundleIdentifier == "com.mitchellh.ghostty")
        #expect(notification.icon == nil)
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

    /// A card that stands for a native notification opens it in its app rather than only switching to the app.
    @Test func describesOpeningANativeNotification() {
        let notification = SidebarNotification(source: "Vivaldi", title: "t", action: .activateApp(name: "Vivaldi"), nativeIdentifiers: ["a"])
        #expect(notification.clickDescription == "Click to open in Vivaldi")
    }

    /// macOS records notifications from an app whose notifications are switched off without showing them. They are
    /// not listed unless the settings ask for them, but `received` keeps them, so Settings › Notifications still
    /// lists the app with Allow; pushed notifications naming the app and other apps' notifications are listed.
    @Test func listsSwitchedOffAppsOnlyWhenAsked() {
        let store = InMemoryStore()
        let model = SidebarModel(performer: RecordingPerformer(), store: store)
        model.notificationsAreOff = { $0 == "com.vivaldi.Vivaldi" }
        let off = SidebarNotification(source: "Vivaldi", title: "Off", bundleIdentifier: "com.vivaldi.Vivaldi", nativeIdentifiers: ["a"])
        let on = SidebarNotification(source: "Codex", title: "On", bundleIdentifier: "com.openai.codex", nativeIdentifiers: ["b"])
        let pushed = SidebarNotification(source: "cli", title: "Pushed", bundleIdentifier: "com.vivaldi.Vivaldi")

        #expect(!model.listsSwitchedOffApps)
        for notification in [off, on, pushed] {
            model.add(notification)
        }

        #expect(model.notifications.map(\.title) == ["Pushed", "On"])
        #expect(model.received.map(\.title) == ["Pushed", "On", "Off"])
        #expect(model.arrivals.count == 2)
        #expect(model.arrivals.cards(after: 0) == [on.id, pushed.id])

        model.apply(listsSwitchedOffApps: true)
        let again = SidebarNotification(source: "Vivaldi", title: "Again", bundleIdentifier: "com.vivaldi.Vivaldi", nativeIdentifiers: ["c"])
        model.add(again)

        #expect(model.listsSwitchedOffApps)
        #expect(model.notifications.map(\.title) == ["Again", "Pushed", "On"])
    }

    /// Turning the setting off drops the cards of apps that are switched off now and saves the list; with none
    /// listed, nothing changes.
    @Test func stopsListingSwitchedOffAppsAndDropsTheirCards() {
        let store = InMemoryStore()
        let alerts = RecordingNativeNotifications()
        let model = SidebarModel(performer: RecordingPerformer(), store: store, listsSwitchedOffApps: true)
        model.nativeNotifications = alerts
        model.notificationsAreOff = { $0 == "com.vivaldi.Vivaldi" }
        model.add(SidebarNotification(source: "Vivaldi", title: "Off", bundleIdentifier: "com.vivaldi.Vivaldi", nativeIdentifiers: ["a"]))
        model.add(SidebarNotification(source: "Codex", title: "On", bundleIdentifier: "com.openai.codex", nativeIdentifiers: ["b"]))
        let saves = store.saves

        model.apply(listsSwitchedOffApps: true)
        #expect(store.saves == saves)

        model.apply(listsSwitchedOffApps: false)
        #expect(model.notifications.map(\.title) == ["On"])
        #expect(store.stored.map(\.title) == ["On"])
        #expect(store.saves == saves + 1)
        #expect(!model.lists(notification: "a"))
        #expect(alerts.releases == 1)

        model.apply(listsSwitchedOffApps: false)
        #expect(store.saves == saves + 1)
    }

    /// NotificationCenter never holds notifications from an app whose notifications are switched off, so its
    /// cards switch to the app at once and say why; other apps' cards still open theirs.
    @Test func switchesToAppsWhoseNotificationsAreOff() async {
        let performer = RecordingPerformer()
        let model = SidebarModel(performer: performer, store: InMemoryStore(), listsSwitchedOffApps: true)
        let alerts = RecordingNativeNotifications()
        model.nativeNotifications = alerts
        model.notificationsAreOff = { $0 == "com.vivaldi.Vivaldi" }
        let off = SidebarNotification(
            source: "Vivaldi", title: "Off", bundleIdentifier: "com.vivaldi.Vivaldi",
            action: .activateApp(name: "Vivaldi"), nativeIdentifiers: ["a"]
        )
        let on = SidebarNotification(
            source: "Codex", title: "On", bundleIdentifier: "com.openai.codex", action: .activateApp(name: "Codex"), nativeIdentifiers: ["b"]
        )
        let pushed = SidebarNotification(source: "cli", title: "Pushed", bundleIdentifier: "com.vivaldi.Vivaldi", action: .open(URL(string: "https://a.example")!))

        #expect(model.appNotificationsAreOff(for: off))
        // Only a card from a switched-off app switches its app on.
        var allowed: [String] = []
        model.allowAppNotifications = { allowed.append("\($0) \($1)"); return nil }
        #expect(!model.appNotificationsAreOff(for: on))
        // Pushed notifications never pass through macOS, whatever app they name.
        #expect(!model.appNotificationsAreOff(for: pushed))
        #expect(model.clickDescription(of: off)
            == "Click to switch to Vivaldi\nIts notifications are off in System Settings, so this one cannot open")
        #expect(model.clickDescription(of: on) == "Click to open in Codex")
        #expect(model.clickDescription(of: pushed) == "Click to open https://a.example")

        for notification in [off, on] {
            model.add(notification)
            model.activate(notification.id)
        }

        #expect(alerts.performed == ["open b from Codex"])
        model.add(off)
        model.add(on)
        model.allowAppNotifications(for: on.id)
        model.allowAppNotifications(for: UUID())
        model.allowAppNotifications(for: off.id)
        for _ in 0..<100 where model.allowingAppNotifications != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(allowed == ["com.vivaldi.Vivaldi Vivaldi"])
        #expect(performer.actions == [.activateApp(name: "Vivaldi")])
        #expect(performer.bundleIdentifiers == ["com.vivaldi.Vivaldi"])
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

    /// Text a user typed reaches the command as an environment variable, never as part of its text.
    @Test func runsCommandsWithAddedEnvironment() throws {
        let directory = try TemporaryDirectory()
        let reply = "it's $HOME; `touch hacked`"

        let process = try WorkspaceActionPerformer.run(
            #"printf '%s|%s|%s' "$AEROSPACE_SIDEBAR_CHOICE" "$AEROSPACE_SIDEBAR_REPLY" "$HOME" > choice.txt"#,
            in: directory.url.path,
            environment: ["AEROSPACE_SIDEBAR_CHOICE": "Note", "AEROSPACE_SIDEBAR_REPLY": reply]
        )
        process.waitUntilExit()

        let written = try String(contentsOf: directory.url.appendingPathComponent("choice.txt"), encoding: .utf8)
        #expect(written == "Note|\(reply)|\(NSHomeDirectory())")
        #expect(!FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("hacked").path))
    }

    @Test func performingAChoiceStartsItsCommand() async throws {
        let directory = try TemporaryDirectory()
        let marker = directory.url.appendingPathComponent("Deploy")

        WorkspaceActionPerformer().run(#"touch "$AEROSPACE_SIDEBAR_CHOICE""#, in: directory.url.path, environment: ["AEROSPACE_SIDEBAR_CHOICE": "Deploy"])

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    /// A command is started only where it was asked to run.
    @Test func refusesMissingWorkingDirectories() {
        #expect(throws: (any Error).self) { try WorkspaceActionPerformer.run("true", in: "/nonexistent-directory") }
    }

    /// A command is never started with a NUL character, which `Process` would raise as an Objective-C exception
    /// that aborts the app. It runs in a process of its own, which such an exception ends.
    @Test func refusesNULCharactersInsteadOfAborting() async {
        await #expect(processExitsWith: .success) {
            let directory = try TemporaryDirectory()
            for (command, workingDirectory, environment) in [
                ("touch marker\u{0}", directory.url.path, [:]),
                ("touch marker", directory.url.path + "\u{0}", [:]),
                ("touch marker", directory.url.path, ["AEROSPACE_SIDEBAR_REPLY": "a\u{0}b"]),
                ("touch marker", directory.url.path, ["A\u{0}": "b"]),
            ] {
                do {
                    try await MainActor.run { _ = try WorkspaceActionPerformer.run(command, in: workingDirectory, environment: environment) }
                    exit(EXIT_FAILURE)
                } catch let error as CocoaError where error.code == .fileReadInvalidFileName {}
            }
            guard try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty else { exit(EXIT_FAILURE) }
        }
    }

    @Test func runsWithLoginShell() {
        #expect(WorkspaceActionPerformer.loginShell == String(cString: getpwuid(getuid()).pointee.pw_shell))
    }

    @Test func performingRunStartsCommand() async throws {
        let directory = try TemporaryDirectory()
        let marker = directory.url.appendingPathComponent("performed.txt")

        WorkspaceActionPerformer().perform(.run(command: "touch performed.txt", workingDirectory: directory.url.path), bundleIdentifier: nil)

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func failingCommandsDoNotThrowFromPerform() throws {
        WorkspaceActionPerformer().perform(.run(command: "exit 3", workingDirectory: "/"), bundleIdentifier: nil)
        WorkspaceActionPerformer().perform(.run(command: "true", workingDirectory: "/nonexistent-directory"), bundleIdentifier: nil)
        WorkspaceActionPerformer().perform(.activateApp(name: "No Such App \(UUID())"), bundleIdentifier: nil)
        WorkspaceActionPerformer().perform(.activateApp(name: "No Such App"), bundleIdentifier: "com.example.no-such-app-\(UUID())")
    }

    /// The app a card switches to is the one that posted its notification, found by bundle identifier, which
    /// LaunchServices launches when it is not running, as clicking the notification in macOS would. A running
    /// copy comes before the one LaunchServices prefers, since two copies can share a bundle identifier. Only
    /// without a bundle identifier is a running app found by name.
    @Test func switchesToTheAppThatPostedTheNotification() async throws {
        let calendar = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        let mail = URL(fileURLWithPath: "/System/Applications/Mail.app")
        let directory = try TemporaryDirectory()
        let release = directory.url.appendingPathComponent("Xcode.app")
        let beta = directory.url.appendingPathComponent("Xcode-beta.app")
        let opened = Mutable<[URL]>([])
        let performer = WorkspaceActionPerformer(
            applicationURL: { ["com.apple.iCal": calendar, "com.apple.dt.Xcode": release][$0] },
            runningApplications: {
                [(name: "Mail", bundleIdentifier: "com.apple.mail", url: mail), (name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", url: beta)]
            },
            openApplication: { url in
                opened.value.append(url)
                if url == mail { throw CocoaError(.fileReadNoPermission) }
            }
        )

        await performer.activateApp(named: "Calendar", bundleIdentifier: "com.apple.iCal")?.value
        await performer.activateApp(named: "Mail", bundleIdentifier: nil)?.value
        await performer.activateApp(named: "Mail", bundleIdentifier: "com.apple.mail")?.value
        await performer.activateApp(named: "Xcode", bundleIdentifier: "com.apple.dt.Xcode")?.value

        #expect(opened.value == [calendar, mail, mail, beta])
        #expect(performer.activateApp(named: "Gone", bundleIdentifier: "com.example.gone") == nil)
        #expect(performer.activateApp(named: "Gone", bundleIdentifier: nil) == nil)
    }

    /// A helper without a user interface stands for the app around it: Chromium browsers post their alerts
    /// from one (Google Chrome Helper (Alerts), whose Info.plist sets `LSUIElement` to the string "1"), and
    /// opening it would leave the browser where it is. An app with a user interface inside another one, such
    /// as Simulator inside Xcode, and an agent of its own are opened as they are.
    @Test func opensTheAppAroundAHelperWithoutAUserInterface() async throws {
        let directory = try TemporaryDirectory()
        func app(_ path: String, _ keys: String = "") throws -> URL {
            try directory.write("""
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict><key>CFBundlePackageType</key><string>APPL</string>\(keys)</dict></plist>
                """, to: "\(path)/Contents/Info.plist")
            return directory.url.appendingPathComponent(path, isDirectory: true)
        }
        let browser = try app("Browser.app")
        let alerts = try app(
            "Browser.app/Contents/Frameworks/Browser Framework.framework/Helpers/Browser Helper (Alerts).app",
            "<key>LSUIElement</key><string>1</string>"
        )
        let updater = try app("Browser.app/Contents/Frameworks/Updater.framework/Updater.app", "<key>LSBackgroundOnly</key><true/>")
        let simulator = try app("IDE.app/Contents/Developer/Applications/Simulator.app")
        let agent = try app("Agent.app", "<key>LSUIElement</key><true/>")
        _ = try app("IDE.app")

        #expect(WorkspaceActionPerformer.app(standingFor: alerts).path == browser.path)
        #expect(WorkspaceActionPerformer.app(standingFor: updater).path == browser.path)
        #expect(WorkspaceActionPerformer.app(standingFor: browser).path == browser.path)
        #expect(WorkspaceActionPerformer.app(standingFor: simulator).path == simulator.path)
        #expect(WorkspaceActionPerformer.app(standingFor: agent).path == agent.path)

        let opened = Mutable<[URL]>([])
        let performer = WorkspaceActionPerformer(
            applicationURL: { _ in nil },
            runningApplications: { [(name: "Browser Helper (Alerts)", bundleIdentifier: "com.example.browser.framework.AlertNotificationService", url: alerts)] },
            openApplication: { opened.value.append($0) }
        )
        await performer.activateApp(named: "Browser", bundleIdentifier: "com.example.browser.framework.AlertNotificationService")?.value
        #expect(opened.value.map(\.path) == [browser.path])
    }
}

/// Choices pushed with a notification: commands, link buttons and asks.
@MainActor
struct PushedChoicesTests {
    static let directory = "/repo"
    static let logs = URL(string: "https://ci.example/logs")!

    static func choices() throws -> [PushedChoice] {
        [
            try PushedChoice(title: "Deploy", action: .run(command: "make deploy", workingDirectory: directory)),
            try PushedChoice(title: "Note", action: .run(command: "echo \"$AEROSPACE_SIDEBAR_REPLY\"", workingDirectory: directory), asksForText: true),
            try PushedChoice(title: "Logs", action: .open(logs)),
        ]
    }

    static func ask(_ title: String = "Deploy?", receivedAt: Date = Date()) throws -> SidebarNotification {
        SidebarNotification(source: "aerospace-sidebar", title: title, pushedChoices: [
            try PushedChoice(title: "Yes", action: .answer),
            try PushedChoice(title: "Why?", action: .answer, asksForText: true),
        ], receivedAt: receivedAt)
    }

    /// A command learns which choice started it, and the text sent with it, only through its environment.
    @Test func runsCommandsWithTheChoiceAndReplyInTheirEnvironment() throws {
        let performer = RecordingPerformer()
        let model = SidebarModel(performer: performer, store: InMemoryStore())
        for title in ["one", "two", "three"] {
            model.add(SidebarNotification(source: "cli", title: title, pushedChoices: try Self.choices()))
        }
        let (three, two, one) = (model.notifications[0], model.notifications[1], model.notifications[2])

        // A choice that asks for text needs its field, text within the limit and without NUL, which no
        // environment can carry, and only it takes a reply.
        model.choose("Note", for: one.id)
        model.reply("Note", text: "", for: one.id)
        model.reply("Note", text: String(repeating: "x", count: PushedChoice.maxReplyLength + 1), for: one.id)
        model.reply("Note", text: "pasted\u{0}text", for: one.id)
        model.reply("Deploy", text: "x", for: one.id)
        #expect(performer.runs.isEmpty)
        #expect(model.notifications.count == 3)

        model.choose("Deploy", for: one.id)
        model.reply("Note", text: "ship it; rm -rf /", for: two.id)
        model.choose("Logs", for: three.id)

        #expect(performer.runs == [
            .init(command: "make deploy", workingDirectory: Self.directory, environment: ["AEROSPACE_SIDEBAR_CHOICE": "Deploy"]),
            .init(command: "echo \"$AEROSPACE_SIDEBAR_REPLY\"", workingDirectory: Self.directory, environment: [
                "AEROSPACE_SIDEBAR_CHOICE": "Note", "AEROSPACE_SIDEBAR_REPLY": "ship it; rm -rf /",
            ]),
        ])
        #expect(performer.actions == [.open(Self.logs)])
        #expect(model.notifications.isEmpty)
    }

    /// Pushed choices show like a native notification's, a reply field with a Send button; a native
    /// notification's choices come first while it offers them.
    @Test func cardsShowPushedChoices() throws {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let pushed = SidebarNotification(source: "cli", title: "t", pushedChoices: try Self.choices())

        #expect(model.cardChoices(of: pushed) == [
            NativeChoice(title: "Deploy"),
            NativeChoice(title: "Note", textInput: NativeChoice.TextInput(sendTitle: "Send")),
            NativeChoice(title: "Logs"),
        ])
        let native = SidebarNotification(source: "Calendar", title: "t", nativeChoices: .init(identifier: "a", choices: ["Allow…"]), nativeIdentifiers: ["a"])
        #expect(model.cardChoices(of: native).isEmpty)
        model.interception = .active
        #expect(model.cardChoices(of: native) == ["Allow…"])
        #expect(model.cardChoices(of: SidebarNotification(source: "cli", title: "plain")).isEmpty)
    }

    @Test func answersTheAskerOnce() throws {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let chosen = RecordingAsker()
        let replied = RecordingAsker()
        model.ask(try Self.ask("one"), asker: chosen)
        model.ask(try Self.ask("two"), asker: replied)

        model.choose("Yes", for: model.notifications[1].id)
        model.reply("Why?", text: "tests are red", for: model.notifications[0].id)

        #expect(chosen.answers == [.answered(choice: "Yes", reply: nil)])
        #expect(replied.answers == [.answered(choice: "Why?", reply: "tests are red")])
        #expect(model.notifications.isEmpty)
    }

    /// Every way a card goes without an answer tells its asker, once.
    @Test func cardsThatGoWithoutAnAnswerAnswerDismissed() throws {
        let now = Mutable(Date())
        let model = SidebarModel(
            performer: RecordingPerformer(), store: InMemoryStore(), history: SidebarSettings.History(retentionHours: 1, maxCount: 10),
            rules: [SidebarSettings.Rule(title: "spam", action: .hide)], now: { now.value }
        )
        func asked(_ title: String, receivedAt: Date? = nil) throws -> (RecordingAsker, SidebarNotification.ID) {
            let asker = RecordingAsker()
            let notification = try Self.ask(title, receivedAt: receivedAt ?? now.value)
            model.ask(notification, asker: asker)
            return (asker, notification.id)
        }
        func isListed(_ id: SidebarNotification.ID) -> Bool { model.notifications.contains { $0.id == id } }

        let (hidden, hiddenID) = try asked("spam")
        #expect(hidden.answers == [.dismissed])
        #expect(!isListed(hiddenID))
        let (old, oldID) = try asked("old", receivedAt: now.value.addingTimeInterval(-2 * 3600))
        #expect(old.answers == [.dismissed])
        #expect(!isListed(oldID))

        let (dismissed, dismissedID) = try asked("dismissed")
        model.dismiss(dismissedID)
        let (clicked, clickedID) = try asked("clicked")
        model.activate(clickedID)
        let (ruled, _) = try asked("ruled out")
        model.apply(rules: [SidebarSettings.Rule(title: "ruled", action: .hide)])
        let (cleared, _) = try asked("cleared")
        model.clear()
        let (expired, expiredID) = try asked("expired")
        #expect(isListed(expiredID))
        now.value = now.value.addingTimeInterval(2 * 3600)
        model.pruneExpired()
        let (dropped, droppedID) = try asked("dropped")
        #expect(isListed(droppedID))
        for index in 0..<10 {
            #expect(dropped.answers.isEmpty)
            model.add(SidebarNotification(source: "cli", title: "\(index)", severity: .high, receivedAt: now.value))
        }
        #expect(!isListed(droppedID))
        #expect(model.notifications.count == 10)

        for asker in [dismissed, clicked, ruled, cleared, expired, dropped] {
            #expect(asker.answers == [.dismissed])
        }
    }

    /// An asker that stops waiting takes its card with it, unanswered.
    @Test func askersThatHangUpWithdrawTheirCards() throws {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let asker = RecordingAsker()
        model.ask(try Self.ask(), asker: asker)
        model.add(SidebarNotification(source: "cli", title: "other"))

        asker.hangUp()
        asker.hangUp()

        #expect(model.notifications.map(\.title) == ["other"])
        #expect(asker.answers.isEmpty)
    }

    /// The same body as markdown and as plain text shows differently, so the two never stack; a pushed payload
    /// keeps its flag on its card.
    @Test func stacksOnlyBodiesShownAlike() throws {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let markdown = try NotificationPayload(title: "build", body: "**done**", markdown: true)
        let card = SidebarNotification(payload: markdown, source: "cli", icons: AppIconFont(ids: []))
        #expect(card.markdown)

        model.add(card)
        model.add(SidebarNotification(payload: markdown, source: "cli", icons: AppIconFont(ids: [])))
        model.add(SidebarNotification(source: "cli", title: "build", body: "**done**"))

        #expect(model.notifications.map(\.occurrences).sorted() == [1, 2])
        #expect(model.notifications.filter(\.markdown).map(\.occurrences) == [2])
    }

    /// Each ask has its own asker, so identical asks never stack; other pushed notifications stack only with the
    /// same choices.
    @Test func stacksOnlyNotificationsWithTheSameChoices() throws {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let first = RecordingAsker()
        let second = RecordingAsker()
        model.ask(try Self.ask(), asker: first)
        model.ask(try Self.ask(), asker: second)
        #expect(model.notifications.count == 2)
        #expect(model.received.count == 2)

        let choices = try Self.choices()
        model.add(SidebarNotification(source: "cli", title: "build", pushedChoices: choices))
        model.add(SidebarNotification(source: "cli", title: "build", pushedChoices: choices))
        model.add(SidebarNotification(source: "cli", title: "build", pushedChoices: Array(choices.prefix(1))))
        #expect(model.notifications.filter { $0.title == "build" }.map(\.occurrences) == [1, 2])
        #expect(first.answers.isEmpty && second.answers.isEmpty)
    }

    /// A stack gets a new card, which would drop a reply being typed on the old one, so cards being replied on
    /// neither take repeats nor stack onto other cards, also when saved rules restack the list.
    @Test func cardsBeingRepliedOnDoNotStack() throws {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let choices = try Self.choices()
        func build() -> SidebarNotification { SidebarNotification(source: "cli", title: "build", pushedChoices: choices) }
        model.add(build())
        let composing = model.notifications[0].id

        model.setComposing(true, on: composing)
        model.add(build())
        #expect(model.notifications.map(\.occurrences) == [1, 1])
        model.apply(rules: [])
        #expect(model.notifications.map(\.occurrences) == [1, 1])
        #expect(model.notifications.contains { $0.id == composing })

        model.setComposing(false, on: composing)
        model.add(build())
        #expect(model.notifications.map(\.occurrences) == [2, 1])
    }

    /// A relaunch loses the askers, so restored cards keep only the choices that do not answer one.
    @Test func restoredCardsDropTheChoicesThatAnswerAsks() throws {
        let link = try PushedChoice(title: "Logs", action: .open(Self.logs))
        let ask = try Self.ask()
        let mixed = SidebarNotification(source: "cli", title: "mixed", pushedChoices: [link])
        let store = InMemoryStore([ask, mixed])

        let model = SidebarModel(performer: RecordingPerformer(), store: store)

        let restored = try #require(model.notifications.first { $0.id == ask.id })
        #expect(restored.pushedChoices.isEmpty)
        #expect(model.clickDescription(of: restored) == "Click to dismiss")
        #expect(model.notifications.first { $0.id == mixed.id }?.pushedChoices == [link])
    }

    @Test func describesWhatEachChoiceDoes() throws {
        let notification = SidebarNotification(
            source: "cli", title: "t", action: .open(Self.logs), pushedChoices: try Self.choices() + [PushedChoice(title: "Yes", action: .answer)]
        )

        #expect(notification.clickDescription == """
            Click to open https://ci.example/logs
            Deploy runs in /repo:
            make deploy
            Note asks for text, then runs in /repo:
            echo "$AEROSPACE_SIDEBAR_REPLY"
            Logs opens https://ci.example/logs
            """)
        #expect(try Self.ask().clickDescription == "Click to dismiss without answering")
    }
}
