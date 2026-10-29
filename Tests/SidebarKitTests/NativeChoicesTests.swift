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
        try fixture.execute("CREATE TABLE categories (app_id INTEGER PRIMARY KEY, categories BLOB)")
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

    func registerCategories(_ categories: [[String: Any]], app: Int = 1) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: categories, format: .binary, options: 0)
        try fixture.execute("INSERT INTO categories VALUES (\(app), x'\(data.map { String(format: "%02x", $0) }.joined())')")
    }

    @Test func readsTitlesTextInputsAndDestructiveActions() {
        let choices = NativeChoice.choices(declaredBy: (Self.slackCategory["acts"] as! [[String: Any]]) + (Self.threeChoices["acts"] as! [[String: Any]]))

        #expect(choices == [
            NativeChoice(title: "Reply", textInput: NativeChoice.TextInput(placeholder: "Message", sendTitle: "Reply")),
            NativeChoice(title: "Approve"),
            NativeChoice(title: "Reject", isDestructive: true),
            NativeChoice(title: "Later"),
        ])
    }

    @Test func readsTheCategoriesAnAppRegistered() throws {
        try registerCategories([Self.slackCategory, Self.threeChoices, ["acts": []]])

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

    /// The database's categories reach the cache; without Full Disk Access every app declared none.
    @Test func readsDeclaredChoicesFromTheDatabase() throws {
        try registerCategories([Self.slackCategory])
        let declared = DeclaredChoices(database: fixture.database)
        #expect(declared.choices(ofApp: "com.apple.ScriptEditor2", titled: ["Reply"])?.first?.textInput?.placeholder == "Message")

        let unreadable = DeclaredChoices(database: NotificationDatabase(url: URL(fileURLWithPath: "/nonexistent/db")))
        #expect(unreadable.choices(ofApp: "com.apple.ScriptEditor2", titled: ["Reply"]) == nil)
    }
}
