import SwiftUI

/// Setup: Accessibility, Full Disk Access, launch at login and the AeroSpace config, each with a one-click
/// action.
/// Its steps take effect immediately, so it has no Cancel or Save.
struct SetupPane: View {
    let onboarding: OnboardingModel
    let aeroSpace: AeroSpaceSync
    /// Shows a file in Finder.
    let reveal: (URL) -> Void

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
                SettingsRow(label: "Full Disk Access") {
                    SetupStep(
                        title: "Open Full Disk Access",
                        doneTitle: "Full Disk Access granted",
                        isDone: onboarding.fullDiskAccessGranted,
                        action: onboarding.requestFullDiskAccess
                    )
                }
                SettingsHint(text: fullDiskAccessHint)
                // Extra buttons sit next to their step: in an accessory column, long hints spanning both
                // columns would widen the step column and push them away from it.
                SettingsRow(label: "Open at login") {
                    HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.columnSpacing) {
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
                        if onboarding.loginItem == .enabled || onboarding.loginItem == .requiresApproval {
                            Button("Remove", font: typography.font(.body), action: onboarding.removeLoginItem)
                        }
                    }
                    // The grid would otherwise squeeze the step to fit, truncating its buttons.
                    .fixedSize()
                }
                SettingsHint(text: loginHint)
                SettingsHint(text: onboarding.message)

                SettingsSectionHeader(title: "AeroSpace")
                SettingsRow(label: "Config") {
                    HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.columnSpacing) {
                        SetupStep(
                            title: "Update AeroSpace Config",
                            doneTitle: "AeroSpace configured",
                            isDone: aeroSpace.isConfigured,
                            action: { Task { await aeroSpace.update() } }
                        )
                        .disabled(aeroSpace.isUpdating)
                        Button("Copy Settings", font: typography.font(.body), action: aeroSpace.copySnippet)
                    }
                    .fixedSize()
                }
                SettingsHint(text: aeroSpaceHint)
                if case .ready(let analysis, _) = aeroSpace.state {
                    ForEach(analysis.warnings, id: \.self) { warning in
                        SettingsHint(text: warning, color: .orange)
                    }
                }
                SettingsHint(text: aeroSpace.message)
                if let url = aeroSpace.configURL {
                    SettingsFileRow(label: "Config file", url: url, reveal: reveal)
                }
            }
        }
        .frame(width: SettingsMetrics.paneWidth * typography.scale)
        .task {
            // Permissions change in System Settings while this window is open, and the AeroSpace config
            // may be edited by hand.
            while !Task.isCancelled {
                onboarding.refresh()
                aeroSpace.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var fullDiskAccessHint: String {
        onboarding.fullDiskAccessGranted
            ? "Lists notifications that showed no banner: during Focus, in quick bursts, or while the sidebar was not running."
            : "Optional. Add AerospaceSidebar to list notifications that showed no banner: during Focus, in quick bursts, or while the sidebar was not running."
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

/// General: sidebar, notification, history and font settings from `config.toml`.
struct GeneralPane: View {
    @Bindable var editor: SettingsEditor
    /// Reports the AeroSpace update that saving a new side or width starts.
    let aeroSpace: AeroSpaceSync
    let configURL: URL
    let reveal: (URL) -> Void
    /// Opens the font panel on the draft font.
    let chooseFont: () -> Void
    /// Quits the app, which hands notifications back to macOS.
    let quit: () -> Void
    let close: () -> Void

    @Environment(\.typography) private var typography

    var body: some View {
        VStack(spacing: 0) {
            SettingsGrid {
                SettingsSectionHeader(title: "Sidebar", isFirst: true)
                SettingsRow(label: "Side") {
                    Picker("Side", selection: $editor.draft.sidebar.side) {
                        Text("Left").tag(SidebarSettings.Sidebar.Side.left)
                        Text("Right").tag(SidebarSettings.Sidebar.Side.right)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(label: "Width") {
                    NumberField(title: "Width", value: $editor.draft.sidebar.width, stepRange: SidebarSettings.Sidebar.widthRange, unit: "points")
                }
                SettingsHint(text: "The sidebar sits on the main display. Saving a new side or width updates the AeroSpace config so tiled windows leave the same strip free, and reloads AeroSpace.")
                SettingsHint(text: aeroSpace.message)

                SettingsSectionHeader(title: "Notifications")
                SettingsRow(label: "macOS banners") {
                    Toggle("Show macOS notifications in the sidebar instead", isOn: $editor.draft.notifications.replaceSystem)
                        .toggleStyle(.checkbox)
                }
                SettingsRow(label: "With buttons") {
                    Toggle("Leave notifications with buttons to macOS", isOn: $editor.draft.notifications.actionableLeftToMacOS)
                        .toggleStyle(.checkbox)
                }
                SettingsHint(text: "Buttons such as Reply or Snooze only work on macOS's own banner. Otherwise these notifications are listed without them; clicking one opens its app.")
                SettingsRow(label: "Apps left to macOS") {
                    TextField("Apps left to macOS", text: $editor.appsLeftToMacOSText, prompt: Text("zoom.us, Calendar"))
                        .labelsHidden()
                        .frame(width: SettingsMetrics.fieldWidth * typography.scale)
                }
                SettingsHint(text: "Comma-separated app names, as shown in their notifications. Their notifications stay on screen and are also listed.")

                SettingsSectionHeader(title: "History")
                SettingsRow(label: "Keep for") {
                    NumberField(
                        title: "Keep for", value: $editor.draft.history.retentionHours,
                        stepRange: SidebarSettings.History.retentionRange, unit: "hours"
                    )
                }
                SettingsRow(label: "Keep at most") {
                    NumberField(
                        title: "Keep at most", value: $editor.draft.history.maxCount,
                        stepRange: SidebarSettings.History.maxCountRange, unit: "notifications"
                    )
                }
                SettingsHint(text: "Notifications survive restarts until they are older than this or the list is full.")

                SettingsSectionHeader(title: "Font")
                SettingsRow(label: "Family") {
                    TextField("Family", text: $editor.draft.font.name, prompt: Text("System font"))
                        .labelsHidden()
                        .frame(width: SettingsMetrics.fieldWidth * typography.scale)
                } accessory: {
                    Button("Choose…", font: typography.font(.body), action: chooseFont)
                }
                SettingsRow(label: "Size") {
                    NumberField(title: "Size", value: $editor.draft.font.size, stepRange: SidebarSettings.Font.sizeRange, unit: "points")
                }
                SettingsHint(text: "Leave empty for the system font. All text sizes scale with Size.")

                SettingsSectionHeader(title: "File")
                SettingsFileRow(label: "Settings file", url: configURL, reveal: reveal)

                SettingsSectionHeader(title: "App")
                SettingsRow(label: "Sidebar") {
                    Button("Quit Sidebar", font: typography.font(.body), action: quit)
                        .keyboardShortcut("q", modifiers: .command)
                }
                SettingsHint(text: "Quitting hands notifications back to macOS until the sidebar starts again.")
            }
            SettingsButtonBar(editor: editor, close: close)
        }
        .frame(width: SettingsMetrics.paneWidth * typography.scale)
    }
}

/// `Label:` | a file's path, with `~` for the home folder and truncated in the middle | Show in Finder.
struct SettingsFileRow: View {
    let label: String
    let url: URL
    let reveal: (URL) -> Void

    @Environment(\.typography) private var typography

    var body: some View {
        SettingsRow(label: label) {
            Text((url.path as NSString).abbreviatingWithTildeInPath)
                .font(typography.font(.subheadline))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.path)
                .textSelection(.enabled)
        } accessory: {
            Button("Show in Finder", font: typography.font(.body)) { reveal(url) }
        }
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
