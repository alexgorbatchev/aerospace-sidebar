import ApplicationServices
import CoreGraphics
import Foundation

/// Opens a notification that only Notification Center's history still holds, as clicking it there would, or
/// performs one of its choices there (`NativeAction`): a history entry offers the same named actions as the
/// banner it was, Reply's text field included (measured on macOS 26.6).
///
/// macOS tells an app which of its notifications was clicked only when the notification itself is clicked
/// in NotificationCenter; a browser, for one, then shows the page that posted it. A banner that timed out,
/// and every notification NotificationCenter filed without showing it, exists only in the history, which is
/// in the accessibility tree only while the history panel is open. The opener therefore presses the menu
/// bar clock, which opens the panel on the main display (AriSweedler/dotfiles notif-center, talon-axkit,
/// NotificationNanny), and moves the panel's window off-screen as soon as it is open, so the panel is never
/// seen. It then presses the entry with one of the notification's identifiers, expanding the app's stacks
/// first: a collapsed stack carries the identifier of its newest entry, and expanding it turns that entry
/// into an `AXNotificationCenterBanner` with the same identifier (OmniWM, SignalLadder). Finally, unless that
/// press closed the panel already, it presses the clock again to close the panel, giving it `closeTimeout` to
/// close however long the search took. A press the clock refuses may still have reached it, and a second press
/// that reaches it opens the closing panel again, so the clock is pressed once more at most, `closeRetryDelay`
/// later, while the panel stays open.
///
/// NotificationCenter moves its window back to the origin as the panel closes (measured on macOS 26.6), and
/// the window still holds the notifications the sidebar keeps hidden for their cards. Once the panel has
/// opened, every step therefore hides the window first, and the request ends only `closeGrace` after the
/// panel has closed, so neither the closing panel nor those notifications reach the screen before the next
/// sweep hides them.
///
/// NotificationCenter can take seconds to answer after a wake, so the panel the clock asked for may open
/// after the request gave up. Such a request watches for it for `latePanelGrace`: the monitor's sweeps hand
/// a panel that opens meanwhile back to it (`adoptLatePanel(windows:application:)`), and it is closed unseen
/// instead of staying open on screen. A request started during the watch does not press the clock again and
/// takes the late panel for its own. NotificationCenter reports nothing that tells that panel from one the
/// user opens meanwhile, so the user's input does (`RecentUserInput`): a panel found open within
/// `userInputWindow` of a click in a menu bar (the clock), a key press (a keyboard shortcut), a scroll or a
/// gesture the Dock handles (perhaps the swipe in from the screen's right edge) is the user's, which ends the
/// watch and stays open. Input the sidebar received does not count: a click on a card is not in a menu bar, and
/// the Return that sends a card's reply, which may start a request during the watch, went to the sidebar. A hot
/// corner opens the panel on pointer motion alone, which tells nothing, so a panel opened that way during the
/// watch is still closed. So is one the user opens while NotificationCenter is slow, which is when panels open
/// late: it may open more than `userInputWindow` after the click, when the pointer may have left the menu bar.
/// And a late panel that opens just after the user gave such input to another app stays open on screen. A panel
/// that opens after the watch stays open on screen.
///
/// Requests run one at a time, in the order they were started: each opens and closes the panel itself, and
/// one started while another runs begins once that one is done, closing its panel included.
///
/// `step(windows:application:clock:)` advances the running request; `NotificationCenterMonitor` calls it on
/// every NotificationCenter event and on a short timer until it returns false.
@MainActor
final class NotificationHistoryOpener {
    /// How long a request may look for the notification before it gives up.
    static let timeout: TimeInterval = 2
    /// How long the open panel is given to list its entries before a request that finds nothing gives up.
    static let listGrace: TimeInterval = 0.3
    /// How long an expanding stack is given before it is pressed again; a second press would collapse it.
    static let expansionGrace: TimeInterval = 0.5
    /// How long the panel is given to close after the first attempt to close it. A panel still open then is
    /// left to the sweeps, which move it back on screen, where the user can close it.
    static let closeTimeout: TimeInterval = 1
    /// How long the panel is given to close after a press the clock refused before the clock is pressed once
    /// more: about as long as the panel takes to open.
    static let closeRetryDelay: TimeInterval = 0.3
    /// How long the window stays hidden after the panel has closed.
    static let closeGrace: TimeInterval = 0.5
    /// How long a request that ended before its panel opened still watches for the panel, to close it.
    static let latePanelGrace: TimeInterval = 2
    /// How recently the user must have clicked in a menu bar, pressed a key or scrolled for a panel found open
    /// while a request waits for a late one to be the user's: the panel opens about 0.3 s after the click while
    /// NotificationCenter answers promptly.
    static let userInputWindow: TimeInterval = 1

