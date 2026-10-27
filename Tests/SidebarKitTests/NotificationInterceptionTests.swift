import ApplicationServices
import Foundation
@testable import SidebarKit
import Testing

@MainActor
struct NotificationBannersTests {
    @Test func findsBannersWithoutDescendingIntoThem() {
        let nested = FakeElement.banner(id: "inner")
        let outer = FakeElement([kAXSubroleAttribute: "AXNotificationCenterAlert"], children: [nested])
        let root = FakeElement(children: [FakeElement(children: [outer]), FakeElement.banner(id: "second")])

        let banners = NotificationBanners.find(in: root)

        #expect(banners.map { $0.string(kAXIdentifierAttribute) } == [nil, "second"])
    }

    /// Only the four subroles NotificationCenter uses for notifications count, matched exactly.
    @Test func recognizesExactlyTheNotificationSubroles() {
        let subroles = [
            "AXNotificationCenterBanner", "AXNotificationCenterAlert", "AXNotificationCenterBannerStack",
            "AXNotificationCenterAlertStack", "AXNotificationCenterNextFocus", "AXNotificationCenterBannerWindow",
        ]
        let root = FakeElement(children: subroles.map { FakeElement([kAXSubroleAttribute: $0, kAXIdentifierAttribute: $0]) })

        #expect(NotificationBanners.find(in: root).map { $0.string(kAXIdentifierAttribute) } == Array(subroles.prefix(4)))
        #expect(NotificationBanners.kind(of: FakeElement.alertStack()) == .stack)
        #expect(NotificationBanners.kind(of: FakeElement.banner()) == .banner)
        #expect(NotificationBanners.kind(of: FakeElement()) == nil)
    }

    @Test func detectsTheOpenHistoryPanel() {
        let application = FakeElement()
        let window = FakeElement.window(FakeElement.banner())
        #expect(!NotificationBanners.isPanelOpen(application: application, windows: [window]))
        #expect(!NotificationBanners.isPanelOpen(application: nil, windows: []))

        application.flags["AXExpanded"] = true
        #expect(NotificationBanners.isPanelOpen(application: application, windows: [window]))

        let panel = FakeElement.window(FakeElement([kAXIdentifierAttribute: NotificationBanners.panelMarker]))
        #expect(NotificationBanners.isPanelOpen(application: nil, windows: [window, panel]))
    }

    @Test func stopsAtMaxDepth() {
        var element = FakeElement.banner()
        for _ in 0..<3 {
            element = FakeElement(children: [element])
        }

        #expect(NotificationBanners.find(in: element, maxDepth: 2).isEmpty)
        #expect(NotificationBanners.find(in: element, maxDepth: 3).count == 1)
    }

