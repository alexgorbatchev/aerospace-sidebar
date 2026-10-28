import SidebarProtocol
import SwiftUI

/// Rules: change the severity of incoming notifications, or hide them, by matching their texts. Each
/// rule shows which recent notifications it matches, including ones whose cards are gone.
struct RulesPane: View {
    @Bindable var editor: SettingsEditor
    /// Every notification received lately, newest first, whether its card is still listed or not.
    let history: () -> [SidebarNotification]
    let close: () -> Void

    /// The selected rule's position in `editor.draft.rules`.
    @State var selection: Int?
    @Environment(\.typography) private var typography

    static let matchLines = 4
    /// The editor's row labels.
    static let editorLabels = SidebarSettings.Rule.Field.allCases.map(\.label) + ["Then", "Matches"]

    var body: some View {
        // Views outside a grid row span the whole grid: the list and the editor use the pane's width, and
        // the editor lines up its own labels.
        SettingsPage(buttonBar: SettingsButtonBar(editor: editor, close: close)) {
            ruleList
            Text("The first matching rule applies to new notifications.")
                .font(typography.font(.subheadline))
                .foregroundStyle(.secondary)
            ruleEditor
        }
    }

    /// The rules in order, with add, remove and reorder buttons along its bottom edge.
    private var ruleList: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.listCornerRadius)
        return VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(editor.draft.rules.indices, id: \.self) { index in
                    Text(Self.summary(of: editor.draft.rules[index]))
                        .font(typography.font(.body))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .tag(index)
                }
            }
            .listStyle(.plain)
            .overlay {
                if editor.draft.rules.isEmpty {
                    Text("No rules. Add one with +.")
                        .font(typography.font(.subheadline))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: SettingsMetrics.ruleListHeight * typography.scale)
            Divider()
            listButtons
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor)))
        .frame(width: contentWidth)
    }

    /// Add, remove and reorder; the order decides which rule applies first.
    private var listButtons: some View {
        HStack(spacing: 0) {
            iconButton("Add Rule", systemImage: "plus") {
                editor.draft.rules.append(SidebarSettings.Rule())
                selection = editor.draft.rules.count - 1
            }
            Divider()
            iconButton("Remove Rule", systemImage: "minus") {
                guard let index = selection else { return }
                editor.draft.rules.remove(at: index)
                selection = editor.draft.rules.isEmpty ? nil : min(index, editor.draft.rules.count - 1)
            }
            .disabled(selection == nil)
            Divider()
            iconButton("Move Up", systemImage: "arrow.up") { move(by: -1) }
                .disabled((selection ?? 0) == 0)
            Divider()
            iconButton("Move Down", systemImage: "arrow.down") { move(by: 1) }
                .disabled(selection.map { $0 >= editor.draft.rules.count - 1 } ?? true)
            Divider()
            Spacer()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func iconButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: typography.size * SettingsMetrics.listButtonSize, height: typography.size * SettingsMetrics.listButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .help(title)
    }

    /// The selected rule's patterns, action and matches. Without a selection the fields are hidden but keep
    /// their space, so selecting a rule does not resize the window.
    private var ruleEditor: some View {
        GroupBox {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: SettingsMetrics.columnSpacing, verticalSpacing: SettingsMetrics.rowSpacing) {
                ForEach(SidebarSettings.Rule.Field.allCases, id: \.self) { field in
                    SettingsRow(label: field.label) {
                        TextField(field.label, text: pattern(field), prompt: Text("Any"))
                            .labelsHidden()
                            .frame(width: editorFieldWidth)
                            .help(field.help)
                    }
                }
                SettingsHint(text: Self.patternNote, wraps: true, width: editorFieldWidth, columns: 1)
                // The pop-up button has no text baseline for the label to line up with.
                SettingsRow(label: "Then", alignment: .center) {
                    PopUpPicker(title: "Then", options: Self.actionOptions, selection: action, font: typography.bodyFont)
                        .fixedSize()
                }
                SettingsRow(label: "Matches") {
                    matchesText
                        // Room for every line whatever the selection, so choosing a rule does not resize the window.
                        .lineLimit(Self.matchLines, reservesSpace: true)
                        .frame(width: editorFieldWidth, alignment: .leading)
                }
            }
            .opacity(selectedRule == nil ? 0 : 1)
            .disabled(selectedRule == nil)
            .accessibilityHidden(selectedRule == nil)
            .overlay {
                if selectedRule == nil {
                    Text(editor.draft.rules.isEmpty ? "Add a rule to edit it here." : "Select a rule to edit it.")
                        .font(typography.font(.subheadline))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .groupBoxStyle(SettingsGroupBoxStyle())
        .frame(width: contentWidth)
    }

    /// Text fields need a fixed width: flexible ones leave the grid's columns open, and the grid then
    /// shrinks them to their ideal width. They take what the box's padding and the widest label leave of
    /// `contentWidth`, so the padding is the same on the left, at the top and on the right. Measured
    /// widths would feed back: the fields set how the note wraps, which resizes the window and the panes.
    private var editorFieldWidth: CGFloat {
        let label = Self.editorLabels
            .map { ($0 + ":" as NSString).size(withAttributes: [.font: typography.bodyFont]).width }
            .max() ?? 0
        return (contentWidth - 2 * SettingsMetrics.groupPadding - label.rounded(.up) - SettingsMetrics.columnSpacing).rounded(.down)
    }

    /// The width the list and the editor share: the pane's own, inside its margins. A pane can be shown
    /// wider, as wide as the widest one, and then keeps the extra on the right like the others.
    private var contentWidth: CGFloat {
        (SettingsMetrics.paneWidth * typography.scale - 2 * SettingsMetrics.paneMargin).rounded(.down)
    }

    /// What the patterns are, under the fields.
    static let patternNote = """
        Each field is a case-insensitive regular expression found anywhere in that text, such as invoice, \
        ^Slack$ or (build|deploy) failed. Source is the app or sender a card shows. Empty fields match anything; \
        a rule needs at least one.
        """

    /// The match count in the body font, or why the rule cannot match in orange, over example matches.
    private var matchesText: Text {
        let lines = matches.split(separator: "\n", maxSplits: 1).map(String.init)
        let first = Text(lines.first ?? "")
            .font(typography.font(.body))
            .foregroundStyle(selectedRule?.problem == nil ? Color.primary : Color.orange)
        guard lines.count > 1 else { return first }
        return first + Text("\n" + lines[1]).font(typography.font(.subheadline)).foregroundStyle(.secondary)
    }

    private func move(by offset: Int) {
        guard let index = selection, editor.draft.rules.indices.contains(index + offset) else { return }
        editor.draft.rules.swapAt(index, index + offset)
        selection = index + offset
    }

    var selectedRule: SidebarSettings.Rule? {
        selectedIndex.map { editor.draft.rules[$0] }
    }

    /// The selected rule's pattern for `field`. A field that loses focus commits its text, also after
    /// Cancel has emptied the list under the selection, so writes go only to a rule that still exists.
    func pattern(_ field: SidebarSettings.Rule.Field) -> Binding<String> {
        Binding(
            get: { selectedRule?[field] ?? "" },
            set: { value in selectedIndex.map { editor.draft.rules[$0][field] = value } }
        )
    }

    /// `selection`, while it names a rule in the draft.
    private var selectedIndex: Int? {
        selection.flatMap { editor.draft.rules.indices.contains($0) ? $0 : nil }
    }

    /// What the selected rule does to what it matches.
    var action: Binding<SidebarSettings.Rule.Action> {
        Binding(
            get: { selectedRule?.action ?? SidebarSettings.Rule().action },
            set: { value in selectedIndex.map { editor.draft.rules[$0].action = value } }
        )
    }

    /// Hiding, then each severity to list matches at.
    static let actionOptions = SidebarSettings.Rule.Action.allCases.map { action in
        switch action {
        case .hide: PopUpPicker.Option(label: "Hide it", value: action)
        case .severity(let severity): PopUpPicker.Option(label: "List as \(severity.rawValue)", value: action, startsGroup: severity == .low)
        }
    }

    /// What the selected rule matches among the notifications received lately, or why it cannot match.
    var matches: String {
        guard let rule = selectedRule else { return "Select a rule to see its matches." }
        if let problem = rule.problem {
            return "This rule \(problem)."
        }
        let rules = NotificationRules([rule])
        let history = history()
        let matched = history.filter { rules.firstMatch(for: $0) != nil }
        let count = "Matches \(matched.count) of the last \(history.count) notifications"
        let examples = matched.prefix(Self.matchLines - 1).map { notification in
            let text = [notification.title, notification.subtitle, notification.body].first { !$0.isEmpty } ?? ""
            return "\(notification.source.isEmpty ? "Notification" : notification.source): \(text)"
        }
        return ([matched.isEmpty ? count + "." : count + ":"] + examples).joined(separator: "\n")
    }

    /// A list row: the rule's patterns and what it does.
    static func summary(of rule: SidebarSettings.Rule) -> String {
        let patterns = SidebarSettings.Rule.Field.allCases
            .filter { !rule[$0].isEmpty }
            .map { "\($0.rawValue) ~ \(rule[$0])" }
        return (patterns.isEmpty ? "No pattern" : patterns.joined(separator: ", ")) + " → " + rule.action.title
    }
}

extension SidebarSettings.Rule.Field {
    var label: String { rawValue.capitalized }

    /// What the field's pattern is matched against.
    var help: String {
        switch self {
        case .source: "Matched against the app or sender a card shows above its title, such as Slack, aerospace-sidebar or macOS."
        case .title: "Matched against the notification's title."
        case .subtitle: "Matched against the notification's subtitle."
        case .body: "Matched against the notification's text."
        }
    }
}

extension SidebarSettings.Rule.Action {
    var title: String { name.capitalized }
}
