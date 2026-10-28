import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Hides native notifications and reports each one's content once.
///
/// Notifications that need interaction (`NotificationBanners.needsInteraction`) stay visible as
/// macOS presents them and are reported with `shownByMacOS`, unless the settings list them without
/// their buttons instead. Alerts whose choices are all named actions (`NotificationBanners.choices`) are
/// the exception: they are hidden but left open, listed with their choices, performed through
/// `perform(_:onAlert:in:)`, and closed once their card is gone.
///
/// Every notification on screen shares NotificationCenter's single "Notification Center" window. A
/// banner that arrives while another notification is showing does not create a window: NotificationCenter
/// only reports a layout change on the banner itself (Tactile, SignalLadder). Each pass therefore looks
/// at whole windows rather than at the element an event names.
///
/// On macOS 26 NotificationCenter ignores position changes on the banner element, and its close
/// action only takes effect after the slide-in animation (about 1.3 s). Moving the window off-screen
/// hides its notifications immediately, so a window is hidden only when every notification in it is
/// intercepted (vorssaint-utils); one that holds a notification left to macOS stays on-screen, and its
/// intercepted banners stay visible until their close action works (MeetingMute). NotificationCenter
/// draws notifications at the right edge of its window, which covers the main display, and the sidebar
/// sits above it; such a window is therefore moved to `nativeOrigin`, beside the sidebar instead of under
/// it. NotificationCenter keeps a window where it was moved, and hit testing follows it, until it
/// discards the window once its notifications are closed; the next window starts at the origin again.
/// Windows moved off-screen or beside the sidebar are moved back by `restore(_:)`.
@MainActor
public final class SystemNotificationInterceptor {
    /// What the sidebar did to an alert it keeps hidden.
    private enum AlertStep: Equatable {
        /// An action performed from the card: a choice, or `AXPress` for a click.
        case performed(String)
        /// Its card is gone, so the sidebar presses Close until it leaves.
        case closing
    }

    nonisolated static let logger = Logger(category: "interception")
    static let offScreen = CGPoint(x: -5000, y: -5000)
    static let duplicateWindow: TimeInterval = 10
    /// How long a stack that was pressed is given to expand before it is pressed again. A second press
    /// while it is still expanding would collapse it.
    static let expansionGrace: TimeInterval = 2
    /// The source shown for notifications that macOS itself posts.
    static let systemSource = "macOS"
    /// How long an alert whose choice was just performed is given to go away before it is closed. Its
    /// card is dismissed as the choice is performed, which would otherwise close it at once.
    static let choiceGrace: TimeInterval = 2

    /// Whether a pass left work for a later one: notifications that are still closing, or stacks that
    /// are still expanding.
    public enum Outcome: Equatable, Sendable {
        case settled
        case pending
    }

    private let onNotification: @MainActor (SidebarNotification) -> Void
    private let leavesToMacOS: @MainActor (String) -> Bool
    private let bundleIdentifier: @MainActor (String) -> String?
    private let leavesActionableToMacOS: @MainActor () -> Bool
    private let listsAlert: @MainActor (String) -> Bool
    private let onPresentAlerts: @MainActor (Set<String>) -> Void
    private let nativeOrigin: @MainActor () -> CGPoint
    private let now: () -> Date
    private let identities: NotificationIdentities
    private var recentContent: [(content: BannerContent, at: Date)] = []
    private var expandedStacks: [String: Date] = [:]
    private var isPanelOpen = false
    /// Alerts kept hidden for a card that offers their choices; once their card is gone, they are closed.
    private var handedOverAlerts: Set<String> = []
    /// What the sidebar last did to a handed-over alert, and when, by identifier.
    private var alertSteps: [String: (step: AlertStep, at: Date)] = [:]
    /// Listed alerts found by the current sweep, unlisted ones it is closing, and the listed ones the last
    /// complete sweep reported.
    private var sweptAlerts: Set<String> = []
    private var closingAlerts: Set<String> = []
    private var presentAlerts: Set<String> = []
    /// Every notification identifier the current sweep found, handed over or not.
    private var sweptIdentifiers: Set<String> = []
    /// NotificationCenter's words in its current language; set when attaching to it.
    public var labels = NotificationCenterLabels.english

