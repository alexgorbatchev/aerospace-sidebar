import SwiftUI

/// Setup: Accessibility, launch at login and the AeroSpace config, each with a one-click action.
struct SetupPane: View {
    let onboarding: OnboardingModel
    let editor: SettingsEditor
    let close: () -> Void

    @Environment(\.typography) private var typography

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
                        Button("Remove", font: typography.font(.body), action: onboarding.removeLoginItem)
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
                    Button("Copy Settings", font: typography.font(.body), action: onboarding.copySnippet)
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
        .frame(width: SettingsMetrics.paneWidth * typography.scale)
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

/// General: notification, history and font settings from `config.toml`.
struct GeneralPane: View {
    @Bindable var editor: SettingsEditor
    let configURL: URL
    let reveal: (URL) -> Void
    /// Opens the font panel on the draft font.
    let chooseFont: () -> Void
    let close: () -> Void

    @Environment(\.typography) private var typography

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
                        .frame(minWidth: SettingsMetrics.fieldMinWidth * typography.scale)
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

                SettingsSectionHeader(title: "Font")
                SettingsRow(label: "Font") {
                    TextField("Font", text: $editor.draft.font.name, prompt: Text("System font"))
                        .labelsHidden()
                        .frame(minWidth: SettingsMetrics.fieldMinWidth * typography.scale)
                } accessory: {
                    Button("Choose…", font: typography.font(.body), action: chooseFont)
                }
                SettingsRow(label: "Size") {
                    NumberField(title: "Size", value: $editor.draft.font.size, stepRange: SidebarSettings.Font.sizeRange, unit: "points")
                }
                SettingsHint(text: "Choose… picks a family and size in the font panel; a typed name matches families ignoring case. Leave it empty for the system font. Every text size in the sidebar and Settings scales with this size. Changes show right away; Cancel undoes them.")

                SettingsSectionHeader(title: "File")
                SettingsRow(label: "Settings file") {
                    Text(configURL.path)
                        .font(typography.font(.subheadline))
                        .textSelection(.enabled)
                } accessory: {
                    Button("Show in Finder", font: typography.font(.body)) { reveal(configURL) }
                }
            }
            SettingsButtonBar(editor: editor, close: close)
        }
        .frame(width: SettingsMetrics.paneWidth * typography.scale)
    }
}

/// An 80-point number field followed by its unit, with stepper arrows when it has a `stepRange`.
struct NumberField<Format: ParseableFormatStyle>: View where Format.FormatOutput == String, Format.FormatInput: Strideable {
    let title: String
    @Binding var value: Format.FormatInput
    let format: Format
    /// The values the arrows step through by 1; `nil` shows no arrows.
    var stepRange: ClosedRange<Format.FormatInput>?
    let unit: String

    @Environment(\.typography) private var typography

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.columnSpacing) {
            HStack(spacing: SettingsMetrics.stepperSpacing) {
                TextField(title, value: $value, format: format)
                    .labelsHidden()
                    .frame(width: SettingsMetrics.numberFieldWidth * typography.scale)
                if let stepRange {
                    Stepper(title, value: $value, in: stepRange)
                        .labelsHidden()
                }
            }
            Text(unit)
        }
    }
}

extension NumberField where Format == IntegerFormatStyle<Int> {
    init(title: String, value: Binding<Int>, stepRange: ClosedRange<Int>? = nil, unit: String) {
        self.init(title: title, value: value, format: .number.grouping(.never), stepRange: stepRange, unit: unit)
    }
}

extension NumberField where Format == FloatingPointFormatStyle<Double> {
    init(title: String, value: Binding<Double>, stepRange: ClosedRange<Double>? = nil, unit: String) {
        self.init(title: title, value: value, format: .number.grouping(.never), stepRange: stepRange, unit: unit)
    }
}
