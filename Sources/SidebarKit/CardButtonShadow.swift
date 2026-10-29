import SwiftUI

/// The shadows a button on a notification card casts: a soft halo around its edge at all times, and a
/// hard shadow under it while the pointer is on it, which fades in and out over `change`.
struct CardButtonShadow: Equatable {
    /// Opacity of the black halo, blurred by `haloRadius` with no offset.
    var halo: Double
    /// Opacity of the black shadow under the pointer.
    var hover: Double
    /// Seconds the hover shadow takes to fade in or out.
    var change: Double

    static let haloRadius: CGFloat = 2
    /// How far the hover shadow falls below the button. It has no blur.
    static let hoverOffset: CGFloat = 2

    /// The card's dismiss button.
    static let dismiss = CardButtonShadow(halo: 0.5, hover: 0.5, change: 0.09)
    /// An alert's choices.
    static let choice = CardButtonShadow(halo: 0, hover: 0.5, change: 0.13)
}

/// Casts `CardButtonShadow` around a capsule-shaped button, with its hover shadow while `isHovered`, or
/// nothing. The hover shadow fades over its own `change`, whatever animation the button runs for its other
/// changes, such as widening.
struct CardButtonShadowEffect: ViewModifier {
    let shadow: CardButtonShadow?
    let isHovered: Bool

    func body(content: Content) -> some View {
        if let shadow {
            content.cutOutShadows(Capsule(), reach: 3 * max(CardButtonShadow.haloRadius, CardButtonShadow.hoverOffset)) {
                ShadowCaster(shape: Capsule(), opacity: shadow.halo, radius: CardButtonShadow.haloRadius)
                // A hard shadow: the copy's own offset shadow, unblurred.
                ShadowCaster(shape: Capsule(), opacity: 1, radius: 0, y: CardButtonShadow.hoverOffset)
                    .animation(.easeOut(duration: shadow.change)) { $0.opacity(isHovered ? shadow.hover : 0) }
            }
        } else {
            content
        }
    }
}