    /// - Parameters:
    ///   - identities: Notifications already listed, shared with `NotificationDatabaseMonitor`.
    ///   - leavesToMacOS: Whether an app's notifications stay native, by app name.
    ///   - bundleIdentifier: The bundle identifier of the app with a name, whose icon its notifications show.
    ///   - leavesActionableToMacOS: Whether notifications that need interaction stay native. Otherwise
    ///     they are hidden and listed like the others, without their buttons. Alerts whose choices the
    ///     sidebar offers are hidden either way.
    ///   - listsAlert: Whether the sidebar still has a card for the alert with this identifier.
    ///   - onPresentAlerts: Receives the identifiers of the listed alerts that still exist, after each
    ///     sweep that changes them.
    ///   - nativeOrigin: Where a window holding a notification left to macOS is placed, so that the
    ///     sidebar does not cover it.
    public init(
        now: @escaping () -> Date = Date.init,
        identities: NotificationIdentities = NotificationIdentities(),
        leavesToMacOS: @escaping @MainActor (String) -> Bool = { _ in false },
        bundleIdentifier: @escaping @MainActor (String) -> String? = { _ in nil },
        leavesActionableToMacOS: @escaping @MainActor () -> Bool = { true },
        listsAlert: @escaping @MainActor (String) -> Bool = { _ in false },
        onPresentAlerts: @escaping @MainActor (Set<String>) -> Void = { _ in },
        nativeOrigin: @escaping @MainActor () -> CGPoint = { .zero },
        onNotification: @escaping @MainActor (SidebarNotification) -> Void
    ) {
        self.now = now
        self.identities = identities
        self.leavesToMacOS = leavesToMacOS
        self.bundleIdentifier = bundleIdentifier
        self.leavesActionableToMacOS = leavesActionableToMacOS
        self.listsAlert = listsAlert
        self.onPresentAlerts = onPresentAlerts
        self.nativeOrigin = nativeOrigin
        self.onNotification = onNotification
    }

    /// One pass over NotificationCenter's windows. While the history panel is open nothing is touched and
    /// hidden windows are moved back, since the panel shares their window.
    @discardableResult
    public func sweep(windows: [any AccessibilityElement], application: (any AccessibilityElement)?) -> Outcome {
        let panelOpen = NotificationBanners.isPanelOpen(application: application, windows: windows)
        if panelOpen != isPanelOpen {
            isPanelOpen = panelOpen
            Self.logger.info("Notification Center panel \(panelOpen ? "opened; leaving it alone" : "closed", privacy: .public)")
        }
        if panelOpen {
            restore(windows)
            return .settled
        }
        sweptAlerts = []
        closingAlerts = []
        sweptIdentifiers = []
        let outcome: Outcome = windows.map(process(window:)).contains(.pending) ? .pending : .settled
        // An alert missing from a sweep is gone, or no longer offers its choices (Reply opened its text
        // field) and is left to macOS. Should a sweep miss one that is still there, it is left to macOS like
        // any other interactive notification the sidebar did not list with its choices.
        let remaining = handedOverAlerts.intersection(sweptAlerts.union(closingAlerts))
        for identifier in handedOverAlerts.subtracting(remaining) {
            logDeparture(of: identifier, returnedToMacOS: sweptIdentifiers.contains(identifier))
        }
        handedOverAlerts = remaining
        publishPresentAlerts(sweptAlerts)
        return outcome
    }

    /// No NotificationCenter is attached, so no alert can be acted on.
    public func detach() {
        publishPresentAlerts([])
    }

    /// Performs `action` on the alert with `identifier` in `windows`; false when it is not there, does
    /// not offer the choice, or neither reports success nor changes. NotificationCenter reports failure
    /// for Reply although it opens the alert's text field before the call returns, which changes the
    /// alert's actions (Show Details becomes Hide Details); an alert that is gone reports none.
    @discardableResult
    public func perform(_ action: AlertAction, onAlert identifier: String, in windows: [any AccessibilityElement]) -> Bool {
        let alert = windows.lazy.flatMap { NotificationBanners.find(in: $0) }.first { $0.string(kAXIdentifierAttribute) == identifier }
        guard let alert else { return false }
        let rawAction: String? = switch action {
        case .open: kAXPressAction
        case .choice(let name): alert.actionNames.first { NotificationBanners.actionName($0) == name }
        }
        guard let rawAction else { return false }
        alertSteps[identifier] = (.performed(NotificationBanners.actionName(rawAction)), now())
        let actionsBefore = alert.actionNames
        let succeeded = alert.perform(rawAction)
        let changed = !succeeded && alert.actionNames != actionsBefore
        let result = succeeded ? "done" : changed ? "reported failure, but the alert changed" : "refused"
        Self.logger.info("""
            Performing \(NotificationBanners.actionName(rawAction), privacy: .public) on alert \(identifier, privacy: .public): \
            \(result, privacy: .public)
            """)
        return succeeded || changed
    }

