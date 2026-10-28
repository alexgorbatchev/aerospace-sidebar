import SwiftUI

/// Layout shared by the Settings panes: a grid with right-aligned `Label:` cells, a control column
/// and an accessory column, and small secondary hints under controls. Widths that hold text are for
/// the default font size and scale with `Typography.scale`.
enum SettingsMetrics {
    /// Hints wrap within this width instead of widening the window.
    static let paneWidth: CGFloat = 560
    /// Width of the list of groups beside the panes.
    static let sidebarWidth: CGFloat = 180
    /// Width of a group row's icon column and the gap after it, in multiples of the font size.
    static let sidebarIconWidth: CGFloat = 1.6
    static let sidebarIconSpacing: CGFloat = 0.5
    static let paneMargin: CGFloat = 20
    static let rowSpacing: CGFloat = 8
    static let columnSpacing: CGFloat = 8
    /// Text fields have a fixed width: a flexible one leaves the grid's column widths open, and the
    /// grid then measures rows at one width and draws them at another, unevening the spacing.
    static let fieldWidth: CGFloat = 320
    static let numberFieldWidth: CGFloat = 80
    /// Height of the list of rules.
    static let ruleListHeight: CGFloat = 120
    /// Side of a list's add and remove buttons, in multiples of the font size.
    static let listButtonSize: CGFloat = 1.8
    /// Corner radius of a list's border, like a text field's.
    static let listCornerRadius: CGFloat = 6
    /// Space inside a group box, the same on every side.
    static let groupPadding: CGFloat = 12
    static let groupCornerRadius: CGFloat = 10
    /// Gap between a number field and its stepper arrows.
    static let stepperSpacing: CGFloat = 2
    static let buttonBarSpacing: CGFloat = 12
    static let statusMaximumLines = 3
}

/// One group's pane: the grid at the pane width, above the Cancel/Save bar when the group edits the draft.
/// Every pane fills the window, which is as large as the largest pane, so each reports the size it needs
/// through `reportPaneSize`.
struct SettingsPage<Content: View>: View {
    var buttonBar: SettingsButtonBar?
    @ViewBuilder let content: () -> Content

    @Environment(\.typography) private var typography
    @Environment(\.reportPaneSize) private var reportPaneSize
    @State private var gridHeight: CGFloat = 0
    @State private var buttonBarHeight: CGFloat = 0

    var body: some View {
        let width = SettingsMetrics.paneWidth * typography.scale
        VStack(spacing: 0) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: SettingsMetrics.columnSpacing, verticalSpacing: SettingsMetrics.rowSpacing) {
                content()
            }
            // Offered more height than its rows measured, a grid spreads the extra between them; keep it below.
            .fixedSize(horizontal: false, vertical: true)
            .padding(SettingsMetrics.paneMargin)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { gridHeight = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let buttonBar {
                buttonBar
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { buttonBarHeight = $0 }
            }
        }
        .frame(width: width)
        .onChange(of: CGSize(width: width, height: gridHeight + buttonBarHeight), initial: true) { _, size in
            reportPaneSize(size)
        }
    }
}

extension EnvironmentValues {
    /// Receives the size a Settings pane needs to show all of its content.
    @Entry var reportPaneSize: @MainActor (CGSize) -> Void = { _ in }
}

/// `Label:` | control | optional accessory. Cells line up on their first text baseline, unless
/// `alignment` says otherwise for a control without text of its own, such as an AppKit view.
struct SettingsRow<Control: View, Accessory: View>: View {
    let label: String
    var alignment: VerticalAlignment?
    @ViewBuilder let control: () -> Control
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        GridRow(alignment: alignment) {
            Text(label + ":")
                // The grid would otherwise squeeze the label to make room for a long control or hint.
                .fixedSize()
                .gridColumnAlignment(.trailing)
            control()
            accessory()
        }
    }
}

extension SettingsRow where Accessory == EmptyView {
    init(label: String, alignment: VerticalAlignment? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.init(label: label, alignment: alignment, control: control, accessory: { EmptyView() })
    }
}

/// Secondary text under a control, aligned with the control column; absent when empty.
///
/// A hint is one line, kept short enough to fit the pane. A cell spanning columns wraps at the width of
/// the widest control above it, not at the pane's edge, and the grid only widens columns for single-column
/// cells, so a wrapping hint breaks well short of the edge. Text that comes from elsewhere, such as status
/// and error messages, `wraps` there instead of running off the pane.
struct SettingsHint: View {
    let text: String?
    var color: Color = .secondary
    var wraps = false
    /// Wraps at this width rather than one the grid picks, which may be wider than the controls above.
    var width: CGFloat?
    /// Columns it spans: the control's and the accessory's. A grid without accessories needs 1, or the
    /// hint adds an empty column, and the gap before it, to the grid.
    var columns = 2

    @Environment(\.typography) private var typography

    var body: some View {
        if let text, !text.isEmpty {
            // The empty label cell has no text baseline, so baseline alignment would push the hint down.
            GridRow(alignment: .top) {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text(text)
                    .font(typography.font(.subheadline))
                    .foregroundStyle(color)
                    .fixedSize(horizontal: !wraps, vertical: true)
                    .frame(width: width, alignment: .leading)
                    .gridCellColumns(columns)
            }
        }
    }
}

/// A group box whose padding is `SettingsMetrics.groupPadding` on every side, so content sized from it
/// fills it exactly; the system style's insets are its own and undocumented.
struct SettingsGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.content
            .padding(SettingsMetrics.groupPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: SettingsMetrics.groupCornerRadius))
    }
}

/// A setup step: a green checkmark once done, else an empty circle and the button that does it.
struct SetupStep: View {
    let title: String
    let isDone: Bool
    let action: () -> Void

    @Environment(\.typography) private var typography

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.columnSpacing) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDone ? .green : .secondary)
                .accessibilityLabel(isDone ? "Done" : "Not done")
            if !isDone {
                Button(title, font: typography.font(.body), action: action)
            }
        }
    }
}

/// Separator, status line, Cancel and Save, at the bottom of panes that edit `config.toml`.
struct SettingsButtonBar: View {
    let editor: SettingsEditor
    let close: () -> Void

    @Environment(\.typography) private var typography

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .center) {
                Text(editor.status ?? "")
                    .lineLimit(SettingsMetrics.statusMaximumLines)
                    .help(editor.status ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel", font: typography.font(.body)) {
                    editor.revert()
                    close()
                }
                Button("Save", font: typography.font(.body)) {
                    if editor.save() { close() }
                }
            }
            .padding(.horizontal, SettingsMetrics.paneMargin)
            .padding(.vertical, SettingsMetrics.buttonBarSpacing)
        }
    }
}