    @Test func readsLabeledTextsAndAppName() {
        let banner = FakeElement([kAXDescriptionAttribute: "Slack, Alex, hello"], children: [
            FakeElement([kAXValueAttribute: "hello there", kAXIdentifierAttribute: "body"]),
            FakeElement([kAXValueAttribute: "#general", kAXIdentifierAttribute: "subtitle"]),
            FakeElement([kAXValueAttribute: "Alex", kAXIdentifierAttribute: "title"]),
        ])

        #expect(NotificationBanners.content(of: banner)
            == BannerContent(appName: "Slack", title: "Alex", subtitle: "#general", body: "hello there"))
    }

    @Test func unlabeledTextsFillRemainingFieldsInOrder() {
        let banner = FakeElement(children: [
            FakeElement([kAXValueAttribute: "Body", kAXIdentifierAttribute: "body"]),
            FakeElement([kAXValueAttribute: "First"]),
            FakeElement([kAXValueAttribute: ""]),
            FakeElement(children: [FakeElement([kAXValueAttribute: "Second"]), FakeElement([kAXValueAttribute: "Extra"])]),
        ])

        #expect(NotificationBanners.content(of: banner) == BannerContent(title: "First", subtitle: "Second", body: "Body"))
    }

    /// macOS's own notifications have no app: their description starts with the title instead.
    @Test func descriptionStartingWithTheTitleNamesNoApp() {
        let banner = FakeElement([kAXDescriptionAttribute: "Disk Not Ejected Properly, Eject “4TB” before disconnecting"], children: [
            FakeElement([kAXValueAttribute: "Disk Not Ejected Properly", kAXIdentifierAttribute: "title"]),
            FakeElement([kAXValueAttribute: "Eject “4TB” before disconnecting", kAXIdentifierAttribute: "body"]),
        ])

        #expect(NotificationBanners.content(of: banner)
            == BannerContent(appName: "", title: "Disk Not Ejected Properly", body: "Eject “4TB” before disconnecting"))
    }

    @Test func skipsHeaderAndDateTexts() {
        let banner = FakeElement([kAXDescriptionAttribute: "Mail, Hi, Lunch?"], children: [
            FakeElement([kAXValueAttribute: "Mail", kAXIdentifierAttribute: "header"]),
            FakeElement([kAXValueAttribute: "now", kAXIdentifierAttribute: "date"]),
            FakeElement([kAXValueAttribute: "Hi", kAXIdentifierAttribute: "title"]),
            FakeElement([kAXValueAttribute: "Lunch?", kAXIdentifierAttribute: "body"]),
        ])

        #expect(NotificationBanners.content(of: banner) == BannerContent(appName: "Mail", title: "Hi", body: "Lunch?"))
    }

    @Test(arguments: [
        // The app name is whatever precedes the exact texts, commas included.
        ("Acme, Inc., Build, Passed", "Acme, Inc."),
        // A collapsed stack ends its description with ", stacked".
        ("Self Service, Build, Passed, stacked", "Self Service"),
        // macOS's own notifications start with the title.
        ("Build, Passed", ""),
        // A description that lags behind the texts falls back to its first part.
        ("Slack, Build, Pass", "Slack"),
        ("Build, Pass", ""),
    ])
    func readsAppNameFromDescription(description: String, appName: String) {
        let content = BannerContent(title: "Build", body: "Passed")

        #expect(NotificationBanners.appName(in: description, content: content, labels: .english) == appName)
    }

    @Test func readsAppNameWithLocalizedSeparator() {
        var labels = NotificationCenterLabels.english
        labels.separator = "、"
        labels.stackedSuffix = "、スタック"
        let content = BannerContent(title: "Build", body: "Passed")

        #expect(NotificationBanners.appName(in: "Xcode、Build、Passed、スタック", content: content, labels: labels) == "Xcode")
    }

    @Test func unlabeledTextCanFillBody() {
        let banner = FakeElement(children: ["A", "B", "C"].map { FakeElement([kAXValueAttribute: $0]) })

        #expect(NotificationBanners.content(of: banner) == BannerContent(title: "A", subtitle: "B", body: "C"))
    }

    @Test func plainBannerNeedsNoInteraction() {
        #expect(!NotificationBanners.needsInteraction(FakeElement.banner()))
        let withCloseButton = FakeElement.banner()
        withCloseButton.childElements.append(FakeElement([kAXRoleAttribute: kAXButtonRole, kAXSubroleAttribute: kAXCloseButtonSubrole]))
        #expect(!NotificationBanners.needsInteraction(withCloseButton))
    }

    /// Alerts stay on screen until dismissed; only their actions and controls decide.
    @Test func alertsWithoutChoicesNeedNoInteraction() {
        let alert = FakeElement.banner()
        alert.attributes[kAXSubroleAttribute] = "AXNotificationCenterAlert"
        alert.childElements.append(FakeElement([kAXRoleAttribute: kAXButtonRole, kAXTitleAttribute: "Close"]))
        alert.childElements.append(FakeElement([kAXRoleAttribute: kAXButtonRole, kAXDescriptionAttribute: "Show"]))

        #expect(!NotificationBanners.needsInteraction(alert))

        alert.childElements.append(FakeElement([kAXRoleAttribute: kAXMenuButtonRole, kAXTitleAttribute: "Options"]))
        #expect(NotificationBanners.needsInteraction(alert))
    }

    @Test func buttonsOtherThanPlainActionsNeedInteraction() {
        let banner = FakeElement.banner()
        banner.childElements.append(FakeElement([kAXRoleAttribute: kAXButtonRole, kAXTitleAttribute: "Reply"]))

        #expect(NotificationBanners.needsInteraction(banner))
    }

    @Test func extraActionsNeedInteraction() {
        let banner = FakeElement.banner()
        banner.actions.append("Name:Snooze\nTarget:0x0\nSelector:(null)")

        #expect(NotificationBanners.needsInteraction(banner))
    }

    @Test(arguments: [kAXTextFieldRole, kAXButtonRole, kAXPopUpButtonRole])
    func nestedControlsNeedInteraction(role: String) {
        let banner = FakeElement.banner()
        banner.childElements.append(FakeElement(children: [FakeElement([kAXRoleAttribute: role])]))

        #expect(NotificationBanners.needsInteraction(banner))
    }

    @Test func judgesActionsInNotificationCentersLanguage() {
        let labels = NotificationCenterLabels(
            close: "Schließen", show: "Anzeigen", showDetails: "Details einblenden", separator: ", ", stackedSuffix: ", gestapelt"
        )
        let banner = FakeElement.banner()
        banner.actions = ["AXPress", "Name:Details einblenden\nTarget:0x0\nSelector:(null)", "Name:Schließen\nTarget:0x0\nSelector:(null)"]
        banner.childElements.append(FakeElement([kAXRoleAttribute: kAXButtonRole, kAXDescriptionAttribute: "Anzeigen"]))

        #expect(!NotificationBanners.needsInteraction(banner, labels: labels))
        #expect(NotificationBanners.needsInteraction(banner, labels: .english))
        #expect(NotificationBanners.dismiss(banner, labels: labels))
        #expect(banner.performed == ["Name:Schließen\nTarget:0x0\nSelector:(null)"])
    }

    @Test func actionButtonsNeedInteraction() {
        let banner = FakeElement.banner()
        banner.childElements.append(FakeElement([kAXIdentifierAttribute: "action_button"]))

        #expect(NotificationBanners.needsInteraction(banner))
    }

    /// An app's own action that merely contains "Close" is not NotificationCenter's Close, and two actions
    /// that both look like Close leave the notification alone.
    @Test func dismissesOnlyWithAnUnambiguousCloseAction() {
        let ticket = FakeElement(actions: ["Name:Close Ticket\nTarget:0x0\nSelector:(null)"])
        #expect(!NotificationBanners.dismiss(ticket))
        #expect(ticket.performed.isEmpty)

        let twice = FakeElement(actions: ["Name:Close\nTarget:0x1\nSelector:(null)", "Name:Close\nTarget:0x2\nSelector:(null)"])
        #expect(!NotificationBanners.dismiss(twice))
        #expect(twice.performed.isEmpty)

        let buttons = (0..<2).map { _ in FakeElement([kAXRoleAttribute: kAXButtonRole, kAXDescriptionAttribute: "Close"]) }
        #expect(!NotificationBanners.dismiss(FakeElement(children: buttons)))
        #expect(buttons.allSatisfy { $0.performed.isEmpty })

        let described = FakeElement([kAXRoleAttribute: kAXButtonRole, kAXDescriptionAttribute: "Close"])
        #expect(NotificationBanners.dismiss(FakeElement(children: [described])))
        #expect(described.performed == [kAXPressAction])
    }

    @Test(arguments: [
        ("Name:Show Details\nTarget:0x0\nSelector:(null)", "Show Details"),
        ("AXPress", "AXPress"),
        ("Name:Close", "Close"),
    ])
    func parsesActionNames(raw: String, name: String) {
        #expect(NotificationBanners.actionName(raw) == name)
    }

    @Test func dismissesWithCloseAction() {
        let banner = FakeElement.banner()

        #expect(NotificationBanners.dismiss(banner))
        #expect(banner.performed == ["Name:Close\nTarget:0x0\nSelector:(null)"])
    }

    @Test func fallsBackToCloseButton() {
        let button = FakeElement([kAXRoleAttribute: kAXButtonRole, kAXSubroleAttribute: kAXCloseButtonSubrole])
        let banner = FakeElement(children: [FakeElement([kAXRoleAttribute: kAXButtonRole]), button], actions: ["AXCancel"])
        banner.actionSucceeds = false

        #expect(NotificationBanners.dismiss(banner))
        #expect(banner.performed == ["AXCancel"])
        #expect(button.performed == [kAXPressAction])
    }

    @Test func reportsWhenNothingCanClose() {
        #expect(!NotificationBanners.dismiss(FakeElement(actions: ["AXPress"])))
    }

    /// macOS 26's "Privacy & Security" alert offers Allow… as a named action beside Show Details and Close.
    @Test func offersAnAlertsNamedActionsAsChoices() {
        let alert = FakeElement.alert(choices: ["Allow…", "Later"])

        #expect(NotificationBanners.choices(of: alert) == ["Allow…", "Later"])

        // Hovering shows the choices as buttons too, beside Close and Show.
        alert.childElements.append(FakeElement([kAXIdentifierAttribute: "action_button", kAXTitleAttribute: "Allow…"]))
        alert.childElements.append(FakeElement([kAXRoleAttribute: kAXButtonRole, kAXDescriptionAttribute: "Later"]))
        alert.childElements.append(FakeElement([kAXRoleAttribute: kAXButtonRole, kAXTitleAttribute: "Close"]))
        #expect(NotificationBanners.choices(of: alert) == ["Allow…", "Later"])
    }

    @Test func offersNoChoicesWhereOnlyMacOSCanPresentThem() {
        let banner = FakeElement.alert()
        banner.attributes[kAXSubroleAttribute] = "AXNotificationCenterBanner"
        #expect(NotificationBanners.choices(of: banner) == nil)

        #expect(NotificationBanners.choices(of: FakeElement.alert(choices: [])) == nil)

        for control in [
            FakeElement([kAXRoleAttribute: kAXTextFieldRole]),
            FakeElement([kAXRoleAttribute: kAXPopUpButtonRole, kAXTitleAttribute: "Allow…"]),
            FakeElement([kAXIdentifierAttribute: "action_button", kAXTitleAttribute: "Options"]),
            FakeElement([kAXIdentifierAttribute: "action_button"]),
        ] {
            let alert = FakeElement.alert()
            alert.childElements.append(FakeElement(children: [control]))
            #expect(NotificationBanners.choices(of: alert) == nil)
        }
    }

    @Test func readsChoicesInNotificationCentersLanguage() {
        let labels = NotificationCenterLabels(
            close: "Schließen", show: "Anzeigen", showDetails: "Details einblenden", separator: ", ", stackedSuffix: ", gestapelt"
        )
        let alert = FakeElement.alert()
        alert.actions = ["AXPress", "Name:Details einblenden", "Name:Erlauben …", "Name:Schließen"]

        #expect(NotificationBanners.choices(of: alert, labels: labels) == ["Erlauben …"])
    }
}

