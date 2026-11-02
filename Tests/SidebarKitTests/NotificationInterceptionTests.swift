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
        // A stack in the history panel starts with "Stacked summary: ", and ends with ", from iPhone" when mirrored.
        ("Stacked summary: Slack, Build, Passed", "Slack"),
        ("Stacked summary: Slack, Build, Passed, from iPhone", "Slack"),
        ("Stacked summary: Slack, Build, Pa", "Slack"),
        // Its summary is often titled with the app's name, which does not make it one of macOS's own.
        ("Stacked summary: Build, Build, Passed and more", "Build"),
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
    /// NotificationCenter lists choices the other way round from the app, so the card shows them reversed.
    @Test func offersAnAlertsNamedActionsAsChoices() {
        let alert = FakeElement.alert(choices: ["Allow…", "Later"])

        #expect(NotificationBanners.choices(of: alert) == ["Later", "Allow…"])

        // Hovering shows the choices as buttons too, beside Close and Show.
        alert.childElements.append(FakeElement([kAXIdentifierAttribute: "action_button", kAXTitleAttribute: "Allow…"]))
        alert.childElements.append(FakeElement([kAXRoleAttribute: kAXButtonRole, kAXDescriptionAttribute: "Later"]))
        alert.childElements.append(FakeElement([kAXRoleAttribute: kAXButtonRole, kAXTitleAttribute: "Close"]))
        #expect(NotificationBanners.choices(of: alert) == ["Later", "Allow…"])
    }

    @Test func offersNoChoicesWhereOnlyMacOSCanPresentThem() {
        let banner = FakeElement.alert()
        banner.attributes[kAXSubroleAttribute] = "AXNotificationCenterBanner"
        #expect(NotificationBanners.choices(of: banner) == nil)

        #expect(NotificationBanners.choices(of: FakeElement.alert(choices: [])) == nil)
        // An actions menu lists its header, which only closes the alert, beside the items: "When?" here.
        #expect(NotificationBanners.choices(of: FakeElement.alert(choices: ["Tomorrow", "Later", "Now", "When?"])) == nil)
        #expect(NotificationBanners.choices(of: FakeElement.alert(choices: ["Tomorrow", "Later", "Now"])) == nil)

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

    /// Banners offer their app's actions as named actions too. Hide Details, which an alert shows while its
    /// details are open, is no choice, and an open reply field only works on screen.
    @Test func readsTheNamedChoicesOfAnyNotification() {
        let banner = FakeElement.replyBanner()
        #expect(NotificationBanners.namedChoices(of: banner) == ["Reply"])
        #expect(NotificationBanners.namedChoices(of: FakeElement.alertStack()) == nil)
        #expect(NotificationBanners.namedChoices(of: FakeElement.alert(choices: ["Hide Details", "Allow…"])) == ["Allow…"])

        _ = banner.perform("Name:Reply\nTarget:0x0\nSelector:(null)")
        #expect(NotificationBanners.namedChoices(of: banner) == nil)
    }

    /// What the app declared under a notification's titles decides its choices, in the app's order, for banners
    /// and for alerts with more than `maxChoices`; NotificationCenter lists them the other way round.
    @Test func offersWhatTheAppDeclared() {
        let declared: [NativeChoice] = ["Approve", NativeChoice(title: "Reject", isDestructive: true), "Later"]
        let banner = FakeElement.banner()
        banner.actions = ["AXPress", "Name:Show Details", "Name:Later", "Name:Reject", "Name:Approve", "Name:Close"]
        let alert = FakeElement.alert(choices: ["Later", "Reject", "Approve"])

        #expect(NotificationBanners.choices(of: banner) { $0 == ["Later", "Reject", "Approve"] ? declared : nil } == declared)
        #expect(NotificationBanners.choices(of: alert) { _ in declared } == declared)
        #expect(NotificationBanners.choices(of: banner) == nil)
        #expect(NotificationBanners.choices(of: alert) == nil)
    }

    /// A choice that asks for text is answered the way a user would: performing it opens a field, which is
    /// filled and sent with the app's send action, or with the one action the field adds when the app named
    /// none. Every step reports failure but takes effect.
    @Test func repliesThroughTheFieldAChoiceOpens() {
        let banner = FakeElement.replyBanner(send: "Send")
        #expect(NotificationBanners.perform(.reply(choice: "Reply", text: "On my way", send: "Send"), on: banner))
        #expect(banner.string("sent") == "On my way")

        let unnamed = FakeElement.replyBanner(send: "Post")
        #expect(NotificationBanners.perform(.reply(choice: "Reply", text: "Later", send: ""), on: unnamed))
        #expect(unnamed.string("sent") == "Later")
    }

    /// A reply that cannot be written or sent closes its field again: while one is open, NotificationCenter
    /// holds back every new notification.
    @Test func closesTheFieldOfAReplyThatFails() throws {
        let unsent = FakeElement.replyBanner(send: "Send")
        #expect(!NotificationBanners.perform(.reply(choice: "Reply", text: "x", send: "Post"), on: unsent))
        #expect(unsent.performed.last == "Name:Hide Details\nTarget:0x0\nSelector:(null)")
        #expect(NotificationBanners.namedChoices(of: unsent) == ["Reply"])

        let unwritable = FakeElement.replyBanner()
        let opens = try #require(unwritable.onPerform)
        unwritable.onPerform = { banner in
            opens(banner)
            Self.textArea(in: banner)?.acceptsValues = false
        }
        #expect(!NotificationBanners.perform(.reply(choice: "Reply", text: "x", send: "Send"), on: unwritable))
        #expect(unwritable.performed.last == "Name:Hide Details\nTarget:0x0\nSelector:(null)")
        #expect(unwritable.string("sent") == nil)

        let other = FakeElement.replyBanner()
        #expect(!NotificationBanners.perform(.reply(choice: "Answer", text: "x", send: "Send"), on: other))
        #expect(other.performed.isEmpty)

        // A send that neither reports success nor changes anything.
        let refusesSend = FakeElement.replyBanner()
        let opensField = try #require(refusesSend.onPerform)
        refusesSend.onPerform = { banner in
            if banner.performed.last != "Name:Send\nTarget:0x0\nSelector:(null)" { opensField(banner) }
        }
        #expect(!NotificationBanners.perform(.reply(choice: "Reply", text: "x", send: "Send"), on: refusesSend))
        #expect(refusesSend.performed.last == "Name:Hide Details\nTarget:0x0\nSelector:(null)")
        #expect(refusesSend.string("sent") == nil)
        #expect(NotificationBanners.namedChoices(of: refusesSend) == ["Reply"])
    }

    static func textArea(in element: FakeElement) -> FakeElement? {
        element.childElements.lazy.compactMap { $0.attributes[kAXRoleAttribute] == kAXTextAreaRole ? $0 : textArea(in: $0) }.first
    }
}

