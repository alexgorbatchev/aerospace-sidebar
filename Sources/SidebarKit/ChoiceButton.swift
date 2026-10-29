import SwiftUI

/// One of a macOS notification's choices on its card: a capsule push button that `CardButtonShadow.choice` lifts
/// under the pointer; a destructive one, such as Delete, draws its title in the system's destructive color.
struct ChoiceButton: View {
    let title: String
    var isDestructive = false
    let action: () -> Void

    @Environment(\.typography) private var typography
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered: Bool

    /// `isHovered` sets where the pointer starts, for tests; the button follows the pointer from there.
    init(title: String, isDestructive: Bool = false, isHovered: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isDestructive = isDestructive
        self.action = action
        _isHovered = State(initialValue: isHovered)
    }

    var body: some View {
        Button(role: isDestructive ? .destructive : nil, action: action) { label }
            // A capsule bezel, so the shadow follows its edge.
            .buttonBorderShape(.capsule)
            .modifier(CardButtonShadowEffect(shadow: .choice, isHovered: isHovered))
            .onHover { isHovered = $0 }
    }

    /// The title in the configured font, set on the `Text` itself, which AppKit's push buttons require. They draw
    /// no role in a color of its own, so a destructive title takes the system's red, dimmed while disabled.
    var label: Text {
        let title = Text(title).font(typography.font(.callout))
        return isDestructive ? title.foregroundStyle(Color.red.opacity(isEnabled ? 1 : 0.5)) : title
    }
}