@MainActor
struct SystemNotificationInterceptorTests {
    @Test func hidesWindowClosesBannerAndReportsContent() throws {
        var received: [SidebarNotification] = []
        let date = Date(timeIntervalSince1970: 100)
        let interceptor = SystemNotificationInterceptor(now: { date }) { received.append($0) }
        let banner = FakeElement.banner(app: "Mail", title: "Hi", body: "Lunch?")
        let window = FakeElement.window(banner)

        interceptor.process(window: window)

        #expect(window.moves == [SystemNotificationInterceptor.offScreen])
        #expect(banner.performed.count == 1)
        let notification = try #require(received.first)
        #expect(received.count == 1)
        #expect(notification.source == "Mail")
        #expect(notification.title == "Hi")
        #expect(notification.body == "Lunch?")
        #expect(notification.severity == .normal)
        #expect(notification.action == .activateApp(name: "Mail"))
        #expect(notification.receivedAt == date)
    }

    @Test func reportsEachBannerOnceButKeepsClosingIt() {
        var received = 0
        let interceptor = SystemNotificationInterceptor { _ in received += 1 }
        let banner = FakeElement.banner(id: "same")

        interceptor.process(window: FakeElement.window(banner))
        interceptor.process(window: FakeElement.window(banner))

        #expect(received == 1)
        #expect(banner.performed.count == 2)
    }

