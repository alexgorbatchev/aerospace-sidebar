import PermissionFlow
import SidebarProtocol
import SwiftUI

/// Root content of the sidebar panel.
struct SidebarView: View {
    let model: SidebarModel
    /// The screen edge the sidebar is pinned to; the top buttons and the scroll indicator align to it.
    let side: SidebarSettings.Sidebar.Side
    /// Why `config.toml` did not load (`SettingsStore.loadProblem`): the sidebar may sit on the default strip
    /// with the default rules, and Settings is the only other place that says so.
    var settingsProblem: String?
    /// Shows the Settings window on a group.
    let openSettings: (SettingsGroup) -> Void
    /// Starts granting a permission from the clicked button's frame on screen.
    let setUp: (PermissionFlowPane, CGRect?) -> Void

    nonisolated static let margin: CGFloat = 16
    /// The panel starts right under the menu bar, which already leaves room above the notes and cards.
    static let topMargin: CGFloat = 2
    /// Room under the buttons at the bottom of the screen.
    static let bottomMargin: CGFloat = 8
    static let motion: Animation = .snappy

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.typography) private var typography
    @Environment(\.pointerIsOnSidebar) private var pointerIsOnSidebar
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// The list's scroll geometry, which changes on every frame of a scroll. Only the views drawn from it read it, so
    /// a scroll does not evaluate this body, and with it every visible card's, on every frame.
    @State private var listScroll = ListScroll()
    @State private var scrollPhase = ScrollPhase.idle
    @State private var isComposing = false
    @State private var arrivalScroll = ArrivalScroll()
    @State private var isRevealed = false
    @State private var hoveredID: SidebarNotification.ID?
    /// PermissionFlow's drag panel flies from the clicked Set Up… button to System Settings.
    @State private var accessibilityAnchor = ScreenFrameAnchor()
    @State private var fullDiskAccessAnchor = ScreenFrameAnchor()

    var body: some View {
        VStack(alignment: screenEdge, spacing: 6) {
            // Everything but the scroll view grows out of its corner on the screen edge (`SidebarReveal`).
            notes
                .modifier(RevealEffect(reveal: reveal))
            list
            controls
                .modifier(RevealEffect(reveal: reveal, edge: .bottom))
        }
        .padding(.top, Self.topMargin)
        .padding(.bottom, Self.bottomMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Above the list and outside its edge fade, so a tooltip is never cut off.
        .sidebarTooltips()
        .opacity(reveal.opacity)
        .onAppear { withAnimation(Self.motion) { isRevealed = true } }
        // With Reduce Motion an arrival's jump goes again once the cards are in place (`ArrivalScroll.scroll`).
        .transaction(value: model.notifications) { transaction in
            let change = arrivalScroll.layoutWillMove()
            transaction.addAnimationCompletion(criteria: .removed) {
                if let step = arrivalScroll.layoutMoved(change, isUsingList: { activity.isUsingList }) { scroll(by: step) }
            }
        }
        // Changes arrive from the model, outside any view action, so the view animates them itself.
        .animation(Self.motion, value: model.notifications)
        .animation(Self.motion, value: model.interception)
        .animation(Self.motion, value: asksForFullDiskAccess)
        .animation(Self.motion, value: settingsProblem)
        .animation(Self.motion, value: model.appNotificationsProblem)
        .animation(Self.motion, value: model.unavailableChoices)
    }

    /// What the sidebar needs or has to say, above the list.
    @ViewBuilder private var notes: some View {
            if let message = statusMessage {
                StatusNote(text: message) {
                    if model.interception == .needsAccessibility {
                        Button("Set Up…", font: typography.font(.body)) { setUp(.accessibility, accessibilityAnchor.screenFrame) }
                            .screenFrameAnchor(accessibilityAnchor)
                            .accessibilityLabel("Set Up Accessibility")
                    }
                }
            }
            if let settingsProblem {
                StatusNote(text: settingsProblem) {
                    // General shows the file with Show in Finder; any group with Save replaces it.
                    Button("Settings…", font: typography.font(.body)) { openSettings(.general) }
                        .accessibilityLabel("Open Settings")
                }
            }
            if let problem = model.appNotificationsProblem {
                StatusNote(text: problem) {
                    Button("Dismiss", font: typography.font(.body)) { model.dismissAppNotificationsProblem() }
                }
            }
            if asksForFullDiskAccess {
                StatusNote(text: Self.fullDiskAccessNote) {
                    HStack(spacing: 6) {
                        Button("Set Up…", font: typography.font(.body)) { setUp(.fullDiskAccess, fullDiskAccessAnchor.screenFrame) }
                            .screenFrameAnchor(fullDiskAccessAnchor)
                            .accessibilityLabel("Set Up Full Disk Access")
                        Button("Dismiss", font: typography.font(.body)) { model.dismissFullDiskAccessNote() }
                    }
                }
            }
    }

    /// The cards. The list spans the full width so the scroll indicator sits in the margin on the sidebar's screen edge.
    private var list: some View {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.notifications, id: \.viewIdentity) { notification in
                        NotificationCard(
                            notification: notification,
                            choices: model.cardChoices(of: notification),
                            isAnswering: model.answering.contains(notification.id),
                            clickDescription: model.clickDescription(of: notification),
                            isHovered: hoveredID == notification.id,
                            hover: { hoveredID = Self.hoveredID(hoveredID, card: notification.id, hovering: $0) },
                            activate: { model.activate(notification.id) },
                            choose: { model.choose($0, for: notification.id) },
                            reply: { model.reply($0, text: $1, for: notification.id) },
                            openLink: { model.openLink($0) },
                            dismiss: { model.dismiss(notification.id) },
                            composingChanged: { model.setComposing($0, on: notification.id) },
                            allowAppNotifications: model.appNotificationsAreOff(for: notification)
                                ? { model.allowAppNotifications(for: notification.id) } : nil,
                            isAllowingAppNotifications: model.allowingAppNotifications != nil,
                            hasLostChoices: model.hasLostChoices(notification)
                        )
                        .transition(cardTransition)
                        // Later cards draw above earlier ones, so when a card is removed the card
                        // sliding up into its place covers it while it fades out.
                        .zIndex(notification.drawingOrder)
                        // Where the card sits, for scrolling it into view when it arrives: outside the transition,
                        // which still holds an arriving card above its place as it reports its first frame. The
                        // scroll waits a turn of the main actor: the list scrolls to a card by identity during the
                        // layout that lays the card out, and an offset set then is lost (measured on macOS 26.6).
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(ArrivalScroll.space)) }) { frame in
                            let identity = notification.viewIdentity
                            guard let offset = arrivalScroll.laidOut(identity, at: frame, isUsingList: { activity.isUsingList }) else { return }
                            Task { @MainActor in scroll(by: .offset(offset)) }
                        }
                        .onDisappear { arrivalScroll.disappeared(notification.viewIdentity) }
                    }
                }
                // Room for the first card's dismiss button, which overhangs its top edge.
                .padding(.top, NotificationCard.dismissOverhang)
                .padding(.horizontal, Self.margin)
                .coordinateSpace(.named(ArrivalScroll.space))
                // Inside the scroll view: AppKit's scroll view, scaled, moves its own scroll position while the scale
                // animates, and left the list scrolled down past the first card (measured on macOS 26.6).
                .modifier(RevealEffect(reveal: reveal))
            }
            // The list runs to the screen edge; scrolled to the end, the last card keeps a margin under it.
            .contentMargins(.bottom, Self.margin, for: .scrollContent)
            .scrollIndicators(.never)
            .scrollPosition($scrollPosition)
            // Notifications arriving while the user is elsewhere scroll into view. `scrollPosition` finds a card by
            // its `ForEach` identity; `scrollTargetLayout()` would also hold the top edge at the first card's top,
            // hiding the room above it for its dismiss button.
            .onChange(of: model.arrivals) { old, new in
                let step = arrivalScroll.arrived(
                    on: new.cards(after: old.count), in: model.notifications, offset: listScroll.metrics.offset, isUsingList: activity.isUsingList
                )
                if let step { scroll(by: step) }
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { arrivalScroll.visibleHeight = $0 }
            .onScrollGeometryChange(for: ScrollMetrics.self, of: ScrollMetrics.init) { listScroll.metrics = $1 }
            .onScrollPhaseChange {
                scrollPhase = $1
                if $1.isUserScrolling { arrivalScroll.cancel() }
            }
            .onPreferenceChange(ComposingReplyKey.self) { isComposing = $0 }
            .mask { ListEdgeFade(scroll: listScroll) }
            .overlay(alignment: Alignment(horizontal: screenEdge, vertical: .center)) {
                ListScrollIndicator(scroll: listScroll, isScrolling: scrollPhase.isScrolling) { scrollPosition.scrollTo(y: $0) }
            }
            .overlay {
                if model.notifications.isEmpty {
                    Text("No notifications")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .floatingShadow()
                        .modifier(RevealEffect(reveal: reveal))
                }
            }
    }

    /// The sidebar's screen edge, where the top buttons and the scroll indicator sit.
    var screenEdge: HorizontalAlignment { side == .left ? .leading : .trailing }

    private var reveal: SidebarReveal {
        SidebarReveal(isRevealed: isRevealed, side: side, reduceMotion: reduceMotion)
    }

    /// What the user is doing in the sidebar, which an arriving notification leaves alone.
    private var activity: SidebarActivity {
        SidebarActivity(pointerIsOn: pointerIsOnSidebar(), scrollPhase: scrollPhase, isComposing: isComposing)
    }

    /// Scrolls the list to show an arriving card (`ArrivalScroll`).
    private func scroll(by step: ArrivalScroll.Step) {
        arrivalScroll.scroll($scrollPosition, by: step, reduceMotion: reduceMotion)
    }

    /// Settings and Clear All as small round icon buttons in the bottom corner on the sidebar's screen edge, Clear
    /// All outermost: Settings, then Clear All from left to right on a right-hand sidebar. Their labels open away
    /// from that edge, so the icon under the pointer stays put.
    private var controls: some View {
        let expandsToward: HorizontalEdge = side == .left ? .trailing : .leading
        let clearAll = ExpandingIconButton("Clear All", systemImage: "xmark", expandsToward: expandsToward, action: model.clear)
            .disabled(model.notifications.isEmpty)
        let settings = ExpandingIconButton("Settings", systemImage: "gearshape", expandsToward: expandsToward) { openSettings(.general) }
            .keyboardShortcut(",", modifiers: .command)
        return HStack(spacing: 4) {
            if side == .left {
                clearAll
                settings
            } else {
                settings
                clearAll
            }
        }
        .padding(.horizontal, Self.margin)
    }

    /// The card under the pointer after `card` reports entering or leaving. Entering the next card
    /// can be reported before leaving the previous one, so leaving only clears the card that left.
    static func hoveredID(
        _ current: SidebarNotification.ID?,
        card: SidebarNotification.ID,
        hovering: Bool
    ) -> SidebarNotification.ID? {
        if hovering { return card }
        return current == card ? nil : current
    }

    /// New cards drop in from above; removed ones fade and shrink in place, since removal also covers
    /// expiry and restacking, not only dismissal. With Reduce Motion cards only fade.
    private var cardTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .scale(scale: 0.95, anchor: .top).combined(with: .opacity)
        )
    }

    static let fullDiskAccessNote = "Grant Full Disk Access to also list notifications that showed no banner."

    /// Full Disk Access is optional, so the note asking for it can be dismissed for good.
    private var asksForFullDiskAccess: Bool {
        model.database == .needsFullDiskAccess && !model.fullDiskAccessNoteDismissed
    }

    private var statusMessage: String? {
        switch model.interception {
        case .starting, .active, .stopped: nil
        case .disabled: "macOS notifications are left to macOS (see Settings)."
        case .needsAccessibility: "Grant Accessibility access to show macOS notifications here."
        case .notificationCenterUnavailable: "macOS notifications cannot be read right now."
        }
    }
}

