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

    func alertModel(present: Set<String> = ["a"]) -> (SidebarModel, RecordingPerformer, RecordingNativeNotifications, SidebarNotification) {
        let performer = RecordingPerformer()
        let alerts = RecordingNativeNotifications()
        let model = SidebarModel(performer: performer, store: InMemoryStore())
        model.nativeNotifications = alerts
        model.presentChoices = present
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

    /// Choices exist only while the alert does, and a refused choice keeps the card.
    @Test func keepsTheCardWhenAChoiceCannotBePerformed() {
        let (model, _, alerts, notification) = alertModel()

        model.choose("Delete", for: notification.id)
        alerts.succeeds = false
        model.choose("Join", for: notification.id)
        model.presentChoices = []
        alerts.succeeds = true
        model.choose("Join", for: notification.id)

        #expect(model.offeredChoices(of: notification) == nil)
        #expect(alerts.performed == ["Join a"])
        #expect(model.notifications.count == 1)
    }

    /// A choice that asks for text is answered with the text and the app's send button, never as a plain
    /// choice and never empty; while one answer runs, the card takes no other.
    @Test func repliesWithTheTextOneAnswerAtATime() {
        let reply = NativeChoice(title: "Reply", textInput: NativeChoice.TextInput(placeholder: "Message", sendTitle: "Send"))
        let alerts = RecordingNativeNotifications()
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        model.nativeNotifications = alerts
        model.presentChoices = ["r"]
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

    @Test func listsAlertsRestoredFromTheSavedList() {
        let saved = SidebarNotification(source: "s", title: "t", nativeChoices: .init(identifier: "a", choices: ["Allow…"]), nativeIdentifiers: ["a"])
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore([saved]))

        #expect(model.lists(notification: "a"))
        #expect(model.offeredChoices(of: saved) == nil)
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

    /// NotificationCenter never holds notifications from an app whose notifications are switched off, so its
    /// cards switch to the app at once and say why; other apps' cards still open theirs.
    @Test func switchesToAppsWhoseNotificationsAreOff() {
        let performer = RecordingPerformer()
        let model = SidebarModel(performer: performer, store: InMemoryStore())
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

        #expect(model.clickDescription(of: off)
            == "Click to switch to Vivaldi\nIts notifications are off in System Settings, so this one cannot open")
        #expect(model.clickDescription(of: on) == "Click to open in Codex")
        #expect(model.clickDescription(of: pushed) == "Click to open https://a.example")

        for notification in [off, on] {
            model.add(notification)
            model.activate(notification.id)
        }

        #expect(alerts.performed == ["open b from Codex"])
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