    @Test func ignoresIdenticalContentWithinDuplicateWindow() {
        var now = Date(timeIntervalSince1970: 0)
        var received = 0
        let interceptor = SystemNotificationInterceptor(now: { now }) { _ in received += 1 }

        interceptor.process(window: FakeElement.window(FakeElement.banner(id: nil)))
        interceptor.process(window: FakeElement.window(FakeElement.banner(id: "")))
        now += SystemNotificationInterceptor.duplicateWindow + 1
        interceptor.process(window: FakeElement.window(FakeElement.banner(id: nil)))

        #expect(received == 2)
    }

    /// Notifications with different identifiers are different notifications, however alike.
    @Test func reportsRepeatsThatCarryNewIdentifiers() {
        var received = 0
        let interceptor = SystemNotificationInterceptor { _ in received += 1 }

        interceptor.process(window: FakeElement.window(FakeElement.banner(id: "first")))
        interceptor.process(window: FakeElement.window(FakeElement.banner(id: "second")))

        #expect(received == 2)
    }

    /// The database source records the notifications it lists in the same identities, so a banner it
    /// already listed is closed but not listed again.
    @Test func skipsNotificationsAlreadyListed() {
        var received = 0
        let identities = NotificationIdentities()
        identities.insert("listed")
        let interceptor = SystemNotificationInterceptor(identities: identities) { _ in received += 1 }
        let banner = FakeElement.banner(id: "LISTED")

        interceptor.process(window: FakeElement.window(banner))

        #expect(received == 0)
        #expect(banner.performed.count == 1)
    }