@MainActor
struct SystemNotificationInterceptorTests {
    /// An intercepted banner is hidden but left open, so that its card can open it, and listed with its
    /// identifier.
    @Test func hidesWindowKeepsBannerAndReportsContent() throws {
        var received: [SidebarNotification] = []
        let date = Date(timeIntervalSince1970: 100)
        let interceptor = SystemNotificationInterceptor(
            now: { date },
            bundleIdentifier: { $0 == "Mail" ? "com.apple.mail" : nil }
        ) { received.append($0) }
        let banner = FakeElement.banner(app: "Mail", title: "Hi", body: "Lunch?")
        let window = FakeElement.window(banner)

        interceptor.process(window: window)

        #expect(window.moves == [SystemNotificationInterceptor.offScreen])
        #expect(banner.performed.isEmpty)
        let notification = try #require(received.first)
        #expect(received.count == 1)
        #expect(notification.source == "Mail")
        #expect(notification.title == "Hi")
        #expect(notification.body == "Lunch?")
        #expect(notification.severity == .normal)
        #expect(notification.action == .activateApp(name: "Mail"))
        #expect(notification.bundleIdentifier == "com.apple.mail")
        #expect(notification.nativeIdentifiers == ["banner-1"])
        #expect(notification.nativeChoices == nil)
        #expect(notification.receivedAt == date)
    }