    private func publishPresentAlerts(_ alerts: Set<String>) {
        guard alerts != presentAlerts else { return }
        presentAlerts = alerts
        onPresentAlerts(alerts)
    }

    /// Expands stacks and closes the notifications in one window, reporting new ones. The window is moved
    /// off-screen unless it holds a notification left to macOS (an interactive one, while those stay
    /// native, or one from an app left to macOS); then it is moved to `nativeOrigin`.
    @discardableResult
    func process(window: any AccessibilityElement) -> Outcome {
        let items = NotificationBanners.find(in: window)
        guard !items.isEmpty else { return .settled }
        let leavesActionable = leavesActionableToMacOS()
        var keepsNative = false
        var outcome = Outcome.settled
        for item in items {
            guard let kind = NotificationBanners.kind(of: item) else { continue }
            let content = NotificationBanners.content(of: item, labels: labels)
            let identifier = item.string(kAXIdentifierAttribute)
            if let identifier { sweptIdentifiers.insert(identifier) }
            let leftToMacOS = leavesToMacOS(content.appName)
            if kind == .stack, !leftToMacOS {
                expand(item, identifier: identifier)
                outcome = .pending
                continue
            }
            if !leftToMacOS, let identifier, !identifier.isEmpty,
               let choices = NotificationBanners.choices(of: item, labels: labels),
               let alertOutcome = handOver(item, identifier: identifier, content: content, choices: choices) {
                if alertOutcome == .pending { outcome = .pending }
                continue
            }
            let shownByMacOS = leftToMacOS || (leavesActionable && NotificationBanners.needsInteraction(item, labels: labels))
            var closed = false
            if shownByMacOS {
                keepsNative = true
            } else {
                closed = NotificationBanners.dismiss(item, labels: labels)
                outcome = .pending
            }
            if report(content, identifier: identifier, shownByMacOS: shownByMacOS) {
                let decision = shownByMacOS ? "left to macOS" : closed ? "intercepted" : "intercepted, but has no close action"
                let actions = item.actionNames.map(NotificationBanners.actionName)
                Self.logger.info("""
                    \(String(describing: kind), privacy: .public) \(identifier ?? "", privacy: .public) \
                    from \(content.appName, privacy: .private): \(decision, privacy: .public); actions \(actions, privacy: .public)
                    """)
            }
        }
        if keepsNative {
            present(window)
        } else {
            hide(window)
        }
        return outcome
    }

    /// Keeps an alert with choices hidden while its card exists, lists it with them when it is new, and
    /// closes it once its card is gone. Nil when it was listed before without its choices, by the
    /// notification database, which leaves it to the handling of other interactive notifications.
    private func handOver(
        _ alert: any AccessibilityElement,
        identifier: String,
        content: BannerContent,
        choices: [String]
    ) -> Outcome? {
        if listsAlert(identifier) {
            // A card restored from the saved list counts too, so the alert closes when that card goes.
            identities.insert(identifier)
            handedOverAlerts.insert(identifier)
            sweptAlerts.insert(identifier)
            return .settled
        }
        if handedOverAlerts.contains(identifier) {
            closingAlerts.insert(identifier)
            let time = now()
            let last = alertSteps[identifier]
            if case .performed = last?.step, let at = last?.at, time.timeIntervalSince(at) < Self.choiceGrace {
                return .pending
            }
            let closed = NotificationBanners.dismiss(alert, labels: labels)
            // Close is pressed on every sweep until the alert goes, but logged once.
            if last?.step != .closing {
                alertSteps[identifier] = (.closing, time)
                Self.logger.info("Closing alert \(identifier, privacy: .public), whose card is gone: \(closed ? "closed" : "refused", privacy: .public)")
            }
            return .pending
        }
        let nativeAlert = SidebarNotification.NativeAlert(identifier: identifier, choices: choices)
        guard report(content, identifier: identifier, shownByMacOS: false, nativeAlert: nativeAlert) else { return nil }
        handedOverAlerts.insert(identifier)
        if listsAlert(identifier) {
            sweptAlerts.insert(identifier)
        }
        Self.logger.info("""
            alert \(identifier, privacy: .public) from \(content.appName, privacy: .private): hidden with its choices \
            \(choices, privacy: .public)
            """)
        return .settled
    }

