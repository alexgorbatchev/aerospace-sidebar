import AppKit
@testable import SidebarKit
import SidebarProtocol
import SwiftUI
import Testing

/// `SidebarModel.arrivals`: which cards arriving notifications were listed on.
@MainActor
struct NotificationArrivalTests {
    let start = Date()

    func model(
        store: InMemoryStore = InMemoryStore(),
        history: SidebarSettings.History = SidebarSettings.History(),
        rules: [SidebarSettings.Rule] = []
    ) -> SidebarModel {
        SidebarModel(performer: RecordingPerformer(), store: store, history: history, rules: rules, now: { [start] in start })
    }

    func notification(_ title: String, severity: NotificationSeverity = .normal, age: TimeInterval = 0) -> SidebarNotification {
        SidebarNotification(source: "s", title: title, severity: severity, receivedAt: start.addingTimeInterval(-age))
    }

    @Test func cardsRestoredAtLaunchDidNotArrive() {
        let sut = model(store: InMemoryStore([notification("kept")]))

        #expect(sut.notifications.map(\.title) == ["kept"])
        #expect(sut.arrivals.count == 0)
        #expect(sut.arrivals.cards(after: 0).isEmpty)
    }

    /// The sidebar sees arrivals made together as one change, and asks for the cards of all of them.
    @Test func namesTheCardsArrivalsWereListedOnSinceAGivenOne() {
        let sut = model()
        let urgent = notification("urgent", severity: .critical)
        let chatter = notification("chatter", severity: .low)

        sut.add(urgent)
        #expect(sut.arrivals.count == 1)
        #expect(sut.arrivals.cards(after: 0) == [urgent.id])
        // A low card lands at the end of the list; it is still a card that arrived.
        sut.add(chatter)
        #expect(sut.arrivals.count == 2)
        #expect(sut.arrivals.cards(after: 1) == [chatter.id])
        #expect(sut.arrivals.cards(after: 0) == [urgent.id, chatter.id])
        #expect(sut.arrivals.cards(after: 2).isEmpty)
    }

    /// A repeat moves its card up as the newest, so it arrives on that card, and each repeat is a new arrival.
    @Test func aRepeatArrivesOnTheCardItStacksOnto() {
        let sut = model()
        let first = notification("again", age: 2)
        sut.add(first)
        sut.add(notification("other", age: 1))

        sut.add(notification("again"))
        #expect(sut.arrivals.cards(after: 2) == [first.id])
        sut.add(notification("again"))
        #expect(sut.arrivals.count == 4)
        #expect(sut.arrivals.cards(after: 3) == [first.id])
        #expect(sut.notifications.map(\.title) == ["again", "other"])
    }

    /// Cards that are gone are forgotten at the next arrival, so the record stays as small as the list.
    @Test func forgetsCardsNoLongerListed() {
        let sut = model()
        let gone = notification("gone", age: 1)
        let next = notification("next")
        sut.add(gone)
        sut.dismiss(gone.id)

        sut.add(next)

        #expect(sut.arrivals.cards(after: 0) == [next.id])
    }

    @Test func onlyArrivalsChangeIt() {
        let store = InMemoryStore()
        let sut = model(store: store)
        sut.add(notification("old", age: 7200))
        sut.add(notification("one", age: 2))
        sut.add(notification("two", age: 1))
        let arrivals = sut.arrivals

        sut.apply(rules: [SidebarSettings.Rule(title: "one", action: .severity(.critical))])
        sut.apply(history: SidebarSettings.History(retentionHours: 1, maxCount: 10))
        sut.dismiss(sut.notifications[0].id)
        sut.clear()

        #expect(store.stored.isEmpty)
        #expect(sut.arrivals == arrivals)
    }

    /// A notification that gets no card arrives nowhere.
    @Test func notificationsWithoutACardArriveNowhere() {
        let sut = model(
            history: SidebarSettings.History(maxCount: 10),
            rules: [SidebarSettings.Rule(title: "spam", action: .hide)]
        )
        for index in 0..<10 {
            sut.add(notification("urgent \(index)", severity: .high))
        }
        let arrivals = sut.arrivals

        // A rule hides it.
        sut.add(notification("spam"))
        // The full list drops the least severe card, which is the one that arrived.
        sut.add(notification("chatter", severity: .low))
        // It is older than the history keeps.
        sut.add(notification("ancient", severity: .critical, age: 2 * 24 * 3600))

        #expect(sut.notifications.count == 10 && sut.notifications.allSatisfy { $0.title.hasPrefix("urgent") })
        #expect(sut.arrivals == arrivals)
    }
}

