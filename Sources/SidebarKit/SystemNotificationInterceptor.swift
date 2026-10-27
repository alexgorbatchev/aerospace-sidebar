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
/// discards a window once its notifications are closed. Windows left off-screen are moved back by
/// `restore(_:)`.
@MainActor
public final class SystemNotificationInterceptor {

    nonisolated static let logger = Logger(subsystem: "com.alexgorbatchev.aerospace-sidebar", category: "interception")
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
    private let leavesActionableToMacOS: @MainActor () -> Bool
    private let listsAlert: @MainActor (String) -> Bool
    private let onPresentAlerts: @MainActor (Set<String>) -> Void
    private let now: () -> Date
    private let identities: NotificationIdentities
    private var recentContent: [(content: BannerContent, at: Date)] = []
    private var expandedStacks: [String: Date] = [:]
    private var isPanelOpen = false
    /// Alerts kept hidden for a card that offers their choices; once their card is gone, they are closed.
    private var handedOverAlerts: Set<String> = []
    /// When a choice was last performed on an alert, by identifier.
    private var chosenAlerts: [String: Date] = [:]
    /// Listed alerts found by the current sweep, unlisted ones it is closing, and the listed ones the last
    /// complete sweep reported.
    private var sweptAlerts: Set<String> = []
    private var closingAlerts: Set<String> = []
    private var presentAlerts: Set<String> = []
    /// NotificationCenter's words in its current language; set when attaching to it.
    public var labels = NotificationCenterLabels.english

    /// - Parameters:
    ///   - identities: Notifications already listed, shared with `NotificationDatabaseMonitor`.
    ///   - leavesToMacOS: Whether an app's notifications stay native, by app name.
    ///   - leavesActionableToMacOS: Whether notifications that need interaction stay native. Otherwise
    ///     they are hidden and listed like the others, without their buttons. Alerts whose choices the
    ///     sidebar offers are hidden either way.
    ///   - listsAlert: Whether the sidebar still has a card for the alert with this identifier.
    ///   - onPresentAlerts: Receives the identifiers of the listed alerts that still exist, after each
    ///     sweep that changes them.
    public init(
        now: @escaping () -> Date = Date.init,
        identities: NotificationIdentities = NotificationIdentities(),
        leavesToMacOS: @escaping @MainActor (String) -> Bool = { _ in false },
        leavesActionableToMacOS: @escaping @MainActor () -> Bool = { true },
        listsAlert: @escaping @MainActor (String) -> Bool = { _ in false },
        onPresentAlerts: @escaping @MainActor (Set<String>) -> Void = { _ in },
        onNotification: @escaping @MainActor (SidebarNotification) -> Void
    ) {
        self.now = now
        self.identities = identities
        self.leavesToMacOS = leavesToMacOS
        self.leavesActionableToMacOS = leavesActionableToMacOS
        self.listsAlert = listsAlert
        self.onPresentAlerts = onPresentAlerts
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
        let outcome: Outcome = windows.map(process(window:)).contains(.pending) ? .pending : .settled
        // An alert missing from a sweep is gone. Should a sweep miss one that is still there, it is left to
        // macOS like any other interactive notification the sidebar did not list with its choices.
        handedOverAlerts.formIntersection(sweptAlerts.union(closingAlerts))
        publishPresentAlerts(sweptAlerts)
        return outcome
    }

    /// No NotificationCenter is attached, so no alert can be acted on.
    public func detach() {
        publishPresentAlerts([])
    }

    /// Performs `action` on the alert with `identifier` in `windows`; false when it is not there or does
    /// not offer the choice.
    @discardableResult
    public func perform(_ action: AlertAction, onAlert identifier: String, in windows: [any AccessibilityElement]) -> Bool {
        let alert = windows.lazy.flatMap { NotificationBanners.find(in: $0) }.first { $0.string(kAXIdentifierAttribute) == identifier }
        guard let alert else { return false }
        let rawAction: String? = switch action {
        case .open: kAXPressAction
        case .choice(let name): alert.actionNames.first { NotificationBanners.actionName($0) == name }
        }
        guard let rawAction else { return false }
        chosenAlerts[identifier] = now()
        let performed = alert.perform(rawAction)
        Self.logger.info("""
            Performing \(NotificationBanners.actionName(rawAction), privacy: .public) on alert \(identifier, privacy: .public): \
            \(performed ? "done" : "refused", privacy: .public)
            """)
        return performed
    }

    private func publishPresentAlerts(_ alerts: Set<String>) {
        guard alerts != presentAlerts else { return }
        presentAlerts = alerts
        onPresentAlerts(alerts)
    }

    /// Expands stacks and closes the notifications in one window, reporting new ones. The window is moved
    /// off-screen unless it holds a notification left to macOS (an interactive one, while those stay
    /// native, or one from an app left to macOS); then it stays on-screen and is moved back if it was hidden.
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
            restore([window])
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
            chosenAlerts = chosenAlerts.filter { time.timeIntervalSince($0.value) < Self.choiceGrace }
            guard chosenAlerts[identifier] == nil else { return .pending }
            let closed = NotificationBanners.dismiss(alert, labels: labels)
            Self.logger.info("Closing alert \(identifier, privacy: .public), whose card is gone: \(closed ? "closed" : "refused", privacy: .public)")
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

    /// Moves NotificationCenter windows that an earlier hide left off-screen back to the origin.
    public func restore(_ windows: [any AccessibilityElement]) {
        for window in windows where Self.isOffScreen(window) {
            let moved = window.setPosition(.zero)
            Self.logger.info("Restoring hidden window: \(moved ? "moved" : "refused", privacy: .public)")
        }
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