    @Test func skipsEmptyBannersAndWindowsWithoutBanners() {
        var received = 0
        let interceptor = SystemNotificationInterceptor { _ in received += 1 }
        let empty = FakeElement([kAXSubroleAttribute: "AXNotificationCenterBanner"])
        let plainWindow = FakeElement.window()

        interceptor.process(window: FakeElement.window(empty))
        interceptor.process(window: plainWindow)

        #expect(received == 0)
        #expect(plainWindow.moves.isEmpty)
    }

    @Test func bannerWithoutAppNameComesFromMacOSWithNoClickAction() {
        var received: [SidebarNotification] = []
        let interceptor = SystemNotificationInterceptor { received.append($0) }
        let banner = FakeElement([kAXSubroleAttribute: "AXNotificationCenterBanner"], children: [FakeElement([kAXValueAttribute: "Title"])])

        interceptor.process(window: FakeElement.window(banner))

        #expect(received.map(\.source) == [SystemNotificationInterceptor.systemSource])
        #expect(received.map(\.action) == [nil])
    }

    @Test func leavesInteractiveNotificationsToMacOS() throws {
        var received: [SidebarNotification] = []
        let interceptor = SystemNotificationInterceptor { received.append($0) }
        let interactive = FakeElement.banner(id: "alert", app: "Calendar", title: "Standup")
        interactive.actions.append("Name:Snooze\nTarget:0x0\nSelector:(null)")
        let plain = FakeElement.banner(id: "plain", app: "Mail", title: "Hi")
        let window = FakeElement.window(interactive, plain, position: SystemNotificationInterceptor.offScreen)

        interceptor.process(window: window)

        #expect(window.position == .zero)
        #expect(interactive.performed.isEmpty)
        #expect(plain.performed.count == 1)
        #expect(received.map(\.title) == ["Standup", "Hi"])
        #expect(received.map(\.shownByMacOS) == [true, false])
    }

    @Test func hidesAlertsWithoutChoices() throws {
        var received: [SidebarNotification] = []
        let interceptor = SystemNotificationInterceptor { received.append($0) }
        let alert = FakeElement.banner(id: "disk", app: "Finder", title: "Disk Not Ejected Properly")
        alert.attributes[kAXSubroleAttribute] = "AXNotificationCenterAlert"
        let window = FakeElement.window(alert)

        interceptor.process(window: window)

        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(alert.performed.count == 1)
        #expect(received.map(\.shownByMacOS) == [false])
    }

    @Test func listsInteractiveNotificationsWithoutButtonsWhenSettingsSaySo() throws {
        var received: [SidebarNotification] = []
        var leavesActionable = false
        let interceptor = SystemNotificationInterceptor(leavesActionableToMacOS: { leavesActionable }) { received.append($0) }
        let reply = FakeElement.banner(id: "reply", app: "Messages", title: "Alex")
        reply.childElements.append(FakeElement([kAXRoleAttribute: kAXTextFieldRole]))
        let window = FakeElement.window(reply)

        interceptor.process(window: window)

        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(reply.performed.count == 1)
        #expect(received.map(\.shownByMacOS) == [false])
        #expect(received.map(\.action) == [.activateApp(name: "Messages")])

        leavesActionable = true
        let later = FakeElement.banner(id: "reply-2", app: "Messages", title: "Sam")
        later.childElements.append(FakeElement([kAXRoleAttribute: kAXTextFieldRole]))
        interceptor.process(window: FakeElement.window(later))
        #expect(received.map(\.shownByMacOS) == [false, true])
    }