/// When an arrival leaves the list alone (`SidebarActivity`).
struct SidebarActivityTests {
    @Test func theUserIsOnTheListWithThePointerWhileTypingAndWhileTheirScrollGoesOn() {
        #expect(!SidebarActivity().isUsingList)
        #expect(SidebarActivity(pointerIsOn: true).isUsingList)
        // A reply typed with the pointer elsewhere, or through VoiceOver.
        #expect(SidebarActivity(isComposing: true).isUsingList)
        for phase in [ScrollPhase.tracking, .interacting, .decelerating] {
            #expect(SidebarActivity(scrollPhase: phase).isUsingList, "\(phase)")
        }
        // The sidebar's own scroll, as for an earlier arrival, which the next one takes over.
        #expect(!SidebarActivity(scrollPhase: .animating).isUsingList)
    }
}

/// Where the list scrolls for an arrival (`ArrivalScroll`).
@MainActor
struct ArrivalScrollTests {
    let start = Date()
    /// The list's height in these tests; `EdgeFadeMask.height` (48) fades its edges, and `SidebarView.margin` (16)
    /// sits under the last card.
    let height: CGFloat = 600

    func card(top: CGFloat, height: CGFloat = 53) -> CGRect {
        CGRect(x: 16, y: top, width: 268, height: height)
    }

    func offset(showing frame: CGRect, from offset: CGFloat) -> CGFloat? {
        ArrivalScroll.offset(showing: frame, from: offset, visibleHeight: height)
    }

    @Test func leavesACardThatShowsClearOfTheFadesWhereItIs() {
        #expect(offset(showing: card(top: 500), from: 300) == nil)
        // Nothing fades at the top of the list.
        #expect(offset(showing: card(top: 5), from: 0) == nil)
    }

    /// The least scrolling that shows the card: its edge stops where the fade ends.
    @Test func bringsACardInClearOfTheFadeOnItsSide() {
        // Below the visible cards: its bottom 48 points above the bottom edge.
        #expect(offset(showing: card(top: 1000), from: 0) == CGFloat(1053 + 48 - 600))
        // Above them: its top 48 points below the top edge.
        #expect(offset(showing: card(top: 66), from: 1000) == CGFloat(66 - 48))
        // In view, but under a fade.
        #expect(offset(showing: card(top: 500), from: 0) == CGFloat(553 + 48 - 600))
        #expect(offset(showing: card(top: 1020), from: 1000) == CGFloat(1020 - 48))
    }

    /// The first card shows at the top, with the room above it for its dismiss button, and the last at the end, with
    /// the margin under it, without waiting for a lazy list to lay them out.
    @Test func showsTheFirstCardAtTheTopAndTheLastAtTheEnd() {
        let list = list()
        let sut = scroller()

        #expect(sut.arrived(on: [list[0].id], in: list, offset: 300, isUsingList: false) == .offset(0))
        #expect(sut.arrived(on: [list[0].id], in: list, offset: 0, isUsingList: false) == nil)
        #expect(sut.arrived(on: [list[3].id], in: list, offset: 0, isUsingList: false) == .end)
        // A card on its own is the first.
        #expect(sut.arrived(on: [list[3].id], in: [list[3]], offset: 0, isUsingList: false) == nil)
    }

    @Test func showsTheTopOfACardTooTallToShowWhole() {
        let tall = card(top: 100, height: 600)

        #expect(offset(showing: tall, from: 0) == 52)
        #expect(offset(showing: tall, from: 52) == nil)
        #expect(offset(showing: tall, from: 400) == 52)
    }

    /// Four cards, most severe first: critical, two normal, low.
    func list() -> [SidebarNotification] {
        [
            SidebarNotification(source: "s", title: "first", severity: .critical, receivedAt: start),
            SidebarNotification(source: "s", title: "middle", receivedAt: start, occurrences: 3),
            SidebarNotification(source: "s", title: "lower", receivedAt: start.addingTimeInterval(-1)),
            SidebarNotification(source: "s", title: "last", severity: .low, receivedAt: start),
        ]
    }

