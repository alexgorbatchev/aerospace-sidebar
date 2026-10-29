import Foundation
import PermissionFlow
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

    func view(
        side: SidebarSettings.Sidebar.Side = .right,
        openSettings: @escaping (SettingsGroup) -> Void = { _ in },
        setUp: @escaping (PermissionFlowPane, CGRect?) -> Void = { _, _ in }
    ) -> SidebarView {
        SidebarView(model: model, side: side, openSettings: openSettings, setUp: setUp)
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
            presentAlert: model.presentAlert(of: notification),
            isHovered: hovered,
            hover: { _ in },
            activate: { model.activate(notification.id) },
            choose: { model.choose($0, for: notification.id) },
            openLink: { model.openLink($0) },
            dismiss: { model.dismiss(notification.id) }
        )
    }

    @Test func dismissButtonRemovesWithoutAction() throws {
        model.add(SidebarNotification(source: "cli", title: "Keep quiet", action: .open(URL(string: "https://a.example")!)))

        try card(model.notifications[0], hovered: true).inspect().find(viewWithAccessibilityLabel: "Dismiss").button().tap()

        #expect(performer.actions.isEmpty)
        #expect(model.notifications.isEmpty)
    }

    /// Option-click dismisses a card without its action, so a click that opens something says so.
    @Test func optionClickDismissesWithoutAction() throws {
        model.add(SidebarNotification(source: "cli", title: "Keep quiet", action: .open(URL(string: "https://a.example")!)))
        let sut = card(model.notifications[0], hovered: false)

        let style = try #require(try sut.inspect().find(ViewType.Button.self).buttonStyle() as? PressableButtonStyle)
        let alternateAction = try #require(style.alternateAction)
        alternateAction()

        #expect(sut.helpText == "Click to open https://a.example\nOption-click to dismiss")
        #expect(performer.actions.isEmpty)
        #expect(model.notifications.isEmpty)
    }

    @Test func helpMentionsOptionClickOnlyWhenAClickDoesMore() throws {
        model.add(SidebarNotification(source: "cli", title: "Plain"))
        model.add(SidebarNotification(source: "macOS", title: "Privacy", nativeAlert: .init(identifier: "a", choices: ["Allow…"])))
        model.presentAlerts = ["a"]

        let plain = try #require(model.notifications.first { $0.title == "Plain" })
        let alert = try #require(model.notifications.first { $0.title == "Privacy" })

        #expect(card(plain, hovered: false).helpText == "Click to dismiss")
        #expect(card(alert, hovered: false).helpText == "Click to open, as clicking the macOS alert would\nOption-click to dismiss")
    }

    @Test func dismissButtonShowsOnlyWhileTheCardIsHovered() throws {
        model.add(SidebarNotification(source: "cli", title: "Keep quiet"))

        let sut = try card(model.notifications[0], hovered: false).inspect()

        #expect(try sut.find(ExpandingIconButton.self).opacity() == 0)
        #expect(throws: (any Error).self) { try sut.find(viewWithAccessibilityLabel: "Dismiss").button().tap() }
        #expect(model.notifications.count == 1)
    }

    /// The dismiss button is drawn for the card it sits on, in that card's tint.
    @Test(arguments: NotificationSeverity.allCases)
    func dismissButtonSitsOnTheCard(severity: NotificationSeverity) throws {
        model.add(SidebarNotification(source: "cli", title: "On a card", severity: severity))

        let button = try card(model.notifications[0], hovered: true).inspect().find(ExpandingIconButton.self).actualView()

        #expect(button.surface == .card(severity))
        let style = try #require(try button.inspect().button().buttonStyle() as? ExpandingIconButtonStyle)
        #expect(style.surface == .card(severity))
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

        let icon = try view().inspect().find(viewWithAccessibilityLabel: "Google Chrome").image()

        let image = try icon.actualImage().nsImage()
        #expect(image === AppIconFont.image(for: .init(id: "google_chrome"), artwork: NotificationCard.iconArtwork))
        #expect(image.isTemplate)
    }

    /// A notification from an app shows the app's icon, leaving the app's name to the source text.
    @Test func drawsTheIconOfTheAppThatPosted() throws {
        let appIcon = NSImage(size: NSSize(width: 64, height: 64))
        model.add(SidebarNotification(source: "Slack", title: "Ping", bundleIdentifier: "com.tinyspeck.slackmacgap"))

        let sut = try view()
            .environment(\.appIcon) { $0 == "com.tinyspeck.slackmacgap" ? appIcon : nil }
            .inspect()
        let image = try sut.find(ViewType.Image.self) { try $0.actualImage().nsImage() === appIcon }

        #expect(try image.accessibilityHidden())
        #expect(throws: Never.self) { try sut.find(text: "Slack") }
    }

    /// An icon the notification names wins over its app's, and an app that is no longer installed shows none.
    @Test func prefersTheNamedIconAndSkipsMissingApps() throws {
        let appIcon = NSImage(size: NSSize(width: 64, height: 64))
        model.add(SidebarNotification(
            source: "Chrome", title: "Named", icon: AppIconFont.vendored.icon(for: "google_chrome"), bundleIdentifier: "com.google.Chrome"
        ))
        model.add(SidebarNotification(source: "Gone", title: "Removed", bundleIdentifier: "com.example.removed"))

        let sut = try view()
            .environment(\.appIcon) { $0 == "com.google.Chrome" ? appIcon : nil }
            .inspect()

        #expect(throws: Never.self) { try sut.find(viewWithAccessibilityLabel: "Google Chrome") }
        #expect(sut.findAll(ViewType.Image.self) { try $0.actualImage().nsImage() === appIcon }.isEmpty)
    }

    /// Links in the body are links in the card's text; VoiceOver, which sees the card as one button, gets
    /// each as an action. Opening one keeps the card.
    @Test func opensLinksInTheBodyWithoutDismissing() throws {
        model.add(SidebarNotification(source: "cli", title: "Build failed", body: "Log: https://ci.example.com/runs/42"))
        let notification = try #require(model.notifications.first)

        let sut = try card(notification, hovered: false).inspect()
        let body = try sut.find(text: "Log: https://ci.example.com/runs/42")
        try sut.find(ViewType.Button.self).accessibilityActions().find(button: "Open ci.example.com").tap()

        #expect(try body.attributes().font() == Typography(SidebarSettings.Font()).font(.callout))
        #expect(performer.actions == [.open(URL(string: "https://ci.example.com/runs/42")!)])
        #expect(model.notifications.map(\.id) == [notification.id])
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

    /// A card offers its alert's choices only while the alert exists.
    @Test func offersTheChoicesOfAPresentAlert() throws {
        let alerts = RecordingAlerts()
        model.alerts = alerts
        model.add(SidebarNotification(source: "macOS", title: "Privacy & Security", nativeAlert: .init(identifier: "a", choices: ["Allow…", "Later"])))

        #expect(throws: (any Error).self) { try view().inspect().find(button: "Allow…") }

        model.presentAlerts = ["a"]
        // The card's label holds the buttons the pointer clicks; its accessibility actions repeat them.
        let label = try view().inspect().find(NotificationCard.self).find(ViewType.Button.self).labelView()
        #expect(try label.find(button: "Later").labelView().text().attributes().font() == Typography(SidebarSettings.Font()).font(.callout))
        try label.find(button: "Allow…").tap()

        #expect(alerts.performed == ["Allow… a"])
        #expect(performer.actions.isEmpty)
        #expect(model.notifications.isEmpty)
    }

    /// VoiceOver sees a card as one button: its label reads what the card shows, and its actions offer the
    /// alert's choices and Dismiss, whose buttons VoiceOver cannot press inside the card.
    @Test func voiceOverReadsCardsAndReachesTheirButtons() throws {
        let alerts = RecordingAlerts()
        model.alerts = alerts
        model.add(SidebarNotification(source: "macOS", title: "Privacy & Security", body: "Allow it?", nativeAlert: .init(identifier: "a", choices: ["Allow…", "Later"])))
        for _ in 0..<2 {
            model.add(SidebarNotification(source: "Calendar", title: "Standup", severity: .high, shownByMacOS: true))
        }
        model.presentAlerts = ["a"]
        let privacy = try #require(model.notifications.first { $0.title == "Privacy & Security" })
        let standup = try #require(model.notifications.first { $0.title == "Standup" })

        let privacyCard = try card(privacy, hovered: false).inspect().find(ViewType.Button.self)
        let standupCard = try card(standup, hovered: false).inspect().find(ViewType.Button.self)

        let privacyLabel = try privacyCard.accessibilityLabel().string()
        #expect(privacyLabel.hasPrefix("macOS, "))
        #expect(privacyLabel.hasSuffix(", Privacy & Security, Allow it?"))
        let standupLabel = try standupCard.accessibilityLabel().string()
        #expect(standupLabel.hasPrefix("high, Calendar, "))
        #expect(standupLabel.hasSuffix(", Received 2 times, Standup, Shown by macOS for its buttons"))
        #expect(throws: (any Error).self) { try standupCard.accessibilityActions().find(button: "Allow…") }

        try privacyCard.accessibilityActions().find(button: "Later").tap()
        try standupCard.accessibilityActions().find(button: "Dismiss").tap()

        #expect(alerts.performed == ["Later a"])
        #expect(performer.actions.isEmpty)
        #expect(model.notifications.isEmpty)
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
                presentAlert: nil,
                isHovered: hovered,
                hover: { _ in },
                activate: {},
                choose: { _ in },
                openLink: { _ in },
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

    /// Set Up… starts PermissionFlow's Accessibility step rather than only opening Settings.
    @Test func promptsForSetupWhenAccessibilityIsMissing() throws {
        model.interception = .needsAccessibility
        var setUps: [PermissionFlowPane] = []

        let sut = try view(setUp: { pane, _ in setUps.append(pane) }).inspect()
        try button("Set Up Accessibility", in: sut).tap()

        #expect(throws: Never.self) { try sut.find(text: "Grant Accessibility access to show macOS notifications here.") }
        #expect(setUps == [.accessibility])
        #expect(throws: (any Error).self) { try sut.find(text: SidebarView.fullDiskAccessNote) }
    }

    /// Full Disk Access is optional: the note asking for it starts its step or goes for good.
    @Test func asksForFullDiskAccessUntilDismissed() throws {
        model.database = .needsFullDiskAccess
        var setUps: [PermissionFlowPane] = []

        let sut = try view(setUp: { pane, _ in setUps.append(pane) }).inspect()
        try button("Set Up Full Disk Access", in: sut).tap()
        #expect(setUps == [.fullDiskAccess])
        try sut.find(button: "Dismiss").tap()

        #expect(model.fullDiskAccessNoteDismissed)
        #expect(throws: (any Error).self) { try view().inspect().find(text: SidebarView.fullDiskAccessNote) }
    }

    @Test func asksForFullDiskAccessOnlyWhileMacOSRefusesIt() throws {
        for status in [NotificationDatabaseStatus.stopped, .reading, .unreadable] {
            model.database = status
            #expect(throws: (any Error).self) { try view().inspect().find(text: SidebarView.fullDiskAccessNote) }
        }
    }

    @Test func settingsButtonOpensSettings() throws {
        var opened: [SettingsGroup] = []

        try button("Settings", in: view(openSettings: { opened.append($0) }).inspect()).tap()

        #expect(opened == [.general])
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
        // They belong to no card, so they float over the background.
        #expect(buttons.allSatisfy { $0.surface == .floating })
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

    /// The saber border is switched off for now, but cards and icon buttons keep asking for it.
    @Test(arguments: [(NotificationSeverity.normal, Color.accentColor), (.high, .orange), (.critical, .red)])
    func cardsAskForTheirBorderOnlyWhileHovered(severity: NotificationSeverity, color: Color) throws {
        model.add(SidebarNotification(source: "s", title: "t", severity: severity))

        for hovered in [false, true] {
            let sut = try card(model.notifications[0], hovered: hovered).inspect()
            let saber = try sut.find(where: { (try? $0.modifier(SaberBorderModifier<RoundedRectangle>.self)) != nil })
                .modifier(SaberBorderModifier<RoundedRectangle>.self).actualView()
            #expect(saber.isActive == hovered)
            #expect(saber.color == color)
            #expect(throws: (any Error).self) { try sut.find(SaberBorder<RoundedRectangle>.self) }
        }
    }

    /// A choice casts the choice shadow under the pointer, keeps its size and takes its own clicks.
    @Test func choiceButtonsLiftUnderThePointer() throws {
        var chosen = 0
        for hovered in [false, true] {
            let sut = try ChoiceButton(title: "Allow", isHovered: hovered) { chosen += 1 }.inspect()
            let shadow = try sut.find(where: { (try? $0.modifier(CardButtonShadowEffect.self)) != nil })
                .modifier(CardButtonShadowEffect.self).actualView()

            #expect(shadow.shadow == .choice)
            #expect(shadow.isHovered == hovered)
            #expect(throws: (any Error).self) { try sut.find(where: { (try? $0.scaleEffect()) != nil }) }
            try sut.find(button: "Allow").tap()
        }
        #expect(chosen == 2)
    }

    /// On a card an icon button casts the dismiss shadow while highlighted instead of the floating shadow,
    /// has a primary label that stays put and the dismiss sizes. Floating, it has the floating shadow, a
    /// secondary label that turns white, and the sidebar's sizes.
    @Test(arguments: [false, true])
    func iconButtonsOnACardTakeTheDismissLooks(onCard: Bool) throws {
        let surface: ExpandingIconButton.Surface = onCard ? .card(.high) : .floating
        for pressed in [false, true] {
            let sut = try ExpandingIconButtonStyle(expandsToward: .leading, surface: surface).inspect(isPressed: pressed)
            let hoverShadow = try sut.find(where: { (try? $0.modifier(CardButtonShadowEffect.self)) != nil })
                .modifier(CardButtonShadowEffect.self).actualView()
            let labels = sut.findAll(ViewType.StyleConfiguration.Label.self)
            let white = try #require(labels.first { (try? $0.foregroundStyleShapeStyle(Color.self)) == .white })
            let shadow = try sut.find(where: { (try? $0.shadow()) != nil }).shadow()

            #expect(hoverShadow.shadow == (onCard ? .dismiss : nil))
            #expect(hoverShadow.isHovered == pressed)
            #expect(try white.opacity() == (pressed && !onCard ? 1 : 0))
            #expect(shadow.color == .black.opacity(onCard ? 0 : 0.5))
            // Drawn at its own size, never scaled, so its edges can fall on whole pixels.
            #expect(throws: (any Error).self) { try sut.find(where: { (try? $0.scaleEffect()) != nil }) }
        }
        #expect(surface.diameterScale == (onCard ? NotificationCard.hoverScale : 1))
        #expect(surface.textScale == (onCard ? 0.9 * NotificationCard.hoverScale : 1))
    }

    /// Drawn on a clear capsule, the shadows are all there is: the halo just past the edge, the hover
    /// shadow below the bottom edge while hovered, and nothing inside, where they are cut out.
    @Test(arguments: [false, true])
    func cardButtonShadowsFallAroundTheButton(isDismiss: Bool) throws {
        let shadow: CardButtonShadow = isDismiss ? .dismiss : .choice
        for hovered in [false, true] {
            // The capsule spans 4 to 44 points across and 4 to 24 points down: 16 to 176 and 16 to 96
            // pixels at this scale.
            let view = Color.clear.frame(width: 40, height: 20)
                .modifier(CardButtonShadowEffect(shadow: shadow, isHovered: hovered))
                .padding(4)
            let renderer = ImageRenderer(content: view.settledForRendering())
            renderer.scale = 4
            let image = try #require(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let alpha = { (x: Int, y: Int) in Double(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) }

            // Half a point above the top edge only the halo reaches.
            #expect((alpha(96, 14) > 0.1) == (shadow.halo > 0))
            // Just over a point below the bottom edge the hover shadow covers whatever halo is left. Its
            // caster is a pixel smaller than the button, so it ends a pixel short of two points.
            #expect((alpha(96, 101) > 0.4) == hovered)
            #expect(alpha(96, 56) < 0.01)
        }
    }

    /// A cut-out shadow falls only around a translucent view: inside it the view looks as it does without a
    /// shadow, and its curved edge pixels stay between the inside and the shadowed outside. A shadow on the
    /// view itself shows through it, darkening the inside and the partly covered edge pixels.
    @Test func cutOutShadowFallsOnlyAroundTheView() throws {
        func render(shadowed: Bool) throws -> NSBitmapImageRep {
            let card = RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.5)).frame(width: 40, height: 40)
            let view = Group {
                if shadowed {
                    card.cutOutShadows(RoundedRectangle(cornerRadius: 10), reach: 20) {
                        ShadowCaster(shape: RoundedRectangle(cornerRadius: 10), opacity: 0.5, radius: 5, y: 2)
                    }
                } else {
                    card
                }
            }
            let renderer = ImageRenderer(content: view.padding(10).background(Color(white: 0.6)).settledForRendering())
            renderer.scale = 4
            let image = try #require(renderer.cgImage)
            return NSBitmapImageRep(cgImage: image)
        }
        // Along the diagonal through the bottom-left corner, `d` pixels in from the padded corner; the arc
        // crosses it between pixels 10 and 12.
        func brightness(_ bitmap: NSBitmapImageRep, _ d: Int) -> Double {
            Double(bitmap.colorAt(x: 40 + d, y: 199 - d)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0)
        }
        let plain = try render(shadowed: false), shadowed = try render(shadowed: true)
        let inside = brightness(shadowed, 14), edge = brightness(shadowed, 11), outside = brightness(shadowed, 9)

        #expect(abs(inside - brightness(plain, 14)) < 0.005)
        #expect(edge > outside && edge < inside)
        #expect(outside < brightness(plain, 9) - 0.05)
    }

    /// The card's outline holds the card and each stack layer under it, inset more per layer.
    @Test func cardSilhouetteLaysOutTheStackLayers() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 60)
        let path = CardSilhouette(stackLayers: 2).path(in: rect)

        #expect(path.boundingRect == rect)
        // The card ends 10 points up; the first layer spans 8 to 92, the second 16 to 84.
        #expect(path.contains(CGPoint(x: 50, y: 49)))
        #expect(path.contains(CGPoint(x: 10, y: 52)))
        #expect(!path.contains(CGPoint(x: 6, y: 52)))
        #expect(path.contains(CGPoint(x: 18, y: 56)))
        #expect(!path.contains(CGPoint(x: 12, y: 56)))
        #expect(CardSilhouette(stackLayers: 0).path(in: rect) == RoundedRectangle(cornerRadius: NotificationCard.cornerRadius).path(in: rect))
    }

    /// Icon buttons are as wide as the text needs, rounded to whole pixels; on a card, as large as they
    /// look on the card scaled under the pointer.
    @Test(arguments: [1.0, 2.0])
    func iconButtonDiametersFallOnWholePixels(displayScale: CGFloat) {
        let typography = Typography(SidebarSettings.Font(name: "", size: SidebarSettings.Font.defaultSize))
        let floating = ExpandingIconButton.diameter(.floating, typography: typography, displayScale: displayScale)
        let card = ExpandingIconButton.diameter(.card(.high), typography: typography, displayScale: displayScale)

        #expect(floating == ExpandingIconButton.diameter)
        // 18 × 1.02 = 18.36 points: 18 at 1×, 37 pixels (18.5 points) at 2×.
        #expect(card == (displayScale == 1 ? 18 : 18.5))
    }

    /// The dismiss button follows the corner of the card, which the hover scale moves out by half the
    /// growth of each side, on whole pixels.
    @Test func dismissButtonFollowsTheScaledCornerOnWholePixels() {
        let size = CGSize(width: 301, height: 87)

        #expect(NotificationCard.dismissOffset(cardSize: size, scale: 1, displayScale: 2) == CGSize(width: 5, height: -5))
        // 5 + 3.01 and 5 + 0.87 points, to the nearest half point.
        #expect(NotificationCard.dismissOffset(cardSize: size, scale: 1.02, displayScale: 2) == CGSize(width: 8, height: -6))
        #expect(NotificationCard.dismissOffset(cardSize: size, scale: 1.02, displayScale: 1) == CGSize(width: 8, height: -6))
    }

    /// Without a shadow, the effect adds no shadow casters; with one, it adds the halo's and the hover
    /// shadow's. Checked in the view tree: a render here can come back with another test's drawing.
    @Test func cardButtonShadowEffectWithoutAShadowDrawsNothing() throws {
        func casters(_ shadow: CardButtonShadow?) throws -> Int {
            try Color.clear.modifier(CardButtonShadowEffect(shadow: shadow, isHovered: true)).inspect()
                .findAll(ShadowCaster<Capsule>.self).count
        }

        #expect(try casters(nil) == 0)
        #expect(try casters(.dismiss) == 2)
    }

    @Test func iconButtonsAskForTheirBorderWhilePressed() throws {
        let style = ExpandingIconButtonStyle(expandsToward: .leading)

        for pressed in [false, true] {
            let sut = try style.inspect(isPressed: pressed)
            let saber = try sut.find(where: { (try? $0.modifier(SaberBorderModifier<Capsule>.self)) != nil })
                .modifier(SaberBorderModifier<Capsule>.self).actualView()
            #expect(saber.isActive == pressed)
            #expect(saber.color == .accentColor)
            #expect(throws: (any Error).self) { try sut.find(SaberBorder<Capsule>.self) }
        }
    }

    /// Switched on, the border shows its glow only while active.
    @Test func saberBorderShowsWhileActiveOnceSwitchedOn() throws {
        for active in [false, true] {
            let sut = try Color.clear
                .saberBorder(Capsule(), color: .red, isActive: active)
                .environment(\.showsSaberBorder, true)
                .inspect()
            let saber = try sut.find(SaberBorder<Capsule>.self)
            #expect(try saber.actualView().isActive == active)
            #expect(try saber.zStack().opacity() == (active ? 1 : 0))
        }
    }

    /// On a rectangle, a stretch of outline turning at most one corner is as long as its bounds are wide
    /// plus tall, so equal steps of the head cover equal distances on horizontal and vertical edges alike.
    @Test func saberBeamKeepsOnePaceOnEveryEdge() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 40)
        let perimeter = 2 * (rect.width + rect.height)
        let length: CGFloat = 0.05

        for head in stride(from: length, through: 1, by: 0.01) {
            let bounds = SaberTrail(outline: Rectangle(), head: head, length: length).path(in: rect).boundingRect
            #expect(abs(bounds.width + bounds.height - length * perimeter) < 0.01, "head \(head)")
        }
    }

    /// A rectangle's outline runs clockwise from its top-left corner.
    @Test(arguments: [(50.0, -5.0, 50.0), (210, 20, 220), (100, 45, 340), (0, 20, 460)])
    func saberBeamStartsNearestTheEntryPoint(x: Double, y: Double, distance: Double) {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 40)
        let entry = CGPoint(x: x, y: y)

        #expect(abs(SaberTrail<Rectangle>.fraction(nearest: entry, along: Rectangle().path(in: rect)) - distance / 480) < 1e-6)
    }

    /// From an entry on the left edge, the beam grows upward out of it, crosses the outline's start at the
    /// top-left corner as two pieces, and keeps one pace throughout.
    @Test func saberBeamRunsFromTheEntryAcrossTheOutlineStart() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 40)
        let entry = CGPoint(x: -3, y: 30)
        func trail(head: CGFloat) -> CGRect {
            SaberTrail(outline: Rectangle(), entry: entry, head: head, length: 0.05).path(in: rect).boundingRect
        }

        let first = trail(head: 0.01)
        #expect(first.minX == 0 && first.width == 0)
        #expect(abs(first.maxY - 30) < 0.01 && abs(first.height - 4.8) < 0.01, "\(first)")
        for head in stride(from: 0.05, through: 1, by: 0.01) {
            let bounds = trail(head: head)
            #expect(abs(bounds.width + bounds.height - 24) < 0.01, "head \(head)")
        }
        // Crossing the start: up the left edge and on along the top.
        let crossing = trail(head: 0.08)
        #expect(crossing.minX == 0 && crossing.minY == 0 && crossing.width > 0 && crossing.height > 0)
    }

    @Test func saberBorderKeepsThePointerEntryUntilItLeaves() {
        let first = CGPoint(x: 3, y: 4)

        #expect(SaberBorderModifier<Capsule>.entry(nil, after: .active(first)) == first)
        #expect(SaberBorderModifier<Capsule>.entry(first, after: .active(CGPoint(x: 9, y: 9))) == first)
        #expect(SaberBorderModifier<Capsule>.entry(first, after: .ended) == nil)
    }

    /// The beam grows out of the outline's start while fading in, and fades out while its head runs on past
    /// the start at full length, so neither end of the lap cuts it off.
    @Test func saberBeamFadesInAtTheStartAndOutPastIt() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 40)
        // A quarter-lap beam, so the stretch past the start stays on the edges asserted below.
        let length: CGFloat = 0.25
        func trail(head: CGFloat) -> CGRect {
            SaberTrail(outline: Rectangle(), head: head, length: length).path(in: rect).boundingRect
        }
        func extent(_ bounds: CGRect) -> CGFloat { bounds.width + bounds.height }

        #expect(SaberTrail(outline: Rectangle(), head: 0, length: length).path(in: rect).isEmpty)
        // Entering, only the part already past the start shows.
        #expect(extent(trail(head: 0.1)) < extent(trail(head: 0.5)))
        // Past the start the head runs on: up the left edge and 48 points (a tenth of the outline) along the top.
        let past = trail(head: 1.1)
        #expect(past.minX == 0 && past.minY == 0 && abs(past.maxX - 0.1 * 480) < 0.01, "\(past)")
        #expect(SaberBeam.fade(at: 0) == 0)
        #expect(SaberBeam.fade(at: SaberBeam.length / 2) == 0.5)
        #expect(SaberBeam.fade(at: SaberBeam.length) == 1)
        #expect(SaberBeam.fade(at: 0.5) == 1)
        #expect(SaberBeam.fade(at: 1) == 1)
        #expect(SaberBeam.fade(at: 1 + SaberBeam.length / 2) == 0.5)
        #expect(SaberBeam.fade(at: SaberBeam.end) == 0)
        for head in stride(from: CGFloat(0), to: SaberBeam.length, by: 0.01) {
            #expect(SaberBeam.fade(at: head) < SaberBeam.fade(at: head + 0.01))
            #expect(SaberBeam.fade(at: 1 + head) > SaberBeam.fade(at: 1 + head + 0.01))
        }
        // SwiftUI animates the head of the trail and the blade, so the lap and its fade play out.
        var animated = SaberTrail(outline: Rectangle(), head: 0, length: length)
        animated.animatableData = 0.5
        #expect(animated.path(in: rect).boundingRect == trail(head: 0.5))
        var blade = SaberBlade(shape: Rectangle(), color: .red, entry: nil, head: 0)
        blade.animatableData = 1.1
        #expect(blade.head == 1.1)
    }

    /// From an entry late in the outline, the head runs past the entry at full length, across the outline's
    /// start again.
    @Test func saberBeamRunsOnPastTheEntry() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 40)
        let entry = CGPoint(x: -3, y: 30)

        for head in stride(from: CGFloat(1), through: SaberBeam.end, by: 0.01) {
            let bounds = SaberTrail(outline: Rectangle(), entry: entry, head: head, length: 0.05).path(in: rect).boundingRect
            #expect(abs(bounds.width + bounds.height - 24) < 0.01, "head \(head)")
        }
    }

    /// The title is always beside the icon on the chosen side; collapsed, the label is the icon's width,
    /// pinned to the icon's side, and the title is invisible.
    @Test(arguments: [HorizontalEdge.leading, .trailing])
    func iconButtonLabelRevealsTitleBesideTheIcon(edge: HorizontalEdge) throws {
        // The stack holds a slot for a leading title, the icon, then a slot for a trailing title.
        let iconIndex = 1
        let titleIndex = edge == .leading ? 0 : 2
        for expanded in [false, true] {
            let stack = try ExpandingLabelStyle(isExpanded: expanded, titleEdge: edge, diameter: 18).inspect().hStack()

            #expect(try stack.styleConfigurationIcon(iconIndex).fixedFrame().width == 18)
            #expect(try stack.styleConfigurationTitle(titleIndex).opacity() == (expanded ? 1 : 0))
            #expect((try? stack.fixedWidth()) == (expanded ? nil : 18))
            #expect(try stack.fixedAlignment().horizontal == (edge == .leading ? .trailing : .leading))
        }
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

extension View {
    /// The view with animations off, for `ImageRenderer`, so it renders its final state.
    func settledForRendering() -> some View {
        transaction { $0.disablesAnimations = true }
    }
}
