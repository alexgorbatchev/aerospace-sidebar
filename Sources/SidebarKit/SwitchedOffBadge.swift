import SidebarProtocol
import SwiftUI

/// An `ExpandingIconButton` under the app icon of a card whose app has its notifications switched off in System
/// Settings, which opens Settings › Notifications: that group lists the app with Allow. NotificationCenter keeps
/// such an app's notifications out of sight, so the card can only switch to the app.
///
/// It takes the space of the round button alone and opens its title toward the card's text, over it, so that
/// widening under the pointer moves neither the button nor the text beside it.
struct SwitchedOffBadge: View {
    /// The app as the card names it.
    let appName: String
    /// The card's severity, whose tint the button draws like the card's dismiss button.
    let severity: NotificationSeverity
    let action: () -> Void

    @Environment(\.typography) private var typography
    @Environment(\.displayScale) private var displayScale

    static let title = "Notifications Off"
    static let symbol = "bell.slash.fill"

    var body: some View {
        let surface = ExpandingIconButton.Surface.card(severity)
        let diameter = ExpandingIconButton.diameter(surface, typography: typography, displayScale: displayScale)
        ExpandingIconButton(Self.title, systemImage: Self.symbol, expandsToward: .trailing, surface: surface, action: action)
            .help(Self.helpText(appName: appName))
            .fixedSize()
            .frame(width: diameter, height: diameter, alignment: .leading)
    }

    static func helpText(appName: String) -> String {
        "Notifications from \(appName) are off in System Settings\nClick to open Settings › Notifications"
    }
}
