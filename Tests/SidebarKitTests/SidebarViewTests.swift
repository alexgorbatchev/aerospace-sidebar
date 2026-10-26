import Foundation
@testable import SidebarKit
import SidebarProtocol
import SwiftUI
import Testing
import ViewInspector

@MainActor
struct SidebarViewTests {
    let performer = RecordingPerformer()
    var model: SidebarModel

    init() {
        model = SidebarModel(performer: performer, store: InMemoryStore())
    }

    func view(openSettings: @escaping () -> Void = {}, quit: @escaping () -> Void = {}) -> SidebarView {
        SidebarView(model: model, openSettings: openSettings, quit: quit)
    }

    @Test func showsEmptyStateWithoutClearAll() throws {
        let sut = try view().inspect()

        #expect(throws: Never.self) { try sut.find(text: "No notifications") }
        #expect(throws: (any Error).self) { try sut.find(button: "Clear All") }
    }

    @Test func clickingCardRunsActionAndDismisses() throws {
        model.add(SidebarNotification(source: "cli", title: "Build done", action: .run(command: "open .", workingDirectory: "/repo")))

        try view().inspect().find(text: "Build done").find(ViewType.Button.self, relation: .parent).tap()

        #expect(performer.actions == [.run(command: "open .", workingDirectory: "/repo")])
        #expect(model.notifications.isEmpty)
    }

    @Test func dismissButtonRemovesWithoutAction() throws {
        model.add(SidebarNotification(source: "cli", title: "Keep quiet", action: .open(URL(string: "https://a.example")!)))

        try view().inspect().find(viewWithAccessibilityLabel: "Dismiss").button().tap()

        #expect(performer.actions.isEmpty)
        #expect(model.notifications.isEmpty)
    }

    @Test func clearAllRemovesEverything() throws {
        model.add(SidebarNotification(source: "a", title: "one"))
        model.add(SidebarNotification(source: "b", title: "two"))

        try view().inspect().find(button: "Clear All").tap()

        #expect(model.notifications.isEmpty)
    }

    @Test func rendersEverySeverityActionAndField() throws {
        let actions: [SidebarNotification.ClickAction?] = [
            nil, .open(URL(string: "https://a.example")!), .run(command: "ls", workingDirectory: "/"), .activateApp(name: "Mail"),
        ]
        for (severity, action) in zip(NotificationSeverity.allCases, actions) {
            model.add(SidebarNotification(
                source: severity == .low ? "" : "source-\(severity)",
                title: "title-\(severity)",
                subtitle: "subtitle-\(severity)",
                body: "body-\(severity)",
                severity: severity,
                action: action
            ))
        }

        let sut = try view().inspect()

        for severity in NotificationSeverity.allCases {
            #expect(throws: Never.self) { try sut.find(text: "subtitle-\(severity)") }
            #expect(throws: Never.self) { try sut.find(text: "body-\(severity)") }
        }
        #expect(throws: Never.self) { try sut.find(text: "Notification") }
        #expect(throws: Never.self) { try sut.find(viewWithAccessibilityLabel: "critical") }
        #expect(throws: Never.self) { try sut.find(viewWithAccessibilityLabel: "high") }
        #expect(throws: (any Error).self) { try sut.find(viewWithAccessibilityLabel: "normal") }
    }

    @Test func marksNotificationsMacOSStillShows() throws {
        model.add(SidebarNotification(source: "Calendar", title: "Standup", shownByMacOS: true))

        #expect(throws: Never.self) { try view().inspect().find(text: "Shown by macOS for its buttons") }
    }

    @Test func bodyOnlyNotificationOmitsTitle() throws {
        model.add(SidebarNotification(source: "s", title: "", body: "just a body"))

        #expect(throws: Never.self) { try view().inspect().find(text: "just a body") }
    }

    @Test func promptsForSetupWhenAccessibilityIsMissing() throws {
        model.interception = .needsAccessibility
        var opened = 0

        let sut = try view(openSettings: { opened += 1 }).inspect()
        try sut.find(button: "Set Up…").tap()

        #expect(throws: Never.self) { try sut.find(text: "Grant Accessibility access to show macOS notifications here.") }
        #expect(opened == 1)
    }

    @Test func settingsButtonOpensSettings() throws {
        var opened = 0

        try view(openSettings: { opened += 1 }).inspect().find(button: "Settings…").tap()

        #expect(opened == 1)
    }

    @Test func explainsDisabledInterception() throws {
        model.interception = .disabled

        #expect(throws: Never.self) { try view().inspect().find(text: "macOS notifications are left to macOS (see Settings).") }
    }

    @Test func reportsUnavailableNotificationCenterWithoutSettingsButton() throws {
        model.interception = .notificationCenterUnavailable

        let sut = try view().inspect()

        #expect(throws: Never.self) { try sut.find(text: "macOS notifications cannot be read right now.") }
        #expect(throws: (any Error).self) { try sut.find(button: "Set Up…") }
    }

    @Test func hidesStatusWhileActive() throws {
        model.interception = .active

        #expect(throws: (any Error).self) { try view().inspect().find(text: "macOS notifications cannot be read right now.") }
    }

    @Test func quitButtonQuits() throws {
        var quits = 0

        try view(quit: { quits += 1 }).inspect().find(button: "Quit Sidebar").tap()

        #expect(quits == 1)
    }
}
