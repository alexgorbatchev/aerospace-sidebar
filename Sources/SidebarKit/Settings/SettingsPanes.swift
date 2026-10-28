import SwiftUI

/// Sidebar: the side and width of the strip the sidebar occupies.
struct SidebarPane: View {
    @Bindable var editor: SettingsEditor
    /// Reports the AeroSpace update that saving a new side or width starts.
    let aeroSpace: AeroSpaceSync
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
            SettingsHint(text: "The sidebar sits on the main display. Saving a new side or width updates the AeroSpace config so tiled windows leave the same strip free, and reloads AeroSpace.")
            SettingsHint(text: aeroSpace.message)
        }
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
                Toggle("Hide banners and list their notifications here", isOn: $editor.draft.notifications.replaceSystem)
                    .toggleStyle(.checkbox)
            }
            SettingsHint(text: "On, the sidebar takes over notifications from other apps: their banners disappear and the notifications are listed here. Needs the Accessibility permission. Off, banners show as usual, and the sidebar lists only notifications sent with the aerospace-sidebar command or URL.")
            SettingsRow(label: "With buttons") {
                Toggle("Keep banners for notifications with buttons", isOn: $editor.draft.notifications.actionableLeftToMacOS)
                    .toggleStyle(.checkbox)
            }
            SettingsHint(text: "Alerts whose buttons are plain choices, such as Allow…, are listed with those buttons either way. Other buttons, such as a reply field, an Options menu or a banner's buttons, only work on the banner itself; otherwise these notifications are listed without them, and clicking one opens its app.")
            SettingsRow(label: "Keep banners for") {
                TextField("Keep banners for", text: $editor.appsLeftToMacOSText, prompt: Text("zoom.us, Calendar"))
                    .labelsHidden()
                    .frame(width: SettingsMetrics.fieldWidth * typography.scale)
            }
            SettingsHint(text: "Comma-separated app names, as shown in their notifications. Their banners still show, and their notifications are also listed.")
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
            SettingsHint(text: "Notifications survive restarts until they are older than this or the list is full.")
        }
    }
}

/// Font: the family and size of all text in the sidebar and Settings.
struct FontPane: View {
    @Bindable var editor: SettingsEditor
    /// Opens the font panel on the draft font.
    let chooseFont: () -> Void
    let close: () -> Void

    @Environment(\.typography) private var typography

    var body: some View {
        SettingsPage(buttonBar: SettingsButtonBar(editor: editor, close: close)) {
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
