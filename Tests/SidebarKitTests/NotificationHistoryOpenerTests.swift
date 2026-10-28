import ApplicationServices
import Foundation
@testable import SidebarKit
import Testing

@MainActor
struct NotificationHistoryOpenerTests {
    /// NotificationCenter, its windows and the menu bar clock. The clock opens the panel only when a test
    /// says so, as macOS does a moment after the press.
    @MainActor
    final class History {
        let application = FakeElement()
        let clock = FakeElement([kAXIdentifierAttribute: SystemAccessibility.clockIdentifier], actions: [kAXPressAction])
        var windows: [FakeElement] = [FakeElement.window()]
        var now = Date(timeIntervalSince1970: 0)
        var results: [Bool] = []
        var opener: NotificationHistoryOpener!

        init() {
            opener = NotificationHistoryOpener(now: { [unowned self] in now })
        }

        /// Shows the panel with `entries` in its one window, which stays where NotificationCenter put it.
        func openPanel(_ entries: FakeElement...) {
            application.flags["AXExpanded"] = true
            windows = [FakeElement(
                [kAXRoleAttribute: kAXWindowRole, kAXSubroleAttribute: kAXSystemDialogSubrole],
                children: [FakeElement([kAXIdentifierAttribute: "AXNotificationListItems"], children: entries)],
                position: .zero
            )]
        }

        func closePanel() {
            application.flags["AXExpanded"] = false
            windows = [FakeElement.window()]
        }

        func start(_ identifiers: [String], from source: String = "Vivaldi") -> Bool {
            opener.start(identifiers, from: source) { [unowned self] in results.append($0) }
        }

        @discardableResult
        func step(clock: FakeElement? = nil, hasClock: Bool = true) -> Bool {
            opener.step(windows: windows, application: application, clock: hasClock ? (clock ?? self.clock) : nil)
        }
    }

    /// The clock opens the panel, whose window goes off-screen before anything is pressed; the entry is
    /// pressed, and the clock closes the panel again. The request ends once the panel is closed.
    @Test func opensAnEntryFromTheHiddenHistoryPanel() {
        let history = History()
        #expect(history.start(["gone", "b"]))
        #expect(!history.start(["other"]))

        #expect(history.step())
        #expect(history.clock.performed == [kAXPressAction])
        #expect(history.step())
        #expect(history.clock.performed == [kAXPressAction])

        let entry = FakeElement.banner(id: "b", app: "Vivaldi", title: "Alex")
        history.openPanel(entry)
        #expect(history.step())
        #expect(history.windows[0].position == SystemNotificationInterceptor.offScreen)
        #expect(entry.performed == [kAXPressAction])
        #expect(history.results == [true])
        #expect(history.clock.performed == [kAXPressAction, kAXPressAction])

        // Until it is closed, the closing panel stays off-screen.
        history.windows[0].position = .zero
        #expect(history.step())
        #expect(history.windows[0].position == SystemNotificationInterceptor.offScreen)
        history.closePanel()
        #expect(!history.step())
        #expect(!history.opener.isOpening)
        #expect(history.results == [true])
        #expect(!history.step())
    }

    /// A collapsed stack shows only its newest entry, so stacks that carry one of the identifiers or come
    /// from the same app are expanded first; other apps' stacks are left alone.
    @Test func expandsTheAppsStacksToReachAnEntry() {
        let history = History()
        _ = history.start(["older"])
        history.step()

        let own = FakeElement.alertStack(id: "newest", app: "Vivaldi")
        let byIdentifier = FakeElement.alertStack(id: "older", app: "Renamed")
        let other = FakeElement.alertStack(id: "mail", app: "Mail")
        history.openPanel(own, byIdentifier, other)
        #expect(history.step())
        #expect(own.performed == [kAXPressAction])
        #expect(byIdentifier.performed == [kAXPressAction])
        #expect(other.performed.isEmpty)
        history.now += NotificationHistoryOpener.listGrace
        #expect(history.step())
        #expect(own.performed == [kAXPressAction])
        #expect(history.results.isEmpty)

        let entry = FakeElement.banner(id: "older", app: "Vivaldi")
        history.openPanel(FakeElement.banner(id: "newest", app: "Vivaldi"), entry, other)
        #expect(history.step())
        #expect(entry.performed == [kAXPressAction])
        #expect(history.results == [true])
    }

    /// Without the entry, once the panel has had `listGrace` to list it and no stack is still expanding,
    /// the request fails and closes the panel.
    @Test func failsWhenTheHistoryNoLongerHoldsTheNotification() {
        let history = History()
        _ = history.start(["read"])
        history.step()
        history.openPanel(FakeElement.alertStack(id: "s", app: "Vivaldi"))

        #expect(history.step())
        history.now += NotificationHistoryOpener.expansionGrace
        #expect(history.step())
        #expect(history.results == [false])
        #expect(history.clock.performed == [kAXPressAction, kAXPressAction])
    }

    /// A press that NotificationCenter refuses fails the request too.
    @Test func reportsARefusedPress() {
        let history = History()
        _ = history.start(["b"])
        history.step()
        let entry = FakeElement.banner(id: "b")
        entry.actionSucceeds = false
        history.openPanel(entry)

        history.step()

        #expect(history.results == [false])
    }

    /// While the screen is locked macOS ignores the clock, so the panel never opens; the request fails after
    /// `timeout` without pressing the clock again.
    @Test func failsWhenThePanelNeverOpens() {
        let history = History()
        _ = history.start(["b"])
        history.step()

        history.now += NotificationHistoryOpener.timeout
        #expect(!history.step())
        #expect(history.results == [false])
        #expect(history.clock.performed == [kAXPressAction])
    }

    /// A panel that will not close does not keep the request running past `timeout`.
    @Test func stopsWaitingForAPanelThatStaysOpen() {
        let history = History()
        _ = history.start(["b"])
        history.step()
        history.openPanel(FakeElement.banner(id: "b"))
        history.step()

        history.now += NotificationHistoryOpener.timeout
        #expect(!history.step())
        #expect(history.results == [true])
    }

    @Test func failsWithoutAClock() {
        let history = History()
        _ = history.start(["b"])

        #expect(!history.step(hasClock: false))
        #expect(history.results == [false])

        _ = history.start(["b"])
        let refusing = FakeElement()
        refusing.actionSucceeds = false
        #expect(!history.step(clock: refusing))
        #expect(history.results == [false, false])
    }

    /// A panel the user opened is used as it is: neither moved nor closed.
    @Test func leavesAPanelTheUserOpenedAlone() {
        let history = History()
        let entry = FakeElement.banner(id: "b")
        history.openPanel(entry)
        _ = history.start(["b"])

        #expect(!history.step())
        #expect(entry.performed == [kAXPressAction])
        #expect(history.windows[0].moves.isEmpty)
        #expect(history.clock.performed.isEmpty)
        #expect(history.results == [true])
    }
}
