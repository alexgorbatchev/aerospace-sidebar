import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Hides native notifications and reports each one's content once.
///
/// Notifications that need interaction (`NotificationBanners.needsInteraction`) stay visible as
/// macOS presents them and are reported with `shownByMacOS`, unless the settings list them without
/// their buttons instead. The others are hidden but left open while their card exists, so that a click on
/// the card can open them as a click in macOS would (`perform(_:on:in:)`), and closed once their card is gone; a
/// banner that times out meanwhile moves to Notification Center's history like any other. Notifications whose
/// choices the sidebar can offer (`NotificationBanners.choices`: what their app declared, or an alert's few
/// named actions) are hidden whatever the settings say, listed with their choices and performed through
/// `perform(_:on:in:)`, unless a card already lists them without their choices. Their cards offer the choices
/// until the interceptor learns that the notification no longer does (`onUnavailableChoices`): a banner that
/// leaves the screen on its own keeps them, since its history entry offers the same actions, while an alert
/// never goes to the history. Notifications without an identifier cannot be told apart later, so they are
/// closed. Notifications whose texts do not read are left as macOS shows them until a later pass reads them,
/// unless the sidebar already keeps them hidden for a card or is closing them.
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
    /// What the sidebar did to a notification it keeps hidden.
    private enum HiddenStep: Equatable {
        /// An action performed from the card: a choice, or `AXPress` for a click.
        case performed(String)
        /// A reply sent from the card. The notification shows its text field until it leaves.
        case replied
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
    /// How long a notification that was just opened, or whose choice was just performed, is given to go away
    /// before it is closed. Its card is dismissed at the same time, which would otherwise close it at once.
    static let choiceGrace: TimeInterval = 2

    /// Whether a pass left work for a later one: notifications that are still closing, or stacks that
    /// are still expanding.
    public enum Outcome: Equatable, Sendable {
        case settled
        case pending
    }

    /// What `perform(_:on:in:)` came to.
    public enum PerformOutcome: Equatable, Sendable {
        case performed
        /// The notification is there but did not take the action.
        case refused
        /// None of the notifications is on screen or hidden; it may be in the history.
        case absent
    }

    private let onNotification: @MainActor (SidebarNotification) -> Void
    private let leavesToMacOS: @MainActor (String) -> Bool
    private let bundleIdentifier: @MainActor (String) -> String?
    private let leavesActionableToMacOS: @MainActor () -> Bool
    private let listsNotification: @MainActor (String) -> Bool
    private let listsChoices: @MainActor (String) -> Bool
    private let declaredChoices: @MainActor (_ bundleIdentifier: String, _ titles: [String]) -> [NativeChoice]?
    private let onUnavailableChoices: @MainActor (Set<String>) -> Void
    private let nativeOrigin: @MainActor () -> CGPoint
    private let now: () -> Date
    private let identities: NotificationIdentities
    private var recentContent: [(content: BannerContent, at: Date)] = []
    private var expandedStacks: [String: Date] = [:]
    private var isPanelOpen = false
    /// Notifications kept hidden for their card; once their card is gone, they are closed.
    private var handedOver: Set<String> = []
    /// What the sidebar last did to a handed-over notification, and when, by identifier.
    private var hiddenSteps: [String: (step: HiddenStep, at: Date)] = [:]
    /// Listed notifications found by the current sweep, and unlisted ones it is closing.
    private var sweptHidden: Set<String> = []
    private var closingHidden: Set<String> = []
    /// Alerts kept hidden with the choices their cards offer. Alerts never go to the history, so one that leaves
    /// the screen without a step from the sidebar is gone.
    private var alertsWithChoices: Set<String> = []
    /// Notifications whose cards offer their choices although they no longer can (`onUnavailableChoices`).
    private var unavailableChoices: Set<String> = []
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
    ///   - listsNotification: Whether the sidebar still has a card for the notification with this identifier.
    ///   - listsChoices: Whether one of those cards lists the choices of the notification with this identifier.
    ///   - declaredChoices: What the app with a bundle identifier declared for a notification whose choices
    ///     NotificationCenter titles so (`DeclaredChoices`); nil when it declared nothing under those titles.
    ///   - onUnavailableChoices: Receives the identifiers of the notifications whose cards offer their choices
    ///     although the notifications no longer offer them, whenever that set changes: an alert that left the
    ///     screen on its own, one that returned to macOS because it holds a control only macOS presents, and
    ///     one whose choice found it nowhere (`choicesGone(of:)`). One found offering them again leaves the set.
    ///   - nativeOrigin: Where a window holding a notification left to macOS is placed, so that the
    ///     sidebar does not cover it.
    public init(
        now: @escaping () -> Date = Date.init,
        identities: NotificationIdentities = NotificationIdentities(),
        leavesToMacOS: @escaping @MainActor (String) -> Bool = { _ in false },
        bundleIdentifier: @escaping @MainActor (String) -> String? = { _ in nil },
        leavesActionableToMacOS: @escaping @MainActor () -> Bool = { true },
        listsNotification: @escaping @MainActor (String) -> Bool = { _ in false },
        listsChoices: @escaping @MainActor (String) -> Bool = { _ in false },
        declaredChoices: @escaping @MainActor (_ bundleIdentifier: String, _ titles: [String]) -> [NativeChoice]? = { _, _ in nil },
        onUnavailableChoices: @escaping @MainActor (Set<String>) -> Void = { _ in },
        nativeOrigin: @escaping @MainActor () -> CGPoint = { .zero },
        onNotification: @escaping @MainActor (SidebarNotification) -> Void
    ) {
        self.now = now
        self.identities = identities
        self.leavesToMacOS = leavesToMacOS
        self.bundleIdentifier = bundleIdentifier
        self.leavesActionableToMacOS = leavesActionableToMacOS
        self.listsNotification = listsNotification
        self.listsChoices = listsChoices
        self.declaredChoices = declaredChoices
        self.onUnavailableChoices = onUnavailableChoices
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
        sweptHidden = []
        closingHidden = []
        sweptIdentifiers = []
        let reported = unavailableChoices
        let outcome: Outcome = windows.map(process(window:)).contains(.pending) ? .pending : .settled
        // A notification missing from a sweep is gone (a banner that timed out is in the history now), or it
        // needs interaction (Reply opened an alert's text field) and is left to macOS. Should a sweep miss one
        // that is still there, it is left to macOS like any other notification the sidebar does not hide.
        let remaining = handedOver.intersection(sweptHidden.union(closingHidden))
        for identifier in handedOver.subtracting(remaining) {
            let returnedToMacOS = sweptIdentifiers.contains(identifier)
            // A banner that timed out keeps its choices in the history. An alert never goes there, and one back with
            // macOS holds a control that works only on screen; should either turn up again with its choices, the
            // sweep that finds it offers them again.
            if returnedToMacOS || (alertsWithChoices.contains(identifier) && hiddenSteps[identifier] == nil) {
                unavailableChoices.insert(identifier)
            }
            logDeparture(of: identifier, returnedToMacOS: returnedToMacOS)
        }
        handedOver = remaining
        alertsWithChoices.formIntersection(remaining)
        reportUnavailableChoices(since: reported)
        return outcome
    }

    /// A choice on the notification found it neither on screen, hidden, nor in the history: it is gone, and its
    /// card stops offering its choices.
    public func choicesGone(of identifier: String) {
        let reported = unavailableChoices
        unavailableChoices.insert(identifier)
        reportUnavailableChoices(since: reported)
    }

    /// Performs `action` on the first of `identifiers`, newest first, that is in `windows`, as the same action on
    /// it in macOS would (`NotificationBanners.perform(_:on:labels:)`). Only notifications themselves count:
    /// pressing a stack would expand it instead.
    @discardableResult
    public func perform(_ action: NativeAction, on identifiers: [String], in windows: [any AccessibilityElement]) -> PerformOutcome {
        var present: [String: any AccessibilityElement] = [:]
        for notification in windows.flatMap({ NotificationBanners.find(in: $0) }) where NotificationBanners.kind(of: notification) != .stack {
            if let identifier = notification.string(kAXIdentifierAttribute), present[identifier] == nil {
                present[identifier] = notification
            }
        }
        guard let identifier = identifiers.first(where: { present[$0] != nil }), let notification = present[identifier] else {
            return .absent
        }
        let performed = NotificationBanners.perform(action, on: notification, labels: labels)
        if performed {
            let step: HiddenStep = if case .reply = action { .replied } else { .performed(action.logDescription) }
            hiddenSteps[identifier] = (step, now())
        }
        Self.logger.info("""
            Performing \(action.logDescription, privacy: .public) on notification \(identifier, privacy: .public): \
            \(performed ? "done" : "refused", privacy: .public)
            """)
        return performed ? .performed : .refused
    }

    /// Reports the notifications whose cards offer choices they no longer have when they differ from those
    /// `reported` before; those no card offers choices for any more drop out.
    private func reportUnavailableChoices(since reported: Set<String>) {
        unavailableChoices = unavailableChoices.filter(listsChoices)
        guard unavailableChoices != reported else { return }
        onUnavailableChoices(unavailableChoices)
    }

    /// Expands stacks and hides or closes the notifications in one window, reporting new ones. The window is
    /// moved off-screen unless it holds a notification left to macOS (an interactive one, while those stay
    /// native, or one from an app left to macOS); then it is moved to `nativeOrigin`. Only the window
    /// `restore(_:)` moves back is processed, so a window the sidebar moves never stays hidden. Listed
    /// notifications found offering their choices leave `unavailableChoices`.
    @discardableResult
    func process(window: any AccessibilityElement) -> Outcome {
        guard NotificationBanners.isNotificationWindow(window) else { return .settled }
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
            // Closing a permission request would deny the app, and a card that goes away (dismissed, cleared,
            // expired, hidden by a rule) closes its notification; macOS presents the request and its answers.
            // Remembering its identifier keeps the notification database from listing it later.
            if NotificationBanners.isPermissionRequest(content, labels: labels) {
                keepsNative = true
                if let identifier, identities.insert(identifier) {
                    Self.logger.info("Permission request \(identifier, privacy: .public): left to macOS")
                }
                continue
            }
            // Texts that do not read (yet) say neither what to list nor whether macOS asks for permission, and
            // closing the notification would lose it: usernoted records a notification only seconds after
            // delivering it. It stays as macOS shows it until a later sweep reads it. A notification the
            // sidebar already keeps hidden for its card, or is closing, needs no texts and stays in its care:
            // showing it would show every notification hidden in its window, and forgetting it would leave an
            // alert whose choice was just performed to macOS instead of closing it.
            if content.isEmpty, !(identifier.map(handedOver.contains) ?? false) {
                keepsNative = true
                outcome = .pending
                continue
            }
            let leftToMacOS = leavesToMacOS(content.appName)
            if kind == .stack, !leftToMacOS {
                expand(item, identifier: identifier)
                outcome = .pending
                continue
            }
            let step = identifier.flatMap { hiddenSteps[$0]?.step }
            // A choice the app did not declare can turn out to open a text field (Reply on an NSUserNotification
            // alert), which only macOS can take typing for, whatever the settings say.
            let openedField = if case .performed = step { NotificationBanners.textField(in: item) != nil } else { false }
            let needsInteraction = (leavesActionable || openedField) && NotificationBanners.needsInteraction(item, labels: labels)
            if !leftToMacOS, let identifier, !identifier.isEmpty {
                let choices = offeredChoices(of: item, identifier: identifier, appName: content.appName)
                // A reply sent from the card leaves its field showing while the notification leaves; it stays hidden.
                if choices != nil || !needsInteraction || step == .replied,
                   let hiddenOutcome = handOver(item, kind: kind, identifier: identifier, content: content, choices: choices) {
                    if hiddenOutcome == .pending { outcome = .pending }
                    if choices != nil, listsChoices(identifier) {
                        unavailableChoices.remove(identifier)
                        if kind == .alert { alertsWithChoices.insert(identifier) }
                    }
                    continue
                }
            }
            let shownByMacOS = leftToMacOS || needsInteraction
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

    /// The choices the sidebar offers for a notification, unless a card already lists it without them: one the
    /// notification database listed first from a record that names no choices, or one listed as shown by macOS
    /// that the database has not given choices since. That card cannot offer them, so the notification is
    /// handled like any other interactive one.
    /// A card that offers them keeps them while they remain named actions only, whatever the database says now.
    private func offeredChoices(of notification: any AccessibilityElement, identifier: String, appName: String) -> [NativeChoice]? {
        if listsNotification(identifier) {
            guard listsChoices(identifier) else { return nil }
            return NotificationBanners.namedChoices(of: notification, labels: labels)?.map { NativeChoice(title: $0) }
        }
        let app = appName.isEmpty ? nil : bundleIdentifier(appName)
        return NotificationBanners.choices(of: notification, labels: labels) { titles in
            app.flatMap { declaredChoices($0, titles) }
        }
    }

    /// Keeps a notification hidden while its card exists, lists it when it is new (an alert with its
    /// choices), and closes it once its card is gone. Nil when it was listed before, by the notification
    /// database or before its card was dismissed, which leaves it to the handling of other notifications.
    private func handOver(
        _ notification: any AccessibilityElement,
        kind: NotificationBanners.Kind,
        identifier: String,
        content: BannerContent,
        choices: [NativeChoice]?
    ) -> Outcome? {
        if listsNotification(identifier) {
            // A card restored from the saved list counts too, so the notification closes when that card goes, and
            // so does a card that now offers the choices the notification database named for it.
            identities.insert(identifier)
            if handedOver.insert(identifier).inserted {
                Self.logger.info("""
                    \(String(describing: kind), privacy: .public) \(identifier, privacy: .public): hidden for the card that \
                    lists it\(choices.map { " with its choices \($0.map(\.title))" } ?? "", privacy: .public)
                    """)
            }
            sweptHidden.insert(identifier)
            return .settled
        }
        if handedOver.contains(identifier) {
            closingHidden.insert(identifier)
            let time = now()
            let last = hiddenSteps[identifier]
            if let last, last.step != .closing, time.timeIntervalSince(last.at) < Self.choiceGrace {
                return .pending
            }
            let closed = NotificationBanners.dismiss(notification, labels: labels)
            // Close is pressed on every sweep until the notification goes, but logged once.
            if last?.step != .closing {
                hiddenSteps[identifier] = (.closing, time)
                Self.logger.info("Closing notification \(identifier, privacy: .public), whose card is gone: \(closed ? "closed" : "refused", privacy: .public)")
            }
            return .pending
        }
        let nativeChoices = choices.map { SidebarNotification.NativeChoices(identifier: identifier, choices: $0) }
        guard report(content, identifier: identifier, shownByMacOS: false, nativeChoices: nativeChoices) else { return nil }
        handedOver.insert(identifier)
        if listsNotification(identifier) {
            sweptHidden.insert(identifier)
        }
        let handling = choices.map { "hidden with its choices \($0.map(\.title))" } ?? "hidden until its card goes"
        let actions = notification.actionNames.map(NotificationBanners.actionName)
        Self.logger.info("""
            \(String(describing: kind), privacy: .public) \(identifier, privacy: .public) from \(content.appName, privacy: .private): \
            \(handling, privacy: .public); actions \(actions, privacy: .public)
            """)
        return .settled
    }

    /// Records how a handed-over notification left NotificationCenter's banners, or returned to macOS because
    /// it needs interaction: after an action performed from its card, after the sidebar closed it, or with no
    /// help from the sidebar (a banner timing out into the history, another device, the history panel).
    private func logDeparture(of identifier: String, returnedToMacOS: Bool) {
        let last = hiddenSteps.removeValue(forKey: identifier)
        let elapsed = last.map { String(format: "%.1f s", now().timeIntervalSince($0.at)) } ?? ""
        let reason = switch last?.step {
        case .performed(let action)?: "\(elapsed) after the sidebar performed \(action)"
        case .replied?: "\(elapsed) after the sidebar sent a reply"
        case .closing?: "\(elapsed) after the sidebar closed it"
        case nil: "without an action from the sidebar"
        }
        let departure = returnedToMacOS ? "returned to macOS" : "left the banners"
        Self.logger.info("Notification \(identifier, privacy: .public) \(departure, privacy: .public) \(reason, privacy: .public)")
    }

    /// Moves NotificationCenter windows that the sidebar moved, off-screen or beside the sidebar, back to
    /// the origin: the main display's top-left corner, where NotificationCenter places its window. Only the
    /// window that holds the notifications and the history panel counts
    /// (`NotificationBanners.isNotificationWindow`): the desktop widgets' windows sit on other displays at
    /// origins of their own that look the same as the ones the sidebar sets.
    public func restore(_ windows: [any AccessibilityElement]) {
        for window in windows where NotificationBanners.isNotificationWindow(window) {
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
        window.position.map(isOffScreen) ?? false
    }

    /// Whether a window at `position` is out of sight, where `offScreen` puts it.
    static func isOffScreen(_ position: CGPoint) -> Bool {
        position.x <= -1000 || position.y <= -1000
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
        nativeChoices: SidebarNotification.NativeChoices? = nil
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
            nativeChoices: nativeChoices,
            nativeIdentifiers: identifier.flatMap { $0.isEmpty ? nil : [$0] } ?? [],
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

extension NativeAction {
    /// The action as the log names it; never the text of a reply.
    var logDescription: String {
        switch self {
        case .open: kAXPressAction
        case .choice(let title): title
        case .reply(let choice, _, _): "\(choice) with a reply"
        }
    }
}
