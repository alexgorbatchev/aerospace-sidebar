import CoreGraphics
import Foundation
import os

/// Geometry of the sidebar strip within a screen's visible frame.
public struct SidebarLayout: Equatable, Sendable {
    /// Width used when the AeroSpace config cannot be read; tiled windows may then overlap the sidebar.
    public static let fallbackWidth: CGFloat = 300

    private static let logger = Logger(subsystem: "com.alexgorbatchev.aerospace-sidebar", category: "layout")

    public var width: CGFloat

    public init(width: CGFloat) {
        self.width = width
    }

    /// Sizes the sidebar to the strip AeroSpace reserves, falling back to `fallbackWidth` with a logged error.
    public static func fromAeroSpaceConfig(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SidebarLayout {
        do {
            return SidebarLayout(width: try AeroSpaceConfig.load(home: home, environment: environment).sidebarWidth)
        } catch {
            logger.error("Cannot read sidebar width from AeroSpace config: \(String(describing: error), privacy: .public)")
            return SidebarLayout(width: fallbackWidth)
        }
    }

    /// Returns the strip pinned to the right edge of `visibleFrame`, spanning its full height.
    /// The width is clamped so the strip never exceeds the visible frame.
    public func frame(in visibleFrame: CGRect) -> CGRect {
        let stripWidth = min(width, visibleFrame.width)
        return CGRect(
            x: visibleFrame.maxX - stripWidth,
            y: visibleFrame.minY,
            width: stripWidth,
            height: visibleFrame.height
        )
    }
}
