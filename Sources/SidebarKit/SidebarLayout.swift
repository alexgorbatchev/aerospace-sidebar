import CoreGraphics

/// Geometry of the sidebar strip within a screen's visible frame.
public struct SidebarLayout: Equatable, Sendable {
    public var width: CGFloat
    public var side: SidebarSettings.Sidebar.Side

    public init(width: CGFloat, side: SidebarSettings.Sidebar.Side) {
        self.width = width
        self.side = side
    }

    public init(_ sidebar: SidebarSettings.Sidebar) {
        self.init(width: CGFloat(sidebar.width), side: sidebar.side)
    }

    /// Returns the strip pinned to the `side` edge of `visibleFrame`, spanning its full height.
    /// The width is clamped so the strip never exceeds the visible frame.
    public func frame(in visibleFrame: CGRect) -> CGRect {
        let stripWidth = min(width, visibleFrame.width)
        return CGRect(
            x: side == .left ? visibleFrame.minX : visibleFrame.maxX - stripWidth,
            y: visibleFrame.minY,
            width: stripWidth,
            height: visibleFrame.height
        )
    }

    /// How far the strip reaches in from the right edge of `visibleFrame`, where NotificationCenter draws
    /// notifications (16 points in from it, left of a Dock on the right): the strip's width on the right
    /// side, nothing on the left side.
    public func coverage(ofRightEdgeOf visibleFrame: CGRect) -> CGFloat {
        side == .right ? frame(in: visibleFrame).width : 0
    }
}
