import Foundation
@testable import SidebarKit
import SidebarProtocol
import SwiftUI
import Testing
import ViewInspector

@MainActor
struct SidebarViewTests {
    let performer = RecordingPerformer()
    var model: SidebarModel

    init() {
        model = SidebarModel(performer: performer, store: InMemoryStore())
    }

    func view(openSettings: @escaping () -> Void = {}, quit: @escaping () -> Void = {}) -> SidebarView {
        SidebarView(model: model, openSettings: openSettings, quit: quit)
    }

    @Test func showsEmptyStateWithoutClearAll() throws {
        let sut = try view().inspect()

        #expect(throws: Never.self) { try sut.find(text: "No notifications") }
        #expect(throws: (any Error).self) { try sut.find(button: "Clear All") }
    }

    @Test func clickingCardRunsActionAndDismisses() throws {
        model.add(SidebarNotification(source: "cli", title: "Build done", action: .run(command: "open .", workingDirectory: "/repo")))

        try view().inspect().find(text: "Build done").find(ViewType.Button.self, relation: .parent).tap()

        #expect(performer.actions == [.run(command: "open .", workingDirectory: "/repo")])
        #expect(model.notifications.isEmpty)
    }

    @Test func dismissButtonRemovesWithoutAction() throws {
        model.add(SidebarNotification(source: "cli", title: "Keep quiet", action: .open(URL(string: "https://a.example")!)))

        try view().inspect().find(viewWithAccessibilityLabel: "Dismiss").button().tap()

        #expect(performer.actions.isEmpty)
        #expect(model.notifications.isEmpty)
    }

    @Test func clearAllRemovesEverything() throws {
        model.add(SidebarNotification(source: "a", title: "one"))
        model.add(SidebarNotification(source: "b", title: "two"))

        try view().inspect().find(button: "Clear All").tap()

        #expect(model.notifications.isEmpty)
    }

    @Test func rendersEverySeverityActionAndField() throws {
        let actions: [SidebarNotification.ClickAction?] = [
            nil, .open(URL(string: "https://a.example")!), .run(command: "ls", workingDirectory: "/"), .activateApp(name: "Mail"),
        ]
        for (severity, action) in zip(NotificationSeverity.allCases, actions) {
            model.add(SidebarNotification(
                source: severity == .low ? "" : "source-\(severity)",
                title: "title-\(severity)",
                subtitle: "subtitle-\(severity)",
                body: "body-\(severity)",
                severity: severity,
                action: action
            ))
        }

        let sut = try view().inspect()

        for severity in NotificationSeverity.allCases {
            #expect(throws: Never.self) { try sut.find(text: "subtitle-\(severity)") }
            #expect(throws: Never.self) { try sut.find(text: "body-\(severity)") }
        }
        #expect(throws: Never.self) { try sut.find(text: "Notification") }
        #expect(throws: Never.self) { try sut.find(viewWithAccessibilityLabel: "critical") }
        #expect(throws: Never.self) { try sut.find(viewWithAccessibilityLabel: "high") }
        #expect(throws: (any Error).self) { try sut.find(viewWithAccessibilityLabel: "normal") }
    }

    @Test func marksNotificationsMacOSStillShows() throws {
        model.add(SidebarNotification(source: "Calendar", title: "Standup", shownByMacOS: true))

        #expect(throws: Never.self) { try view().inspect().find(text: "Shown by macOS for its buttons") }
    }

    @Test func showsCountAndLayersForStackedNotifications() throws {
        model.add(SidebarNotification(source: "ci", title: "single"))
        for _ in 0..<2 {
            model.add(SidebarNotification(source: "ci", title: "twice"))
        }
        for _ in 0..<5 {
            model.add(SidebarNotification(source: "ci", title: "often"))
        }

        let sut = try view().inspect()
        let cards = sut.findAll(NotificationCard.self)

        #expect(try cards.map { try $0.actualView().notification.title } == ["often", "twice", "single"])
        #expect(throws: Never.self) { try sut.find(text: "×5") }
        #expect(throws: Never.self) { try sut.find(viewWithAccessibilityLabel: "Received 2 times") }
        #expect(throws: (any Error).self) { try sut.find(text: "×1") }
        #expect(try cards.map { try $0.find(ViewType.ForEach.self).count } == [NotificationCard.maxStackLayers, 1, 0])
    }

    @Test func hoverPassesFromCardToCardInEitherReportOrder() {
        let first = UUID()
        let second = UUID()

        #expect(SidebarView.hoveredID(nil, card: first, hovering: true) == first)
        #expect(SidebarView.hoveredID(first, card: first, hovering: false) == nil)
        // Entering the second card before leaving the first must not lose the second.
        #expect(SidebarView.hoveredID(first, card: second, hovering: true) == second)
        #expect(SidebarView.hoveredID(second, card: first, hovering: false) == second)
    }

