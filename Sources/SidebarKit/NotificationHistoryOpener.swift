import ApplicationServices
import CoreGraphics
import Foundation

/// Opens a notification that only Notification Center's history still holds, as clicking it there would.
///
/// macOS tells an app which of its notifications was clicked only when the notification itself is clicked
/// in NotificationCenter; a browser, for one, then shows the page that posted it. A banner that timed out,
/// and every notification NotificationCenter filed without showing it, exists only in the history, which is
/// in the accessibility tree only while the history panel is open. The opener therefore presses the menu
/// bar clock, which opens the panel on the main display (AriSweedler/dotfiles notif-center, talon-axkit,
/// NotificationNanny), and moves the panel's window off-screen as soon as it is open, so the panel is never
/// seen. It then presses the entry with one of the notification's identifiers, expanding the app's stacks
/// first: a collapsed stack carries the identifier of its newest entry, and expanding it turns that entry
/// into an `AXNotificationCenterBanner` with the same identifier (OmniWM, SignalLadder). Finally it presses
/// the clock again to close the panel, and finishes once the panel is closed, so that the next sweep does
/// not move the closing panel back on screen.
///
/// `step(windows:application:clock:)` advances one request; `NotificationCenterMonitor` calls it on every
/// NotificationCenter event and on a short timer until it returns false.
@MainActor
final class NotificationHistoryOpener {
    /// How long a request may take before it gives up, closing the panel if it opened it.
    static let timeout: TimeInterval = 2
    /// How long the open panel is given to list its entries before a request that finds nothing gives up.
    static let listGrace: TimeInterval = 0.3
    /// How long an expanding stack is given before it is pressed again; a second press would collapse it.
    static let expansionGrace: TimeInterval = 0.5

    private struct Request {
        let identifiers: [String]
        let source: String
        let completion: @MainActor (Bool) -> Void
        let startedAt: Date
        var openedPanel = false
        var panelOpenedAt: Date?
        var expanded: [String: Date] = [:]
        /// Set once the outcome is known; the request then only waits for the panel to close.
        var opened: Bool?
    }

    private let now: () -> Date
    private var request: Request?
    var labels = NotificationCenterLabels.english

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    var isOpening: Bool { request != nil }

    /// Starts opening the first of `identifiers` the history holds, from the app named `source`; false when a
    /// request is already running.
    func start(_ identifiers: [String], from source: String, completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard request == nil else { return false }
        request = Request(identifiers: identifiers, source: source, completion: completion, startedAt: now())
        SystemNotificationInterceptor.logger.info("Opening \(identifiers, privacy: .public) from the history")
        return true
    }

    /// Abandons the request, which fails unless its outcome is known already.
    func cancel() {
        guard let request else { return }
        self.request = nil
        if request.opened == nil {
            request.completion(false)
        }
    }

    /// Advances the request; false once it is finished.
    @discardableResult
    func step(
        windows: [any AccessibilityElement],
        application: (any AccessibilityElement)?,
        clock: (any AccessibilityElement)?
    ) -> Bool {
        guard var request else { return false }
        let time = now()
        let panelOpen = NotificationBanners.isPanelOpen(application: application, windows: windows)
        // A panel the user opened stays where it is.
        if panelOpen, request.openedPanel {
            hide(windows)
        }
        if request.opened != nil {
            // Waiting for the panel to close.
            if !panelOpen || time.timeIntervalSince(request.startedAt) >= Self.timeout {
                self.request = nil
                return false
            }
            return true
        }
        if !request.openedPanel, !panelOpen {
            guard let clock, clock.perform(kAXPressAction) else {
                SystemNotificationInterceptor.logger.error("Cannot open Notification Center: no menu bar clock to press")
                return conclude(request, opened: false, panelOpen: false, clock: clock)
            }
            request.openedPanel = true
            self.request = request
            return true
        }
        guard time.timeIntervalSince(request.startedAt) < Self.timeout else {
            SystemNotificationInterceptor.logger.notice("Notification Center did not list \(request.identifiers, privacy: .public) in time")
            return conclude(request, opened: false, panelOpen: panelOpen, clock: clock)
        }
        guard panelOpen else {
            self.request = request
            return true
        }
        if request.panelOpenedAt == nil { request.panelOpenedAt = time }
        let items = windows.flatMap { NotificationBanners.find(in: $0) }
        let entries = items.filter { NotificationBanners.kind(of: $0) != .stack }
        for identifier in request.identifiers {
            guard let entry = entries.first(where: { $0.string(kAXIdentifierAttribute) == identifier }) else { continue }
            let opened = entry.perform(kAXPressAction)
            SystemNotificationInterceptor.logger.info("""
                Opening \(identifier, privacy: .public) from the history: \(opened ? "done" : "refused", privacy: .public)
                """)
            return conclude(request, opened: opened, panelOpen: panelOpen, clock: clock)
        }
        var expanding = false
        for stack in items where isStack(stack, holding: request) {
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
            return conclude(request, opened: false, panelOpen: panelOpen, clock: clock)
        }
        self.request = request
        return true
    }

    /// A collapsed stack that may hold the request's notification: one that carries one of its identifiers,
    /// or one from the same app.
    private func isStack(_ item: any AccessibilityElement, holding request: Request) -> Bool {
        guard NotificationBanners.kind(of: item) == .stack else { return false }
        if let identifier = item.string(kAXIdentifierAttribute), request.identifiers.contains(identifier) { return true }
        return !request.source.isEmpty && NotificationBanners.content(of: item, labels: labels).appName == request.source
    }

    /// Reports the outcome, then closes the panel if the request opened it; the request ends once the panel
    /// is closed. Returns whether the request is still running.
    private func conclude(_ request: Request, opened: Bool, panelOpen: Bool, clock: (any AccessibilityElement)?) -> Bool {
        var request = request
        request.opened = opened
        request.completion(opened)
        guard request.openedPanel, panelOpen, clock?.perform(kAXPressAction) == true else {
            self.request = nil
            return false
        }
        self.request = request
        return true
    }

    /// Moves the window holding the panel off-screen, so that the panel opens unseen.
    private func hide(_ windows: [any AccessibilityElement]) {
        for window in windows where window.string(kAXSubroleAttribute) == kAXSystemDialogSubrole {
            guard let position = window.position, position.x > -1000, position.y > -1000 else { continue }
            window.setPosition(SystemNotificationInterceptor.offScreen)
        }
    }
}
