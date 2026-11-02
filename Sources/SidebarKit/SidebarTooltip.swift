import Observation
import SwiftUI

/// Tooltips the sidebar draws itself. AppKit shows `help(_:)` tooltips only while their app is active, and the
/// sidebar never is (its panel is non-activating), so a view in the sidebar marks its text with
/// `sidebarTooltip(_:)` and `SidebarView` draws it with `sidebarTooltips()`, above everything in the panel.
struct SidebarTooltip: Equatable {
    let text: String
    /// The marked view's bounds, resolved in the view that draws the tooltip.
    let anchor: Anchor<CGRect>
}

/// The tooltips currently shown, innermost last.
struct SidebarTooltipKey: PreferenceKey {
    static let defaultValue: [SidebarTooltip] = []

    static func reduce(value: inout [SidebarTooltip], nextValue: () -> [SidebarTooltip]) {
        value.append(contentsOf: nextValue())
    }
}

/// When a marked view's tooltip shows: once the pointer has rested on the view for `delay`, until it leaves or the
/// view is clicked (`dismiss()`); after a click it shows again only once the pointer has left and come back.
@MainActor
@Observable
final class SidebarTooltipHover {
    /// About as long as AppKit waits before showing a tooltip.
    static let delay: Duration = .milliseconds(700)

    private(set) var isShown: Bool
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Clicked since the pointer came onto the view.
    @ObservationIgnored private var isDismissed = false

    init(isShown: Bool = false, delay: Duration = SidebarTooltipHover.delay) {
        self.isShown = isShown
        self.delay = delay
    }

    func hover(_ isInside: Bool) {
        pending?.cancel()
        pending = nil
        guard isInside else {
            isShown = false
            isDismissed = false
            return
        }
        guard !isDismissed else { return }
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.isShown = true
        }
    }

    /// Hides the tooltip for a click on its view, as AppKit hides its tooltips.
    func dismiss() {
        pending?.cancel()
        pending = nil
        isShown = false
        isDismissed = true
    }
}

struct SidebarTooltipModifier: ViewModifier {
    let text: String
    @State var hover: SidebarTooltipHover

    func body(content: Content) -> some View {
        content
            .onHover { hover.hover($0) }
            .accessibilityHint(text)
            .anchorPreference(key: SidebarTooltipKey.self, value: .bounds) { [isShown = hover.isShown] anchor in
                isShown ? [SidebarTooltip(text: text, anchor: anchor)] : []
            }
    }
}

/// The tooltip of the innermost marked view the pointer rests on, placed by `SidebarTooltipPlacement`.
struct SidebarTooltipLayer: View {
    let tooltips: [SidebarTooltip]

    var body: some View {
        GeometryReader { proxy in
            if let tooltip = tooltips.last {
                SidebarTooltipPlacement(anchor: proxy[tooltip.anchor]) {
                    SidebarTooltipBubble(text: tooltip.text)
                }
                .transition(.opacity)
            }
        }
        // It only shows text; the pointer stays on the view under it.
        .allowsHitTesting(false)
        // The marked view's accessibility hint already reads the text.
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.15), value: tooltips.last?.text)
    }
}

/// The tooltip's text in the configured font, a size under the cards' body text, on material of the opposite
/// appearance: light over the dark cards, dark over light ones, so it never reads as one of them.
struct SidebarTooltipBubble: View {
    let text: String

    @Environment(\.typography) private var typography
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(typography.font(.subheadline))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8))
            .environment(\.colorScheme, colorScheme == .dark ? .light : .dark)
            .floatingShadow()
    }
}

/// Places the tooltip under `anchor`, or above it where there is no room below, kept `margin` inside the
/// container's edges and at most `maxWidth` wide.
struct SidebarTooltipPlacement: Layout {
    let anchor: CGRect
    var margin: CGFloat = SidebarView.margin
    var gap: CGFloat = 6
    var maxWidth: CGFloat = 300

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let width = max(min(maxWidth, bounds.width - 2 * margin), 0)
        let size = bubble.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let frame = Self.frame(of: size, under: anchor, in: CGRect(origin: .zero, size: bounds.size), margin: margin, gap: gap)
        bubble.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
    }

    /// Where a tooltip of `size` goes for a view at `anchor` in `container`: starting at the view's leading edge
    /// `gap` below it, moved left to fit before the trailing margin but never past the leading one, and `gap`
    /// above the view when it would cross the bottom margin there.
    static func frame(of size: CGSize, under anchor: CGRect, in container: CGRect, margin: CGFloat, gap: CGFloat) -> CGRect {
        let x = max(min(anchor.minX, container.maxX - margin - size.width), container.minX + margin)
        let below = anchor.maxY + gap
        let y = below + size.height > container.maxY - margin ? anchor.minY - gap - size.height : below
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

extension View {
    /// Shows `text` in a tooltip the sidebar draws (`sidebarTooltips()`) once the pointer rests on this view.
    func sidebarTooltip(_ text: String) -> some View {
        sidebarTooltip(text, hover: SidebarTooltipHover())
    }

    /// Shows `text` in a tooltip as `hover` decides, which the view's action dismisses on a click.
    func sidebarTooltip(_ text: String, hover: SidebarTooltipHover) -> some View {
        modifier(SidebarTooltipModifier(text: text, hover: hover))
    }

    /// Draws the tooltips of the views inside, above them.
    func sidebarTooltips() -> some View {
        overlayPreferenceValue(SidebarTooltipKey.self) { SidebarTooltipLayer(tooltips: $0) }
    }
}
