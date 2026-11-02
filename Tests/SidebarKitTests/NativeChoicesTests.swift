import Foundation
@testable import SidebarKit
import SQLite3
import Testing

@MainActor
struct NativeChoicesTests {
    let fixture: NotificationDatabaseFixture

    init() throws {
        fixture = try NotificationDatabaseFixture()
        try fixture.create()
    }

    /// Slack's category, as usernoted stores it on macOS 26.
    static let slackCategory: [String: Any] = [
        "id": "CATEGORY_1",
        "opt": 1,
        "acts": [["id": "REPLY_ACTION", "op": 0, "st": 1, "ti": "Reply", "tia": "Reply", "tip": "Message"]],
    ]
    static let threeChoices: [String: Any] = [
        "id": "three",
        "opt": 0,
        "acts": [["id": "approve", "op": 0, "ti": "Approve"], ["id": "reject", "op": 2, "ti": "Reject"], ["id": "later", "op": 0, "ti": "Later"]],
    ]

    /// The actions alerter's `--actions "Now,Later today,Tomorrow" --dropdown-label "When?"` carries in its record:
    /// the menu's items, and its action button as the menu's header.
    static let menuActions: [[String: Any]] = [
        ["id": "ACTION", "op": 0, "ti": "When?"],
        ["id": "0", "op": 64, "ti": "Now"],
        ["id": "1", "op": 64, "ti": "Later today"],
        ["id": "2", "op": 66, "ti": "Tomorrow"],
    ]

