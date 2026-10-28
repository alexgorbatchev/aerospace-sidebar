import Foundation
@testable import SidebarKit
import SidebarProtocol
import SwiftUI
import Testing
import ViewInspector

typealias Rule = SidebarSettings.Rule

@MainActor
struct NotificationRuleTests {
    @Test func rulesRoundTripThroughConfigWithOnlyTheirPatterns() throws {
        let directory = try TemporaryDirectory()
        let file = SettingsFile(url: directory.url.appendingPathComponent("config.toml"))
        let settings = SidebarSettings(rules: [
            Rule(source: "^Slack$", action: .severity(.high)),
            Rule(title: "deploy", body: "failed", action: .hide),
        ])

        try file.save(settings)
        let text = try String(contentsOf: file.url, encoding: .utf8)

        #expect(text.contains("[[rules]]\naction = \"high\"\nsource = \"^Slack$\"\n"))
        #expect(text.contains("[[rules]]\naction = \"hide\"\nbody = \"failed\"\ntitle = \"deploy\"\n"))
        #expect(try file.load() == settings)
    }

    @Test(arguments: [
        ("[[rules]]\nsource = \"Slack\"\naction = \"loud\"\n", "rules[0].action: action must be hide, low, normal, high, or critical"),
        ("[[rules]]\naction = \"hide\"\n", "rules[0].action: a rule needs at least one pattern"),
        ("[[rules]]\nsource = \"Slack\"\naction = \"low\"\n\n[[rules]]\ntitle = \"(\"\naction = \"hide\"\n", "rules[1].title: invalid regular expression"),
        ("[[rules]]\nsource = \"Slack\"\n", "rules[0]"),
    ])
    func rejectsUnusableRules(toml: String, fragment: String) throws {
        let directory = try TemporaryDirectory()
        try directory.write(toml, to: "config.toml")

        #expect {
            try SettingsFile(url: directory.url.appendingPathComponent("config.toml")).load()
        } throws: { error in
            SettingsStore.describe(error).contains(fragment)
        }
    }

    @Test func describesWhyARuleCannotBeUsed() {
        #expect(Rule().problem == .matchesEverything)
        #expect(Rule().problem?.description == "needs at least one pattern")
        #expect(Rule(body: "[").problem.map { "\($0)".hasPrefix("has an invalid body pattern: ") } == true)
        #expect(Rule(subtitle: "x").problem == nil)
    }

    @Test func actionsReadAndWriteTheirNames() {
        #expect(Rule.Action.allCases.map(\.name) == ["hide", "low", "normal", "high", "critical"])
        #expect(Rule.Action.allCases.map(\.title) == ["Hide", "Low", "Normal", "High", "Critical"])
        #expect(Rule.Action.allCases.allSatisfy { Rule.Action(name: $0.name) == $0 })
        #expect(Rule.Action(name: "High") == nil)
    }

    /// Every pattern of a rule must match, case-insensitively and anywhere in its field; the first such rule
    /// applies.
    @Test func firstRuleWhosePatternsAllMatchApplies() {
        let rules = NotificationRules([
            Rule(source: "^slack$", title: "alice", action: .severity(.critical)),
            Rule(source: "slack", action: .severity(.high)),
            Rule(subtitle: "#random", action: .hide),
            Rule(body: "(", action: .hide),
        ])
        let fromAlice = SidebarNotification(source: "Slack", title: "Alice Smith", body: "lunch?")
        let fromBob = SidebarNotification(source: "Slack", title: "Bob", subtitle: "#random")
        let random = SidebarNotification(source: "Mail", title: "Digest", subtitle: "From #Random")
        let other = SidebarNotification(source: "Mail", title: "(", body: "(")

        #expect(rules.apply(to: fromAlice)?.severity == .critical)
        #expect(rules.apply(to: fromBob) == fromBob.with(severity: .high))
        #expect(rules.apply(to: random) == nil)
        // The rule with an invalid pattern is left out rather than matching everything.
        #expect(rules.apply(to: other) == other)
    }

    @Test func modelChangesOrHidesArrivingNotifications() {
        let store = InMemoryStore()
        let model = SidebarModel(
            performer: RecordingPerformer(),
            store: store,
            rules: [Rule(source: "Slack", action: .severity(.critical)), Rule(title: "noise", action: .hide)]
        )

        model.add(SidebarNotification(source: "ci", title: "Build", severity: .high))
        model.add(SidebarNotification(source: "Slack", title: "Hi"))
        model.add(SidebarNotification(source: "ci", title: "More noise"))
        model.add(SidebarNotification(source: "Slack", title: "Hi"))

        #expect(model.notifications.map(\.title) == ["Hi", "Build"])
        #expect(model.notifications.first?.severity == .critical)
        #expect(model.notifications.first?.occurrences == 2)
        #expect(store.stored.map(\.title) == ["Hi", "Build"])
    }

    /// New rules apply to notifications that arrive later; listed ones stay as they are.
    @Test func newRulesApplyFromNowOn() {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        model.add(SidebarNotification(source: "Slack", title: "Before"))

        model.apply(rules: [Rule(source: "Slack", action: .hide)])
        model.add(SidebarNotification(source: "Slack", title: "After"))

        #expect(model.notifications.map(\.title) == ["Before"])
    }

    @Test func savingRefusesUnusableRules() throws {
        let directory = try TemporaryDirectory()
        let store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let editor = SettingsEditor(store: store)

        editor.draft.rules = [Rule(source: "Slack"), Rule(action: .hide)]
        #expect(!editor.save())
        #expect(editor.status == "Rule 2 needs at least one pattern.")

        editor.draft.rules[1].title = "(unclosed"
        #expect(!editor.save())
        #expect(editor.status?.hasPrefix("Rule 2 has an invalid title pattern: ") == true)

        editor.draft.rules[1].title = "closed"
        #expect(editor.save())
        #expect(store.settings.rules == [Rule(source: "Slack"), Rule(title: "closed", action: .hide)])
    }
}

