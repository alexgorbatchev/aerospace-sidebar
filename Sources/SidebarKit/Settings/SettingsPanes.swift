import SwiftUI

/// Sidebar: the side and width of the strip the sidebar occupies, and whether AeroSpace reserves it.
struct SidebarPane: View {
    @Bindable var editor: SettingsEditor
    /// Reports the AeroSpace update that saving a new side or width starts.
    let aeroSpace: AeroSpaceSync
    /// Shows a file in Finder.
    let reveal: (URL) -> Void
    let close: () -> Void

    var body: some View {
        SettingsPage(buttonBar: SettingsButtonBar(editor: editor, close: close)) {
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
            SettingsHint(text: "On the main display. Saving also updates AeroSpace.")
            AeroSpaceRows(aeroSpace: aeroSpace, reveal: reveal)
        }
        // The AeroSpace config may be edited by hand while this window is open.
        .refreshingWhileShown(aeroSpace.refresh)
    }
}

/// Notifications: which macOS notifications the sidebar takes over.
struct NotificationsPane: View {
    @Bindable var editor: SettingsEditor
    let close: () -> Void

    @Environment(\.typography) private var typography

    var body: some View {
        SettingsPage(buttonBar: SettingsButtonBar(editor: editor, close: close)) {
            SettingsRow(label: "Banners") {
                Toggle("Hide banners and list them here", isOn: $editor.draft.notifications.replaceSystem)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            SettingsHint(text: "Needs Accessibility. Off, only pushed ones are listed.")
            SettingsRow(label: "With buttons") {
                Toggle("Keep banners with buttons", isOn: $editor.draft.notifications.actionableLeftToMacOS)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            SettingsHint(text: "Off, cards keep only choices such as Allow…")
            SettingsRow(label: "Keep banners for") {
                TextField("Keep banners for", text: $editor.appsLeftToMacOSText, prompt: Text("zoom.us, Calendar"))
                    .labelsHidden()
                    .frame(width: SettingsMetrics.fieldWidth * typography.scale)
            }
            SettingsHint(text: "Comma-separated app names, also listed here.")
        }
    }
}

/// History: how long and how many notifications the list keeps.
struct HistoryPane: View {
    @Bindable var editor: SettingsEditor
    let close: () -> Void

    var body: some View {
        SettingsPage(buttonBar: SettingsButtonBar(editor: editor, close: close)) {
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
            SettingsHint(text: "Kept across restarts until too old or the list is full.")
        }
    }
}

/// Appearance: the font and size of all text in the sidebar and Settings.
struct AppearancePane: View {
    @Bindable var editor: SettingsEditor
    /// Opens the font panel on the draft font.
    let chooseFont: () -> Void
    let close: () -> Void

    @Environment(\.typography) private var typography

    var body: some View {
        SettingsPage(buttonBar: SettingsButtonBar(editor: editor, close: close)) {
            SettingsRow(label: "Font") {
                TextField("Font", text: $editor.draft.font.name, prompt: Text("System font"))
                    .labelsHidden()
                    .frame(width: SettingsMetrics.fieldWidth * typography.scale)
            } accessory: {
                Button("Choose…", font: typography.font(.body), action: chooseFont)
            }
            SettingsRow(label: "Size") {
                NumberField(title: "Size", value: $editor.draft.font.size, stepRange: SidebarSettings.Font.sizeRange, unit: "points")
            }
            SettingsHint(text: "Empty for the system font. All text scales with Size.")
        }
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
        // The grid would otherwise squeeze the unit to fit, wrapping it mid-word.
        .fixedSize()
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