/// Grows a part of the sidebar out of its corner on the screen edge as the sidebar first appears
/// (`SidebarReveal`): the top corner, or the bottom one for the buttons that sit there. Each part scales on its
/// own, never the list's scroll view.
struct RevealEffect: ViewModifier {
    let reveal: SidebarReveal
    var edge: VerticalEdge = .top

    func body(content: Content) -> some View {
        content.scaleEffect(reveal.scale, anchor: anchor)
    }

    var anchor: UnitPoint {
        guard edge == .bottom else { return reveal.anchor }
        return UnitPoint(x: reveal.anchor.x, y: 1)
    }
}

/// How the sidebar's content looks before and after it first appears: it grows out of its top corner on the
/// screen edge, where the top buttons sit, or with Reduce Motion only fades in.
struct SidebarReveal: Equatable {
    let scale: CGFloat
    let opacity: Double
    let anchor: UnitPoint

    /// Too small to see, but not zero: AppKit inverts the content's transform and asserts on a zero scale.
    static let collapsedScale: CGFloat = 0.01

    init(isRevealed: Bool, side: SidebarSettings.Sidebar.Side, reduceMotion: Bool) {
        scale = isRevealed || reduceMotion ? 1 : Self.collapsedScale
        opacity = isRevealed || !reduceMotion ? 1 : 0
        anchor = side == .left ? .topLeading : .topTrailing
    }
}