    /// An `ArrivalScroll` for a list `height` tall.
    func scroller() -> ArrivalScroll {
        let sut = ArrivalScroll()
        sut.visibleHeight = height
        return sut
    }

    /// Of several cards that arrived together, the top-most shows: the most severe and newest.
    @Test func scrollsToTheTopMostArrivingCardByItsIdentityUntilItIsLaidOut() {
        let list = list()
        let sut = scroller()

        let step = sut.arrived(on: [list[2].id, list[1].id], in: list, offset: 1000, isUsingList: false)

        // Cards are identified by their count too, since a repeat gets a new card (`SidebarView`).
        #expect(step == .card(SidebarNotification.ViewIdentity(id: list[1].id, occurrences: 3)))
    }

    /// The card's frame, once laid out, sets the offset, compared with where the list was when the card arrived.
    @Test func theAwaitedCardsFrameSetsTheOffset() {
        let list = list()
        let sut = scroller()
        _ = sut.arrived(on: [list[1].id], in: list, offset: 1000, isUsingList: false)

        #expect(sut.laidOut(list[0].viewIdentity, at: card(top: 5), isUsingList: { false }) == nil)
        #expect(sut.laidOut(list[1].viewIdentity, at: card(top: 66), isUsingList: { false }) == CGFloat(66 - 48))
        // Only once: a later layout of the card moves nothing.
        #expect(sut.laidOut(list[1].viewIdentity, at: card(top: 70), isUsingList: { false }) == nil)
    }

    /// The list's height is its own, not what the scroll view reported (`visibleHeight`).
    @Test func showsACardAboveTheBottomFadeOfAListAsTallAsItsFrame() {
        let list = list()
        let sut = scroller()
        _ = sut.arrived(on: [list[2].id], in: list, offset: 0, isUsingList: false)

        #expect(sut.laidOut(list[2].viewIdentity, at: card(top: 1500), isUsingList: { false }) == CGFloat(1553 + 48 - 600))
        sut.visibleHeight = 500
        #expect(sut.arrived(on: [list[2].id], in: list, offset: 0, isUsingList: false) == .offset(1553 + 48 - 500))
    }

    /// SwiftUI reports an arriving card's frame after `onChange` has seen it (measured), but nothing promises it.
    @Test func aCardLaidOutBeforeItsArrivalScrollsStraightThere() {
        let list = list()
        let sut = scroller()
        _ = sut.laidOut(list[1].viewIdentity, at: card(top: 66), isUsingList: { false })

        #expect(sut.arrived(on: [list[1].id], in: list, offset: 1000, isUsingList: false) == .offset(66 - 48))
        // One that shows already moves nothing.
        _ = sut.laidOut(list[2].viewIdentity, at: card(top: 1200), isUsingList: { false })
        #expect(sut.arrived(on: [list[2].id], in: list, offset: 1000, isUsingList: false) == nil)
    }

    @Test func forgetsWhereACardSatOnceTheListNoLongerLaysItOut() {
        let list = list()
        let sut = scroller()
        _ = sut.laidOut(list[1].viewIdentity, at: card(top: 66), isUsingList: { false })

        sut.disappeared(list[1].viewIdentity)

        #expect(sut.arrived(on: [list[1].id], in: list, offset: 1000, isUsingList: false) == .card(list[1].viewIdentity))
    }

    @Test func leavesTheListAloneWhileTheUserIsOnIt() {
        let list = list()
        let sut = scroller()

        #expect(sut.arrived(on: [list[1].id], in: list, offset: 1000, isUsingList: true) == nil)
        #expect(sut.laidOut(list[1].viewIdentity, at: card(top: 66), isUsingList: { false }) == nil)

        // The user took to the list before the card was laid out.
        _ = sut.arrived(on: [list[2].id], in: list, offset: 1000, isUsingList: false)
        #expect(sut.laidOut(list[2].viewIdentity, at: card(top: 1500), isUsingList: { true }) == nil)
        #expect(sut.laidOut(list[2].viewIdentity, at: card(top: 1500), isUsingList: { false }) == nil)

        // The user scrolls the list meanwhile.
        _ = sut.arrived(on: [list[1].id], in: list, offset: 1000, isUsingList: false)
        sut.cancel()
        #expect(sut.laidOut(list[1].viewIdentity, at: card(top: 66), isUsingList: { false }) == nil)
    }