    /// A banner without an identifier cannot be found again, so it is closed, on every pass until it goes.
    @Test func reportsEachUnidentifiedBannerOnceButKeepsClosingIt() {
        var received: [SidebarNotification] = []
        let interceptor = SystemNotificationInterceptor { received.append($0) }
        let banner = FakeElement.banner(id: nil)

        interceptor.process(window: FakeElement.window(banner))
        interceptor.process(window: FakeElement.window(banner))

        #expect(received.map(\.nativeIdentifiers) == [[]])
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

    /// A notification whose texts do not read (yet) is neither listed nor closed, identified or not, and its
    /// window stays on screen: closing it would lose it before usernoted records it. Sweeps go on until one
    /// reads it.
    @Test func waitsForNotificationsWhoseTextsDoNotRead() {
        var received: [SidebarNotification] = []
        let interceptor = SystemNotificationInterceptor { received.append($0) }
        let identified = FakeElement.banner(id: "a", title: "First")
        let unidentified = FakeElement.banner(id: nil, title: "Second")
        let texts = [identified.childElements, unidentified.childElements]
        identified.childElements = []
        unidentified.childElements = []
        let window = FakeElement.window(identified, unidentified)
        let plainWindow = FakeElement.window()

        #expect(interceptor.sweep(windows: [window, plainWindow], application: nil) == .pending)
        #expect(identified.performed.isEmpty)
        #expect(unidentified.performed.isEmpty)
        #expect(received.isEmpty)
        #expect(window.moves.isEmpty)
        #expect(plainWindow.moves.isEmpty)

        identified.childElements = texts[0]
        unidentified.childElements = texts[1]
        interceptor.sweep(windows: [window, plainWindow], application: nil)
        #expect(received.map(\.title) == ["First", "Second"])
        #expect(window.position == SystemNotificationInterceptor.offScreen)
    }

    @Test func listsNotificationsWithOnlyASubtitle() {
        var received: [SidebarNotification] = []
        let interceptor = SystemNotificationInterceptor { received.append($0) }
        let banner = FakeElement(
            [kAXSubroleAttribute: "AXNotificationCenterBanner", kAXIdentifierAttribute: "s", kAXDescriptionAttribute: "Mail, Lunch"],
            children: [FakeElement([kAXValueAttribute: "Lunch", kAXIdentifierAttribute: "subtitle"])],
            actions: ["AXPress", "Name:Close\nTarget:0x0\nSelector:(null)"]
        )

        interceptor.process(window: FakeElement.window(banner))

        #expect(received.map(\.subtitle) == ["Lunch"])
        #expect(received.map(\.source) == ["Mail"])
        #expect(banner.performed.isEmpty)
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
        #expect(plain.performed.isEmpty)
        #expect(received.map(\.title) == ["Standup", "Hi"])
        #expect(received.map(\.shownByMacOS) == [true, false])
        // A card for a notification macOS shows opens it too.
        #expect(received.map(\.nativeIdentifiers) == [["alert"], ["plain"]])
    }

    @Test func hidesAlertsWithoutChoices() throws {
        var received: [SidebarNotification] = []
        let interceptor = SystemNotificationInterceptor { received.append($0) }
        let alert = FakeElement.banner(id: "disk", app: "Finder", title: "Disk Not Ejected Properly")
        alert.attributes[kAXSubroleAttribute] = "AXNotificationCenterAlert"
        let window = FakeElement.window(alert)

        interceptor.process(window: window)

        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(alert.performed.isEmpty)
        #expect(received.map(\.shownByMacOS) == [false])
        #expect(received.map(\.nativeChoices) == [nil])
        #expect(received.map(\.nativeIdentifiers) == [["disk"]])
    }

    @Test func listsInteractiveNotificationsWithoutButtonsWhenSettingsSaySo() throws {
        var received: [SidebarNotification] = []
        let leavesActionable = Mutable(false)
        let interceptor = SystemNotificationInterceptor(leavesActionableToMacOS: { leavesActionable.value }) { received.append($0) }
        let reply = FakeElement.banner(id: "reply", app: "Messages", title: "Alex")
        reply.childElements.append(FakeElement([kAXRoleAttribute: kAXTextFieldRole]))
        let window = FakeElement.window(reply)

        interceptor.process(window: window)

        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(reply.performed.isEmpty)
        #expect(received.map(\.shownByMacOS) == [false])
        #expect(received.map(\.action) == [.activateApp(name: "Messages")])

        leavesActionable.value = true
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
        #expect(interceptor.sweep(windows: [expandedWindow], application: nil) == .settled)
        #expect(received.map(\.title) == ["First", "Second"])
        #expect(expanded.map(\.performed.count) == [0, 0])

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

        #expect(interceptor.sweep(windows: [kept, hidden], application: FakeElement()) == .settled)
        interceptor.sweep(windows: [kept, hidden], application: FakeElement())

        #expect(kept.moves.isEmpty)
        #expect(hidden.moves == [SystemNotificationInterceptor.offScreen])
    }

    /// Only the "Notification Center" window is processed, since only it is moved back: notifications in a
    /// window with another subrole, or one that does not read, are left as macOS shows them.
    @Test func touchesNoWindowButTheNotificationWindow() {
        var received = 0
        let interceptor = SystemNotificationInterceptor { _ in received += 1 }
        let banners = [FakeElement.banner(id: "standard"), FakeElement.banner(id: nil)]
        let standard = FakeElement.window(banners[0])
        standard.attributes[kAXSubroleAttribute] = kAXStandardWindowSubrole
        let unread = FakeElement.window(banners[1])
        unread.attributes[kAXSubroleAttribute] = nil

        #expect(interceptor.sweep(windows: [standard, unread], application: nil) == .settled)

        #expect(standard.moves.isEmpty)
        #expect(unread.moves.isEmpty)
        #expect(banners.allSatisfy { $0.performed.isEmpty })
        #expect(received == 0)
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
        #expect(banner.performed.isEmpty)
        #expect(received == 1)
    }

    /// The sidebar's model, as far as the interceptor sees it.
    final class AlertList {
        var notifications: [SidebarNotification] = []
        /// Each set of notifications reported as offering their choices no more.
        var unavailable: [Set<String>] = []

        func lists(_ identifier: String) -> Bool {
            notifications.contains { $0.nativeIdentifiers.contains(identifier) }
        }

        func listsChoices(_ identifier: String) -> Bool {
            notifications.contains { $0.nativeChoices?.identifier == identifier }
        }
    }

    func interceptor(
        for list: AlertList,
        identities: NotificationIdentities = NotificationIdentities(),
        leavesToMacOS: @escaping @MainActor (String) -> Bool = { _ in false },
        leavesActionableToMacOS: Bool = true,
        declared: [String: [NativeChoice]] = [:],
        declaringNone: Set<String> = [],
        now: @escaping () -> Date = Date.init
    ) -> SystemNotificationInterceptor {
        SystemNotificationInterceptor(
            now: now,
            identities: identities,
            leavesToMacOS: leavesToMacOS,
            bundleIdentifier: { declared.isEmpty && declaringNone.isEmpty ? nil : "bundle.\($0)" },
            leavesActionableToMacOS: { leavesActionableToMacOS },
            listsNotification: { list.lists($0) },
            listsChoices: { list.listsChoices($0) },
            declaredChoices: { app, titles in
                // What the apps declared, by app name, matched like `DeclaredChoices` does.
                declared[String(app.dropFirst("bundle.".count))].flatMap { Set($0.map(\.title)) == Set(titles) ? $0 : nil }
            },
            declaresNoChoices: { declaringNone.contains(String($0.dropFirst("bundle.".count))) },
            onUnavailableChoices: { list.unavailable.append($0) }
        ) { list.notifications.append($0) }
    }

    /// macOS's request to let an app post notifications stays on screen, unlisted, and is never closed: its
    /// Close answers Don't Allow. A notification hidden in the same window shows with it.
    @Test func leavesPermissionRequestsToMacOS() {
        let list = AlertList()
        let identities = NotificationIdentities()
        let interceptor = interceptor(for: list, identities: identities)
        let request = FakeElement.alert(
            id: "ask", app: "", title: "“Notif Probe” Notifications", choices: ["Don’t Allow", "Allow"]
        )
        request.childElements[1].attributes[kAXValueAttribute] = NotificationCenterLabels.english.permissionBodies[0]
        let banner = FakeElement.banner(id: "b")
        let window = FakeElement.window(banner, request, position: SystemNotificationInterceptor.offScreen)

        #expect(interceptor.sweep(windows: [window], application: nil) == .settled)
        // No card lists it, as after a dismissed card or a rule that hides it, yet later sweeps leave it alone.
        interceptor.sweep(windows: [window], application: nil)

        #expect(request.performed.isEmpty)
        #expect(window.position == .zero)
        #expect(list.notifications.map(\.nativeIdentifiers) == [["b"]])
        #expect(!identities.insert("ask"))
    }

    @Test func recognizesPermissionRequestsByTitleOrBody() {
        let labels = NotificationCenterLabels.english
        #expect(NotificationBanners.isPermissionRequest(BannerContent(title: "“Slack” Notifications"), labels: labels))
        #expect(NotificationBanners.isPermissionRequest(BannerContent(title: "“Slack” Critical Alerts"), labels: labels))
        #expect(NotificationBanners.isPermissionRequest(BannerContent(title: "Slack", body: labels.permissionBodies[1]), labels: labels))
        #expect(!NotificationBanners.isPermissionRequest(BannerContent(title: "“” Notifications"), labels: labels))
        #expect(!NotificationBanners.isPermissionRequest(BannerContent(title: "Slack Notifications", body: "New message"), labels: labels))
        var japanese = labels
        japanese.permissionTitles = ["“%@”の通知"]
        #expect(NotificationBanners.isPermissionRequest(BannerContent(title: "“Slack”の通知"), labels: japanese))
        #expect(!NotificationBanners.isPermissionRequest(BannerContent(title: "“Slack” Notifications"), labels: japanese))
    }

    /// An alert with more choices than the sidebar offers, such as an actions menu, is left to macOS like
    /// any interactive notification.
    @Test func leavesAlertsWithManyChoicesToMacOS() {
        let list = AlertList()
        let interceptor = interceptor(for: list)
        let alert = FakeElement.alert(id: "menu", choices: ["Tomorrow", "Later", "Now", "When?"])
        let window = FakeElement.window(alert)

        interceptor.sweep(windows: [window], application: nil)

        #expect(window.moves.isEmpty)
        #expect(alert.performed.isEmpty)
        #expect(list.notifications.map(\.shownByMacOS) == [true])
        #expect(list.notifications.map(\.nativeChoices) == [nil])
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
        #expect(notification.nativeChoices == SidebarNotification.NativeChoices(identifier: "privacy", choices: ["Allow…"]))
        #expect(!notification.shownByMacOS)
        #expect(list.unavailable.isEmpty)
    }

    /// The setting that leaves interactive notifications to macOS covers only those the sidebar cannot offer.
    @Test func hidesAlertsWithChoicesWhateverTheSettingSays() {
        var received: [SidebarNotification] = []
        let interceptor = SystemNotificationInterceptor(leavesActionableToMacOS: { false }) { received.append($0) }
        let alert = FakeElement.alert()

        interceptor.process(window: FakeElement.window(alert))

        #expect(alert.performed.isEmpty)
        #expect(received.map(\.nativeChoices?.choices) == [["Allow…"]])
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

        #expect(interceptor.perform(.choice("Allow…"), on: ["a"], in: [window]) == .performed)
        list.notifications = []
        #expect(interceptor.sweep(windows: [window], application: nil) == .pending)
        #expect(alert.performed == ["Name:Allow…\nTarget:0x0\nSelector:(null)"])

        now += SystemNotificationInterceptor.choiceGrace
        #expect(interceptor.sweep(windows: [window], application: nil) == .pending)
        #expect(alert.performed.last == "Name:Close\nTarget:0x0\nSelector:(null)")
        #expect(window.position == SystemNotificationInterceptor.offScreen)

        #expect(interceptor.sweep(windows: [FakeElement.window()], application: nil) == .settled)
        #expect(list.notifications.isEmpty)
        // The alert left after a step from the sidebar, without a card to offer anything.
        #expect(list.unavailable.isEmpty)
    }

    /// A banner is hidden but left open while its card exists, so that the card can open it, and closed once
    /// the card is gone, until it leaves.
    @Test func keepsBannersHiddenUntilTheirCardIsGone() throws {
        let list = AlertList()
        let interceptor = interceptor(for: list)
        let banner = FakeElement.banner(id: "b")
        let window = FakeElement.window(banner)

        #expect(interceptor.sweep(windows: [window], application: nil) == .settled)
        #expect(interceptor.sweep(windows: [window], application: nil) == .settled)
        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(banner.performed.isEmpty)
        #expect(list.notifications.map(\.nativeIdentifiers) == [["b"]])

        list.notifications = []
        #expect(interceptor.sweep(windows: [window], application: nil) == .pending)
        #expect(banner.performed == ["Name:Close\nTarget:0x0\nSelector:(null)"])
        #expect(interceptor.sweep(windows: [FakeElement.window()], application: nil) == .settled)
    }

    /// Notifications hidden for their cards stay hidden, with their choices offered, while their texts do not
    /// read, and still close once their cards go: right away, or after `choiceGrace` for an alert whose choice
    /// was just performed. Showing them would show the whole window, and forgetting them would leave the alert
    /// to macOS for good.
    @Test func keepsNotificationsHiddenForCardsWhileTheirTextsDoNotRead() {
        let list = AlertList()
        var now = Date(timeIntervalSince1970: 0)
        let interceptor = interceptor(for: list, now: { now })
        let banner = FakeElement.banner(id: "b")
        let alert = FakeElement.alert(id: "a")
        let alertTexts = alert.childElements
        let window = FakeElement.window(banner, alert)
        interceptor.sweep(windows: [window], application: nil)
        banner.childElements = []
        alert.childElements = []

        #expect(interceptor.sweep(windows: [window], application: nil) == .settled)
        #expect(window.moves == [SystemNotificationInterceptor.offScreen])
        #expect(list.unavailable.isEmpty)
        #expect(list.notifications.flatMap(\.nativeIdentifiers) == ["b", "a"])

        #expect(interceptor.perform(.choice("Allow…"), on: ["a"], in: [window]) == .performed)
        list.notifications = []
        #expect(interceptor.sweep(windows: [window], application: nil) == .pending)
        #expect(banner.performed == ["Name:Close\nTarget:0x0\nSelector:(null)"])
        #expect(alert.performed == ["Name:Allow…\nTarget:0x0\nSelector:(null)"])

        alert.childElements = alertTexts
        now += SystemNotificationInterceptor.choiceGrace
        interceptor.sweep(windows: [window], application: nil)
        #expect(alert.performed.last == "Name:Close\nTarget:0x0\nSelector:(null)")
        #expect(window.moves == [SystemNotificationInterceptor.offScreen])
        #expect(list.notifications.isEmpty)
    }

    /// A card opens the newest of its notifications that NotificationCenter still shows or hides; a stack
    /// with one of their identifiers does not count, since pressing it would only expand it. The opened
    /// notification is given `choiceGrace` to go away before it is closed for its dismissed card.
    @Test func opensTheNewestNotificationACardStandsFor() {
        let list = AlertList()
        var now = Date(timeIntervalSince1970: 0)
        let interceptor = interceptor(for: list, now: { now })
        let older = FakeElement.banner(id: "older", title: "Old")
        let newer = FakeElement.banner(id: "newer", title: "New")
        let stack = FakeElement.alertStack(id: "stacked")
        let window = FakeElement.window(older, newer, stack)
        interceptor.sweep(windows: [window], application: nil)

        #expect(interceptor.perform(.open, on: ["stacked", "missing"], in: [window]) == .absent)
        #expect(interceptor.perform(.open, on: [], in: [window]) == .absent)
        #expect(interceptor.perform(.open, on: ["missing", "newer", "older"], in: [window]) == .performed)
        #expect(newer.performed == [kAXPressAction])
        #expect(older.performed.isEmpty)
        #expect(stack.performed == [kAXPressAction])

        list.notifications.removeAll { $0.nativeIdentifiers == ["newer"] }
        interceptor.sweep(windows: [window], application: nil)
        #expect(newer.performed == [kAXPressAction])
        now += SystemNotificationInterceptor.choiceGrace
        interceptor.sweep(windows: [window], application: nil)
        #expect(newer.performed.last == "Name:Close\nTarget:0x0\nSelector:(null)")
        #expect(older.performed.isEmpty)
    }

    /// After a relaunch the saved card stands for the alert, which stays hidden and is not listed twice,
    /// and closes when that card goes.
    @Test func keepsAlertsHiddenForCardsRestoredFromTheSavedList() {
        let list = AlertList()
        list.notifications = [SidebarNotification(
            source: "Calendar", title: "Standup", nativeChoices: .init(identifier: "a", choices: ["Allow…"]), nativeIdentifiers: ["a"]
        )]
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

    /// An alert the notification database listed first has a card without its choices, so it stays with macOS,
    /// unclosed, while that card exists and after it goes.
    @Test func leavesAlertsListedWithoutTheirChoicesToMacOS() {
        let list = AlertList()
        let listed = SidebarNotification(source: "Calendar", title: "Standup", nativeIdentifiers: ["a"])
        list.notifications = [listed]
        let identities = NotificationIdentities()
        identities.insert("a")
        let interceptor = interceptor(for: list, identities: identities)
        let alert = FakeElement.alert(id: "a")
        let window = FakeElement.window(alert, position: SystemNotificationInterceptor.offScreen)

        interceptor.sweep(windows: [window], application: nil)
        #expect(window.position == .zero)
        #expect(list.notifications == [listed])

        list.notifications = []
        interceptor.sweep(windows: [window], application: nil)
        #expect(window.position == .zero)
        #expect(alert.performed.isEmpty)
        #expect(list.notifications.isEmpty)
    }

    /// An alert listed as shown by macOS while its app was left to macOS keeps that handling once the app no
    /// longer is: its card has no choices to offer.
    @Test func keepsAlertsListedAsShownByMacOSWithMacOS() {
        let list = AlertList()
        let leftToMacOS = Mutable(true)
        let interceptor = interceptor(for: list, leavesToMacOS: { _ in leftToMacOS.value })
        let alert = FakeElement.alert(id: "a")
        let window = FakeElement.window(alert)
        interceptor.sweep(windows: [window], application: nil)
        #expect(list.notifications.map(\.shownByMacOS) == [true])

        leftToMacOS.value = false
        interceptor.sweep(windows: [window], application: nil)
        #expect(window.moves.isEmpty)

        list.notifications = []
        interceptor.sweep(windows: [window], application: nil)
        #expect(window.moves.isEmpty)
        #expect(alert.performed.isEmpty)
    }

    /// While interactive notifications are listed without their buttons, an alert whose card has no choices is
    /// hidden like them, offers nothing, and is closed once that card goes.
    @Test func hidesAlertsListedWithoutTheirChoicesLikeOtherInteractiveNotifications() {
        let list = AlertList()
        list.notifications = [SidebarNotification(source: "Calendar", title: "Standup", nativeIdentifiers: ["a"])]
        let interceptor = interceptor(for: list, leavesActionableToMacOS: false)
        let alert = FakeElement.alert(id: "a")
        let window = FakeElement.window(alert)

        interceptor.sweep(windows: [window], application: nil)
        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(alert.performed.isEmpty)
        #expect(list.notifications.count == 1)

        list.notifications = []
        interceptor.sweep(windows: [window], application: nil)
        #expect(alert.performed == ["Name:Close\nTarget:0x0\nSelector:(null)"])
    }

    /// A choice such as Reply can turn the alert into one with a text field, which only works on screen, and a
    /// banner can come to hold a control only macOS presents: either returns to macOS, and its card stops offering
    /// its choices until the control goes and the notification is hidden again.
    @Test func returnsANotificationToMacOSWhenItGainsAControl() {
        let list = AlertList()
        let interceptor = interceptor(for: list, declared: ["Notif Probe": [Self.reply]])
        let alert = FakeElement.alert(id: "a", choices: ["Reply"])
        let banner = FakeElement.replyBanner(id: "r")
        let alertWindow = FakeElement.window(alert)
        let bannerWindow = FakeElement.window(banner)
        interceptor.sweep(windows: [alertWindow, bannerWindow], application: nil)

        alert.childElements.append(FakeElement([kAXRoleAttribute: kAXTextFieldRole]))
        banner.childElements.append(FakeElement([kAXRoleAttribute: kAXPopUpButtonRole]))
        interceptor.sweep(windows: [alertWindow, bannerWindow], application: nil)

        #expect(alertWindow.position == .zero)
        #expect(bannerWindow.position == .zero)
        #expect(alert.performed.isEmpty)
        #expect(list.unavailable == [["a", "r"]])

        alert.childElements.removeLast()
        banner.childElements.removeLast()
        interceptor.sweep(windows: [alertWindow, bannerWindow], application: nil)
        #expect(alertWindow.position == SystemNotificationInterceptor.offScreen)
        #expect(list.unavailable == [["a", "r"], []])
    }

    @Test func leavesAlertsFromAppsLeftToMacOSAlone() {
        let list = AlertList()
        let interceptor = interceptor(for: list, leavesToMacOS: { $0 == "Calendar" })
        let alert = FakeElement.alert()
        let window = FakeElement.window(alert)

        interceptor.sweep(windows: [window], application: nil)

        #expect(window.moves.isEmpty)
        #expect(list.notifications.map(\.shownByMacOS) == [true])
        #expect(list.notifications.map(\.nativeChoices) == [nil])
    }

    /// An alert that leaves on its own, after a choice or without one, is forgotten: should its identifier
    /// show up again, the sidebar no longer treats it as one it hid, so it is neither hidden nor closed.
    @Test func forgetsAlertsThatLeaveOnTheirOwn() {
        let list = AlertList()
        let interceptor = interceptor(for: list)
        let chosen = FakeElement.alert(id: "chosen")
        let ignored = FakeElement.alert(id: "ignored")
        let window = FakeElement.window(chosen, ignored)
        interceptor.sweep(windows: [window], application: nil)
        interceptor.perform(.choice("Allow…"), on: ["chosen"], in: [window])
        list.notifications = []

        interceptor.sweep(windows: [FakeElement.window()], application: nil)
        let returning = FakeElement.window(chosen, ignored, position: SystemNotificationInterceptor.offScreen)
        interceptor.sweep(windows: [returning], application: nil)

        #expect(chosen.performed == ["Name:Allow…\nTarget:0x0\nSelector:(null)"])
        #expect(ignored.performed.isEmpty)
        #expect(returning.position == .zero)
    }

    @Test func performsChoicesAndOpensAlertsByIdentifier() {
        let interceptor = SystemNotificationInterceptor { _ in }
        let other = FakeElement.alert(id: "other")
        let alert = FakeElement.alert(id: "a")
        let windows = [FakeElement.window(other), FakeElement.window(alert)]

        #expect(interceptor.perform(.open, on: ["a"], in: windows) == .performed)
        #expect(interceptor.perform(.choice("Allow…"), on: ["a"], in: windows) == .performed)
        #expect(interceptor.perform(.choice("Snooze"), on: ["a"], in: windows) == .refused)
        #expect(interceptor.perform(.open, on: ["gone"], in: windows) == .absent)
        alert.actionSucceeds = false
        #expect(interceptor.perform(.open, on: ["a"], in: windows) == .refused)

        #expect(alert.performed == [kAXPressAction, "Name:Allow…\nTarget:0x0\nSelector:(null)", kAXPressAction])
        #expect(other.performed.isEmpty)
    }

    /// NotificationCenter reports failure for Reply although the alert opens its text field at once; a
    /// changed alert counts as performed, an unchanged one as refused.
    @Test func countsAChangedAlertAsPerformedDespiteAReportedFailure() {
        let interceptor = SystemNotificationInterceptor { _ in }
        let alert = FakeElement.alert(id: "a", choices: ["Reply"])
        alert.actionSucceeds = false
        let windows = [FakeElement.window(alert)]

        #expect(interceptor.perform(.choice("Reply"), on: ["a"], in: windows) == .refused)

        alert.onPerform = { alert in
            alert.actions = alert.actions.map { $0.replacingOccurrences(of: "Name:Show Details", with: "Name:Hide Details") }
            alert.childElements.append(FakeElement([kAXRoleAttribute: kAXTextAreaRole]))
        }
        #expect(interceptor.perform(.choice("Reply"), on: ["a"], in: windows) == .performed)

        alert.onPerform = { $0.actions = [] }
        #expect(interceptor.perform(.choice("Reply"), on: ["a"], in: windows) == .performed)
    }

    static let reply = NativeChoice(title: "Reply", textInput: NativeChoice.TextInput(placeholder: "Message", sendTitle: "Send"))

    /// A notification whose app declared its choices is hidden for its card with them, banners included,
    /// while other notifications with buttons stay with macOS; the card's reply is written and sent on the
    /// hidden banner.
    @Test func handsOverNotificationsWithTheChoicesTheirAppDeclared() {
        let list = AlertList()
        let interceptor = interceptor(for: list, declared: ["Notif Probe": [Self.reply]])
        let declared = FakeElement.replyBanner(id: "r")
        let undeclared = FakeElement.replyBanner(id: "u", app: "Other")
        let window = FakeElement.window(declared, undeclared, position: SystemNotificationInterceptor.offScreen)

        interceptor.sweep(windows: [window], application: nil)

        #expect(list.notifications.map(\.nativeChoices) == [SidebarNotification.NativeChoices(identifier: "r", choices: [Self.reply]), nil])
        #expect(list.notifications.map(\.shownByMacOS) == [false, true])
        #expect(list.unavailable.isEmpty)
        #expect(window.position == .zero)

        #expect(interceptor.perform(.reply(choice: "Reply", text: "On my way", send: "Send"), on: ["r"], in: [window]) == .performed)
        #expect(declared.string("sent") == "On my way")
        #expect(undeclared.performed.isEmpty)
    }

    /// An app known to have declared no choices, such as a Chromium browser, which puts a Settings button on its web
    /// notifications, carries them on each notification, and only its record names them, about 5 s later. Its
    /// notification is hidden for its card at once rather than left on screen, a banner for its whole life; once the
    /// record gives the card its choices, the card offers them and the notification stays hidden. An app nothing is
    /// known about keeps its notification with macOS, and so does a notification with a control besides named
    /// actions, which works on screen only.
    @Test func hidesNotificationsWhoseRecordsWillNameTheirChoices() {
        let list = AlertList()
        let identities = NotificationIdentities()
        let interceptor = interceptor(for: list, identities: identities, declaringNone: ["Vivaldi"])
        func settingsBanner(id: String, app: String) -> FakeElement {
            let banner = FakeElement.banner(id: id, app: app)
            banner.actions = ["AXPress", "Name:Show Details", "Name:Settings", "Name:Close"]
            return banner
        }
        let vivaldi = settingsBanner(id: "v", app: "Vivaldi")
        let unknown = settingsBanner(id: "u", app: "Unknown")
        let withField = settingsBanner(id: "f", app: "Vivaldi")
        withField.childElements.append(FakeElement([kAXRoleAttribute: kAXTextAreaRole]))
        // The database listed this one first from a record that named no choices, so none are coming.
        let recorded = settingsBanner(id: "r", app: "Vivaldi")
        list.notifications.append(SidebarNotification(source: "Vivaldi", title: "Subject", nativeIdentifiers: ["r"]))
        identities.insert("r")
        let window = FakeElement.window(vivaldi, unknown, withField, recorded)

        interceptor.sweep(windows: [window], application: nil)

        #expect(list.notifications.map(\.nativeIdentifiers) == [["r"], ["v"], ["u"], ["f"]])
        #expect(list.notifications.map(\.nativeChoices) == [nil, nil, nil, nil])
        #expect(list.notifications.map(\.shownByMacOS) == [false, false, true, true])
        // Only the one whose record is still to come is hidden; the window keeps the others on screen.
        #expect(recorded.performed.isEmpty)
        #expect(vivaldi.performed.isEmpty)
        #expect(window.position == .zero)

        // The record names the Settings button: the card offers it, and the banner stays hidden for it.
        list.notifications[1] = list.notifications[1].offering(SidebarNotification.NativeChoices(identifier: "v", choices: ["Settings"]))
        let alone = FakeElement.window(vivaldi)
        interceptor.sweep(windows: [alone], application: nil)
        interceptor.sweep(windows: [alone], application: nil)

        #expect(alone.position == SystemNotificationInterceptor.offScreen)
        #expect(vivaldi.performed.isEmpty)
        #expect(list.notifications.count == 4)
        #expect(interceptor.perform(.choice("Settings"), on: ["v"], in: [alone]) == .performed)
    }

    /// A banner with choices that leaves the screen on its own times out into the history, whose entry offers
    /// the same choices, so its card keeps them; it loses them once the history turns out not to hold it. An
    /// alert never times out, so one that leaves on its own is gone; one the sidebar acted on has no card left to
    /// offer anything. Only notifications whose cards offer choices are reported, and only while they do.
    @Test func keepsTheChoicesOfBannersThatTimeOutIntoTheHistory() {
        let list = AlertList()
        let interceptor = interceptor(for: list, declared: ["Notif Probe": [Self.reply]])
        let window = FakeElement.window(
            FakeElement.replyBanner(id: "kept"), FakeElement.replyBanner(id: "forgotten"), FakeElement.replyBanner(id: "answered"),
            FakeElement.alert(id: "alert"), FakeElement.alert(id: "chosen"), FakeElement.banner(id: "plain")
        )
        interceptor.sweep(windows: [window], application: nil)
        #expect(list.unavailable.isEmpty)
        interceptor.perform(.reply(choice: "Reply", text: "hi", send: "Send"), on: ["answered"], in: [window])
        interceptor.perform(.choice("Allow…"), on: ["chosen"], in: [window])

        interceptor.sweep(windows: [FakeElement.window()], application: nil)
        #expect(list.unavailable == [["alert"]])

        interceptor.choicesGone(of: "forgotten")
        interceptor.choicesGone(of: "plain")
        interceptor.choicesGone(of: "unknown")
        #expect(list.unavailable == [["alert"], ["alert", "forgotten"]])

        list.notifications.removeAll { $0.nativeIdentifiers == ["alert"] }
        interceptor.sweep(windows: [FakeElement.window()], application: nil)
        #expect(list.unavailable.last == ["forgotten"])
    }

    /// A sweep that misses an alert, such as one whose accessibility calls time out, takes it for gone; the next
    /// sweep that finds it offering its choices gives them back to its card.
    @Test func offersTheChoicesOfAnAlertASweepMissedAgain() {
        let list = AlertList()
        let interceptor = interceptor(for: list)
        let alert = FakeElement.alert(id: "a")
        let window = FakeElement.window(alert)
        interceptor.sweep(windows: [window], application: nil)

        interceptor.sweep(windows: [], application: nil)
        #expect(list.unavailable == [["a"]])

        interceptor.sweep(windows: [window], application: nil)
        #expect(list.unavailable == [["a"], []])
        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(alert.performed.isEmpty)
        #expect(list.notifications.count == 1)
    }

    /// After a reply is sent from the card, the notification shows its field while it leaves, which reads as
    /// interactive; the sweep the dismissed card asks for keeps it hidden, and the notifications hidden with it.
    @Test func keepsANotificationHiddenWhileItsSentReplyLeaves() {
        let list = AlertList()
        var now = Date(timeIntervalSince1970: 0)
        let interceptor = interceptor(for: list, declared: ["Notif Probe": [Self.reply]], now: { now })
        let replied = FakeElement.replyBanner(id: "r")
        let window = FakeElement.window(replied, FakeElement.banner(id: "other"))
        interceptor.sweep(windows: [window], application: nil)

        #expect(interceptor.perform(.reply(choice: "Reply", text: "On my way", send: "Send"), on: ["r"], in: [window]) == .performed)
        list.notifications.removeAll { $0.nativeIdentifiers == ["r"] }
        replied.childElements.append(FakeElement([kAXRoleAttribute: kAXTextAreaRole]))
        #expect(interceptor.sweep(windows: [window], application: nil) == .pending)

        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(list.notifications.map(\.nativeIdentifiers) == [["other"]])
        now += SystemNotificationInterceptor.choiceGrace
        interceptor.sweep(windows: [window], application: nil)
        #expect(window.position == SystemNotificationInterceptor.offScreen)
    }

    /// A choice the app did not declare can open a text field (Reply on an NSUserNotification alert); only macOS
    /// can take that typing, so the alert returns on screen even while interactive notifications are hidden.
    @Test func returnsAnAlertWhoseChoiceOpenedAFieldEvenWithButtonsHidden() {
        let list = AlertList()
        let interceptor = interceptor(for: list, leavesActionableToMacOS: false)
        let alert = FakeElement.alert(id: "a", choices: ["Reply"])
        let window = FakeElement.window(alert)
        interceptor.sweep(windows: [window], application: nil)
        #expect(window.position == SystemNotificationInterceptor.offScreen)

        alert.onPerform = { $0.childElements.append(FakeElement([kAXRoleAttribute: kAXTextAreaRole])) }
        #expect(interceptor.perform(.choice("Reply"), on: ["a"], in: [window]) == .performed)
        list.notifications = []
        interceptor.sweep(windows: [window], application: nil)

        #expect(window.position == .zero)
        #expect(!alert.performed.contains("Name:Close\nTarget:0x0\nSelector:(null)"))
    }

    /// A card that offers a notification's choices keeps them whatever the database says later, such as when a
    /// read fails: the notification stays hidden with them.
    @Test func keepsTheChoicesACardOffersWithoutTheDatabase() {
        let list = AlertList()
        let declared = Mutable<[String: [NativeChoice]]>(["Notif Probe": [Self.reply]])
        let interceptor = SystemNotificationInterceptor(
            bundleIdentifier: { $0 },
            listsNotification: { list.lists($0) },
            listsChoices: { list.listsChoices($0) },
            declaredChoices: { app, _ in declared.value[app] },
            onUnavailableChoices: { list.unavailable.append($0) }
        ) { list.notifications.append($0) }
        let window = FakeElement.window(FakeElement.replyBanner(id: "r"))
        interceptor.sweep(windows: [window], application: nil)

        declared.value = [:]
        interceptor.sweep(windows: [window], application: nil)

        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(list.unavailable.isEmpty)
    }

    /// An alert left to macOS for its actions menu, whose card the notification database later gave the menu's
    /// choices, is handed over to that card and hidden, its header included among the choices it keeps; performing
    /// one of the menu's items is a named action on the hidden alert.
    @Test func handsOverAnAlertWhoseCardGainedItsChoices() {
        let list = AlertList()
        let interceptor = interceptor(for: list)
        let alert = FakeElement.alert(id: "menu", app: "alerter", choices: ["Tomorrow", "Later today", "Now", "When?"])
        let window = FakeElement.window(alert)
        interceptor.sweep(windows: [window], application: nil)
        #expect(window.moves.isEmpty)
        #expect(list.notifications.map(\.shownByMacOS) == [true])

        let card = list.notifications[0]
        list.notifications = [card.offering(.init(identifier: "menu", choices: ["Now", "Later today", "Tomorrow"]))]
        interceptor.sweep(windows: [window], application: nil)
        #expect(window.position == SystemNotificationInterceptor.offScreen)
        #expect(list.notifications.count == 1)

        #expect(interceptor.perform(.choice("Later today"), on: ["menu"], in: [window]) == .performed)
        #expect(alert.performed == ["Name:Later today\nTarget:0x0\nSelector:(null)"])
        list.notifications = []
        interceptor.sweep(windows: [FakeElement.window()], application: nil)
        #expect(list.unavailable.isEmpty)
    }

    /// The notifications' window goes back to the origin from off-screen or beside the sidebar. NotificationCenter's
    /// other windows, such as desktop widgets on displays left of or above the main one, stay where they are.
    @Test func restoresMovedWindows() {
        let interceptor = SystemNotificationInterceptor { _ in }
        let hidden = FakeElement.window(position: SystemNotificationInterceptor.offScreen)
        let beside = FakeElement.window(position: CGPoint(x: -300, y: 0))
        let atOrigin = FakeElement.window()
        let unknown = FakeElement.window()
        unknown.position = nil
        let widgetsLeft = FakeElement.widgetWindow(position: CGPoint(x: -1920, y: 0))
        let widgetsAbove = FakeElement.widgetWindow(position: CGPoint(x: 0, y: -1080))

        interceptor.restore([hidden, beside, atOrigin, unknown, widgetsLeft, widgetsAbove])

        #expect(hidden.position == .zero)
        #expect(beside.position == .zero)
        #expect(atOrigin.moves.isEmpty)
        #expect(unknown.moves.isEmpty)
        #expect(widgetsLeft.moves.isEmpty)
        #expect(widgetsAbove.moves.isEmpty)
    }

    /// A window that holds a native notification moves to `nativeOrigin`, from the origin or from
    /// off-screen, once; a window of intercepted notifications is hidden as before.
    @Test func movesWindowsWithNativeNotificationsToTheirOrigin() {
        let beside = CGPoint(x: -300, y: 0)
        let interceptor = SystemNotificationInterceptor(leavesToMacOS: { $0 == "zoom.us" }, nativeOrigin: { beside }) { _ in }
        let shown = FakeElement.window(FakeElement.banner(id: "z", app: "zoom.us", title: "Meeting"))
        let wasHidden = FakeElement.window(
            FakeElement.banner(id: "z2", app: "zoom.us", title: "Call"),
            position: SystemNotificationInterceptor.offScreen
        )
        let intercepted = FakeElement.window(FakeElement.banner(id: "m", app: "Mail", title: "Lunch"))

        interceptor.sweep(windows: [shown, wasHidden, intercepted], application: nil)
        interceptor.sweep(windows: [shown, wasHidden, intercepted], application: nil)

        #expect(shown.moves == [beside])
        #expect(wasHidden.moves == [beside])
        #expect(intercepted.moves == [SystemNotificationInterceptor.offScreen])
    }

    /// Opening the history panel, which shares the window, puts a window beside the sidebar back. The
    /// desktop widgets' windows stay where they are.
    @Test func movesWindowsBackWhileThePanelIsOpen() {
        let interceptor = SystemNotificationInterceptor(leavesToMacOS: { _ in true }, nativeOrigin: { CGPoint(x: -300, y: 0) }) { _ in }
        let window = FakeElement.window(FakeElement.banner(id: "z", app: "zoom.us", title: "Meeting"))
        let widgets = FakeElement.widgetWindow(position: CGPoint(x: -1920, y: 0))
        interceptor.sweep(windows: [window, widgets], application: nil)

        let application = FakeElement()
        application.flags["AXExpanded"] = true
        interceptor.sweep(windows: [window, widgets], application: application)

        #expect(window.moves == [CGPoint(x: -300, y: 0), .zero])
        #expect(widgets.moves.isEmpty)
    }
}