    /// Records how a handed-over alert left NotificationCenter, or returned to macOS because it no longer
    /// offers its choices: after a choice performed from its card, after the sidebar closed it, or with no
    /// help from the sidebar (another device, the history panel).
    private func logDeparture(of identifier: String, returnedToMacOS: Bool) {
        let last = alertSteps.removeValue(forKey: identifier)
        let elapsed = last.map { String(format: "%.1f s", now().timeIntervalSince($0.at)) } ?? ""
        let reason = switch last?.step {
        case .performed(let action)?: "\(elapsed) after the sidebar performed \(action)"
        case .closing?: "\(elapsed) after the sidebar closed it"
        case nil: "without an action from the sidebar"
        }
        let departure = returnedToMacOS ? "returned to macOS" : "left NotificationCenter"
        Self.logger.info("Alert \(identifier, privacy: .public) \(departure, privacy: .public) \(reason, privacy: .public)")
    }

    /// Moves NotificationCenter windows that the sidebar moved, off-screen or beside the sidebar, back to
    /// the origin: the main display's top-left corner, where NotificationCenter places its window.
    public func restore(_ windows: [any AccessibilityElement]) {
        for window in windows {
            guard let position = window.position, position != .zero else { continue }
            let moved = window.setPosition(.zero)
            Self.logger.info("Restoring moved window: \(moved ? "moved" : "refused", privacy: .public)")
        }
    }

    /// Moves a window holding a notification left to macOS to `nativeOrigin`, out from under the sidebar.
    private func present(_ window: any AccessibilityElement) {
        let origin = nativeOrigin()
        guard let position = window.position, position != origin else { return }
        let moved = window.setPosition(origin)
        Self.logger.info("Moving window with native notifications to x \(origin.x, privacy: .public): \(moved ? "moved" : "refused", privacy: .public)")
    }

    /// Moves the window off-screen and checks that NotificationCenter kept the new position.
    private func hide(_ window: any AccessibilityElement) {
        guard !Self.isOffScreen(window) else { return }
        window.setPosition(Self.offScreen)
        if !Self.isOffScreen(window) {
            Self.logger.notice("NotificationCenter kept its window on-screen; banners stay visible until closed")
        }
    }

    private static func isOffScreen(_ window: any AccessibilityElement) -> Bool {
        guard let position = window.position else { return false }
        return position.x <= -1000 || position.y <= -1000
    }

    /// Presses a collapsed stack so its notifications appear one by one, unless it was pressed within
    /// `expansionGrace`.
    private func expand(_ stack: any AccessibilityElement, identifier: String?) {
        let key = identifier ?? stack.string(kAXDescriptionAttribute) ?? ""
        let time = now()
        expandedStacks = expandedStacks.filter { time.timeIntervalSince($0.value) < Self.expansionGrace }
        guard expandedStacks[key] == nil else { return }
        expandedStacks[key] = time
        let pressed = stack.perform(kAXPressAction)
        Self.logger.info("Expanding stack \(key, privacy: .private): \(pressed ? "pressed" : "refused", privacy: .public)")
    }

    /// Lists the notification unless it was listed before; true when it was new.
    private func report(
        _ content: BannerContent,
        identifier: String?,
        shownByMacOS: Bool,
        nativeAlert: SidebarNotification.NativeAlert? = nil
    ) -> Bool {
        guard isNew(identifier: identifier, content: content) else { return false }
        onNotification(SidebarNotification(
            source: content.appName.isEmpty ? Self.systemSource : content.appName,
            title: content.title,
            subtitle: content.subtitle,
            body: content.body,
            bundleIdentifier: content.appName.isEmpty ? nil : bundleIdentifier(content.appName),
            action: content.appName.isEmpty ? nil : .activateApp(name: content.appName),
            shownByMacOS: shownByMacOS,
            nativeAlert: nativeAlert,
            receivedAt: now()
        ))
        return true
    }

    /// NotificationCenter reports the same notification on every pass while it shows. Each one carries a
    /// UUID as its `AXIdentifier`, which survives stack expansion and NotificationCenter restarts
    /// (SignalLadder, Tactile), so notifications are remembered by it. Only a notification without one is
    /// compared by content, which is ignored when identical within `duplicateWindow` seconds; comparing
    /// identified ones by content would drop genuine repeats, which `SidebarModel` stacks instead.
    private func isNew(identifier: String?, content: BannerContent) -> Bool {
        guard !content.isEmpty else { return false }
        if let identifier, !identifier.isEmpty {
            return identities.insert(identifier)
        }
        let time = now()
        recentContent.removeAll { time.timeIntervalSince($0.at) > Self.duplicateWindow }
        if recentContent.contains(where: { $0.content == content }) { return false }
        recentContent.append((content, time))
        return true
    }
}
