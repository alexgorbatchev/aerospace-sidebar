import SwiftUI

/// Permissions: everything the sidebar asks macOS for, why it needs it, and how to take it back.
/// Its steps take effect immediately, so it has no Cancel or Save.
struct PermissionsPane: View {
    let onboarding: OnboardingModel

    /// PermissionFlow's drag panel flies from the clicked step to System Settings.
    @State private var accessibilityAnchor = ScreenFrameAnchor()
    @State private var fullDiskAccessAnchor = ScreenFrameAnchor()

    var body: some View {
        SettingsPage {
            SettingsRow(label: "Accessibility") {
                RemovableStep(remove: { Task { await onboarding.removeAccessibility() } }) {
                    SetupStep(title: "Open Accessibility", isDone: onboarding.accessibilityGranted, anchor: accessibilityAnchor) {
                        onboarding.authorize(.accessibility, from: accessibilityAnchor.screenFrame)
                    }
                }
            }
            SettingsHint(text: "Required to read and hide banners.")
            SettingsRow(label: "Full Disk Access") {
                RemovableStep(remove: { Task { await onboarding.removeFullDiskAccess() } }) {
                    SetupStep(title: "Open Full Disk Access", isDone: onboarding.fullDiskAccess == .granted, anchor: fullDiskAccessAnchor) {
                        onboarding.authorize(.fullDiskAccess, from: fullDiskAccessAnchor.screenFrame)
                    }
                }
            }
            SettingsHint(text: "Optional. Lists notifications that showed no banner.")
            SettingsHint(text: fullDiskAccessWarning, color: .orange, wraps: true)
            SettingsRow(label: "Open at login") {
                RemovableStep(remove: removeLoginItem) {
                    switch onboarding.loginItem {
                    case .requiresApproval:
                        SetupStep(title: "Open Login Items", isDone: false, action: onboarding.openLoginItemsSettings)
                    case .enabled, .disabled, .unavailable:
                        SetupStep(title: "Add to Login Items", isDone: onboarding.loginItem == .enabled, action: onboarding.addLoginItem)
                    }
                }
            }
            SettingsHint(text: loginHint)
            SettingsHint(text: "After an update, Remove and grant it again.")
            SettingsHint(text: onboarding.message, wraps: true)
        }
        // Permissions and login items change in System Settings while this window is open.
        .refreshingWhileShown(onboarding.refresh)
    }

    /// The notification database fails for a reason other than missing access, so the step cannot tell.
    private var fullDiskAccessWarning: String? {
        onboarding.fullDiskAccess == .unknown
            ? "Cannot tell whether it is granted: the notification database does not open, which a macOS update can cause."
            : nil
    }

    /// Removes the login item while there is one, approved or not.
    private var removeLoginItem: (() -> Void)? {
        switch onboarding.loginItem {
        case .enabled, .requiresApproval: onboarding.removeLoginItem
        case .disabled, .unavailable: nil
        }
    }

    private var loginHint: String {
        switch onboarding.loginItem {
        case .enabled, .disabled: "Optional. Starts the sidebar when you log in."
        case .requiresApproval: "Allow it in System Settings › General › Login Items."
        case .unavailable: "Install the app in Applications to open it at login."
        }
    }
}

/// A step with its Remove button beside it, when there is something to remove. In an accessory column,
/// long hints spanning both columns would widen the step column and push the button away from its step.
struct RemovableStep<Step: View>: View {
    let remove: (() -> Void)?
    @ViewBuilder let step: () -> Step

    @Environment(\.typography) private var typography

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.columnSpacing) {
            step()
            if let remove {
                Button("Remove", font: typography.font(.body), action: remove)
            }
        }
        // The grid would otherwise squeeze the step to fit, truncating its buttons.
        .fixedSize()
    }
}

/// Whether the AeroSpace config reserves the sidebar's strip, with a one-click update. Its steps take
/// effect immediately, on the saved side and width.
struct AeroSpaceRows: View {
    let aeroSpace: AeroSpaceSync
    /// Shows a file in Finder.
    let reveal: (URL) -> Void

    @Environment(\.typography) private var typography

    var body: some View {
        if let url = aeroSpace.configURL {
            SettingsFileRow(label: "AeroSpace config", url: url, reveal: reveal)
        }
        // Extra buttons sit next to their step: in an accessory column, long hints spanning both
        // columns would widen the step column and push them away from it.
        SettingsRow(label: "AeroSpace") {
            HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.columnSpacing) {
                SetupStep(
                    title: "Update Config",
                    isDone: aeroSpace.isConfigured,
                    action: { Task { await aeroSpace.update() } }
                )
                .disabled(aeroSpace.isUpdating)
                // A config that already matches can still be written again, for example to reload
                // AeroSpace or to put a hand-edited block back in its usual form.
                if aeroSpace.isConfigured {
                    Button("Write Again", font: typography.font(.body)) {
                        Task { await aeroSpace.update(rewritingBlock: true) }
                    }
                    .disabled(aeroSpace.isUpdating)
                }
                Button("Copy Settings", font: typography.font(.body), action: aeroSpace.copySnippet)
            }
            // The grid would otherwise squeeze the step to fit, truncating its buttons.
            .fixedSize()
        }
        SettingsHint(text: aeroSpaceHint, wraps: true)
        if case .ready(let analysis, _) = aeroSpace.state {
            ForEach(analysis.warnings, id: \.self) { warning in
                SettingsHint(text: warning, color: .orange, wraps: true)
            }
        }
        SettingsHint(text: aeroSpace.message, wraps: true)
    }

    private var aeroSpaceHint: String {
        switch aeroSpace.state {
        case .notFound:
            "No AeroSpace config found."
        case .unreadable(let reason):
            "Cannot read the AeroSpace config: \(reason)"
        case .ready(let analysis, let url):
            Self.describe(analysis, file: url.lastPathComponent)
        }
    }

    static func describe(_ analysis: AeroSpaceConfigEditor.Analysis, file: String) -> String {
        let sidebar = analysis.sidebar
        if analysis.isConfigured {
            return "\(file) reserves \(sidebar.width) points on the \(sidebar.side.rawValue) for the sidebar."
        }
        var problems: [String] = []
        switch analysis.reservedWidth {
        case nil: problems.append("reserves no sidebar strip on the \(sidebar.side.rawValue)")
        case let width? where width != sidebar.width: problems.append("reserves \(width) points on the \(sidebar.side.rawValue), not \(sidebar.width)")
        default: break
        }
        if let width = analysis.oppositeReservedWidth {
            problems.append("also reserves \(width) points on the \(sidebar.side.opposite.rawValue)")
        }
        if analysis.missingFloatRule {
            problems.append("lacks the floating rule")
        }
        return "\(file) " + problems.formatted(.list(type: .and)) + "."
    }
}

/// General: the settings file and Quit.
struct GeneralPane: View {
    let configURL: URL
    let reveal: (URL) -> Void
    /// Quits the app, which hands notifications back to macOS.
    let quit: () -> Void

    @Environment(\.typography) private var typography

    var body: some View {
        SettingsPage {
            SettingsFileRow(label: "Settings file", url: configURL, reveal: reveal)
            SettingsRow(label: "Sidebar") {
                Button("Quit Sidebar", font: typography.font(.body), action: quit)
                    .keyboardShortcut("q", modifiers: .command)
            }
            SettingsHint(text: "Quitting hands notifications back to macOS.")
        }
    }
}

extension View {
    /// Calls `refresh` every second while the view is shown, for state that changes outside the app.
    func refreshingWhileShown(_ refresh: @escaping () -> Void) -> some View {
        task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