    typealias Completion = @MainActor (SystemNotificationInterceptor.PerformOutcome) -> Void

    private struct Request {
        let action: NativeAction
        let identifiers: [String]
        let source: String
        let completion: Completion
        let startedAt: Date
        /// Whether the clock was pressed to open the panel; only then is the panel hidden and closed.
        var openedPanel: Bool
        /// Whether that press was made by a request that gave up before the panel opened, this one or an
        /// earlier one: a panel found open then may be the user's instead (`userOpenedPanel()`).
        var waitsForLatePanel: Bool
        var panelOpenedAt: Date?
        var expanded: [String: Date] = [:]
        /// Whether the outcome was reported; the request then only closes the panel it opened.
        var concluded = false
        /// When the closing panel was first found open, how often the clock was pressed to close it, and
        /// whether it took a press.
        var closingSince: Date?
        var closePresses = 0
        var pressedClose = false
        /// When the closing panel reported closed.
        var closedAt: Date?

        /// Whether the panel the request opened has been seen open, so that the window is the request's to hide.
        var ownsPanel: Bool { openedPanel && panelOpenedAt != nil }
    }

    private let now: () -> Date
    private let input: RecentUserInput
    private var request: Request?
    /// Requests started while another runs, oldest first.
    private var waiting: [(action: NativeAction, identifiers: [String], source: String, completion: Completion)] = []
    /// A request that ended before the panel it asked for opened, and until when it watches for the panel.
    private var unopened: (request: Request, until: Date)?
    var labels = NotificationCenterLabels.english

    init(now: @escaping () -> Date, input: RecentUserInput) {
        self.now = now
        self.input = input
    }

    /// Whether a request is running, closing its panel included; its steps then replace the sweeps.
    var isOpening: Bool { request != nil }

    /// Performs `action` on the first of `identifiers` the history holds, from the app named `source`, once the
    /// requests started before it are done; returns whether it began at once, else it begins from the steps of
    /// the one running. Its `timeout` counts from when it begins. `completion` receives `.absent` when the
    /// history no longer holds any of them, `.refused` when the entry refused or the panel did not list it in
    /// time.
    @discardableResult
    func start(_ action: NativeAction, on identifiers: [String], from source: String, completion: @escaping Completion) -> Bool {
        guard request == nil else {
            waiting.append((action, identifiers, source, completion))
            SystemNotificationInterceptor.logger.info("""
                \(action.logDescription, privacy: .public) on \(identifiers, privacy: .public) from the history after the requests before it
                """)
            return false
        }
        begin(action, on: identifiers, from: source, completion: completion)
        return true
    }

    /// Makes the request the running one. While an earlier request watches for its panel, the clock is not
    /// pressed again: a second press would close the panel the first one opens.
    private func begin(_ action: NativeAction, on identifiers: [String], from source: String, completion: @escaping Completion) {
        let time = now()
        let clockPressed = unopened.map { time < $0.until } ?? false
        unopened = nil
        request = Request(
            action: action, identifiers: identifiers, source: source, completion: completion, startedAt: time,
            openedPanel: clockPressed, waitsForLatePanel: clockPressed
        )
        SystemNotificationInterceptor.logger.info("\(action.logDescription, privacy: .public) on \(identifiers, privacy: .public) from the history")
    }

    /// Ends the running request and begins the oldest waiting one; returns whether one began.
    private func finish() -> Bool {
        request = nil
        guard !waiting.isEmpty else { return false }
        let next = waiting.removeFirst()
        begin(next.action, on: next.identifiers, from: next.source, completion: next.completion)
        return true
    }

    /// Abandons the requests, which fail unless their outcome is known already, and closes the panel the running
    /// one opened, or the late panel one watches for, if that is open in `windows` and not the user's.
    /// NotificationCenter is read only for a request that may have opened the panel.
    func cancel(
        windows: @autoclosure () -> [any AccessibilityElement],
        application: @autoclosure () -> (any AccessibilityElement)?,
        clock: @autoclosure () -> (any AccessibilityElement)?
    ) {
        let time = now()
        let abandoned = request ?? unopened.flatMap { time < $0.until ? $0.request : nil }
        let waiting = waiting
        request = nil
        unopened = nil
        self.waiting = []
        if let abandoned, !abandoned.concluded {
            abandoned.completion(.refused)
        }
        for request in waiting {
            request.completion(.refused)
        }
        guard let abandoned else { return }
        guard abandoned.openedPanel, !abandoned.pressedClose,
              NotificationBanners.isPanelOpen(application: application(), windows: windows()) else { return }
        if !abandoned.ownsPanel, abandoned.waitsForLatePanel, userOpenedPanel() {
            SystemNotificationInterceptor.logger.notice("The user opened Notification Center while an abandoned request waited for its panel; leaving it open")
            return
        }
        let pressed = clock()?.perform(kAXPressAction) == true
        SystemNotificationInterceptor.logger.info("Closing Notification Center for an abandoned request: \(pressed ? "pressed" : "refused", privacy: .public)")
    }

