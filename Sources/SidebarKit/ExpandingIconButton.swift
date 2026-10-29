import SwiftUI

/// A small round icon button. Under the pointer it widens into a capsule that shows its title next to the
/// icon, which stays in place, turns white and traces its edge with a `SaberBorder`.
struct ExpandingIconButton: View {
    let title: String
    let systemImage: String
    /// The side the title opens on. The button grows toward it when it is anchored on the other side.
    let expandsToward: HorizontalEdge
    let action: () -> Void

    static let diameter: CGFloat = 18

    init(_ title: String, systemImage: String, expandsToward: HorizontalEdge, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.expandsToward = expandsToward
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(ExpandingIconButtonStyle(expandsToward: expandsToward))
        .accessibilityLabel(title)
    }
}

struct ExpandingIconButtonStyle: ButtonStyle {
    let expandsToward: HorizontalEdge

    func makeBody(configuration: Configuration) -> some View {
        ExpandingIconButtonBody(configuration: configuration, expandsToward: expandsToward)
    }
}

struct ExpandingIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let expandsToward: HorizontalEdge

    @Environment(\.typography) private var typography
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var isHighlighted: Bool { isEnabled && (isHovered || configuration.isPressed) }

    var body: some View {
        let style = ExpandingLabelStyle(
            isExpanded: isHighlighted,
            titleEdge: expandsToward,
            diameter: ExpandingIconButton.diameter * typography.scale
        )
        // Vibrant `.secondary` and plain white do not interpolate, so animating between them flashes.
        // A white copy fades in over the secondary label instead.
        configuration.label
            .foregroundStyle(.secondary)
            .overlay {
                configuration.label
                    .foregroundStyle(.white)
                    .opacity(isHighlighted ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .labelStyle(style)
            .font(typography.font(.caption1))
            .background(.regularMaterial, in: Capsule())
            .saberBorder(Capsule(), color: .accentColor, isActive: isHighlighted)
            .clipShape(Capsule())
            .floatingShadow()
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
