import SwiftUI

/// The scroll state of a vertical scroll view that `ScrollIndicator` draws and drags.
struct ScrollMetrics: Equatable {
    var contentHeight: CGFloat
    var visibleHeight: CGFloat
    /// Distance scrolled from the top.
    var offset: CGFloat

    init(contentHeight: CGFloat = 0, visibleHeight: CGFloat = 0, offset: CGFloat = 0) {
        self.contentHeight = contentHeight
        self.visibleHeight = visibleHeight
        self.offset = offset
    }

    init(_ geometry: ScrollGeometry) {
        self.init(
            contentHeight: geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom,
            visibleHeight: geometry.containerSize.height,
            offset: geometry.contentOffset.y + geometry.contentInsets.top
        )
    }

    var maxOffset: CGFloat { max(0, contentHeight - visibleHeight) }
    var isScrollable: Bool { maxOffset >= 1 }
    /// Whether content is hidden above the visible area.
    var hasContentAbove: Bool { offset >= 1 }
    /// Whether content is hidden below the visible area.
    var hasContentBelow: Bool { maxOffset - offset >= 1 }

    /// The knob's distance from the top of a track `trackLength` long, and its length.
    func knob(trackLength: CGFloat, minLength: CGFloat) -> (y: CGFloat, length: CGFloat) {
        guard isScrollable, trackLength > 0 else { return (0, max(trackLength, 0)) }
        let length = min(trackLength, max(minLength, trackLength * visibleHeight / contentHeight))
        let progress = min(max(offset / maxOffset, 0), 1)
        return ((trackLength - length) * progress, length)
    }

    /// The scroll offset that moves the knob `translation` points from where it was at `startOffset`.
    func offset(draggingKnobBy translation: CGFloat, from startOffset: CGFloat, trackLength: CGFloat, minLength: CGFloat) -> CGFloat {
        let travel = trackLength - knob(trackLength: trackLength, minLength: minLength).length
        guard travel > 0 else { return startOffset }
        return min(max(startOffset + translation * maxOffset / travel, 0), maxOffset)
    }
}

/// A thin knob over a side gutter of a scroll view, used instead of the system scroller. With a
/// mouse attached macOS uses legacy scrollers, which are wide, draw a track, and take their width from
/// the content. The knob takes no layout space, appears while the view scrolls or the pointer is over
/// the gutter, fades out shortly after, and can be dragged.
struct ScrollIndicator: View {
    static let gutterWidth: CGFloat = 14
    static let knobWidth: CGFloat = 4
    static let minKnobLength: CGFloat = 24
    /// Gap between the knob's travel and the ends of the gutter.
    static let inset: CGFloat = 4
    static let linger: Duration = .milliseconds(800)

    let metrics: ScrollMetrics
    let isScrolling: Bool
    let scrollTo: (CGFloat) -> Void

    @State private var isHovering = false
    @State private var dragStartOffset: CGFloat?
    @State private var isVisible = false

    var body: some View {
        Capsule()
            .fill(.secondary)
            .frame(width: Self.knobWidth, height: knob.length)
            .offset(y: Self.inset + knob.y)
            .opacity(isVisible ? 1 : 0)
            .frame(width: Self.gutterWidth, height: metrics.visibleHeight, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag(by: $0.translation.height) }
                .onEnded { _ in dragStartOffset = nil })
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.2), value: isVisible)
            .task(id: isActive) {
                if isActive {
                    isVisible = true
                } else if (try? await Task.sleep(for: Self.linger)) != nil {
                    isVisible = false
                }
            }
            .accessibilityHidden(true)
    }

    /// The indicator covers the scroll view's full height.
    private var trackLength: CGFloat { metrics.visibleHeight - 2 * Self.inset }
    private var knob: (y: CGFloat, length: CGFloat) { metrics.knob(trackLength: trackLength, minLength: Self.minKnobLength) }

    private var isActive: Bool { isScrolling || isHovering || dragStartOffset != nil }

    private func drag(by translation: CGFloat) {
        let start = dragStartOffset ?? metrics.offset
        dragStartOffset = start
        scrollTo(metrics.offset(draggingKnobBy: translation, from: start, trackLength: trackLength, minLength: Self.minKnobLength))
    }
}
