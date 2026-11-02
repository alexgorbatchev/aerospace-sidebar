import SwiftUI

/// A round button under the app icon of a card whose app has its notifications switched off in System Settings,
/// which opens Settings › Notifications: that group lists the app with Allow. NotificationCenter keeps such an
/// app's notifications out of sight, so the card can only switch to the app.
struct SwitchedOffBadge: View {
    /// The app as the card names it.
    let appName: String
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
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .help(Self.helpText(appName: appName))
        .accessibilityLabel(Self.accessibilityLabel(appName: appName))
    }

    static func helpText(appName: String) -> String {
        "Notifications from \(appName) are off in System Settings\nClick to open Settings › Notifications"
    }

    static func accessibilityLabel(appName: String) -> String {
        "Notifications from \(appName) are off; open Settings › Notifications"
    }
}