    @Test func hoverBringsTextForwardWhileBackgroundStaysSolid() throws {
        func card(hovered: Bool) throws -> InspectableView<ViewType.ClassifiedView> {
            try NotificationCard(
                notification: SidebarNotification(source: "s", title: "t"),
                isHovered: hovered,
                hover: { _ in },
                activate: {},
                dismiss: {}
            ).inspect()
        }
        func contentOpacity(_ card: InspectableView<ViewType.ClassifiedView>) throws -> Double {
            try card.find(text: "t").find(ViewType.VStack.self, relation: .parent).opacity()
        }
        func dismissOpacity(_ card: InspectableView<ViewType.ClassifiedView>) throws -> Double {
            try card.find(viewWithAccessibilityLabel: "Dismiss").opacity()
        }

        let resting = try card(hovered: false)
        let hovered = try card(hovered: true)

        #expect(try contentOpacity(resting) < 1)
        #expect(try dismissOpacity(resting) < 1)
        #expect(throws: (any Error).self) { try resting.vStack().opacity() }
        #expect(try resting.vStack().scaleEffect() == CGSize(width: 1, height: 1))
        #expect(try contentOpacity(hovered) == 1)
        #expect(try dismissOpacity(hovered) == 1)
        #expect(try hovered.vStack().scaleEffect().width > 1)
    }

    @Test func laterCardsDrawAboveEarlierOnesSoTheyCoverRemovals() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        model.add(SidebarNotification(source: "s", title: "old-normal", receivedAt: start))
        model.add(SidebarNotification(source: "s", title: "new-normal", receivedAt: start.addingTimeInterval(1)))
        model.add(SidebarNotification(source: "s", title: "old-critical", severity: .critical, receivedAt: start.addingTimeInterval(-3600)))
        model.add(SidebarNotification(source: "s", title: "low", severity: .low, receivedAt: start.addingTimeInterval(3600)))

        let before = try view().inspect().findAll(NotificationCard.self)
        let zIndexBefore = try before.map { try $0.zIndex() }
        model.dismiss(model.notifications[1].id)
        let after = try view().inspect().findAll(NotificationCard.self)

        #expect(try before.map { try $0.actualView().notification.title } == ["old-critical", "new-normal", "old-normal", "low"])
        #expect(zIndexBefore == zIndexBefore.sorted() && Set(zIndexBefore).count == zIndexBefore.count)
        // The card that slides into the removed card's place keeps a value above it.
        #expect(try after[1].zIndex() == zIndexBefore[2])
        #expect(try after[1].zIndex() > zIndexBefore[1])
    }

    @Test func bodyOnlyNotificationOmitsTitle() throws {
        model.add(SidebarNotification(source: "s", title: "", body: "just a body"))

        #expect(throws: Never.self) { try view().inspect().find(text: "just a body") }
    }

    @Test func promptsForSetupWhenAccessibilityIsMissing() throws {
        model.interception = .needsAccessibility
        var opened = 0

        let sut = try view(openSettings: { opened += 1 }).inspect()
        try sut.find(button: "Set Up…").tap()

        #expect(throws: Never.self) { try sut.find(text: "Grant Accessibility access to show macOS notifications here.") }
        #expect(opened == 1)
    }

    @Test func settingsButtonOpensSettings() throws {
        var opened = 0

        try view(openSettings: { opened += 1 }).inspect().find(button: "Settings…").tap()

        #expect(opened == 1)
    }

    @Test func explainsDisabledInterception() throws {
        model.interception = .disabled

        #expect(throws: Never.self) { try view().inspect().find(text: "macOS notifications are left to macOS (see Settings).") }
    }

    @Test func reportsUnavailableNotificationCenterWithoutSettingsButton() throws {
        model.interception = .notificationCenterUnavailable

        let sut = try view().inspect()

        #expect(throws: Never.self) { try sut.find(text: "macOS notifications cannot be read right now.") }
        #expect(throws: (any Error).self) { try sut.find(button: "Set Up…") }
    }

    @Test func hidesStatusWhileActive() throws {
        model.interception = .active

        #expect(throws: (any Error).self) { try view().inspect().find(text: "macOS notifications cannot be read right now.") }
    }

    @Test func textUsesFontSettings() throws {
        let typography = Typography(SidebarSettings.Font(name: "Menlo", size: 20))
        model.add(SidebarNotification(source: "ci", title: "Build done", subtitle: "main", body: "All green", shownByMacOS: true))

        let sut = try view().environment(\.typography, typography).inspect()

        #expect(try sut.find(text: "Notifications").attributes().font() == typography.font(.headline))
        #expect(try sut.find(text: "Build done").attributes().font() == typography.font(.body).bold())
        #expect(try sut.find(text: "main").attributes().font() == typography.font(.callout))
        #expect(try sut.find(text: "All green").attributes().font() == typography.font(.callout))
        #expect(try sut.find(text: "Shown by macOS for its buttons").attributes().font() == typography.font(.caption2))
        for title in ["Clear All", "Settings…", "Quit Sidebar"] {
            #expect(try sut.find(button: title).labelView().text().attributes().font() == typography.font(.body))
        }
    }

    @Test func quitButtonQuits() throws {
        var quits = 0

        try view(quit: { quits += 1 }).inspect().find(button: "Quit Sidebar").tap()

        #expect(quits == 1)
    }
}
