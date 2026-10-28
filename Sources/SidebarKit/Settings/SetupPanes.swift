import SwiftUI

/// Permissions: everything the sidebar asks macOS for, why it needs it, and how to take it back.
/// Its steps take effect immediately, so it has no Cancel or Save.
struct PermissionsPane: View {
    let onboarding: OnboardingModel

    var body: some View {
        SettingsPage {
            SettingsRow(label: "Accessibility") {
                RemovableStep(remove: { Task { await onboarding.removeAccessibility() } }) {
                    SetupStep(title: "Open Accessibility", isDone: onboarding.accessibilityGranted, action: onboarding.requestAccessibility)
                }
            }
            SettingsHint(text: "Required to take over notifications. macOS draws banners in its Notification Center process, and the Accessibility API is the only way another app can read and hide them. Without it, banners keep showing.")
            SettingsRow(label: "Full Disk Access") {
                RemovableStep(remove: { Task { await onboarding.removeFullDiskAccess() } }) {
                    SetupStep(title: "Open Full Disk Access", isDone: onboarding.fullDiskAccessGranted, action: onboarding.requestFullDiskAccess)
                }
            }
            SettingsHint(text: "Optional. macOS records every notification in a database that only apps with Full Disk Access can open. The sidebar only reads it, to list notifications that showed no banner: during Focus, in quick bursts, or while the sidebar was not running.")
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
            SettingsHint(text: "Remove takes AerospaceSidebar off that list in System Settings. After an update macOS no longer recognizes, remove it and grant it again.")
            SettingsHint(text: onboarding.message)
        }
        // Permissions and login items change in System Settings while this window is open.
        .refreshingWhileShown(onboarding.refresh)
    }

    /// Removes the login item while there is one, approved or not.
    private var removeLoginItem: (() -> Void)? {
        switch onboarding.loginItem {
        case .enabled, .requiresApproval: onboarding.removeLoginItem
        case .disabled, .unavailable: nil
        }
    }

    private var loginHint: String {
        let purpose = "Optional. Starts the sidebar when you log in, so it handles notifications from the start."
        return switch onboarding.loginItem {
        case .enabled, .disabled: purpose
        case .requiresApproval: purpose + " Allow AerospaceSidebar in System Settings › General › Login Items."
        case .unavailable: purpose + " Install the app in Applications to use it."
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

/// AeroSpace: whether its config reserves the sidebar's strip, with a one-click update.
/// Its steps take effect immediately, so it has no Cancel or Save.
struct AeroSpacePane: View {
    let aeroSpace: AeroSpaceSync
    /// Shows a file in Finder.
    let reveal: (URL) -> Void

    @Environment(\.typography) private var typography

    var body: some View {
        SettingsPage {
            if let url = aeroSpace.configURL {
                SettingsFileRow(label: "Config file", url: url, reveal: reveal)
            }
            // Extra buttons sit next to their step: in an accessory column, long hints spanning both
            // columns would widen the step column and push them away from it.
            SettingsRow(label: "Config") {
                HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.columnSpacing) {
                    SetupStep(
                        title: "Update AeroSpace Config",
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
            SettingsHint(text: aeroSpaceHint)
            if case .ready(let analysis, _) = aeroSpace.state {
                ForEach(analysis.warnings, id: \.self) { warning in
                    SettingsHint(text: warning, color: .orange)
                }
            }
            SettingsHint(text: aeroSpace.message)
        }
        // The AeroSpace config may be edited by hand while this window is open.
        .refreshingWhileShown(aeroSpace.refresh)
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
            SettingsHint(text: "Quitting hands notifications back to macOS until the sidebar starts again.")
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