/// A note above the list, such as what the sidebar needs to work, with buttons that act on it.
private struct StatusNote<Actions: View>: View {
    let text: String
    @ViewBuilder let actions: () -> Actions

    @Environment(\.typography) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(typography.font(.callout))
                .foregroundStyle(.secondary)
            actions()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The panel is transparent, so text outside cards gets the cards' material.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: NotificationCard.cornerRadius))
        .floatingShadow()
        .padding(.horizontal, SidebarView.margin)
        .transition(.opacity)
    }
}

/// The list's scroll geometry (`ScrollMetrics`), observed by the views drawn from it alone (`ListEdgeFade`,
/// `ListScrollIndicator`).
@MainActor
@Observable
final class ListScroll {
    var metrics = ScrollMetrics()
}

/// `EdgeFadeMask` for the list as it is scrolled.
struct ListEdgeFade: View {
    let scroll: ListScroll

    var body: some View {
        EdgeFadeMask(fadesTop: scroll.metrics.hasContentAbove, fadesBottom: scroll.metrics.hasContentBelow)
    }
}

/// The list's `ScrollIndicator` while it scrolls at all.
struct ListScrollIndicator: View {
    let scroll: ListScroll
    let isScrolling: Bool
    /// Scrolls the list to an offset from the top.
    let scrollTo: (CGFloat) -> Void