    @Test func scrollsNowhereWithoutAListedCard() {
        let list = list()
        let sut = scroller()
        let gone = SidebarNotification(source: "s", title: "dismissed")

        #expect(sut.arrived(on: [], in: list, offset: 1000, isUsingList: false) == nil)
        #expect(sut.arrived(on: [gone.id], in: list, offset: 1000, isUsingList: false) == nil)
    }

    func position() -> (Mutable<ScrollPosition>, Binding<ScrollPosition>) {
        let position = Mutable(ScrollPosition(edge: .bottom))
        return (position, Binding(get: { position.value }, set: { position.value = $0 }))
    }

    @Test func movesTheScrollPositionLikeTheSidebarMovesOrJumpsWithReduceMotion() {
        let identity = SidebarNotification.ViewIdentity(id: UUID(), occurrences: 2)
        let sut = scroller()
        let (position, binding) = position()

        sut.scroll(binding, by: .card(identity), reduceMotion: false)
        #expect(position.value.viewID(type: SidebarNotification.ViewIdentity.self) == identity)
        sut.scroll(binding, by: .end, reduceMotion: false)
        #expect(position.value.edge == .bottom)
        sut.scroll(binding, by: .offset(120), reduceMotion: true)
        #expect(position.value.viewID == nil)
        if #available(macOS 26, *) { #expect(position.value.y == 120) }
        #expect(ArrivalScroll.animation(reduceMotion: false) == SidebarView.motion)
        #expect(ArrivalScroll.animation(reduceMotion: true) == nil)
    }

    /// The sidebar animates its cards into place, with Reduce Motion too, and the content grows with them; a scroll to
    /// a place meanwhile goes again once that change is done, past where the content ended at first.
    @Test func aScrollToAPlaceGoesAgainOnceTheCardsAreInPlace() {
        let sut = scroller()
        let (_, binding) = position()

        let change = sut.layoutWillMove()
        sut.scroll(binding, by: .offset(500), reduceMotion: true)
        #expect(sut.layoutMoved(change, isUsingList: { false }) == .offset(500))
        #expect(sut.layoutMoved(change, isUsingList: { false }) == nil)

        // Not for a change done before the scroll, nor for a scroll by identity; an animated one too.
        let done = sut.layoutWillMove()
        let next = sut.layoutWillMove()
        sut.scroll(binding, by: .offset(500), reduceMotion: true)
        #expect(sut.layoutMoved(done, isUsingList: { false }) == nil)
        sut.scroll(binding, by: .offset(700), reduceMotion: false)
        sut.scroll(binding, by: .card(SidebarNotification.ViewIdentity(id: UUID(), occurrences: 1)), reduceMotion: true)
        #expect(sut.layoutMoved(next, isUsingList: { false }) == .offset(700))

        // The end too, which moves while the content grows.
        let growing = sut.layoutWillMove()
        sut.scroll(binding, by: .end, reduceMotion: false)
        #expect(sut.layoutMoved(growing, isUsingList: { false }) == .end)

        // Not when the user has taken to the list meanwhile, nor after a newer arrival.
        let moving = sut.layoutWillMove()
        sut.scroll(binding, by: .offset(500), reduceMotion: true)
        #expect(sut.layoutMoved(moving, isUsingList: { true }) == nil)
        let later = sut.layoutWillMove()
        sut.scroll(binding, by: .offset(500), reduceMotion: true)
        _ = sut.arrived(on: [], in: list(), offset: 0, isUsingList: false)
        #expect(sut.layoutMoved(later, isUsingList: { false }) == nil)
    }
}

/// The sidebar scrolling for arrivals. SwiftUI scrolls only a list it has laid out in a window, here a transparent
/// `TestPanel` that leaves the desktop alone; the list of 30 cards is far taller than the panel.
@MainActor
@Suite(.leavesDesktopAlone)
struct ArrivalScrollHostedTests {
    let start = Date()

    func listed(_ title: String, severity: NotificationSeverity = .normal, at offset: TimeInterval) -> SidebarNotification {
        SidebarNotification(source: "s", title: title, severity: severity, receivedAt: start.addingTimeInterval(offset))
    }

    func model() -> SidebarModel {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        for index in 0..<30 {
            model.add(listed("card \(index)", at: Double(index - 60)))
        }
        return model
    }

