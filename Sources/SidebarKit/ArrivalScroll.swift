import SwiftUI

extension SidebarModel {
    /// The notifications that arrived and were listed (`SidebarModel.arrivals`).
    public struct Arrivals: Equatable, Sendable {
        /// How many arrived since launch.
        public private(set) var count = 0
        /// The number of the latest arrival on each listed card, counting from 1.
        private var latest: [SidebarNotification.ID: Int] = [:]

        /// The cards notifications arrived on after the first `count` of them. The sidebar sees several arrivals
        /// made in one turn of the main actor, such as a batch the notification database lists, as one change.
        public func cards(after count: Int) -> Set<SidebarNotification.ID> {
            Set(latest.compactMap { $0.value > count ? $0.key : nil })
        }

        /// Counts an arrival on `card` when it is among the `listed` cards, and forgets the cards that are not.
        mutating func record(_ card: SidebarNotification.ID, listed: [SidebarNotification]) {
            let ids = Set(listed.map(\.id))
            guard ids.contains(card) else { return }
            count += 1
            latest = latest.filter { ids.contains($0.key) }
            latest[card] = count
        }
    }
}

/// What the user is doing in the sidebar that an arriving notification must not disturb by scrolling the list:
/// they may be reading, scrolling or typing there.
struct SidebarActivity: Equatable {
    /// The pointer is on the panel (`pointerIsOnSidebar`).
    var pointerIsOn = false
    /// How the list scrolls. A scroll the user started coasts on after the pointer has left the strip.
    var scrollPhase = ScrollPhase.idle
    /// A reply is being typed on a card, perhaps with the pointer elsewhere, or through VoiceOver.
    var isComposing = false

    var isUsingList: Bool { pointerIsOn || isComposing || scrollPhase.isUserScrolling }
}

extension ScrollPhase {
    /// The user scrolls, or the list coasts on from their scroll. `.animating` is the sidebar's own scrolling, such
    /// as for an earlier arrival, which the next one takes over.
    var isUserScrolling: Bool {
        switch self {
        case .tracking, .interacting, .decelerating: true
        case .idle, .animating: false
        }
    }
}

/// Brings the card a notification arrived on into view (`SidebarModel.arrivals`): whole and clear of the fades at
/// the list's edges (`EdgeFadeMask`), with the least scrolling. Cards sort by severity, then newest first, so a new
/// card can land anywhere in the list, far below the visible cards for a low one.
///
/// The first card shows at the top of the list, with the room above it for its dismiss button, and the last at its
/// end, with the margin under it; neither needs the card's frame. The list is lazy and lays out only the cards near
/// the visible ones, and SwiftUI reports an arriving card's frame only after `onChange` has seen the arrival
/// (measured on macOS 26.6). Until a card in between reports its frame, the list scrolls to it by its identity, which
/// brings it in at an edge, under the fade; the frame then sets the offset, further in the same direction, so the two
/// scrolls read as one. A frame reported first is used at once.
@MainActor
final class ArrivalScroll {
    /// The coordinate space of the list's content, in which cards report their frames and the list scrolls.
    nonisolated static let space = "notificationList"

    /// A scroll that shows an arriving card.
    enum Step: Equatable {
        /// To this offset from the top.
        case offset(CGFloat)
        /// To the end of the list, the margin under the last card included.
        case end
        /// To the card by its `ForEach` identity, the least scrolling that brings it into view, while the list has
        /// not laid it out.
        case card(SidebarNotification.ViewIdentity)

        func apply(to position: inout ScrollPosition) {
            switch self {
            case .offset(let offset): position.scrollTo(y: offset)
            case .end: position.scrollTo(edge: .bottom)
            case .card(let identity): position.scrollTo(id: identity)
            }
        }

        /// Whether it is a place in the list, which a jump stops short of while the content grows, rather than a card.
        var isPlace: Bool {
            if case .card = self { false } else { true }
        }
    }

    /// An arriving card between the first and the last, and the list as it was when the card arrived.
    private struct Target {
        let card: SidebarNotification.ViewIdentity
        let offset: CGFloat
        let visibleHeight: CGFloat

        func offset(showing frame: CGRect) -> CGFloat? {
            ArrivalScroll.offset(showing: frame, from: offset, visibleHeight: visibleHeight)
        }
    }

    /// The list's height. The scroll view's own geometry leaves out the margin under the content until the list
    /// first scrolls (measured on macOS 26.6), so the list's frame tells it.
    var visibleHeight: CGFloat = 0
    /// Where each card the list laid out sits in its content. Every arrival makes a card of a new identity (a
    /// restack too, `SidebarNotification.viewIdentity`), so an arriving card's frame is never one from before it.
    private var frames: [SidebarNotification.ViewIdentity: CGRect] = [:]
    /// The arriving card whose frame the list has not reported yet.
    private var awaited: Target?
    /// The latest change of the list's cards (`layoutWillMove()`).
    private var layoutChange = 0
    /// The place the list last scrolled to, and the change of its cards animating then (`scroll(_:by:reduceMotion:)`).
    private var jumpToRepeat: (step: Step, change: Int)?