    /// Takes back a panel that opened after its request ended, which then closes it like a panel it found
    /// open; false when no request watches for its panel, the panel is not open, or the user opened it, which
    /// ends the watch.
    func adoptLatePanel(windows: [any AccessibilityElement], application: (any AccessibilityElement)?) -> Bool {
        guard let unopened, request == nil else { return false }
        let time = now()
        guard time < unopened.until else {
            self.unopened = nil
            return false
        }
        guard NotificationBanners.isPanelOpen(application: application, windows: windows) else { return false }
        self.unopened = nil
        guard !userOpenedPanel() else {
            SystemNotificationInterceptor.logger.notice("""
                The user opened Notification Center while the request for \(unopened.request.identifiers, privacy: .public) \
                watched for its panel; leaving it open
                """)
            return false
        }
        var request = unopened.request
        request.panelOpenedAt = time
        self.request = request
        SystemNotificationInterceptor.logger.notice("Notification Center opened after the request for \(request.identifiers, privacy: .public) ended; closing it")
        return true
    }

    /// Advances the running request; false once it and the requests waiting for it are finished. The clock is
    /// looked up only to be pressed.
    @discardableResult
    func step(
        windows: [any AccessibilityElement],
        application: (any AccessibilityElement)?,
        clock: @autoclosure () -> (any AccessibilityElement)?
    ) -> Bool {
        guard var request else { return false }
        let time = now()
        // Hiding a window that is already off-screen costs two reads, less than finding out whether the panel
        // is still open, and it comes first because NotificationCenter moves the window back as the panel closes.
        if request.ownsPanel {
            hide(windows)
        }
        let panelOpen = NotificationBanners.isPanelOpen(application: application, windows: windows)
        // A panel the user opened stays where it is: one open before the request started, or one the user opened
        // while the request waited for a late one.
        if panelOpen, request.openedPanel, !request.ownsPanel {
            if request.waitsForLatePanel, userOpenedPanel() {
                request.openedPanel = false
                SystemNotificationInterceptor.logger.notice("""
                    The user opened Notification Center while the request for \(request.identifiers, privacy: .public) \
                    waited for an earlier request's panel; using it where it is
                    """)
            } else {
                hide(windows)
            }
        }
        if request.concluded {
            return close(request, panelOpen: panelOpen, at: time, clock: clock)
        }
        if !request.openedPanel, !panelOpen {
            guard clock()?.perform(kAXPressAction) == true else {
                SystemNotificationInterceptor.logger.error("Cannot open Notification Center: no menu bar clock to press")
                return conclude(request, .refused, panelOpen: false, at: time, clock: clock)
            }
            request.openedPanel = true
            self.request = request
            return true
        }
        guard time.timeIntervalSince(request.startedAt) < Self.timeout else {
            SystemNotificationInterceptor.logger.notice("Notification Center did not list \(request.identifiers, privacy: .public) in time")
            return conclude(request, .refused, panelOpen: panelOpen, at: time, clock: clock)
        }
        guard panelOpen else {
            self.request = request
            return true
        }
        if request.panelOpenedAt == nil { request.panelOpenedAt = time }
        // Each entry's identifier is read once, however many notifications a stacked card stands for: every read
        // is a round trip to NotificationCenter on the main thread.
        var stacks: [any AccessibilityElement] = []
        var entries: [String: any AccessibilityElement] = [:]
        for item in windows.flatMap({ NotificationBanners.find(in: $0) }) {
            if NotificationBanners.kind(of: item) == .stack {
                stacks.append(item)
            } else if let identifier = item.string(kAXIdentifierAttribute), entries[identifier] == nil {
                entries[identifier] = item
            }
        }
        if let identifier = request.identifiers.first(where: { entries[$0] != nil }), let entry = entries[identifier] {
            let performed = NotificationBanners.perform(request.action, on: entry, labels: labels)
            SystemNotificationInterceptor.logger.info("""
                \(request.action.logDescription, privacy: .public) on \(identifier, privacy: .public) from the history: \
                \(performed ? "done" : "refused", privacy: .public)
                """)
            // The press leaves the panel open (measured on macOS 26.6), but a press that closed it must not be
            // followed by a press of the clock, which would open it again. NotificationCenter's elements are live.
            let stillOpen = NotificationBanners.isPanelOpen(application: application, windows: windows)
            return conclude(request, performed ? .performed : .refused, panelOpen: stillOpen, at: time, clock: clock)
        }
        var expanding = false
        for stack in stacks where mayHold(stack, request) {
            let key = stack.string(kAXIdentifierAttribute) ?? stack.string(kAXDescriptionAttribute) ?? ""
            if let pressedAt = request.expanded[key] {
                expanding = expanding || time.timeIntervalSince(pressedAt) < Self.expansionGrace
            } else {
                request.expanded[key] = time
                stack.perform(kAXPressAction)
                expanding = true
            }
        }
        if !expanding, let openedAt = request.panelOpenedAt, time.timeIntervalSince(openedAt) >= Self.listGrace {
            SystemNotificationInterceptor.logger.info("The history no longer holds \(request.identifiers, privacy: .public)")
            return conclude(request, .absent, panelOpen: panelOpen, at: time, clock: clock)
        }
        self.request = request
        return true
    }

