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
            content.shadow(
                color: .black.opacity(Self.opacity),
                radius: square.size.height * Self.radius,
                y: square.size.height * Self.offset
            )
        }
    }
}
