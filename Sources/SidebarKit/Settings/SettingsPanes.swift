import SwiftUI

/// Setup: Accessibility, launch at login and the AeroSpace config, each with a one-click action.
struct SetupPane: View {
    let onboarding: OnboardingModel
    let editor: SettingsEditor
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsGrid {
                SettingsSectionHeader(title: "macOS", isFirst: true)
                SettingsRow(label: "Accessibility") {
                    SetupStep(
                        title: "Open Accessibility",
                        doneTitle: "Accessibility granted",
                        isDone: onboarding.accessibilityGranted,
                        action: onboarding.requestAccessibility
                    )
                }
                SettingsHint(text: "Lets the sidebar read macOS notifications and hide their banners.")
                SettingsRow(label: "Open at login") {
                    switch onboarding.loginItem {
                    case .requiresApproval:
                        SetupStep(title: "Open Login Items", doneTitle: "", isDone: false, action: onboarding.openLoginItemsSettings)
                    case .enabled, .disabled, .unavailable:
                        SetupStep(
                            title: "Add to Login Items",
                            doneTitle: "Opens at login",
                            isDone: onboarding.loginItem == .enabled,
                            action: onboarding.addLoginItem
                        )
                    }
                } accessory: {
                    if onboarding.loginItem == .enabled || onboarding.loginItem == .requiresApproval {
                        Button("Remove", action: onboarding.removeLoginItem)
                    }
                }
                SettingsHint(text: loginHint)

                SettingsSectionHeader(title: "AeroSpace")
                SettingsRow(label: "Config") {
                    SetupStep(
                        title: "Update AeroSpace Config",
                        doneTitle: "AeroSpace configured",
                        isDone: aeroSpaceConfigured,
                        action: { Task { await onboarding.updateAeroSpace() } }
                    )
                    .disabled(onboarding.isUpdatingAeroSpace)
                } accessory: {
                    Button("Copy Settings", action: onboarding.copySnippet)
                }
                SettingsHint(text: aeroSpaceHint)
                if case .ready(let analysis, _) = onboarding.aeroSpace {
                    ForEach(analysis.warnings, id: \.self) { warning in
                        SettingsHint(text: warning, color: .orange)
                    }
                }
                SettingsHint(text: onboarding.message)
            }
            SettingsButtonBar(editor: editor, close: close)
        }
        .frame(width: SettingsMetrics.paneWidth)
        .task {
            // Permissions change in System Settings while this window is open.
            while !Task.isCancelled {
                onboarding.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var aeroSpaceConfigured: Bool {
        if case .ready(let analysis, _) = onboarding.aeroSpace { analysis.isConfigured } else { false }
    }

    private var loginHint: String {
        switch onboarding.loginItem {
        case .enabled: "AerospaceSidebar opens when you log in."
        case .disabled: "AerospaceSidebar does not open at login."
        case .requiresApproval: "Allow AerospaceSidebar in System Settings › General › Login Items."
        case .unavailable: "Install the app in Applications to open it at login."
        }
    }

    private var aeroSpaceHint: String {
        switch onboarding.aeroSpace {
        case .notFound:
            "No AeroSpace config found."
        case .unreadable(let reason):
            "Cannot read the AeroSpace config: \(reason)"
        case .ready(let analysis, let url):
            if analysis.isConfigured {
                "\(url.lastPathComponent) reserves \(Int(analysis.width ?? 0)) points for the sidebar."
            } else {
                "\(url.lastPathComponent) is missing " + [
                    analysis.missingGap ? "the sidebar gap" : nil,
                    analysis.missingFloatRule ? "the floating rule" : nil,
                ].compactMap { $0 }.joined(separator: " and ") + "."
            }
        }
    }
}

/// General: notification and history settings from `config.toml`.
struct GeneralPane: View {
    @Bindable var editor: SettingsEditor
    let configURL: URL
    let reveal: (URL) -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsGrid {
                SettingsSectionHeader(title: "Notifications", isFirst: true)
                SettingsRow(label: "macOS banners") {
                    Toggle("Show macOS notifications in the sidebar instead", isOn: $editor.draft.notifications.replaceSystem)
                        .toggleStyle(.checkbox)
                }
                SettingsRow(label: "Apps left to macOS") {
                    TextField("Apps left to macOS", text: $editor.appsLeftToMacOSText, prompt: Text("zoom.us, Calendar"))
                        .labelsHidden()
                        .frame(minWidth: SettingsMetrics.fieldMinWidth)
                }
                SettingsHint(text: "Comma-separated app names, as shown in their notifications. Their notifications stay on screen and are also listed.")

                SettingsSectionHeader(title: "History")
                SettingsRow(label: "Keep for") {
                    NumberField(title: "Keep for", value: $editor.draft.history.retentionHours, unit: "hours")
                }
                SettingsRow(label: "Keep at most") {
                    NumberField(title: "Keep at most", value: $editor.draft.history.maxCount, unit: "notifications")
                }
                SettingsHint(text: "Notifications survive restarts until they are older than this or the list is full.")

                SettingsSectionHeader(title: "File")
                SettingsRow(label: "Settings file") {
                    Text(configURL.path)
                        .font(.system(size: SettingsMetrics.hintFontSize))
                        .textSelection(.enabled)
                } accessory: {
                    Button("Show in Finder") { reveal(configURL) }
                }
            }
            SettingsButtonBar(editor: editor, close: close)
        }
        .frame(width: SettingsMetrics.paneWidth)
    }
}

/// An 80-point integer field followed by its unit.
struct NumberField: View {
    let title: String
    @Binding var value: Int
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.columnSpacing) {
            TextField(title, value: $value, format: .number.grouping(.never))
                .labelsHidden()
                .frame(width: SettingsMetrics.numberFieldWidth)
            Text(unit)
        }
    }
}
