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

    func view(side: SidebarSettings.Sidebar.Side = .right, openSettings: @escaping () -> Void = {}) -> SidebarView {
        SidebarView(model: model, side: side, openSettings: openSettings)
    }

    func button(_ title: String, in sut: InspectableView<ViewType.ClassifiedView>) throws -> InspectableView<ViewType.Button> {
        try sut.find(viewWithAccessibilityLabel: title).button()
    }

    @Test func showsEmptyStateWithClearAllDisabled() throws {
        let sut = try view().inspect()

        #expect(throws: Never.self) { try sut.find(text: "No notifications") }
        #expect(try button("Clear All", in: sut).isDisabled())
    }

    @Test func clickingCardRunsActionAndDismisses() throws {
        model.add(SidebarNotification(source: "cli", title: "Build done", action: .run(command: "open .", workingDirectory: "/repo")))

        try view().inspect().find(text: "Build done").find(ViewType.Button.self, relation: .parent).tap()

        #expect(performer.actions == [.run(command: "open .", workingDirectory: "/repo")])
        #expect(model.notifications.isEmpty)
    }

    func card(_ notification: SidebarNotification, hovered: Bool) -> NotificationCard {
        NotificationCard(
            notification: notification,
            isHovered: hovered,
            hover: { _ in },
            activate: { model.activate(notification.id) },
            dismiss: { model.dismiss(notification.id) }
        )
    }

    @Test func dismissButtonRemovesWithoutAction() throws {
        model.add(SidebarNotification(source: "cli", title: "Keep quiet", action: .open(URL(string: "https://a.example")!)))

        try card(model.notifications[0], hovered: true).inspect().find(viewWithAccessibilityLabel: "Dismiss").button().tap()

        #expect(performer.actions.isEmpty)
        #expect(model.notifications.isEmpty)
    }

    @Test func dismissButtonShowsOnlyWhileTheCardIsHovered() throws {
        model.add(SidebarNotification(source: "cli", title: "Keep quiet"))

        let sut = try card(model.notifications[0], hovered: false).inspect()

        #expect(try sut.find(ExpandingIconButton.self).opacity() == 0)
        #expect(throws: (any Error).self) { try sut.find(viewWithAccessibilityLabel: "Dismiss").button().tap() }
        #expect(model.notifications.count == 1)
    }

    @Test func clearAllRemovesEverything() throws {
        model.add(SidebarNotification(source: "a", title: "one"))
        model.add(SidebarNotification(source: "b", title: "two"))

        let sut = try view().inspect()
        #expect(try !button("Clear All", in: sut).isDisabled())
        try button("Clear All", in: sut).tap()

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

    @Test func drawsIconInTheAppIconFontLabeledWithItsApp() throws {
        model.add(SidebarNotification(source: "cli", title: "Browse", icon: AppIconFont.vendored.icon(for: "google_chrome")))

        let icon = try view().inspect().find(viewWithAccessibilityLabel: "Google Chrome").text()

        #expect(try icon.string() == ":google_chrome:")
        #expect(try icon.attributes().font() == .custom(AppIconFont.family, fixedSize: 10))
    }

    @Test func notesUnknownIconLikeOtherCardNotes() throws {
        model.add(SidebarNotification(source: "cli", title: "Typo", invalidIcon: "slak"))

        let note = try view().inspect().find(text: "Invalid icon: slak")

        #expect(try note.attributes().font() == Typography(SidebarSettings.Font()).font(.caption2))
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

    @Test func hoverScalesCardWithoutFadingIt() throws {
        func card(hovered: Bool) throws -> InspectableView<ViewType.ClassifiedView> {
            try NotificationCard(
                notification: SidebarNotification(source: "s", title: "t"),
                isHovered: hovered,
                hover: { _ in },
                activate: {},
                dismiss: {}
            ).inspect()
        }

        /// No opacity modifier counts as fully opaque.
        func opacity(_ view: () throws -> InspectableView<some BaseViewType>) -> Double {
            (try? view().opacity()) ?? 1
        }

        for hovered in [false, true] {
            let sut = try card(hovered: hovered)
            #expect(opacity { try sut.vStack() } == 1)
            #expect(opacity { try sut.find(text: "t").find(ViewType.VStack.self, relation: .parent) } == 1)
            #expect(opacity { try sut.find(ExpandingIconButton.self) } == (hovered ? 1 : 0))
            #expect(try sut.vStack().scaleEffect().width == (hovered ? NotificationCard.hoverScale : 1))
        }
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

        try button("Settings", in: view(openSettings: { opened += 1 }).inspect()).tap()

        #expect(opened == 1)
    }

    /// The top buttons hug the sidebar's screen edge, Settings outermost, and open their labels away from it.
    @Test(arguments: [
        (SidebarSettings.Sidebar.Side.right, ["Clear All", "Settings"], HorizontalEdge.leading),
        (.left, ["Settings", "Clear All"], .trailing),
    ])
    func controlsFollowTheSidebarSide(side: SidebarSettings.Sidebar.Side, order: [String], expandsToward: HorizontalEdge) throws {
        let buttons = try view(side: side).inspect().findAll(ExpandingIconButton.self).map { try $0.actualView() }

        #expect(buttons.map(\.title) == order)
        #expect(buttons.allSatisfy { $0.expandsToward == expandsToward })
    }

    /// The scroll indicator only exists while the list scrolls, so this checks the edge it is placed on.
    @Test(arguments: [(SidebarSettings.Sidebar.Side.right, HorizontalAlignment.trailing), (.left, .leading)])
    func buttonsAndScrollIndicatorSitOnTheScreenEdge(side: SidebarSettings.Sidebar.Side, edge: HorizontalAlignment) {
        #expect(view(side: side).screenEdge == edge)
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

        #expect(try sut.find(text: "Build done").attributes().font() == typography.font(.body).bold())
        #expect(try sut.find(text: "main").attributes().font() == typography.font(.callout))
        #expect(try sut.find(text: "All green").attributes().font() == typography.font(.callout))
        #expect(try sut.find(text: "Shown by macOS for its buttons").attributes().font() == typography.font(.caption2))
    }

    @Test func iconButtonsTurnWhiteWhilePressed() throws {
        let style = ExpandingIconButtonStyle(expandsToward: .leading)

        for pressed in [false, true] {
            let labels = try style.inspect(isPressed: pressed).findAll(ViewType.StyleConfiguration.Label.self)
            let white = try #require(labels.first { (try? $0.foregroundStyleShapeStyle(Color.self)) == .white })
            #expect(try white.opacity() == (pressed ? 1 : 0))
        }
    }

    @Test func iconButtonLabelShowsTitleOnlyWhenExpandedOnTheChosenSide() throws {
        func label(expanded: Bool, edge: HorizontalEdge) throws -> InspectableView<ViewType.HStack> {
            try ExpandingLabelStyle(isExpanded: expanded, titleEdge: edge, diameter: 18).inspect().hStack()
        }

        #expect(throws: (any Error).self) { try label(expanded: false, edge: .leading).find(ViewType.StyleConfiguration.Title.self) }
        // The stack holds an optional leading title, the icon, then an optional trailing title.
        let leading = try label(expanded: true, edge: .leading)
        #expect(throws: Never.self) { try leading.styleConfigurationTitle(0) }
        #expect(try leading.styleConfigurationIcon(1).fixedFrame().width == 18)
        #expect(throws: (any Error).self) { try leading.styleConfigurationTitle(2) }
        let trailing = try label(expanded: true, edge: .trailing)
        #expect(throws: (any Error).self) { try trailing.styleConfigurationTitle(0) }
        #expect(throws: Never.self) { try trailing.styleConfigurationTitle(2) }
    }

    @Test func edgesFadeOnlyWhileCardsAreHiddenPastThem() throws {
        for (top, bottom) in [(false, false), (true, false), (false, true), (true, true)] {
            let gradients = try EdgeFadeMask(fadesTop: top, fadesBottom: bottom).inspect().findAll(ViewType.LinearGradient.self)

            #expect(try gradients.map { try $0.gradient().stops.map(\.color) } == [
                [.black, .black.opacity(top ? 0 : 1)],
                [.black, .black.opacity(bottom ? 0 : 1)],
            ])
            #expect(try gradients.map { try $0.endPoint() } == [.top, .bottom])
        }
    }
}
