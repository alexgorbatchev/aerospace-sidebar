import Observation
import SwiftUI

/// The Settings window's groups, in the order the sidebar lists them. General and Permissions act
/// immediately; the others edit the draft and end with Cancel and Save.
public enum SettingsGroup: Int, CaseIterable, Identifiable, Sendable {
    case general, appearance, sidebar, permissions, notifications, rules, history

    public var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .sidebar: "Sidebar"
        case .permissions: "Permissions"
        case .notifications: "Notifications"
        case .rules: "Rules"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "textformat"
        case .sidebar: "sidebar.right"
        case .permissions: "hand.raised"
        case .notifications: "bell.badge"
        case .rules: "line.3.horizontal.decrease.circle"
        case .history: "clock.arrow.circlepath"
        }
    }
}

/// The group the Settings window shows. The sidebar's selection binds to it, and the window controller
/// follows it through `onSelect`.
@MainActor
@Observable
final class SettingsNavigation {
    var selection: SettingsGroup = .general {
        didSet { onSelect?(selection) }
    }

    @ObservationIgnored var onSelect: ((SettingsGroup) -> Void)?
}

/// The source list of groups on the window's leading side.
struct SettingsSidebar: View {
    let navigation: SettingsNavigation
    /// Reports the height the list needs to show every group without scrolling, including its insets.
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        List(SettingsGroup.allCases, selection: selection) { group in
            Label(group.title, systemImage: group.symbol)
                .labelStyle(SettingsSidebarLabelStyle())
        }
        .listStyle(.sidebar)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
        } action: { _, height in
            onHeightChange(height)
        }
    }

    /// Clicking below the last row deselects; the shown group stays selected instead.
    private var selection: Binding<SettingsGroup?> {
        Binding(get: { navigation.selection }, set: { $0.map { navigation.selection = $0 } })
    }
}

/// A group row in the configured font. The sidebar list style sizes its own icon column for the system's
/// sidebar font, so icons in a row set in another font lose their alignment; this style sizes the column
/// from the configured font instead.
struct SettingsSidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsSidebarRow(configuration: configuration)
    }
}

struct SettingsSidebarRow: View {
    let configuration: LabelStyleConfiguration

    @Environment(\.typography) private var typography

    var body: some View {
        HStack(spacing: typography.size * SettingsMetrics.sidebarIconSpacing) {
            configuration.icon
                .frame(width: typography.size * SettingsMetrics.sidebarIconWidth)
            configuration.title
        }
        .font(typography.font(.body))
    }
}
