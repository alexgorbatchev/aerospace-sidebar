import SwiftUI

/// One of a macOS alert's choices on its card: a capsule push button that `CardButtonShadow.choice` lifts
/// under the pointer.
struct ChoiceButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.typography) private var typography
    @State private var isHovered: Bool

    /// `isHovered` sets where the pointer starts, for tests; the button follows the pointer from there.
    init(title: String, isHovered: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.action = action
        _isHovered = State(initialValue: isHovered)
    }

    var body: some View {
        Button(title, font: typography.font(.callout), action: action)
            // A capsule bezel, so the shadow follows its edge.
            .buttonBorderShape(.capsule)
            .modifier(CardButtonShadowEffect(shadow: .choice, isHovered: isHovered))
            .onHover { isHovered = $0 }
    }
}
