import SidebarProtocol
import SwiftUI

/// Rules: change the severity of incoming notifications, or hide them, by matching their texts. Each
/// rule shows which listed notifications it matches.
struct RulesPane: View {
    @Bindable var editor: SettingsEditor
    /// The notifications in the sidebar, to show what a rule matches.
    let listed: () -> [SidebarNotification]
    let close: () -> Void

    /// The selected rule's position in `editor.draft.rules`.
    @State var selection: Int?
    @Environment(\.typography) private var typography

    static let matchLines = 4

    var body: some View {
        SettingsPage(buttonBar: SettingsButtonBar(editor: editor, close: close)) {
            SettingsRow(label: "Rules") {
                VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                    List(selection: $selection) {
                        ForEach(editor.draft.rules.indices, id: \.self) { index in
                            Text(Self.summary(of: editor.draft.rules[index]))
                                .font(typography.font(.body))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .tag(index)
                        }
                    }
                    .listStyle(.bordered)
                    .frame(width: SettingsMetrics.fieldWidth * typography.scale, height: SettingsMetrics.ruleListHeight * typography.scale)
                    listButtons
                }
            }
            SettingsHint(text: "The first matching rule applies to new notifications.")
            ForEach(SidebarSettings.Rule.Field.allCases, id: \.self) { field in
                SettingsRow(label: field.label) {
                    TextField(field.label, text: pattern(field), prompt: Text("Any"))
                        .labelsHidden()
                        .frame(width: SettingsMetrics.fieldWidth * typography.scale)
                        .disabled(selection == nil)
                }
            }
            SettingsHint(text: "Case-insensitive regular expressions, found anywhere.")
            SettingsRow(label: "Then") {
                // Pop-up buttons do not open in a key window of an inactive app. AppKit draws the segments in
                // the system font; the configured font does not reach them.
                Picker("Then", selection: action) {
                    ForEach(SidebarSettings.Rule.Action.allCases, id: \.self) { action in
                        Text(action.title).tag(action)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(selection == nil)
            }
            SettingsRow(label: "Matches") {
                Text(matches)
                    .font(typography.font(.subheadline))
                    .foregroundStyle(selectedRule?.problem == nil ? .secondary : Color.orange)
                    // Room for every line whatever the selection, so choosing a rule does not resize the window.
                    .lineLimit(Self.matchLines, reservesSpace: true)
                    .frame(width: SettingsMetrics.fieldWidth * typography.scale, alignment: .leading)
            }
        }
    }

    /// Add, remove and reorder; the order decides which rule applies first.
    private var listButtons: some View {
        HStack(spacing: SettingsMetrics.stepperSpacing) {
            iconButton("Add Rule", systemImage: "plus") {
                editor.draft.rules.append(SidebarSettings.Rule())
                selection = editor.draft.rules.count - 1
            }
            iconButton("Remove Rule", systemImage: "minus") {
                guard let index = selection else { return }
                editor.draft.rules.remove(at: index)
                selection = editor.draft.rules.isEmpty ? nil : min(index, editor.draft.rules.count - 1)
            }
            .disabled(selection == nil)
            iconButton("Move Up", systemImage: "arrow.up") { move(by: -1) }
                .disabled((selection ?? 0) == 0)
            iconButton("Move Down", systemImage: "arrow.down") { move(by: 1) }
                .disabled(selection.map { $0 >= editor.draft.rules.count - 1 } ?? true)
        }
    }

    private func iconButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: typography.size)
        }
        .accessibilityLabel(title)
        .help(title)
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

    var action: Binding<SidebarSettings.Rule.Action> {
        Binding(
            get: { selectedRule?.action ?? SidebarSettings.Rule().action },
            set: { value in selectedIndex.map { editor.draft.rules[$0].action = value } }
        )
    }

    /// What the selected rule matches among the listed notifications, or why it cannot match.
    var matches: String {
        guard let rule = selectedRule else { return "Select a rule to see its matches." }
        if let problem = rule.problem {
            return "This rule \(problem)."
        }
        let rules = NotificationRules([rule])
        let listed = listed()
        let matched = listed.filter { rules.firstMatch(for: $0) != nil }
        let count = "Matches \(matched.count) of \(listed.count) listed notifications"
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
}

extension SidebarSettings.Rule.Action {
    var title: String { name.capitalized }
}