@MainActor
struct RulesPaneTests {
    let directory: TemporaryDirectory
    let store: SettingsStore
    let editor: SettingsEditor
    let listed = [
        SidebarNotification(source: "Slack", title: "Alice", body: "lunch?"),
        SidebarNotification(source: "Slack", title: "", body: "Bob joined"),
        SidebarNotification(source: "Mail", title: "Invoice"),
        SidebarNotification(source: "", title: "Slack outage"),
    ]

    init() throws {
        directory = try TemporaryDirectory()
        store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        editor = SettingsEditor(store: store)
    }

    func pane(selection: Int? = nil) -> RulesPane {
        RulesPane(editor: editor, listed: { listed }, close: {}, selection: selection)
    }

    @Test func addsRemovesAndReordersRules() throws {
        editor.draft.rules = [Rule(source: "a"), Rule(source: "b")]

        try pane().inspect().find(viewWithAccessibilityLabel: "Add Rule").button().tap()
        #expect(editor.draft.rules == [Rule(source: "a"), Rule(source: "b"), Rule()])

        try pane(selection: 2).inspect().find(viewWithAccessibilityLabel: "Move Up").button().tap()
        #expect(editor.draft.rules == [Rule(source: "a"), Rule(), Rule(source: "b")])
        try pane(selection: 0).inspect().find(viewWithAccessibilityLabel: "Move Down").button().tap()
        #expect(editor.draft.rules == [Rule(), Rule(source: "a"), Rule(source: "b")])

        try pane(selection: 0).inspect().find(viewWithAccessibilityLabel: "Remove Rule").button().tap()
        #expect(editor.draft.rules == [Rule(source: "a"), Rule(source: "b")])
        #expect(store.settings.rules.isEmpty)
    }

    @Test func listButtonsNeedASelectionThatCanMove() throws {
        editor.draft.rules = [Rule(source: "a"), Rule(source: "b")]
        let unselected = try pane().inspect()
        let first = try pane(selection: 0).inspect()
        let last = try pane(selection: 1).inspect()

        for label in ["Remove Rule", "Move Up", "Move Down"] {
            #expect(try unselected.find(viewWithAccessibilityLabel: label).button().isDisabled())
        }
        #expect(try first.find(viewWithAccessibilityLabel: "Move Up").button().isDisabled())
        #expect(try !first.find(viewWithAccessibilityLabel: "Move Down").button().isDisabled())
        #expect(try last.find(viewWithAccessibilityLabel: "Move Down").button().isDisabled())
        #expect(try unselected.find(ViewType.TextField.self, where: { try $0.labelView().text().string() == "Title" }).isDisabled())
    }

    @Test func editsTheSelectedRule() throws {
        editor.draft.rules = [Rule(source: "a"), Rule(source: "b")]
        let sut = try pane(selection: 1).inspect()

        try sut.find(ViewType.TextField.self, where: { try $0.labelView().text().string() == "Body" }).setInput("joined")
        try sut.find(ViewType.Picker.self).select(value: Rule.Action.hide)

        #expect(editor.draft.rules == [Rule(source: "a"), Rule(source: "b", body: "joined", action: .hide)])
        #expect(try sut.find(ViewType.TextField.self, where: { try $0.labelView().text().string() == "Source" }).input() == "b")
    }

    @Test func showsWhatTheSelectedRuleMatches() {
        editor.draft.rules = [Rule(source: "slack"), Rule(title: "nothing"), Rule(title: "(")]

        #expect(pane().matches == "Select a rule to see its matches.")
        #expect(pane(selection: 0).matches == "Matches 2 of 4 listed notifications:\nSlack: Alice\nSlack: Bob joined")
        #expect(pane(selection: 1).matches == "Matches 0 of 4 listed notifications.")
        #expect(pane(selection: 2).matches.hasPrefix("This rule has an invalid title pattern: "))
        editor.draft.rules = [Rule(title: "slack")]
        #expect(pane(selection: 0).matches == "Matches 1 of 4 listed notifications:\nNotification: Slack outage")
    }

    @Test func summarizesRulesInTheList() throws {
        editor.draft.rules = [Rule(source: "^Slack$", body: "x", action: .hide), Rule()]

        #expect(RulesPane.summary(of: editor.draft.rules[0]) == "source ~ ^Slack$, body ~ x → Hide")
        #expect(throws: Never.self) { try pane().inspect().find(text: "No pattern → High") }
    }
}
