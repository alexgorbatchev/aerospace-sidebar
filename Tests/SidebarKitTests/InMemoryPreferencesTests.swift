import Foundation
@testable import SidebarKit
import Testing

/// A fresh store per fixture; shared references model relaunches without writing preference domains.
final class InMemoryPreferences: Preferences {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

struct InMemoryPreferencesTests {
    @Test func retainsValuesAcrossConsumersAndRemovesNilValues() {
        let store = InMemoryPreferences()
        let first: any Preferences = store
        let relaunched: any Preferences = store
        let date = Date()

        first.set(date, forKey: "readPosition")
        first.set(["one", "two"], forKey: "identities")
        first.set(true, forKey: "dismissed")
        #expect(relaunched.object(forKey: "readPosition") as? Date == date)
        #expect(relaunched.stringArray(forKey: "identities") == ["one", "two"])
        #expect(relaunched.bool(forKey: "dismissed"))

        relaunched.set(nil, forKey: "readPosition")
        relaunched.set(nil, forKey: "identities")
        relaunched.set(nil, forKey: "dismissed")
        #expect(first.object(forKey: "readPosition") == nil)
        #expect(first.stringArray(forKey: "identities") == nil)
        #expect(!first.bool(forKey: "dismissed"))
    }

    @Test func fixturePreferencesAreIsolatedEvenWhenAScopeThrows() throws {
        enum Failure: Error { case expected }
        let untouched = try NotificationDatabaseFixture()
        #expect(throws: Failure.self) {
            let failing = try NotificationDatabaseFixture()
            failing.defaults.set(true, forKey: "dismissed")
            #expect(failing.defaults.bool(forKey: "dismissed"))
            throw Failure.expected
        }
        let next = try NotificationDatabaseFixture()
        #expect(!untouched.defaults.bool(forKey: "dismissed"))
        #expect(!next.defaults.bool(forKey: "dismissed"))
    }
}