    var body: some View {
        if scroll.metrics.isScrollable {
            ScrollIndicator(metrics: scroll.metrics, isScrolling: isScrolling, scrollTo: scrollTo)
        }
    }
}

/// Opaque except for its top and bottom `height` points, which fade out while cards are hidden past that
/// edge, so cards cut off by the edge fade instead of ending abruptly.
struct EdgeFadeMask: View {
    let fadesTop: Bool
    let fadesBottom: Bool

    nonisolated static let height: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            Self.edge(fading: fadesTop, toward: .top)
            Color.black
            Self.edge(fading: fadesBottom, toward: .bottom)
        }
        .animation(.easeOut(duration: 0.2), value: fadesTop)
        .animation(.easeOut(duration: 0.2), value: fadesBottom)
    }

    /// Opaque on the inner side, transparent at `edge` while `fading`.
    private static func edge(fading: Bool, toward edge: UnitPoint) -> some View {
        LinearGradient(colors: [.black, .black.opacity(fading ? 0 : 1)], startPoint: edge == .top ? .bottom : .top, endPoint: edge)
            .frame(height: height)
    }
}

struct NotificationCard: View {
    let notification: SidebarNotification
    /// The choices the card offers (`SidebarModel.cardChoices(of:)`): the macOS notification's, or those pushed
    /// with it.
    let choices: [NativeChoice]
    /// One of its choices is being performed; the others wait for it.
    let isAnswering: Bool
    /// What a click does (`SidebarModel.clickDescription(of:)`).
    let clickDescription: String
    let isHovered: Bool
    let hover: (Bool) -> Void
    let activate: () -> Void
    let choose: (String) -> Void
    /// Sends the text typed for a choice that asks for it, such as Reply.
    let reply: (_ choice: String, _ text: String) -> Void
    /// Opens a link in the notification's body.
    let openLink: (URL) -> Void
    let dismiss: () -> Void
    /// Reports whether a reply is being typed on the card (`isComposing`), which keeps it from stacking: a stack
    /// gets a new card, without this one's field and text.
    var composingChanged: (Bool) -> Void = { _ in }
    /// Switches on the posting app's notifications in System Settings, set while they are off
    /// (`SidebarModel.appNotificationsAreOff(for:)`); the card then shows `SwitchedOffBadge`.
    var allowAppNotifications: (() -> Void)?
    /// Another card is switching an app's notifications on; the badge waits for it.
    var isAllowingAppNotifications = false
    /// The notification's choices are known to be gone (`SidebarModel.hasLostChoices(_:)`), so a note says why the
    /// card shows none.
    var hasLostChoices = false