    /// Whether a collapsed stack may hold the request's notification: it carries one of its identifiers, or
    /// comes from the same app.
    private func mayHold(_ stack: any AccessibilityElement, _ request: Request) -> Bool {
        if let identifier = stack.string(kAXIdentifierAttribute), request.identifiers.contains(identifier) { return true }
        return !request.source.isEmpty && NotificationBanners.content(of: stack, labels: labels).appName == request.source
    }

    /// Closes the panel if the request opened it, or watches for one that has not opened yet, then reports the
    /// outcome. Returns whether a request is still running. The outcome is reported last: a completion that
    /// changes the card list asks for a sweep, which steps the opener again from inside this step, and that
    /// step has to find the request concluded, or it performs the action a second time and presses the clock
    /// again, which reopens the closing panel.
    private func conclude(
        _ request: Request,
        _ outcome: SystemNotificationInterceptor.PerformOutcome,
        panelOpen: Bool,
        at time: Date,
        clock: () -> (any AccessibilityElement)?
    ) -> Bool {
        var request = request
        request.concluded = true
        if request.openedPanel, panelOpen, request.panelOpenedAt == nil { request.panelOpenedAt = time }
        if !request.openedPanel {
            _ = finish()
        } else if request.ownsPanel {
            _ = close(request, panelOpen: panelOpen, at: time, clock: clock)
        } else {
            request.waitsForLatePanel = true
            unopened = (request, time.addingTimeInterval(Self.latePanelGrace))
            _ = finish()
        }
        request.completion(outcome)
        // The completion may have stepped the opener on, or started a request.
        return isOpening
    }

    /// Presses the clock to close the panel, once more `closeRetryDelay` later if the clock refused and the panel
    /// is still open, and ends the request `closeGrace` after the panel has closed, or `closeTimeout` after the
    /// first attempt while it stays open. Returns whether a request is still running.
    private func close(_ request: Request, panelOpen: Bool, at time: Date, clock: () -> (any AccessibilityElement)?) -> Bool {
        var request = request
        if panelOpen {
            request.closedAt = nil
            let closingSince = request.closingSince ?? time
            request.closingSince = closingSince
            let closing = time.timeIntervalSince(closingSince)
            guard closing < Self.closeTimeout else {
                SystemNotificationInterceptor.logger.notice("Notification Center stayed open \(Self.closeTimeout, privacy: .public) s after closing it")
                return finish()
            }
            if !request.pressedClose, request.closePresses == 0 || (request.closePresses == 1 && closing >= Self.closeRetryDelay) {
                request.closePresses += 1
                request.pressedClose = clock()?.perform(kAXPressAction) == true
                SystemNotificationInterceptor.logger.info("Closing Notification Center: \(request.pressedClose ? "pressed" : "refused", privacy: .public)")
            }
        } else {
            let closedAt = request.closedAt ?? time
            request.closedAt = closedAt
            guard time.timeIntervalSince(closedAt) < Self.closeGrace else { return finish() }
        }
        self.request = request
        return true
    }

    /// Whether the user just did something outside the sidebar that opens the panel, within `userInputWindow`: a
    /// click in a menu bar, where the clock is, a key press (a keyboard shortcut), or a scroll or Dock gesture.
    private func userOpenedPanel() -> Bool {
        func recent(_ kind: RecentUserInput.Kind) -> Bool { input.secondsSince(kind) < Self.userInputWindow }
        return (recent(.mouseDown) && input.isPointerInMenuBar()) || recent(.keyDown) || recent(.scroll)
    }

    /// Moves the window holding the panel off-screen, so that the panel opens unseen.
    private func hide(_ windows: [any AccessibilityElement]) {
        for window in windows where NotificationBanners.isNotificationWindow(window) {
            guard let position = window.position, !SystemNotificationInterceptor.isOffScreen(position) else { continue }
            window.setPosition(SystemNotificationInterceptor.offScreen)
        }
    }
}