    @Test func readsTitlesTextInputsAndDestructiveActions() {
        let choices = NativeChoice.choices(declaredBy: (Self.slackCategory["acts"] as! [[String: Any]]) + (Self.threeChoices["acts"] as! [[String: Any]]))

        #expect(choices == [
            NativeChoice(title: "Reply", textInput: NativeChoice.TextInput(placeholder: "Message", sendTitle: "Reply")),
            NativeChoice(title: "Approve"),
            NativeChoice(title: "Reject", isDestructive: true),
            NativeChoice(title: "Later"),
        ])
    }

    /// An actions menu's header only closes the notification unanswered; without a menu, the action button is the
    /// one choice. Actions without a title name no accessibility action.
    @Test func leavesAnActionsMenusHeaderOut() {
        #expect(NativeChoice.choices(declaredBy: Self.menuActions) == ["Now", "Later today", NativeChoice(title: "Tomorrow", isDestructive: true)])
        #expect(NativeChoice.choices(declaredBy: [["id": "ACTION", "op": 0, "ti": "Approve"]]) == ["Approve"])
        #expect(NativeChoice.choices(declaredBy: [["id": "ACTION", "op": 0], ["id": "other", "ti": ""]]).isEmpty)
    }

    @Test func readsTheCategoriesAnAppRegistered() throws {
        try fixture.declare([Self.slackCategory, Self.threeChoices, ["acts": []]])

        let declared = try fixture.database.declaredChoices(ofApp: "COM.apple.ScriptEditor2")

        #expect(declared.keys.sorted() == ["CATEGORY_1", "three"])
        #expect(declared["three"]?.map(\.title) == ["Approve", "Reject", "Later"])
        #expect(try fixture.database.declaredChoices(ofApp: "com.example.missing").isEmpty)
    }

    /// A notification gets the one category of its app with exactly its titles, in the app's order; an app's
    /// categories are read once per `DeclaredChoices.lifetime`.
    @Test func matchesTheCategoryWithANotificationsTitles() {
        let reply = NativeChoice(title: "Reply", textInput: NativeChoice.TextInput(placeholder: "Message", sendTitle: "Send"))
        let three: [NativeChoice] = ["Approve", NativeChoice(title: "Reject", isDestructive: true), "Later"]
        var now = Date(timeIntervalSince1970: 0)
        var reads: [String] = []
        let declared = DeclaredChoices(now: { now }) { app in
            reads.append(app)
            return switch app {
            case "probe": ["three": three, "reply": [reply]]
            // The same titles, once asking for text and once not.
            case "ambiguous": ["reply": [reply], "plain": ["Reply"]]
            // The same choices under two categories.
            case "twice": ["a": [reply], "b": [reply]]
            default: [:]
            }
        }

        #expect(declared.choices(ofApp: "probe", titled: ["Later", "Reject", "Approve"]) == three)
        #expect(declared.choices(ofApp: "probe", titled: ["Reply"]) == [reply])
        #expect(declared.choices(ofApp: "probe", titled: ["Approve"]) == nil)
        #expect(declared.choices(ofApp: "ambiguous", titled: ["Reply"]) == nil)
        #expect(declared.choices(ofApp: "twice", titled: ["Reply"]) == [reply])
        #expect(reads == ["probe", "ambiguous", "twice"])

        now += DeclaredChoices.lifetime
        _ = declared.choices(ofApp: "probe", titled: ["Reply"])
        #expect(reads == ["probe", "ambiguous", "twice", "probe"])
    }

    /// A read that fails keeps what was read before and is tried again after `retryInterval`, not `lifetime`.
    @Test func readsAgainSoonAfterAFailedRead() {
        var now = Date(timeIntervalSince1970: 0)
        var results: [[String: [NativeChoice]]?] = [["a": ["Later"]], nil, nil, ["a": ["Now"]]]
        let declared = DeclaredChoices(now: { now }) { _ in results.removeFirst() }

        #expect(declared.choices(ofApp: "app", titled: ["Later"]) == ["Later"])
        now += DeclaredChoices.lifetime
        #expect(declared.choices(ofApp: "app", titled: ["Later"]) == ["Later"])
        now += DeclaredChoices.retryInterval
        #expect(declared.choices(ofApp: "app", titled: ["Later"]) == ["Later"])
        now += DeclaredChoices.retryInterval
        #expect(declared.choices(ofApp: "app", titled: ["Now"]) == ["Now"])
        #expect(results.isEmpty)
    }

    /// An app is known to declare no choices only once its categories were read and it has none; a read that fails,
    /// as without Full Disk Access, tells nothing, and one that fails later keeps what was known.
    @Test func knowsWhichAppsDeclareNoChoices() {
        var now = Date(timeIntervalSince1970: 0)
        var results: [String: [[String: [NativeChoice]]?]] = [
            "legacy": [[:], nil], "categories": [["a": ["Later"]]], "unreadable": [nil],
        ]
        let declared = DeclaredChoices(now: { now }) { results[$0]!.removeFirst() }

        #expect(declared.declaresNone(ofApp: "legacy"))
        #expect(!declared.declaresNone(ofApp: "categories"))
        #expect(!declared.declaresNone(ofApp: "unreadable"))
        now += DeclaredChoices.lifetime
        #expect(declared.declaresNone(ofApp: "legacy"))
    }

    /// The database's categories reach the cache; without Full Disk Access every app declared none.
    @Test func readsDeclaredChoicesFromTheDatabase() throws {
        try fixture.declare([Self.slackCategory])
        let declared = DeclaredChoices(database: fixture.database)
        #expect(declared.choices(ofApp: "com.apple.ScriptEditor2", titled: ["Reply"])?.first?.textInput?.placeholder == "Message")

        let unreadable = DeclaredChoices(database: NotificationDatabase(url: URL(fileURLWithPath: "/nonexistent/db")))
        #expect(unreadable.choices(ofApp: "com.apple.ScriptEditor2", titled: ["Reply"]) == nil)
    }

    /// A record names an NSUserNotification's own actions, or the category its app declared for it, read when asked
    /// for, so a category declared after an earlier read counts. A category the app did not declare, or one without
    /// actions, names none, and so does a record without either.
    @Test func readsTheChoicesARecordNames() throws {
        let start = Date(timeIntervalSinceReferenceDate: 799_000_000)
        try fixture.insert(title: "Menu", delivered: start + 1, actions: Self.menuActions)
        try fixture.insert(title: "Declared", delivered: start + 2, category: "three")
        try fixture.insert(title: "Undeclared", delivered: start + 3, category: "missing")
        try fixture.insert(title: "Empty", delivered: start + 4, category: "empty")
        try fixture.insert(title: "Untitled", delivered: start + 5, category: "", actions: [["id": "ACTION", "op": 0]])
        try fixture.insert(title: "Plain", delivered: start + 6)
        let records = try fixture.database.notifications(deliveredAfter: start, by: start + 10)
        #expect(records.map(\.category) == [nil, "three", "missing", "empty", nil, nil])
        #expect(throws: NotificationDatabase.Failure.self) { try fixture.database.choices(ofNotification: records[1]) }

        try fixture.declare([Self.threeChoices, ["id": "empty", "acts": []]])

        #expect(try records.map { try fixture.database.choices(ofNotification: $0)?.map(\.title) } == [
            ["Now", "Later today", "Tomorrow"], ["Approve", "Reject", "Later"], nil, nil, nil, nil,
        ])
    }
}
