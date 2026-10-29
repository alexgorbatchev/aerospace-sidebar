import SidebarProtocol
import SwiftUI

/// A small round icon button. Under the pointer it widens into a capsule that shows its title next to the
/// icon, which stays in place, and traces its edge with a `SaberBorder`.
struct ExpandingIconButton: View {
    let title: String
    let systemImage: String
    /// The side the title opens on. The button grows toward it when it is anchored on the other side.
    let expandsToward: HorizontalEdge
    let surface: Surface
    let action: () -> Void

    static let diameter: CGFloat = 18

    /// What the button sits on, which sets how it looks at rest.
    enum Surface: Equatable {
        /// Whatever is behind the panel: material, a secondary label that turns white under the pointer,
        /// and the floating shadow.
        case floating
        /// A notification card of this severity: the card's tint over the same material, a primary label,
        /// `CardButtonShadow.dismiss` instead of the floating shadow, and the sizes of
        /// `NotificationCard.dismissScale`.
        case card(NotificationSeverity)

        /// The button's diameter relative to `ExpandingIconButton.diameter`.
        var diameterScale: CGFloat {
            if case .card = self { NotificationCard.dismissScale.diameter } else { 1 }
        }

        /// The label's size relative to the caption text style.
        var textScale: CGFloat {
            if case .card = self { NotificationCard.dismissScale.text } else { 1 }
        }
    }

    /// The diameter for text at `typography`, rounded to the pixels of `displayScale` so the edges fall on
    /// pixel boundaries instead of across them.
    static func diameter(_ surface: Surface, typography: Typography, displayScale: CGFloat) -> CGFloat {
        let points = diameter * surface.diameterScale * typography.scale
        return (points * displayScale).rounded() / displayScale
    }

    init(
        _ title: String,
        systemImage: String,
        expandsToward: HorizontalEdge,
        surface: Surface = .floating,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.expandsToward = expandsToward
        self.surface = surface
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(ExpandingIconButtonStyle(expandsToward: expandsToward, surface: surface))
        .accessibilityLabel(title)
    }
}

struct ExpandingIconButtonStyle: ButtonStyle {
    let expandsToward: HorizontalEdge
    var surface: ExpandingIconButton.Surface = .floating

    func makeBody(configuration: Configuration) -> some View {
        ExpandingIconButtonBody(configuration: configuration, expandsToward: expandsToward, surface: surface)
    }
}

struct ExpandingIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let expandsToward: HorizontalEdge
    let surface: ExpandingIconButton.Surface

    @Environment(\.typography) private var typography
    @Environment(\.displayScale) private var displayScale
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var isHighlighted: Bool { isEnabled && (isHovered || configuration.isPressed) }

    private var card: NotificationSeverity? {
        if case .card(let severity) = surface { severity } else { nil }
    }

    private var onCard: Bool { card != nil }

    var body: some View {
        let style = ExpandingLabelStyle(
            isExpanded: isHighlighted,
            titleEdge: expandsToward,
            diameter: ExpandingIconButton.diameter(surface, typography: typography, displayScale: displayScale)
        )
        // Vibrant `.secondary` and plain white do not interpolate, so animating between them flashes.
        // A white copy fades in over the secondary label instead. On a card the label is already primary
        // and its shadow shows the highlight.
        configuration.label
            .foregroundStyle(onCard ? .primary : .secondary)
            .overlay {
                configuration.label
                    .foregroundStyle(.white)
                    .opacity(isHighlighted && !onCard ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .labelStyle(style)
            .font(typography.font(.caption1, scale: surface.textScale))
            .background(card?.cardFill ?? AnyShapeStyle(.clear), in: Capsule())
            .background(.regularMaterial, in: Capsule())
            .saberBorder(Capsule(), color: .accentColor, isActive: isHighlighted)
            .clipShape(Capsule())
            .modifier(CardButtonShadowEffect(shadow: onCard ? .dismiss : nil, isHovered: isHighlighted))
            .floatingShadow(isShown: !onCard)
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isHighlighted)
            .onHover { isHovered = $0 }
    }
}

/// The icon in a circle `diameter` wide; when expanded, the title beside it on `titleEdge`.
///
/// The title is always laid out beside the icon, and collapsed the label is only the icon's width, pinned
/// to the icon's side. Widening then reveals the title where it will stay while it fades in, instead of
/// inserting it at full width, where it would slide in with the label's growing edge.
struct ExpandingLabelStyle: LabelStyle {
    let isExpanded: Bool
    let titleEdge: HorizontalEdge
    let diameter: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            if titleEdge == .leading { title(configuration) }
            configuration.icon
                .fontWeight(.semibold)
                .frame(width: diameter, height: diameter)
            if titleEdge == .trailing { title(configuration) }
        }
        .fixedSize()
        .frame(width: isExpanded ? nil : diameter, alignment: titleEdge == .leading ? .trailing : .leading)
    }

    private func title(_ configuration: Configuration) -> some View {
        configuration.title
            .lineLimit(1)
            .padding(titleEdge == .leading ? .leading : .trailing, diameter / 2)
            .opacity(isExpanded ? 1 : 0)
            .accessibilityHidden(!isExpanded)
    }
}