    /// A collapsed stack exposes only its newest notification, so it is pressed open and its notifications
    /// are handled one by one on later passes. It is not pressed again while it expands.
    @Test func expandsStacksInsteadOfReportingThem() {
        var now = Date(timeIntervalSince1970: 0)
        var received: [SidebarNotification] = []
        let interceptor = SystemNotificationInterceptor(now: { now }) { received.append($0) }
        let stack = FakeElement.alertStack()
        let window = FakeElement.window(stack)

        #expect(interceptor.sweep(windows: [window], application: nil) == .pending)
        #expect(interceptor.sweep(windows: [window], application: nil) == .pending)
        #expect(stack.performed == [kAXPressAction])
        #expect(received.isEmpty)
        #expect(window.position == SystemNotificationInterceptor.offScreen)

        now += SystemNotificationInterceptor.expansionGrace
        interceptor.sweep(windows: [window], application: nil)
        #expect(stack.performed == [kAXPressAction, kAXPressAction])

        let expanded = [FakeElement.banner(id: "a", title: "First"), FakeElement.banner(id: "b", title: "Second")]
        expanded.forEach { $0.attributes[kAXSubroleAttribute] = "AXNotificationCenterAlert" }
        let expandedWindow = FakeElement.window(expanded[0], expanded[1])
        #expect(interceptor.sweep(windows: [expandedWindow], application: nil) == .pending)
        #expect(received.map(\.title) == ["First", "Second"])
        #expect(expanded.map(\.performed.count) == [1, 1])

        #expect(interceptor.sweep(windows: [FakeElement.window()], application: nil) == .settled)
    }

    @Test func leavesStacksFromAppsLeftToMacOSCollapsed() {
        var received: [SidebarNotification] = []
        let interceptor = SystemNotificationInterceptor(leavesToMacOS: { $0 == "Self Service" }) { received.append($0) }
        let stack = FakeElement.alertStack()
        let window = FakeElement.window(stack)

        #expect(interceptor.sweep(windows: [window], application: nil) == .settled)

        #expect(stack.performed.isEmpty)
        #expect(window.moves.isEmpty)
        #expect(received.map(\.title) == ["Slack"])
        #expect(received.map(\.shownByMacOS) == [true])
    }

    @Test func leavesEverythingAloneWhileTheHistoryPanelIsOpen() {
        var received = 0
        let interceptor = SystemNotificationInterceptor { _ in received += 1 }
        let banner = FakeElement.banner()
        let stack = FakeElement.alertStack()
        let window = FakeElement.window(banner, stack, FakeElement([kAXIdentifierAttribute: NotificationBanners.panelMarker]))

        #expect(interceptor.sweep(windows: [window], application: nil) == .settled)

        #expect(banner.performed.isEmpty)
        #expect(stack.performed.isEmpty)
        #expect(window.moves.isEmpty)
        #expect(received == 0)
    }

    /// A window is hidden only when every notification in it is intercepted, and only once.
    @Test func hidesEachWindowOnItsOwn() {
        let interceptor = SystemNotificationInterceptor { _ in }
        let interactive = FakeElement.banner(id: "native")
        interactive.actions.append("Name:Snooze\nTarget:0x0\nSelector:(null)")
        let kept = FakeElement.window(interactive)
        let hidden = FakeElement.window(FakeElement.banner(id: "plain"))

        #expect(interceptor.sweep(windows: [kept, hidden], application: FakeElement()) == .pending)
        interceptor.sweep(windows: [kept, hidden], application: FakeElement())

        #expect(kept.moves.isEmpty)
        #expect(hidden.moves == [SystemNotificationInterceptor.offScreen])
    }

    @Test func toleratesAWindowThatRefusesToMove() {
        var received = 0
        let interceptor = SystemNotificationInterceptor { _ in received += 1 }
        let banner = FakeElement.banner()
        let window = FakeElement.window(banner)
        window.keepsMoves = false

        interceptor.process(window: window)

        #expect(window.moves == [SystemNotificationInterceptor.offScreen])
        #expect(window.position == .zero)
        #expect(banner.performed.count == 1)
        #expect(received == 1)
    }

