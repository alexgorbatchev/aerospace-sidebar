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

    @Test func alertsNeedInteraction() {
        #expect(NotificationBanners.needsInteraction(FakeElement([kAXSubroleAttribute: "AXNotificationCenterAlert"])))
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

    @Test func forgetsOldestIdentifiersBeyondLimit() {
        var now = Date(timeIntervalSince1970: 0)
        var received = 0
        let interceptor = SystemNotificationInterceptor(now: { now }) { _ in received += 1 }
        for index in 0...SystemNotificationInterceptor.maxRememberedBanners {
            interceptor.process(window: FakeElement.window(FakeElement.banner(id: "id-\(index)", title: "t\(index)")))
        }
        now += SystemNotificationInterceptor.duplicateWindow + 1

        interceptor.process(window: FakeElement.window(FakeElement.banner(id: "id-0", title: "t0")))

        #expect(received == SystemNotificationInterceptor.maxRememberedBanners + 2)
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

    @Test func bannerWithoutAppNameHasNoClickAction() {
        var received: [SidebarNotification] = []
        let interceptor = SystemNotificationInterceptor { received.append($0) }
        let banner = FakeElement([kAXSubroleAttribute: "AXNotificationCenterBanner"], children: [FakeElement([kAXValueAttribute: "Title"])])

        interceptor.process(window: FakeElement.window(banner))

        #expect(received.map(\.action) == [nil])
    }

    @Test func leavesInteractiveNotificationsToMacOS() throws {
        var received: [SidebarNotification] = []
        let interceptor = SystemNotificationInterceptor { received.append($0) }
        let alert = FakeElement.banner(id: "alert", app: "Calendar", title: "Standup")
        alert.attributes[kAXSubroleAttribute] = "AXNotificationCenterAlert"
        let plain = FakeElement.banner(id: "plain", app: "Mail", title: "Hi")
        let window = FakeElement.window(alert, plain, position: SystemNotificationInterceptor.offScreen)

        interceptor.process(window: window)

        #expect(window.position == .zero)
        #expect(alert.performed.isEmpty)
        #expect(plain.performed.count == 1)
        #expect(received.map(\.title) == ["Standup", "Hi"])
        #expect(received.map(\.shownByMacOS) == [true, false])
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
