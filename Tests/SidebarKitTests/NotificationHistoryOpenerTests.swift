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
        /// Whether each request was performed, and what each came to.
        var results: [Bool] = []
        var outcomes: [SystemNotificationInterceptor.PerformOutcome] = []
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

        func start(_ identifiers: [String], from source: String = "Vivaldi", action: NativeAction = .open) -> Bool {
            opener.start(action, on: identifiers, from: source) { [unowned self] in
                outcomes.append($0)
                results.append($0 == .performed)
            }
        }

        @discardableResult
        func step(clock: FakeElement? = nil, hasClock: Bool = true) -> Bool {
            opener.step(windows: windows, application: application, clock: hasClock ? (clock ?? self.clock) : nil)
        }
    }

    /// The clock opens the panel, whose window goes off-screen before anything is pressed; the entry is
    /// pressed, and the clock closes the panel again. The request ends `closeGrace` after the panel closed.
    @Test func opensAnEntryFromTheHiddenHistoryPanel() {
        let history = History()
        #expect(history.start(["gone", "b"]))

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

        // Until it is closed, and for `closeGrace` after, the window stays off-screen: NotificationCenter moves it
        // back as the panel closes.
        history.windows[0].position = .zero
        #expect(history.step())
        #expect(history.windows[0].position == SystemNotificationInterceptor.offScreen)
        history.closePanel()
        #expect(history.step())
        #expect(history.windows[0].position == SystemNotificationInterceptor.offScreen)
        history.now += NotificationHistoryOpener.closeGrace
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
    /// `timeout` without pressing the clock again, and a panel opening after `latePanelGrace` is not its own.
    @Test func failsWhenThePanelNeverOpens() {
        let history = History()
        _ = history.start(["b"])
        history.step()

        history.now += NotificationHistoryOpener.timeout
        #expect(!history.step())
        #expect(history.results == [false])
        #expect(history.outcomes == [.refused])
        #expect(!history.opener.adoptLatePanel(windows: history.windows, application: history.application))
        history.now += NotificationHistoryOpener.latePanelGrace
        history.openPanel()
        #expect(!history.opener.adoptLatePanel(windows: history.windows, application: history.application))
        #expect(!history.opener.isOpening)
        #expect(history.clock.performed == [kAXPressAction])
    }

    /// A slow NotificationCenter can open the panel after the request gave up. Handed back by a sweep, the
    /// panel is hidden at once and closed again, and the request ends `closeGrace` after it closed.
    @Test func closesAPanelThatOpensAfterTheRequestGaveUp() {
        let history = History()
        _ = history.start(["b"])
        history.step()
        history.now += NotificationHistoryOpener.timeout
        #expect(!history.step())
        #expect(history.results == [false])

        history.now += NotificationHistoryOpener.latePanelGrace - NotificationHistoryOpener.closeTimeout / 2
        history.openPanel(FakeElement.banner(id: "b"))
        #expect(history.opener.adoptLatePanel(windows: history.windows, application: history.application))
        #expect(!history.opener.adoptLatePanel(windows: history.windows, application: history.application))
        #expect(history.opener.isOpening)
        #expect(history.step())
        #expect(history.windows[0].position == SystemNotificationInterceptor.offScreen)
        #expect(history.clock.performed == [kAXPressAction, kAXPressAction])
        // Closing has its own time, past the end of the watch.
        history.now += NotificationHistoryOpener.closeTimeout / 2
        #expect(history.step())

        history.closePanel()
        #expect(history.step())
        history.now += NotificationHistoryOpener.closeGrace
        #expect(!history.step())
        #expect(history.results == [false])
        #expect(history.clock.performed == [kAXPressAction, kAXPressAction])
    }

    /// While an earlier request may still get its panel, the next one does not press the clock again, which
    /// would close that panel as it opens; it uses the panel once it opens.
    @Test func waitsForTheEarlierRequestsPanel() {
        let history = History()
        _ = history.start(["a"])
        history.step()
        history.now += NotificationHistoryOpener.timeout
        #expect(!history.step())

        #expect(history.start(["b"]))
        #expect(history.step())
        #expect(history.clock.performed == [kAXPressAction])
        let entry = FakeElement.banner(id: "b")
        history.openPanel(entry)
        #expect(history.step())
        #expect(entry.performed == [kAXPressAction])
        #expect(history.windows[0].position == SystemNotificationInterceptor.offScreen)
        #expect(history.results == [false, true])
        #expect(history.clock.performed == [kAXPressAction, kAXPressAction])
    }

    /// A panel that opens just before the search runs out of time is still closed: closing gets its own
    /// `closeTimeout` from the press, and the panel stays off-screen meanwhile.
    @Test func givesTheCloseItsOwnTime() {
        let history = History()
        _ = history.start(["b"])
        history.step()
        history.now += NotificationHistoryOpener.timeout - NotificationHistoryOpener.listGrace / 2
        history.openPanel()
        #expect(history.step())

        history.now += NotificationHistoryOpener.listGrace / 2
        #expect(history.step())
        #expect(history.results == [false])
        #expect(history.clock.performed == [kAXPressAction, kAXPressAction])

        history.now += NotificationHistoryOpener.closeTimeout / 2
        history.windows[0].position = .zero
        #expect(history.step())
        #expect(history.windows[0].position == SystemNotificationInterceptor.offScreen)
        history.closePanel()
        #expect(history.step())
        history.now += NotificationHistoryOpener.closeGrace
        #expect(!history.step())
        #expect(history.clock.performed == [kAXPressAction, kAXPressAction])
    }

    /// A clock that refuses the closing press is pressed once more, `closeRetryDelay` later while the panel
    /// stays open, and never again: a refused press may have reached the clock all the same, and each further
    /// press that does opens the closing panel again.
    @Test func pressesTheClockOnceMoreWhenItRefusesToClose() {
        let history = History()
        _ = history.start(["b"])
        history.step()
        history.openPanel(FakeElement.banner(id: "b"))
        history.clock.actionSucceeds = false
        #expect(history.step())
        #expect(history.results == [true])
        #expect(history.clock.performed.count == 2)
        history.now += NotificationHistoryOpener.closeRetryDelay / 2
        #expect(history.step())
        #expect(history.clock.performed.count == 2)

        history.now += NotificationHistoryOpener.closeRetryDelay
        #expect(history.step())
        #expect(history.clock.performed.count == 3)
        history.now += NotificationHistoryOpener.closeRetryDelay
        #expect(history.step())
        #expect(history.clock.performed.count == 3)
        history.now += NotificationHistoryOpener.closeTimeout
        #expect(!history.step())
        #expect(history.clock.performed.count == 3)

        // The second press takes; none follows it.
        history.closePanel()
        history.clock.actionSucceeds = true
        _ = history.start(["b"])
        history.step()
        history.openPanel(FakeElement.banner(id: "b"))
        history.clock.actionSucceeds = false
        history.step()
        history.clock.actionSucceeds = true
        history.now += NotificationHistoryOpener.closeTimeout / 2
        #expect(history.step())
        #expect(history.step())
        #expect(history.clock.performed.count == 6)
        history.closePanel()
        #expect(history.step())
        history.now += NotificationHistoryOpener.closeGrace
        #expect(!history.step())
        #expect(history.clock.performed.count == 6)
        #expect(history.results == [true, true])
    }

    /// A panel that will not close, or a clock that never takes the press, does not keep the request running
    /// past `closeTimeout`; the sweep then leaves the panel on screen for the user to close.
    @Test func stopsWaitingForAPanelThatStaysOpen() {
        let history = History()
        _ = history.start(["b"])
        history.step()
        history.openPanel(FakeElement.banner(id: "b"))
        history.step()

        history.now += NotificationHistoryOpener.closeTimeout
        #expect(!history.step())
        #expect(history.results == [true])

        // The step that finds the time up does not press the clock again, which could open the closing panel
        // for the sweeps to show.
        history.closePanel()
        _ = history.start(["b"])
        history.step()
        history.openPanel(FakeElement.banner(id: "b"))
        history.clock.actionSucceeds = false
        history.step()
        #expect(history.clock.performed.count == 4)
        history.now += NotificationHistoryOpener.closeTimeout
        #expect(!history.step())
        #expect(history.results == [true, true])
        #expect(history.clock.performed.count == 4)
    }

    /// Abandoning a request closes the panel it opened, unless its close was pressed already; a panel that is
    /// not open, or one the user opened, is left alone.
    @Test func closesThePanelWhenAbandoned() {
        let history = History()
        func cancel() {
            history.opener.cancel(windows: history.windows, application: history.application, clock: history.clock)
        }
        // The panel has not opened yet.
        _ = history.start(["b"])
        history.step()
        cancel()
        #expect(history.results == [false])
        #expect(history.outcomes == [.refused])
        #expect(history.clock.performed == [kAXPressAction])

        _ = history.start(["b"])
        history.step()
        history.openPanel()
        cancel()
        #expect(!history.opener.isOpening)
        #expect(history.results == [false, false])
        #expect(history.outcomes == [.refused, .refused])
        #expect(history.clock.performed == [kAXPressAction, kAXPressAction, kAXPressAction])

        // The panel is open before the request starts, so the user opened it.
        _ = history.start(["b"])
        history.step()
        cancel()
        #expect(history.results == [false, false, false])
        #expect(history.outcomes == [.refused, .refused, .refused])
        #expect(history.clock.performed.count == 3)

        // The clock was pressed to close the panel already.
        history.closePanel()
        _ = history.start(["b"])
        history.step()
        history.openPanel(FakeElement.banner(id: "b"))
        history.step()
        #expect(history.clock.performed.count == 5)
        cancel()
        #expect(history.results == [false, false, false, true])
        #expect(history.clock.performed.count == 5)

        cancel()
        #expect(history.results == [false, false, false, true])

        // The request gave up, and its panel opened late.
        history.closePanel()
        _ = history.start(["b"])
        history.step()
        history.now += NotificationHistoryOpener.timeout
        history.step()
        history.openPanel()
        cancel()
        #expect(history.results == [false, false, false, true, false])
        #expect(history.clock.performed.count == 7)
        #expect(!history.opener.adoptLatePanel(windows: history.windows, application: history.application))
    }

    /// A choice or reply is performed on the entry as on a banner. Its completion runs once the request is
    /// concluded: one that steps the opener again, as the sweep a dismissed card asks for does, performs nothing
    /// twice and does not press the clock again, which would reopen the closing panel.
    @Test func performsAChoiceOnItsEntryOnce() {
        let history = History()
        let entry = FakeElement.replyBanner(id: "b", app: "Vivaldi")
        var nested: [Bool] = []
        history.opener.start(.reply(choice: "Reply", text: "On my way", send: "Send"), on: ["b"], from: "Vivaldi") { outcome in
            history.outcomes.append(outcome)
            nested.append(history.step())
        }
        history.step()
        history.openPanel(entry)
        #expect(history.step())

        #expect(entry.string("sent") == "On my way")
        #expect(entry.performed.filter { $0.hasPrefix("Name:Reply") }.count == 1)
        #expect(history.outcomes == [.performed])
        #expect(nested == [true])
        #expect(history.clock.performed.count == 2)
    }

    /// The outcome tells a history that no longer holds the notification from an entry that refuses.
    @Test func tellsAGoneNotificationFromARefusal() {
        let gone = History()
        _ = gone.start(["b"], action: .choice("Later"))
        gone.step()
        gone.openPanel()
        gone.step()
        // Past `listGrace`, within `timeout`.
        gone.now += 1
        gone.step()

        let refusing = History()
        _ = refusing.start(["b"], action: .choice("Snooze"))
        refusing.step()
        refusing.openPanel(FakeElement.alert(id: "b", choices: ["Later"]))
        refusing.step()

        #expect(gone.outcomes == [.absent])
        #expect(refusing.outcomes == [.refused])
    }

    /// A request started while another runs waits until that one has closed its panel, then opens the panel
    /// for itself, with its own `timeout` from then on. Abandoning them fails the one running and those waiting.
    @Test func runsRequestsOneAfterAnother() {
        let history = History()
        var waited: [Bool] = []
        #expect(history.start(["a"]))
        #expect(!history.opener.start(.open, on: ["b"], from: "Vivaldi") { waited.append($0 == .performed) })
        history.step()

        history.now += NotificationHistoryOpener.timeout - NotificationHistoryOpener.listGrace
        let first = FakeElement.banner(id: "a")
        history.openPanel(first, FakeElement.banner(id: "b"))
        #expect(history.step())
        #expect(first.performed == [kAXPressAction])
        #expect(history.results == [true])
        #expect(waited.isEmpty)
        #expect(history.clock.performed.count == 2)
        history.closePanel()
        #expect(history.step())
        history.now += NotificationHistoryOpener.closeGrace
        #expect(history.step())
        #expect(history.opener.isOpening)
        #expect(history.clock.performed.count == 2)

        #expect(history.step())
        #expect(history.clock.performed.count == 3)
        history.now += NotificationHistoryOpener.listGrace
        let second = FakeElement.banner(id: "b")
        history.openPanel(second)
        #expect(history.step())
        #expect(second.performed == [kAXPressAction])
        #expect(waited == [true])
        #expect(history.windows[0].position == SystemNotificationInterceptor.offScreen)
        history.closePanel()
        history.step()
        history.now += NotificationHistoryOpener.closeGrace
        #expect(!history.step())

        _ = history.start(["c"])
        _ = history.opener.start(.open, on: ["d"], from: "Vivaldi") { waited.append($0 == .performed) }
        history.opener.cancel(windows: history.windows, application: history.application, clock: history.clock)
        #expect(history.results == [true, false])
        #expect(waited == [true, false])
        #expect(!history.opener.isOpening)
    }

    @Test func failsWithoutAClock() {
        let history = History()
        _ = history.start(["b"])

        #expect(!history.step(hasClock: false))
        #expect(history.results == [false])
        #expect(history.outcomes == [.refused])

        _ = history.start(["b"])
        let refusing = FakeElement()
        refusing.actionSucceeds = false
        #expect(!history.step(clock: refusing))
        #expect(history.results == [false, false])
        #expect(history.outcomes == [.refused, .refused])
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
