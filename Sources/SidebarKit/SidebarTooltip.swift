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

/// When a marked view's tooltip shows: once the pointer has rested on the view for `delay`, until it leaves.
@MainActor
@Observable
final class SidebarTooltipHover {
    /// About as long as AppKit waits before showing a tooltip.
    static let delay: Duration = .milliseconds(700)

    private(set) var isShown: Bool
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private var pending: Task<Void, Never>?

    init(isShown: Bool = false, delay: Duration = SidebarTooltipHover.delay) {
        self.isShown = isShown
        self.delay = delay
    }

    func hover(_ isInside: Bool) {
        pending?.cancel()
        pending = nil
        guard isInside else {
            isShown = false
            return
        }
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.isShown = true
        }
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

/// The tooltip's text on the cards' material, in the configured font.
struct SidebarTooltipBubble: View {
    let text: String

    @Environment(\.typography) private var typography

    var body: some View {
        Text(text)
            .font(typography.font(.callout))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .floatingShadow()
    }
}

/// Places the tooltip under `anchor`, or above it where there is no room below, kept `margin` inside the
/// container's edges and at most `maxWidth` wide.
struct SidebarTooltipPlacement: Layout {
    let anchor: CGRect
    var margin: CGFloat = SidebarView.margin
    var gap: CGFloat = 6
    var maxWidth: CGFloat = 320

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
        modifier(SidebarTooltipModifier(text: text, hover: SidebarTooltipHover()))
    }

    /// Draws the tooltips of the views inside, above them.
    func sidebarTooltips() -> some View {
        overlayPreferenceValue(SidebarTooltipKey.self) { SidebarTooltipLayer(tooltips: $0) }
    }
}
