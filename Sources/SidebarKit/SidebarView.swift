import SidebarProtocol
import SwiftUI

/// Root content of the sidebar panel.
struct SidebarView: View {
    let model: SidebarModel
    let openSettings: () -> Void
    let quit: () -> Void

    static let margin: CGFloat = 16
    static let motion: Animation = .snappy

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.typography) private var typography
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var scrollMetrics = ScrollMetrics()
    @State private var isScrolling = false
    @State private var hoveredID: SidebarNotification.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Notifications")
                    .font(typography.font(.headline))
                    .lineLimit(1)
                Spacer()
                if !model.notifications.isEmpty {
                    Button("Clear All", font: typography.font(.body), action: model.clear)
                        .buttonStyle(.link)
                }
            }
            .padding(.horizontal, Self.margin)
            if let message = statusMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(typography.font(.callout))
                        .foregroundStyle(.secondary)
                    if model.interception == .needsAccessibility {
                        Button("Set Up…", font: typography.font(.body), action: openSettings)
                    }
                }
                .padding(.horizontal, Self.margin)
                .transition(.opacity)
            }
            // The list spans the full width so the scroll indicator sits in the trailing margin.
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.notifications, id: \.viewIdentity) { notification in
                        NotificationCard(
                            notification: notification,
                            isHovered: hoveredID == notification.id,
                            hover: { hoveredID = Self.hoveredID(hoveredID, card: notification.id, hovering: $0) },
                            activate: { model.activate(notification.id) },
                            dismiss: { model.dismiss(notification.id) }
                        )
                        .transition(cardTransition)
                        // Later cards draw above earlier ones, so when a card is removed the card
                        // sliding up into its place covers it while it fades out.
                        .zIndex(notification.drawingOrder)
                    }
                }
                .padding(.horizontal, Self.margin)
            }
            .scrollIndicators(.never)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollMetrics.self, of: ScrollMetrics.init) { scrollMetrics = $1 }
            .onScrollPhaseChange { isScrolling = $1.isScrolling }
            .overlay(alignment: .trailing) {
                if scrollMetrics.isScrollable {
                    ScrollIndicator(metrics: scrollMetrics, isScrolling: isScrolling) { scrollPosition.scrollTo(y: $0) }
                }
            }
            .overlay {
                if model.notifications.isEmpty {
                    Text("No notifications")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Settings…", font: typography.font(.body), action: openSettings)
                    .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("Quit Sidebar", font: typography.font(.body), action: quit)
                    .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, Self.margin)
        }
        .padding(.vertical, Self.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Changes arrive from the model, outside any view action, so the view animates them itself.
        .animation(Self.motion, value: model.notifications)
        .animation(Self.motion, value: model.interception)
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

struct NotificationCard: View {
    let notification: SidebarNotification
    let isHovered: Bool
    let hover: (Bool) -> Void
    let activate: () -> Void
    let dismiss: () -> Void

    static let cornerRadius: CGFloat = 10
    /// How far each layer under a stacked card shows, and how much narrower it is per side.
    static let stackLayerHeight: CGFloat = 5
    static let stackLayerInset: CGFloat = 8
    static let maxStackLayers = 2
    /// Cards scale up slightly under the pointer.
    static let hoverScale: CGFloat = 1.02

    @Environment(\.typography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            card
            ForEach(1..<stackLayers + 1, id: \.self) { layer in
                UnevenRoundedRectangle(bottomLeadingRadius: Self.stackLayerHeight, bottomTrailingRadius: Self.stackLayerHeight)
                    .fill(background)
                    .opacity(0.8 - 0.25 * Double(layer))
                    .frame(height: Self.stackLayerHeight)
                    .padding(.horizontal, Self.stackLayerInset * CGFloat(layer))
            }
        }
        .scaleEffect(isHovered && !reduceMotion ? Self.hoverScale : 1)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover(perform: hover)
    }

    /// Layers drawn under the card for notifications received more than once.
    private var stackLayers: Int { min(notification.occurrences - 1, Self.maxStackLayers) }

    private var card: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: activate) {
                VStack(alignment: .leading, spacing: 4) {
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
                    if !notification.title.isEmpty {
                        Text(notification.title).font(typography.font(.body).bold())
                    }
                    if !notification.subtitle.isEmpty {
                        Text(notification.subtitle).font(typography.font(.callout))
                    }
                    if !notification.body.isEmpty {
                        Text(notification.body).font(typography.font(.callout)).lineLimit(8)
                    }
                    if notification.shownByMacOS {
                        Text("Shown by macOS for its buttons")
                            .font(typography.font(.caption2))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .padding(.trailing, 16)
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
                .opacity(notification.severity == .low ? 0.6 : 1)
                .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            }
            .buttonStyle(.plain)
            .help(notification.clickDescription)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(typography.font(.caption1))
            }
            .buttonStyle(.borderless)
            .padding(8)
            .accessibilityLabel("Dismiss")
        }
    }

    private var accent: Color? {
        switch notification.severity {
        case .low, .normal: nil
        case .high: .orange
        case .critical: .red
        }
    }

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
