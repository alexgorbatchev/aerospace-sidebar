import SwiftUI

/// A round push button under the app icon of a card whose app has its notifications switched off in System
/// Settings, which opens Settings › Notifications: that group lists the app with Allow. NotificationCenter keeps
/// such an app's notifications out of sight, so the card can only switch to the app. It acts on the card like
/// the card's choices and follows the pointer as they do (`CardActionLift`).
struct SwitchedOffBadge: View {
    /// The app as the card names it.
    let appName: String
    /// Where the pointer starts, for tests; the button follows the pointer from there.
    var isHovered = false
    let action: () -> Void

    @Environment(\.typography) private var typography

    static let symbol = "bell.slash.fill"

    var body: some View {
        Button(action: action) {
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
        .sidebarTooltip(Self.helpText(appName: appName))
        .accessibilityLabel(Self.accessibilityLabel(appName: appName))
    }

    /// What is wrong, what it costs and what a click does about it.
    static func helpText(appName: String) -> String {
        """
        \(appName) has notifications switched off in System Settings, so macOS keeps them out of \
        Notification Center: this card can only switch to \(appName), not open the message or answer it.
        Click to switch them on from Settings › Notifications.
        """
    }

    static func accessibilityLabel(appName: String) -> String {
        "Notifications from \(appName) are off; open Settings › Notifications"
    }
}
