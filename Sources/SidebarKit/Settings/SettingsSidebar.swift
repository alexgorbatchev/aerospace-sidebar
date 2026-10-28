import Observation
import SwiftUI

/// The Settings window's groups, in the order the sidebar lists them. Permissions, AeroSpace and General
/// act immediately; the others edit the draft and end with Cancel and Save.
enum SettingsGroup: Int, CaseIterable, Identifiable {
    case permissions, aeroSpace, sidebar, notifications, history, font, general

    var id: Self { self }

    var title: String {
        switch self {
        case .permissions: "Permissions"
        case .aeroSpace: "AeroSpace"
        case .sidebar: "Sidebar"
        case .notifications: "Notifications"
        case .history: "History"
        case .font: "Font"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .permissions: "hand.raised"
        case .aeroSpace: "rectangle.split.3x1"
        case .sidebar: "sidebar.right"
        case .notifications: "bell.badge"
        case .history: "clock.arrow.circlepath"
        case .font: "textformat"
        case .general: "gearshape"
        }
    }
}

/// The group the Settings window shows. The sidebar's selection binds to it, and the window controller
/// follows it through `onSelect`.
@MainActor
@Observable
final class SettingsNavigation {
    var selection: SettingsGroup = .permissions {
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
