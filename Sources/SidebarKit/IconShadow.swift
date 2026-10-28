import SwiftUI

/// The drop shadow macOS draws into app icons, for icons drawn without one, such as font icons. Measured
/// on the icons `NSWorkspace` returns (Notes, Calendar and Script Editor match): a 25% black shadow with
/// a 15-point blur radius, 8 points down, on a 1024-point icon. It scales with the square the content is
/// given, so a small icon gets a proportionally small shadow.
struct IconShadow: ViewModifier {
    static let opacity = 0.25
    static let radius: CGFloat = 15.0 / 1024.0
    static let offset: CGFloat = 8.0 / 1024.0

    func body(content: Content) -> some View {
        GeometryReader { square in
            content.iconShadow(square: square.size.height)
        }
    }
}

/// `IconShadow` for content that keeps its own size and fills it the way an icon's artwork fills its
/// square, such as a push button: the shadow an icon of that artwork would cast. A `GeometryReader` would
/// take all the space offered instead of the content's own size, so the height is read after layout.
struct ArtworkShadow: ViewModifier {
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .iconShadow(square: height / NotificationCard.iconArtwork)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
    }
}

private extension View {
    /// The icon shadow for a square of `side` points.
    func iconShadow(square side: CGFloat) -> some View {
        shadow(color: .black.opacity(IconShadow.opacity), radius: side * IconShadow.radius, y: side * IconShadow.offset)
    }
}
