import SidebarProtocol
import SwiftUI

/// Root content of the sidebar panel.
struct SidebarView: View {
    let model: SidebarModel
    /// The screen edge the sidebar is pinned to; the top buttons and the scroll indicator align to it.
    let side: SidebarSettings.Sidebar.Side
    /// Shows the Settings window on a group.
    let openSettings: (SettingsGroup) -> Void

    static let margin: CGFloat = 16
    /// The panel starts right under the menu bar, which already leaves room above the buttons.
    static let topMargin: CGFloat = 2
    static let motion: Animation = .snappy

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.typography) private var typography
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var scrollMetrics = ScrollMetrics()
    @State private var isScrolling = false
    @State private var hoveredID: SidebarNotification.ID?

    var body: some View {
        VStack(alignment: screenEdge, spacing: 6) {
            controls
            if let message = statusMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(typography.font(.callout))
                        .foregroundStyle(.secondary)
                    if model.interception == .needsAccessibility {
                        Button("Set Up…", font: typography.font(.body)) { openSettings(.permissions) }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The panel is transparent, so text outside cards gets the cards' material.
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: NotificationCard.cornerRadius))
                .floatingShadow()
                .padding(.horizontal, Self.margin)
                .transition(.opacity)
            }
            // The list spans the full width so the scroll indicator sits in the margin on the sidebar's screen edge.
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.notifications, id: \.viewIdentity) { notification in
                        NotificationCard(
                            notification: notification,
                            presentAlert: model.presentAlert(of: notification),
                            isHovered: hoveredID == notification.id,
                            hover: { hoveredID = Self.hoveredID(hoveredID, card: notification.id, hovering: $0) },
                            activate: { model.activate(notification.id) },
                            choose: { model.choose($0, for: notification.id) },
                            dismiss: { model.dismiss(notification.id) }
                        )
                        .transition(cardTransition)
                        // Later cards draw above earlier ones, so when a card is removed the card
                        // sliding up into its place covers it while it fades out.
                        .zIndex(notification.drawingOrder)
                    }
                }
                // Room for the first card's dismiss button, which overhangs its top edge.
                .padding(.top, NotificationCard.dismissOverhang)
                .padding(.horizontal, Self.margin)
            }
            // The list runs to the screen edge; scrolled to the end, the last card keeps a margin under it.
            .contentMargins(.bottom, Self.margin, for: .scrollContent)
            .scrollIndicators(.never)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollMetrics.self, of: ScrollMetrics.init) { scrollMetrics = $1 }
            .onScrollPhaseChange { isScrolling = $1.isScrolling }
            .mask { EdgeFadeMask(fadesTop: scrollMetrics.hasContentAbove, fadesBottom: scrollMetrics.hasContentBelow) }
            .overlay(alignment: Alignment(horizontal: screenEdge, vertical: .center)) {
                if scrollMetrics.isScrollable {
                    ScrollIndicator(metrics: scrollMetrics, isScrolling: isScrolling) { scrollPosition.scrollTo(y: $0) }
                }
            }
            .overlay {
                if model.notifications.isEmpty {
                    Text("No notifications")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .floatingShadow()
                }
            }
        }
        .padding(.top, Self.topMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Changes arrive from the model, outside any view action, so the view animates them itself.
        .animation(Self.motion, value: model.notifications)
        .animation(Self.motion, value: model.interception)
        .animation(Self.motion, value: model.presentAlerts)
    }

    /// The sidebar's screen edge, where the top buttons and the scroll indicator sit.
    var screenEdge: HorizontalAlignment { side == .left ? .leading : .trailing }

    /// Clear All and Settings as small round icon buttons in the top corner on the sidebar's screen edge,
    /// Settings outermost. Their labels open away from that edge, so the icon under the pointer stays put.
    private var controls: some View {
        let expandsToward: HorizontalEdge = side == .left ? .trailing : .leading
        let clearAll = ExpandingIconButton("Clear All", systemImage: "xmark", expandsToward: expandsToward, action: model.clear)
            .disabled(model.notifications.isEmpty)
        let settings = ExpandingIconButton("Settings", systemImage: "gearshape", expandsToward: expandsToward) { openSettings(.general) }
            .keyboardShortcut(",", modifiers: .command)
        return HStack(spacing: 4) {
            if side == .left {
                settings
                clearAll
            } else {
                clearAll
                settings
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

    private var statusMessage: String? {
        switch model.interception {
        case .starting, .active: nil
        case .disabled: "macOS notifications are left to macOS (see Settings)."
        case .needsAccessibility: "Grant Accessibility access to show macOS notifications here."
        case .notificationCenterUnavailable: "macOS notifications cannot be read right now."
        }
    }
}

/// Opaque except for its top and bottom `height` points, which fade out while cards are hidden past that
/// edge, so cards cut off by the edge fade instead of ending abruptly.
struct EdgeFadeMask: View {
    let fadesTop: Bool
    let fadesBottom: Bool

    static let height: CGFloat = 48

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
    /// The hidden macOS alert the card stands for, while it exists; the card offers its choices.
    let presentAlert: SidebarNotification.NativeAlert?
    let isHovered: Bool
    let hover: (Bool) -> Void
    let activate: () -> Void
    let choose: (String) -> Void
    let dismiss: () -> Void

    static let cornerRadius: CGFloat = 10
    /// How far each layer under a stacked card shows, and how much narrower it is per side.
    static let stackLayerHeight: CGFloat = 5
    static let stackLayerInset: CGFloat = 8
    static let maxStackLayers = 2
    /// Cards scale up slightly under the pointer.
    static let hoverScale: CGFloat = 1.02
    /// How far the dismiss button sticks out past the card's top-trailing corner.
    static let dismissOverhang: CGFloat = 5

    @Environment(\.typography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The dismiss button overhangs the card, so the pointer can rest on it outside the card's hover area.
    @State private var isDismissHovered = false

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
        .floatingShadow()
        .overlay(alignment: .topTrailing) {
            ExpandingIconButton("Dismiss", systemImage: "xmark", expandsToward: .leading, action: dismiss)
                .onHover { isDismissHovered = $0 }
                .offset(x: Self.dismissOverhang, y: -Self.dismissOverhang)
                .opacity(showsDismiss ? 1 : 0)
                .allowsHitTesting(showsDismiss)
                .animation(.easeOut(duration: 0.15), value: showsDismiss)
        }
        .scaleEffect(isHovered && !reduceMotion ? Self.hoverScale : 1)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover(perform: hover)
    }

    /// Layers drawn under the card for notifications received more than once.
    private var stackLayers: Int { min(notification.occurrences - 1, Self.maxStackLayers) }

    private var card: some View {
        Button(action: activate) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if let icon = notification.icon {
                        Text(icon.glyph)
                            .font(.custom(AppIconFont.family, fixedSize: typography.size(.caption1)))
                            .accessibilityLabel(icon.accessibilityLabel)
                    }
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
                if !notification.title.isEmpty {
                    Text(notification.title).font(typography.font(.body).bold())
                }
                if !notification.subtitle.isEmpty {
                    Text(notification.subtitle).font(typography.font(.callout))
                }
                if !notification.body.isEmpty {
                    Text(notification.body).font(typography.font(.callout)).lineLimit(8)
                }
                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .font(typography.font(.caption2))
                        .foregroundStyle(.secondary)
                }
                if let presentAlert {
                    // Buttons inside the card's button take their own clicks. VoiceOver cannot reach them
                    // there: it sees the card as one button, and pressing a nested button through
                    // accessibility runs the card's action. It gets the choices as the card's actions.
                    HStack(spacing: 6) {
                        ForEach(presentAlert.choices, id: \.self) { choice in
                            Button(choice, font: typography.font(.callout)) { choose(choice) }
                        }
                    }
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
            // The tints are translucent; the material keeps a card sliding over another (when one
            // above it is removed) from showing the other's text through it.
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
            .overlay {
                if let accent {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .strokeBorder(accent, lineWidth: notification.severity == .critical ? 2 : 1)
                }
            }
            .saberBorder(RoundedRectangle(cornerRadius: Self.cornerRadius), color: saberColor, isActive: isHovered)
            .opacity(notification.severity == .low ? 0.6 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            // The card's label and actions describe it; each text would otherwise become an action.
            .accessibilityElement(children: .ignore)
        }
        // Option-click dismisses the card without acting, like its dismiss button.
        .buttonStyle(PressableButtonStyle(alternateAction: dismiss))
        .help(helpText)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityActions {
            if let presentAlert {
                ForEach(presentAlert.choices, id: \.self) { choice in
                    Button(choice) { choose(choice) }
                }
            }
            // The dismiss button shows only under the pointer.
            Button("Dismiss", action: dismiss)
        }
    }

    /// What a click does, and that Option-click only dismisses, unless a click does nothing else.
    var helpText: String {
        if presentAlert != nil {
            return "Click to open, as clicking the macOS alert would\nOption-click to dismiss"
        }
        guard notification.action != nil else { return notification.clickDescription }
        return notification.clickDescription + "\nOption-click to dismiss"
    }

    /// Caption lines under the card's text.
    var notes: [String] {
        [
            notification.invalidIcon.map { "Invalid icon: \($0)" },
            notification.shownByMacOS ? "Shown by macOS for its buttons" : nil,
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
        parts += [notification.title, notification.subtitle, notification.body].filter { !$0.isEmpty }.map { Text($0) }
        parts += notes.map { Text($0) }
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(", ") + $1 }
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

    private var background: AnyShapeStyle {
        switch notification.severity {
        case .critical: AnyShapeStyle(Color.red.opacity(0.25))
        case .high: AnyShapeStyle(Color.orange.opacity(0.15))
        case .low, .normal: AnyShapeStyle(.quaternary)
        }
    }

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
        case .run: "terminal"
        case .activateApp: nil
        }
    }

}

extension View {
    /// Lifts a card or button off whatever is behind the transparent panel. The shadow is cast by the
    /// composited view, so text inside it casts none of its own.
    func floatingShadow() -> some View {
        compositingGroup().shadow(color: .black.opacity(0.5), radius: 5, y: 2)
    }
}

private extension SidebarNotification {
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