    @Test(.enabled(if: !NSScreen.screens.isEmpty, "requires a display"))
    func arrivalsScrollIntoViewClearOfTheFadesUnlessTheUserIsOnTheList() async throws {
        let model = model()
        let pointerIsOn = Mutable(false)
        let sidebar = try HostedSidebar(model: model, pointerIsOn: pointerIsOn)
        defer { sidebar.close() }
        try await sidebar.revealed()

        // A low card, delivered before the others, lands at the very end, and the list scrolls to its end, margin
        // included.
        model.add(listed("late", severity: .low, at: -61))
        #expect(try await sidebar.settles { $0.offset > 1000 && abs($0.offset - $0.maxOffset) < 1 }, "\(sidebar.state)")

        // A new card on top: the top of the list, with the room above the card for its dismiss button.
        model.add(listed("news", at: 0))
        #expect(try await sidebar.settles { abs($0.offset) < 0.5 }, "\(sidebar.state)")

        // On the sidebar, a newer low card lands far below the visible cards, and the list stays.
        pointerIsOn.value = true
        model.add(listed("quiet", severity: .low, at: 0))
        #expect(try await sidebar.settles { abs($0.offset) < 0.5 }, "\(sidebar.state)")

        // Elsewhere, a card dropping in among the visible ones, under the bottom fade, comes out from under it.
        pointerIsOn.value = false
        model.add(listed("between", at: -37.5))
        #expect(model.notifications[8].title == "between")
        #expect(try await sidebar.settles { abs($0.span(ofCardAt: 8, of: model).upperBound - ($0.visibleHeight - EdgeFadeMask.height)) < 1 })
        #expect(sidebar.offset > 0)

        // A newer low card lands far below, above the two older low cards: the list scrolls just far enough to show
        // it above the bottom fade, short of the end.
        model.add(listed("newer", severity: .low, at: 1))
        let newer = try #require(model.notifications.firstIndex { $0.title == "newer" })
        #expect(try await sidebar.settles { abs($0.span(ofCardAt: newer, of: model).upperBound - ($0.visibleHeight - EdgeFadeMask.height)) < 1 })
        #expect(sidebar.offset < sidebar.maxOffset - 1)

        // A card arriving above the visible cards comes in below the top fade.
        model.add(listed("earlier", at: -0.5))
        #expect(model.notifications[1].title == "earlier")
        #expect(try await sidebar.settles { abs($0.span(ofCardAt: 1, of: model).lowerBound - EdgeFadeMask.height) < 1 })

        // Of several arriving together, the list shows the top-most, the most severe, although a low one came last.
        model.add(listed("fire", severity: .critical, at: 2))
        model.add(listed("noise", severity: .low, at: 2))
        #expect(try await sidebar.settles { abs($0.offset) < 0.5 })
    }

    /// An assertion matching the old position must not finish before SwiftUI observes the arrival.
    @Test(.enabled(if: !NSScreen.screens.isEmpty, "requires a display"))
    func settlingDoesNotAcceptThePositionBeforeAnArrival() async throws {
        let model = model()
        let sidebar = try HostedSidebar(model: model, pointerIsOn: Mutable(false))
        defer { sidebar.close() }
        try await sidebar.revealed()

        model.add(listed("late", severity: .low, at: -61))
        let acceptedOldPosition = try await sidebar.settles(timeout: .seconds(1)) { abs($0.offset) < 0.5 }
        #expect(!acceptedOldPosition)
        #expect(try await sidebar.settles { $0.offset > 1000 && abs($0.offset - $0.maxOffset) < 1 }, "\(sidebar.state)")
    }

    /// With Reduce Motion the list jumps to the arriving card, all the way to the end for the last one, although the
    /// sidebar still moves its cards into place.
    @Test(.enabled(if: !NSScreen.screens.isEmpty, "requires a display"))
    func withReduceMotionTheListJumpsToTheArrivingCard() async throws {
        let model = model()
        let sidebar = try HostedSidebar(model: model, pointerIsOn: Mutable(false), reduceMotion: true)
        defer { sidebar.close() }
        try await sidebar.revealed()

        model.add(listed("late", severity: .low, at: -61))
        let toTheEnd = try await sidebar.offsets { $0.offset > 1000 && abs($0.offset - $0.maxOffset) < 1 }
        // At the end the list has grown to, the last card above the margin.
        #expect(toTheEnd.last ?? 0 > 1000)
        #expect(abs((toTheEnd.last ?? 0) - sidebar.maxOffset) < 1)
        // A scroll would pass through many offsets. The list stops at most once on its way: scrolled to the card by
        // identity, before it laid the card out, it stops at the end it had then.
        #expect(toTheEnd.count <= 3, "\(toTheEnd)")

        model.add(listed("earlier", at: 0))
        let toTheTop = try await sidebar.offsets { abs($0.offset) < 0.5 }
        #expect(abs(toTheTop.last ?? .infinity) < 0.5)
        #expect(toTheTop.count <= 3, "\(toTheTop)")
    }