    nonisolated static let cornerRadius: CGFloat = 10
    /// How far each layer under a stacked card shows, and how much narrower it is per side.
    nonisolated static let stackLayerHeight: CGFloat = 5
    nonisolated static let stackLayerInset: CGFloat = 8
    static let maxStackLayers = 2
    /// The soft shadow that lifts a card off whatever is behind the panel.
    static let shadowOpacity = 0.5
    static let shadowRadius: CGFloat = 5
    static let shadowOffset: CGFloat = 2
    /// Cards scale up slightly under the pointer.
    nonisolated static let hoverScale: CGFloat = 1.02
    /// How far the dismiss button sticks out past the card's top-trailing corner.
    static let dismissOverhang: CGFloat = 5
    /// The dismiss button's size relative to the sidebar's own buttons (diameter) and the caption text
    /// style (text). It sits outside the card's hover scale, so its edges can fall on whole pixels, and is
    /// drawn as large as it looks on the scaled card.
    nonisolated static let dismissScale = (diameter: hoverScale, text: 0.9 * hoverScale)
    /// The underline under links in the body, which keep the text's color.
    static let linkUnderline = Color.primary.opacity(0.35)
    /// The underline under the link the pointer is on, white like a hovered button's label.
    static let hoveredLinkUnderline = Color.white
    /// Space between the card's lines of text.
    static let lineSpacing: CGFloat = 4
    /// Space between the icon and the text beside it.
    static let iconSpacing: CGFloat = 8
    /// Says why a card that had buttons shows none.
    static let lostChoicesNote = "Its buttons are no longer available"
    /// The VoiceOver action that does what `SwitchedOffBadge` does.
    static let allowNotificationsAction = "Allow Notifications"
    /// How much of the icon's square its artwork fills: 824 of an app icon's 1024 points (Apple's macOS
    /// app icon grid), the rest is a transparent margin. Font icons are drawn this size to match.
    static let iconArtwork: CGFloat = 824.0 / 1024.0

    @Environment(\.typography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appIcon) private var appIcon
    @Environment(\.displayScale) private var displayScale
    @Environment(\.requestKeyboard) private var requestKeyboard
    /// The dismiss button overhangs the card, so the pointer can rest on it outside the card's hover area.
    @State private var isDismissHovered = false
    /// The card's size with its stack layers, before the hover scale.
    @State private var size = CGSize.zero
    /// What is typed for a choice that asks for text.
    @State var draft = ReplyDraft()

    /// The dismiss button shows only while the pointer is on the card or on the button itself.
    var showsDismiss: Bool { isHovered || isDismissHovered }