    /// Where to scroll for the cards notifications arrived on, in the list `notifications` scrolled `offset` from its
    /// top: to the top-most of them, the most severe and newest. Nowhere while `isUsingList`.
    func arrived(
        on cards: Set<SidebarNotification.ID>,
        in notifications: [SidebarNotification],
        offset: CGFloat,
        isUsingList: Bool
    ) -> Step? {
        cancel()
        guard !isUsingList, let index = notifications.firstIndex(where: { cards.contains($0.id) }) else { return nil }
        if index == notifications.startIndex {
            return offset > 0.5 ? .offset(0) : nil
        }
        if index == notifications.index(before: notifications.endIndex) {
            return .end
        }
        let target = Target(card: notifications[index].viewIdentity, offset: offset, visibleHeight: visibleHeight)
        if let frame = frames[target.card] {
            return target.offset(showing: frame).map(Step.offset)
        }
        awaited = target
        return .card(target.card)
    }

    /// Notes where `card` sits in the list's content. For the card an arrival awaits, the offset that shows it,
    /// unless the user has taken to the list since (`isUsingList`).
    func laidOut(_ card: SidebarNotification.ViewIdentity, at frame: CGRect, isUsingList: () -> Bool) -> CGFloat? {
        frames[card] = frame
        guard let target = awaited, target.card == card else { return nil }
        awaited = nil
        return isUsingList() ? nil : target.offset(showing: frame)
    }

    /// Forgets a card the list no longer lays out.
    func disappeared(_ card: SidebarNotification.ViewIdentity) {
        frames[card] = nil
    }

    /// Leaves the list where it is: the user scrolls it, or a newer arrival takes over.
    func cancel() {
        awaited = nil
        jumpToRepeat = nil
    }

    /// The list starts animating a change of its cards: the number of the change, for `layoutMoved(_:isUsingList:)`.
    func layoutWillMove() -> Int {
        layoutChange += 1
        return layoutChange
    }

    /// The list finished animating change `change` of its cards: the scroll to a place made while it animated, to
    /// make again, unless the user has taken to the list since.
    func layoutMoved(_ change: Int, isUsingList: () -> Bool) -> Step? {
        guard let jump = jumpToRepeat, jump.change == change else { return nil }
        jumpToRepeat = nil
        return isUsingList() ? nil : jump.step
    }

    /// Scrolls `position` by `step` as the sidebar moves, or with Reduce Motion jumps. A binding, so that the position
    /// changes inside the animation: an `inout` @State would change only once this returns, outside it, and jump.
    ///
    /// The sidebar animates its cards into place, with Reduce Motion too, and the list's content grows with them: a
    /// scroll meanwhile stops where the content ends so far, which can leave a card at the end hidden (measured on
    /// macOS 26.6, more often while the main thread is busy). A scroll to a place, an offset or the end, is made
    /// again once that change has finished (`layoutMoved(_:isUsingList:)`), and does nothing when the list is there
    /// already. It is made at once too: SwiftUI never finishes a change whose moving cards the scroll takes out of
    /// the lazy list (measured on macOS 26.6).
    func scroll(_ position: Binding<ScrollPosition>, by step: Step, reduceMotion: Bool) {
        if step.isPlace {
            jumpToRepeat = (step, layoutChange)
        }
        withAnimation(Self.animation(reduceMotion: reduceMotion)) { step.apply(to: &position.wrappedValue) }
    }

    /// The scroll moves like the sidebar's other changes; with Reduce Motion it jumps.
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : SidebarView.motion
    }

    /// The offset from the top that shows `card`, its frame in the list's content, whole and clear of the edge
    /// fades, with the least scrolling from `offset` in a list `visibleHeight` tall; nil when it shows already. A card
    /// too tall to show whole shows its top.
    nonisolated static func offset(showing card: CGRect, from offset: CGFloat, visibleHeight: CGFloat) -> CGFloat? {
        let fade = EdgeFadeMask.height
        // The furthest the list scrolls with the card's top in view, and the least with its bottom in view.
        let topShows = max(card.minY - fade, 0)
        let bottomShows = max(card.maxY + fade - visibleHeight, 0)
        guard bottomShows <= topShows else { return abs(offset - topShows) < 0.5 ? nil : topShows }
        if offset < bottomShows - 0.5 { return bottomShows }
        if offset > topShows + 0.5 { return topShows }
        return nil
    }
}

/// Whether a reply is being typed on a card of the list (`NotificationCard.isComposing`).
struct ComposingReplyKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension EnvironmentValues {
    /// Whether the pointer is on the sidebar panel: over it, gaps between cards included, or dragging from a press
    /// on it (`SidebarPanel.hasPointer`).
    @Entry var pointerIsOnSidebar: @MainActor () -> Bool = { false }
}