    /// The sidebar's model, as far as the interceptor sees it.
    final class AlertList {
        var notifications: [SidebarNotification] = []
        var present: [Set<String>] = []

        func lists(_ identifier: String) -> Bool {
            notifications.contains { $0.nativeAlert?.identifier == identifier }
        }
    }

    func interceptor(
        for list: AlertList,
        identities: NotificationIdentities = NotificationIdentities(),
        leavesToMacOS: @escaping @MainActor (String) -> Bool = { _ in false },
        now: @escaping () -> Date = Date.init
    ) -> SystemNotificationInterceptor {
        SystemNotificationInterceptor(
            now: now,
            identities: identities,
            leavesToMacOS: leavesToMacOS,
            listsAlert: { list.lists($0) },
            onPresentAlerts: { list.present.append($0) }
        ) { list.notifications.append($0) }
    }

    /// An alert whose choices are named actions is hidden without closing it, and listed with them.
    @Test func hidesAlertsWithChoicesAndListsThemWithTheirChoices() throws {
        let list = AlertList()
        let interceptor = interceptor(for: list)
        let alert = FakeElement.alert(id: "privacy", app: "", title: "Privacy & Security")
        alert.attributes[kAXDescriptionAttribute] = "Privacy & Security, Text"
        let window = FakeElement.window(alert)

        #expect(interceptor.sweep(windows: [window], application: nil) == .settled)
        interceptor.sweep(windows: [window], application: nil)

        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(alert.performed.isEmpty)
        let notification = try #require(list.notifications.first)
        #expect(list.notifications.count == 1)
        #expect(notification.source == SystemNotificationInterceptor.systemSource)
        #expect(notification.nativeAlert == SidebarNotification.NativeAlert(identifier: "privacy", choices: ["Allow…"]))
        #expect(!notification.shownByMacOS)
        #expect(list.present == [["privacy"]])
    }

    /// The setting that leaves interactive notifications to macOS covers only those the sidebar cannot offer.
    @Test func hidesAlertsWithChoicesWhateverTheSettingSays() {
        var received: [SidebarNotification] = []
        let interceptor = SystemNotificationInterceptor(leavesActionableToMacOS: { false }) { received.append($0) }
        let alert = FakeElement.alert()

        interceptor.process(window: FakeElement.window(alert))

        #expect(alert.performed.isEmpty)
        #expect(received.map(\.nativeAlert?.choices) == [["Allow…"]])
    }

    /// Once the card is gone the alert is closed, but an alert whose choice was just performed is given
    /// `choiceGrace` to go away on its own first.
    @Test func closesAlertsOnceTheirCardIsGone() {
        let list = AlertList()
        var now = Date(timeIntervalSince1970: 0)
        let interceptor = interceptor(for: list, now: { now })
        let alert = FakeElement.alert(id: "a")
        let window = FakeElement.window(alert)
        interceptor.sweep(windows: [window], application: nil)

        #expect(interceptor.perform(.choice("Allow…"), onAlert: "a", in: [window]))
        list.notifications = []
        #expect(interceptor.sweep(windows: [window], application: nil) == .pending)
        #expect(alert.performed == ["Name:Allow…\nTarget:0x0\nSelector:(null)"])

        now += SystemNotificationInterceptor.choiceGrace
        #expect(interceptor.sweep(windows: [window], application: nil) == .pending)
        #expect(alert.performed.last == "Name:Close\nTarget:0x0\nSelector:(null)")
        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(list.present == [["a"], []])

        #expect(interceptor.sweep(windows: [FakeElement.window()], application: nil) == .settled)
        #expect(list.notifications.isEmpty)
    }

    /// After a relaunch the saved card stands for the alert, which stays hidden and is not listed twice,
    /// and closes when that card goes.
    @Test func keepsAlertsHiddenForCardsRestoredFromTheSavedList() {
        let list = AlertList()
        list.notifications = [SidebarNotification(source: "Calendar", title: "Standup", nativeAlert: .init(identifier: "a", choices: ["Allow…"]))]
        let identities = NotificationIdentities()
        let interceptor = interceptor(for: list, identities: identities)
        let alert = FakeElement.alert(id: "a")
        let window = FakeElement.window(alert)

        interceptor.sweep(windows: [window], application: nil)
        #expect(list.notifications.count == 1)
        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(identities.contains("a"))
        #expect(alert.performed.isEmpty)

        list.notifications = []
        interceptor.sweep(windows: [window], application: nil)
        #expect(alert.performed == ["Name:Close\nTarget:0x0\nSelector:(null)"])
    }