    var body: some View {
        VStack(spacing: 0) {
            card
            ForEach(1..<stackLayers + 1, id: \.self) { layer in
                let shape = UnevenRoundedRectangle(bottomLeadingRadius: Self.stackLayerHeight, bottomTrailingRadius: Self.stackLayerHeight)
                shape
                    .fill(background)
                    .background(.regularMaterial, in: shape)
                    .opacity(0.8 - 0.25 * Double(layer))
                    .frame(height: Self.stackLayerHeight)
                    .padding(.horizontal, Self.stackLayerInset * CGFloat(layer))
            }
        }
        .cutOutShadows(CardSilhouette(stackLayers: stackLayers), reach: 3 * Self.shadowRadius + Self.shadowOffset) {
            ShadowCaster(shape: CardSilhouette(stackLayers: stackLayers), opacity: Self.shadowOpacity, radius: Self.shadowRadius, y: Self.shadowOffset)
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
        .scaleEffect(scale)
        // Outside the scale, which would put its edges between pixels; `dismissOffset` follows the corner.
        .overlay(alignment: .topTrailing) {
            ExpandingIconButton(
                "Dismiss",
                systemImage: "xmark",
                expandsToward: .leading,
                surface: .card(notification.severity),
                action: dismiss
            )
                .onHover { isDismissHovered = $0 }
                .offset(Self.dismissOffset(cardSize: size, scale: scale, displayScale: displayScale))
                .opacity(showsDismiss ? 1 : 0)
                .allowsHitTesting(showsDismiss)
                .animation(.easeOut(duration: 0.15), value: showsDismiss)
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover(perform: hover)
        .preference(key: ComposingReplyKey.self, value: isComposing)
        .onChange(of: isComposing) { composingChanged($1) }
    }

    private var scale: CGFloat { isHovered && !reduceMotion ? Self.hoverScale : 1 }

    /// Where the dismiss button sits off the top-trailing corner of a card `cardSize` large, which `scale`
    /// moves out by half the growth of each side, rounded to the pixels of `displayScale`.
    static func dismissOffset(cardSize: CGSize, scale: CGFloat, displayScale: CGFloat) -> CGSize {
        let growth = (scale - 1) / 2
        func pixels(_ points: CGFloat) -> CGFloat { (points * displayScale).rounded() / displayScale }
        return CGSize(
            width: pixels(dismissOverhang + cardSize.width * growth),
            height: pixels(-(dismissOverhang + cardSize.height * growth))
        )
    }

    /// Layers drawn under the card for notifications received more than once.
    private var stackLayers: Int { min(notification.occurrences - 1, Self.maxStackLayers) }

    /// Whether a reply is being typed. The card is then no button, so that the field and its send button are
    /// controls of their own, which VoiceOver reaches; inside a button's label it reaches none.
    var isComposing: Bool { !choices.isEmpty && draft.choice?.textInput != nil }

    @ViewBuilder private var card: some View {
        if isComposing {
            face
                .accessibilityElement(children: .contain)
                .accessibilityLabel(accessibilitySummary)
                // The dismiss button shows only under the pointer; the body's links are elements of their own.
                .accessibilityActions { Button("Dismiss", action: dismiss) }
        } else {
            Button(action: activate) {
                // The card's label and actions describe it; each text would otherwise become an action.
                face.accessibilityElement(children: .ignore)
            }
            // Option-click dismisses the card without acting, like its dismiss button.
            .buttonStyle(PressableButtonStyle(alternateAction: dismiss))
            .help(helpText)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityActions {
                ForEach(choices, id: \.title) { choice in
                    // A choice that asks for text opens its field, which the card then shows as a control.
                    Button(choice.title) {
                        guard choice.textInput != nil else { return choose(choice.title) }
                        draft.open(choice)
                        requestKeyboard()
                    }
                }
                // Links in the text are not separate elements inside the card's button.
                ForEach(bodyLinks, id: \.self) { url in
                    Button("Open \(url.host() ?? url.absoluteString)") { openLink(url) }
                }
                // Nor is the badge under the icon.
                if let allowAppNotifications, !isAllowingAppNotifications {
                    Button(Self.allowNotificationsAction, action: allowAppNotifications)
                }
                // The dismiss button shows only under the pointer.
                Button("Dismiss", action: dismiss)
            }
        }
    }

    /// What the card shows, whether it is a button or a reply is being typed on it.
    private var face: some View {
        Group {
            if hasIcon {
                // The icon spans the header and the line under it; every line sits beside it.
                LeadingIconLayout(spannedLines: 2, lineSpacing: Self.lineSpacing, iconSpacing: Self.iconSpacing) {
                    icon
                    // Only notifications from installed apps come from switched-off apps, and those have an icon.
                    if let allowAppNotifications {
                        SwitchedOffBadge(appName: notification.source, action: allowAppNotifications)
                            .disabled(isAllowingAppNotifications)
                            .underIcon()
                    }
                    content
                }
            } else {
                VStack(alignment: .leading, spacing: Self.lineSpacing) { content }
            }
        }
        // A link click opens the link only; the card's own action needs a click elsewhere on it.
        .environment(\.openURL, OpenURLAction { url in
            openLink(url)
            return .handled
        })
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        // The tints are translucent; the material keeps a card sliding over another (when one
        // above it is removed) from showing the other's text through it.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay {
            if let accent {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(accent, lineWidth: 1)
            }
        }
        .saberBorder(RoundedRectangle(cornerRadius: Self.cornerRadius), color: saberColor, isActive: isHovered)
        .opacity(notification.severity == .low ? 0.6 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
    }

    /// The icon of the app that posted the notification, unless the notification names an icon.
    private var appImage: NSImage? {
        notification.icon == nil ? notification.bundleIdentifier.flatMap(appIcon) : nil
    }

    private var hasIcon: Bool { notification.icon != nil || appImage != nil }

    /// The icon the notification names, else the icon of the app that posted it, filling the square it
    /// is given.
    @ViewBuilder private var icon: some View {
        if let icon = notification.icon {
            // App icons carry their shadow; the glyph gets the same one.
            Image(nsImage: AppIconFont.image(for: icon, artwork: Self.iconArtwork))
                .resizable()
                .modifier(IconShadow())
                .accessibilityLabel(icon.accessibilityLabel)
        } else if let appImage {
            // The source in the header names the app.
            Image(nsImage: appImage).resizable().accessibilityHidden(true)
        }
    }

    /// The card's lines: header, texts, notes and the alert's choices.
    @ViewBuilder private var content: some View {
        header
        ForEach(lines) { line in
            // Links keep the text's color; only a faint underline marks them, white under the pointer.
            LinkedText(text: line.text, hoverUnderline: Self.hoveredLinkUnderline)
                .font(line.font)
                .lineLimit(line.lineLimit)
                .tint(.primary)
        }
        ForEach(notes, id: \.self) { note in
            Text(note)
                .font(typography.font(.caption2))
                .foregroundStyle(.secondary)
        }
        if !choices.isEmpty {
            // Buttons inside the card's button take their own clicks. VoiceOver cannot reach them
            // there: it sees the card as one button, and pressing a nested button through
            // accessibility runs the card's action. It gets the choices as the card's actions, until a
            // reply is typed and the card is no button.
            CardChoices(choices: choices, draft: draft, choose: choose, reply: reply, acceptsReply: acceptsReply)
                .disabled(isAnswering)
                .padding(.top, 2)
                .accessibilityHidden(!isComposing)
        }
    }

    /// Who posted the notification, when, and how often.
    private var header: some View {
        HStack(spacing: 4) {
            if let symbol = severitySymbol {
                Image(systemName: symbol)
                    .foregroundStyle(accent ?? .secondary)
                    .accessibilityLabel(notification.severity.rawValue)
            }
            if let symbol = actionSymbol {
                Image(systemName: symbol)
            }
            Text(notification.source.isEmpty ? "Notification" : notification.source)
            Text(notification.receivedAt, style: .time)
            if notification.occurrences > 1 {
                Text("×\(notification.occurrences)")
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("Received \(notification.occurrences) times")
            }
        }
        .font(typography.font(.caption1))
        .foregroundStyle(.secondary)
    }

    /// One of the card's texts under the header.
    struct Line: Identifiable {
        let id: String
        let text: AttributedString
        let font: Font
        let lineLimit: Int?
    }

    /// The title, subtitle and body the notification has, in that order.
    var lines: [Line] {
        [
            Line(id: "title", text: AttributedString(notification.title), font: typography.font(.body).bold(), lineLimit: nil),
            Line(id: "subtitle", text: AttributedString(notification.subtitle), font: typography.font(.callout), lineLimit: nil),
            Line(id: "body", text: linkedBody, font: typography.font(.callout), lineLimit: 8),
        ].filter { !$0.text.characters.isEmpty }
    }

    /// Whether a reply can be sent: any text for a macOS notification, which sets no limit, and for a pushed
    /// choice text within `PushedChoice.maxReplyLength`.
    func acceptsReply(_ text: String) -> Bool {
        !text.isEmpty && (notification.pushedChoices.isEmpty || PushedChoice.fits(reply: text))
    }

    /// The body with its web links, and for a markdown body its inline styles (`NotificationMarkdown`).
    var linkedBody: AttributedString {
        let body = notification.markdown
            ? NotificationMarkdown.styled(notification.body, codeFont: typography.font(.callout).monospaced())
            : AttributedString(notification.body)
        return NotificationLinks.linked(body, underline: Self.linkUnderline)
    }

    /// The web links in the notification's body, in order.
    var bodyLinks: [URL] { linkedBody.runs[\.link].compactMap { link, _ in link } }

    /// What a click does, and that Option-click only dismisses, unless a click does nothing else.
    var helpText: String {
        if notification.nativeChoices != nil, !choices.isEmpty {
            return "Click to open, as clicking the macOS notification would\nOption-click to dismiss"
        }
        guard notification.action != nil else { return clickDescription }
        return clickDescription + "\nOption-click to dismiss"
    }

    /// Caption lines under the card's text.
    var notes: [String] {
        [
            notification.invalidIcon.map { "Invalid icon: \($0)" },
            notification.shownByMacOS ? "Shown by macOS for its buttons" : nil,
            hasLostChoices ? Self.lostChoicesNote : nil,
        ].compactMap { $0 }
    }

    /// What VoiceOver reads for the card: everything it shows, in reading order. The card is one button,
    /// which otherwise leaves its texts as unnamed custom actions.
    var accessibilitySummary: Text {
        var parts: [Text] = []
        if let icon = notification.icon {
            parts.append(Text(icon.accessibilityLabel))
        }
        if severitySymbol != nil {
            parts.append(Text(notification.severity.rawValue))
        }
        parts.append(Text(notification.source.isEmpty ? "Notification" : notification.source))
        parts.append(Text(notification.receivedAt, style: .time))
        if notification.occurrences > 1 {
            parts.append(Text("Received \(notification.occurrences) times"))
        }
        parts += [notification.title, notification.subtitle, notification.displayedBody].filter { !$0.isEmpty }.map { Text($0) }
        parts += notes.map { Text($0) }
        return parts.dropFirst().reduce(parts[0]) { Text("\($0), \($1)") }
    }

    private var accent: Color? {
        switch notification.severity {
        case .low, .normal: nil
        case .high: .orange
        case .critical: .red
        }
    }

    /// The hover border takes the severity's color, so it does not clash with the accent stroke.
    var saberColor: Color { accent ?? .accentColor }

    private var background: AnyShapeStyle { notification.severity.cardFill }

    private var severitySymbol: String? {
        switch notification.severity {
        case .low, .normal: nil
        case .high: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }

    private var actionSymbol: String? {
        switch notification.action {
        case nil: nil
        case .open: "link"
        case .run, .activateApp: nil
        }
    }

}

extension View {
    /// Lifts a card or button off whatever is behind the transparent panel. The shadow is cast by the
    /// composited view, so text inside it casts none of its own. Not for AppKit controls such as push
    /// buttons: the composited glass bezel has nothing behind it to blend with and turns black.
    func floatingShadow(isShown: Bool = true) -> some View {
        compositingGroup().shadow(color: .black.opacity(isShown ? 0.5 : 0), radius: 5, y: 2)
    }
}

extension SidebarNotification {
    struct ViewIdentity: Hashable {
        let id: UUID
        let occurrences: Int
    }

    /// A restacked notification gets a new card rather than moving the old one across the list: the
    /// old copy fades out where it was and the stack drops in at its new position.
    var viewIdentity: ViewIdentity { ViewIdentity(id: id, occurrences: occurrences) }

    /// Grows down the list, which is sorted by severity, then newest first. It belongs to the
    /// notification rather than its position, because a list index would pass a removed card's value to
    /// the card replacing it, and SwiftUI does not define which of two equal values draws on top.
    var drawingOrder: Double {
        let severityRank = Double(NotificationSeverity.allCases.firstIndex(of: severity)!)
        return -(severityRank * 1e10 + receivedAt.timeIntervalSinceReferenceDate)
    }
}

extension NotificationSeverity {
    /// The tint a card of this severity draws over its material, shared by its dismiss button.
    var cardFill: AnyShapeStyle {
        switch self {
        case .critical: AnyShapeStyle(Color.red.opacity(0.25))
        case .high: AnyShapeStyle(Color.orange.opacity(0.15))
        case .low, .normal: AnyShapeStyle(.quaternary)
        }
    }
}

/// The outline of a card and the stack layers under it, laid out as `NotificationCard` lays them out: the
/// card fills the space above the layers, and each layer is `stackLayerHeight` tall and inset
/// `stackLayerInset` more per side than the one above it.
struct CardSilhouette: Shape {
    let stackLayers: Int

    func path(in rect: CGRect) -> Path {
        let layerHeight = NotificationCard.stackLayerHeight
        var card = rect
        card.size.height -= CGFloat(stackLayers) * layerHeight
        var path = RoundedRectangle(cornerRadius: NotificationCard.cornerRadius).path(in: card)
        for layer in 1..<stackLayers + 1 {
            let inset = NotificationCard.stackLayerInset * CGFloat(layer)
            let layerRect = CGRect(
                x: rect.minX + inset,
                y: card.maxY + CGFloat(layer - 1) * layerHeight,
                width: rect.width - 2 * inset,
                height: layerHeight
            )
            path.addPath(UnevenRoundedRectangle(bottomLeadingRadius: layerHeight, bottomTrailingRadius: layerHeight).path(in: layerRect))
        }
        return path
    }
}