    /// A card with a reply being typed on it tells the list, which then leaves the scroll alone
    /// (`SidebarActivity.isComposing`).
    @Test func aCardTellsTheListWhileAReplyIsTypedOnIt() async throws {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        let reply = NativeChoice(title: "Reply", textInput: NativeChoice.TextInput(placeholder: "Message", sendTitle: "Send"))
        model.add(SidebarNotification(source: "Slack", title: "Ada", nativeChoices: .init(identifier: "r", choices: [reply]), nativeIdentifiers: ["r"]))
        model.interception = .active
        let notification = model.notifications[0]
        let draft = ReplyDraft()
        let isComposing = Mutable(false)
        let card = NotificationCard(
            notification: notification,
            choices: model.cardChoices(of: notification),
            isAnswering: false,
            clickDescription: "",
            isHovered: false,
            hover: { _ in },
            activate: {},
            choose: { _ in },
            reply: { _, _ in },
            openLink: { _ in },
            dismiss: {},
            draft: draft
        )
        let panel = TestPanel(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentView = NSHostingView(rootView: card.onPreferenceChange(ComposingReplyKey.self) { isComposing.value = $0 })
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        panel.contentView?.layoutSubtreeIfNeeded()

        draft.open(reply)
        #expect(try await HostedSidebar.eventually { isComposing.value })
        draft.choice = nil
        #expect(try await HostedSidebar.eventually { !isComposing.value })
    }
}

/// The sidebar's content in a transparent `TestPanel` as tall as a short screen, and the `NSScrollView` behind its
/// list, whose clip view tells where the list is scrolled.
///
/// This exercises arrival scrolling with uniform cards, not the production panel's launch geometry. It builds
/// `SidebarPanelContent` directly in a 300×600, alpha-zero window, without `SidebarPanelController`, its background
/// panel or the full-height screen strip. Restoring a scale transform on the list's `ScrollView` does not reproduce
/// the launch offset drift here, even with varying card heights and reply buttons; the cause of that difference
/// has not been isolated. Passing these tests therefore does not establish that launch stays at the top.
/// `contentGrowsOutOfItsCornersOnTheScreenEdge` guards the unscaled scroll-view structure instead. A future launch
/// regression test must first fail with that transform restored; if it shows a panel, use `.showsWindowsOnScreen`.
@MainActor
final class HostedSidebar {
    let panel: TestPanel
    let clip: NSClipView
    private let directory: TemporaryDirectory
    private let model: SidebarModel
    private let renderedArrivals = Mutable(-1)
    private let scrollPhase = Mutable(ScrollPhase.idle)