    /// An alert the notification database listed first has a card without its choices, so it stays with macOS.
    @Test func leavesAlertsListedWithoutTheirChoicesToMacOS() {
        let list = AlertList()
        let identities = NotificationIdentities()
        identities.insert("a")
        let interceptor = interceptor(for: list, identities: identities)
        let alert = FakeElement.alert(id: "a")
        let window = FakeElement.window(alert, position: SystemNotificationInterceptor.offScreen)

        interceptor.sweep(windows: [window], application: nil)

        #expect(window.position == .zero)
        #expect(alert.performed.isEmpty)
        #expect(list.notifications.isEmpty)
    }

    /// A choice such as Reply can turn the alert into one with a text field, which only works on screen.
    @Test func returnsAnAlertToMacOSWhenItGainsAControl() {
        let list = AlertList()
        let interceptor = interceptor(for: list)
        let alert = FakeElement.alert(id: "a", choices: ["Reply"])
        let window = FakeElement.window(alert)
        interceptor.sweep(windows: [window], application: nil)

        alert.childElements.append(FakeElement([kAXRoleAttribute: kAXTextFieldRole]))
        interceptor.sweep(windows: [window], application: nil)

        #expect(window.position == .zero)
        #expect(alert.performed.isEmpty)
        #expect(list.present == [["a"], []])
    }

    @Test func leavesAlertsFromAppsLeftToMacOSAlone() {
        let list = AlertList()
        let interceptor = interceptor(for: list, leavesToMacOS: { $0 == "Calendar" })
        let alert = FakeElement.alert()
        let window = FakeElement.window(alert)

        interceptor.sweep(windows: [window], application: nil)

        #expect(window.moves.isEmpty)
        #expect(list.notifications.map(\.shownByMacOS) == [true])
        #expect(list.notifications.map(\.nativeAlert) == [nil])
    }

    @Test func performsChoicesAndOpensAlertsByIdentifier() {
        let interceptor = SystemNotificationInterceptor { _ in }
        let other = FakeElement.alert(id: "other")
        let alert = FakeElement.alert(id: "a")
        let windows = [FakeElement.window(other), FakeElement.window(alert)]

        #expect(interceptor.perform(.open, onAlert: "a", in: windows))
        #expect(interceptor.perform(.choice("Allow…"), onAlert: "a", in: windows))
        #expect(!interceptor.perform(.choice("Snooze"), onAlert: "a", in: windows))
        #expect(!interceptor.perform(.open, onAlert: "gone", in: windows))
        alert.actionSucceeds = false
        #expect(!interceptor.perform(.open, onAlert: "a", in: windows))

        #expect(alert.performed == [kAXPressAction, "Name:Allow…\nTarget:0x0\nSelector:(null)", kAXPressAction])
        #expect(other.performed.isEmpty)
    }

    @Test func detachingLeavesNoAlertToActOn() {
        let list = AlertList()
        let interceptor = interceptor(for: list)
        interceptor.sweep(windows: [FakeElement.window(FakeElement.alert(id: "a"))], application: nil)

        interceptor.detach()
        interceptor.detach()

        #expect(list.present == [["a"], []])
    }

    @Test func restoresOnlyOffScreenWindows() {
        let interceptor = SystemNotificationInterceptor { _ in }
        let hidden = FakeElement(position: SystemNotificationInterceptor.offScreen)
        let hiddenVertically = FakeElement(position: CGPoint(x: 0, y: -2000))
        let visible = FakeElement(position: CGPoint(x: 10, y: 10))
        let unknown = FakeElement()

        interceptor.restore([hidden, hiddenVertically, visible, unknown])

        #expect(hidden.position == .zero)
        #expect(hiddenVertically.position == .zero)
        #expect(visible.moves.isEmpty)
        #expect(unknown.moves.isEmpty)
    }
}
