import SwiftUI

/// A round push button under the app icon of a card whose app has its notifications switched off in System
/// Settings, which switches them on there, like Allow in Settings › Notifications. NotificationCenter keeps such
/// an app's notifications out of sight, so the card can only switch to the app. It acts on the card like the
/// card's choices and follows the pointer as they do (`CardActionLift`).
struct SwitchedOffBadge: View {
    /// The app as the card names it.
    let appName: String
    /// Where the pointer starts, for tests; the button follows the pointer from there.
    let isHovered: Bool
    let action: () -> Void

    @Environment(\.typography) private var typography
    /// Its tooltip, which a click hides.
    @State private var tooltip: SidebarTooltipHover

    /// `tooltip` sets whether the tooltip starts shown, for tests.
    init(appName: String, isHovered: Bool = false, tooltip: SidebarTooltipHover = SidebarTooltipHover(), action: @escaping () -> Void) {
        self.appName = appName
        self.isHovered = isHovered
        self.action = action
        _tooltip = State(initialValue: tooltip)
    }

    static let symbol = "bell.slash.fill"

    var body: some View {
        Button {
            tooltip.dismiss()
            action()
        } label: {
            // Push buttons draw their label through AppKit, which takes the font only from the label itself.
            Image(systemName: Self.symbol)
                .font(typography.font(.caption2))
                .accessibilityHidden(true)
        }
        // A round bezel, which the lift's capsule shadow follows.
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .modifier(CardActionLift(isHovered: isHovered))
        // AppKit's tooltips show only while the app is active, which the sidebar never is.
        .sidebarTooltip(Self.helpText(appName: appName), hover: tooltip)
        .accessibilityLabel(Self.accessibilityLabel(appName: appName))
    }

    /// What is wrong, what it costs and what a click does about it.
    static func helpText(appName: String) -> String {
        """
        This card can only switch to \(appName) because notifications are switched off in macOS System Settings.

        Click to switch them on.
        """
    }

    static func accessibilityLabel(appName: String) -> String {
        "Notifications from \(appName) are off; switch them on"
    }
}