    init(model: SidebarModel, pointerIsOn: Mutable<Bool>, reduceMotion: Bool = false) throws {
        self.model = model
        directory = try TemporaryDirectory()
        let settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        panel = TestPanel(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        let content = SidebarPanelContent(
            model: model, settings: settings, openSettings: { _ in }, setUp: { _, _ in }, requestKeyboard: {},
            pointerIsOn: { pointerIsOn.value }
        )
        panel.contentView = NSHostingView(rootView: ObservedSidebar(
            model: model, renderedArrivals: renderedArrivals, scrollPhase: scrollPhase, content: content
        ).environment(\._accessibilityReduceMotion, reduceMotion))
        panel.orderFrontRegardless()
        let view = try #require(panel.contentView)
        view.layoutSubtreeIfNeeded()
        clip = try #require(Self.scrollView(in: view)).contentView
    }

    func close() {
        panel.orderOut(nil)
    }

    var offset: CGFloat { clip.bounds.minY }
    /// Where the list is scrolled and how far it scrolls, for failure messages.
    var state: String {
        "offset \(offset) of \(maxOffset), visible \(visibleHeight), arrivals \(renderedArrivals.value)/\(model.arrivals.count)"
    }
    var maxOffset: CGFloat { clip.constrainBoundsRect(CGRect(origin: CGPoint(x: 0, y: 1e6), size: clip.bounds.size)).minY }
    var visibleHeight: CGFloat { clip.bounds.height }

    /// Where the card at `index` sits in the visible list, from the list's top. Every card here is as tall as the
    /// others, which the end of the list tells: the room for the first card's dismiss button, the cards with 8 points
    /// between them, and the bottom margin.
    func span(ofCardAt index: Int, of model: SidebarModel) -> ClosedRange<CGFloat> {
        let spacing: CGFloat = 8
        let pitch = (maxOffset + visibleHeight - NotificationCard.dismissOverhang - SidebarView.margin + spacing)
            / CGFloat(model.notifications.count)
        let top = NotificationCard.dismissOverhang + CGFloat(index) * pitch - offset
        return top...(top + pitch - spacing)
    }

    /// The initial view must have observed the model and finished laying out before the first arrival.
    /// Suite startup can monopolize the main actor for over ten seconds; readiness gets a separate 30s bound.
    func revealed() async throws {
        try #require(try await settles(timeout: .seconds(30)) { $0.visibleHeight > 0 }, "\(state)")
    }

    /// An unchanged offset alone is not a settled scroll: it can pause while the content still grows, and the
    /// arrival may not even have reached SwiftUI yet. Wait for the observed arrival generation and stable clip
    /// bounds/content extent for half a second, without changing the timeout or the caller's geometric tolerance.
    func settles(timeout: Duration = .seconds(10), _ condition: (HostedSidebar) -> Bool) async throws -> Bool {
        try await waitForSettlement(timeout: timeout, still: .milliseconds(500), sample: { _ in }, until: condition)
    }

    /// The distinct offsets traversed before the same layout/arrival barrier used by `settles` completes.
    func offsets(
        timeout: Duration = .seconds(10), still: Duration = .milliseconds(500), until condition: (HostedSidebar) -> Bool
    ) async throws -> [CGFloat] {
        var offsets = [offset]
        let settled = try await waitForSettlement(timeout: timeout, still: still, pollEvery: .milliseconds(5), sample: { offset in
            if abs(offsets[offsets.count - 1] - offset) >= 0.5 { offsets.append(offset) }
        }, until: condition)
        #expect(settled, "\(state)")
        return offsets
    }

    private func waitForSettlement(
        timeout: Duration, still: Duration, pollEvery: Duration = .milliseconds(20),
        sample: (CGFloat) -> Void, until condition: (HostedSidebar) -> Bool
    ) async throws -> Bool {
        var previous = (clip.bounds, maxOffset)
        var stableSince: ContinuousClock.Instant?
        var lastSample = ContinuousClock.now
        let deadline = lastSample + timeout
        repeat {
            // Apply pending hosting-view layout before inspecting AppKit's scroll geometry.
            panel.contentView?.layoutSubtreeIfNeeded()
            let current = (clip.bounds, maxOffset)
            let now = ContinuousClock.now
            let ready = renderedArrivals.value == model.arrivals.count && scrollPhase.value == .idle && condition(self)
            // Time spent unable to sample the main actor is not evidence that animation finished.
            if current != previous || !ready || now - lastSample >= still { stableSince = nil }
            lastSample = now
            previous = current
            sample(offset)
            if now >= deadline { return false }
            if ready {
                if let stableSince, now - stableSince >= still { return true }
                if stableSince == nil { stableSince = now }
            }
            try await Task.sleep(for: pollEvery)
        } while true
    }

    /// Observe arrivals from a view body, so this tracks rendered model changes rather than a value captured when
    /// constructing the host. It observes production content without substituting its scrolling behavior.
    private struct ObservedSidebar: View {
        let model: SidebarModel
        let renderedArrivals: Mutable<Int>
        let scrollPhase: Mutable<ScrollPhase>
        let content: SidebarPanelContent

        var body: some View {
            content
                .onChange(of: model.arrivals.count, initial: true) { _, count in renderedArrivals.value = count }
                .onScrollPhaseChange { _, phase in scrollPhase.value = phase }
        }
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }

    /// Waits up to `timeout` for `condition`.
    static func eventually(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}
