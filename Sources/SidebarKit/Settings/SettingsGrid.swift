import SwiftUI

/// Layout shared by the Settings panes: a grid with right-aligned `Label:` cells, a control column
/// and an accessory column, bold section headers and small secondary hints under controls.
enum SettingsMetrics {
    /// Hints wrap within this width instead of widening the window.
    static let paneWidth: CGFloat = 620
    static let paneMargin: CGFloat = 20
    static let rowSpacing: CGFloat = 8
    static let columnSpacing: CGFloat = 8
    static let sectionTopPadding: CGFloat = 12
    static let fieldMinWidth: CGFloat = 320
    static let numberFieldWidth: CGFloat = 80
    static let hintFontSize: CGFloat = 11
    static let buttonBarSpacing: CGFloat = 12
    static let statusMaximumLines = 3
}

struct SettingsGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: SettingsMetrics.columnSpacing, verticalSpacing: SettingsMetrics.rowSpacing) {
            content()
        }
        .padding([.top, .horizontal], SettingsMetrics.paneMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A bold header spanning the grid; every header but the first gets extra space above it.
struct SettingsSectionHeader: View {
    let title: String
    var isFirst = false

    var body: some View {
        GridRow {
            Text(title)
                .font(.system(size: NSFont.systemFontSize, weight: .bold))
                .gridCellColumns(3)
        }
        .padding(.top, isFirst ? 0 : SettingsMetrics.sectionTopPadding)
    }
}

/// `Label:` | control | optional accessory.
struct SettingsRow<Control: View, Accessory: View>: View {
    let label: String
    @ViewBuilder let control: () -> Control
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        GridRow {
            Text(label + ":")
                .gridColumnAlignment(.trailing)
            control()
            accessory()
        }
    }
}

extension SettingsRow where Accessory == EmptyView {
    init(label: String, @ViewBuilder control: @escaping () -> Control) {
        self.init(label: label, control: control, accessory: { EmptyView() })
    }
}

/// Secondary text under a control, aligned with the control column; absent when empty.
struct SettingsHint: View {
    let text: String?
    var color: Color = .secondary

    var body: some View {
        if let text, !text.isEmpty {
            // The empty label cell has no text baseline, so baseline alignment would push the hint down.
            GridRow(alignment: .top) {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text(text)
                    .font(.system(size: SettingsMetrics.hintFontSize))
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
                    .gridCellColumns(2)
            }
        }
    }
}

/// A Setup step: a green checkmark and what is done, or an empty circle and the button that does it.
struct SetupStep: View {
    let title: String
    let doneTitle: String
    let isDone: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.columnSpacing) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDone ? .green : .secondary)
                .accessibilityLabel(isDone ? "Done" : "Not done")
            if isDone {
                Text(doneTitle)
            } else {
                Button(title, action: action)
            }
        }
    }
}

/// Separator, status line, Cancel and Save, at the bottom of every pane.
struct SettingsButtonBar: View {
    let editor: SettingsEditor
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .center) {
                Text(editor.status ?? "")
                    .lineLimit(SettingsMetrics.statusMaximumLines)
                    .help(editor.status ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") {
                    editor.revert()
                    close()
                }
                Button("Save") {
                    if editor.save() { close() }
                }
            }
            .padding(.horizontal, SettingsMetrics.paneMargin)
            .padding(.vertical, SettingsMetrics.buttonBarSpacing)
        }
    }
}
