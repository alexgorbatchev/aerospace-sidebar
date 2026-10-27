import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Hides native notifications and reports each one's content once.
///
/// Notifications that need interaction (`NotificationBanners.needsInteraction`) stay visible as
/// macOS presents them and are reported with `shownByMacOS`, unless the settings list them without
/// their buttons instead.
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

    /// Whether a pass left work for a later one: notifications that are still closing, or stacks that
    /// are still expanding.
    public enum Outcome: Equatable, Sendable {
        case settled
        case pending
    }

    private let onNotification: @MainActor (SidebarNotification) -> Void
    private let leavesToMacOS: @MainActor (String) -> Bool
    private let leavesActionableToMacOS: @MainActor () -> Bool
    private let now: () -> Date
    private let identities: NotificationIdentities
    private var recentContent: [(content: BannerContent, at: Date)] = []
    private var expandedStacks: [String: Date] = [:]
    private var isPanelOpen = false
    /// NotificationCenter's words in its current language; set when attaching to it.
    public var labels = NotificationCenterLabels.english

    /// - Parameters:
    ///   - identities: Notifications already listed, shared with `NotificationDatabaseMonitor`.
    ///   - leavesToMacOS: Whether an app's notifications stay native, by app name.
    ///   - leavesActionableToMacOS: Whether notifications that need interaction stay native. Otherwise
    ///     they are hidden and listed like the others, without their buttons.
    public init(
        now: @escaping () -> Date = Date.init,
        identities: NotificationIdentities = NotificationIdentities(),
        leavesToMacOS: @escaping @MainActor (String) -> Bool = { _ in false },
        leavesActionableToMacOS: @escaping @MainActor () -> Bool = { true },
        onNotification: @escaping @MainActor (SidebarNotification) -> Void
    ) {
        self.now = now
        self.identities = identities
        self.leavesToMacOS = leavesToMacOS
        self.leavesActionableToMacOS = leavesActionableToMacOS
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
        return windows.map(process(window:)).contains(.pending) ? .pending : .settled
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
    private func report(_ content: BannerContent, identifier: String?, shownByMacOS: Bool) -> Bool {
        guard isNew(identifier: identifier, content: content) else { return false }
        onNotification(SidebarNotification(
            source: content.appName.isEmpty ? Self.systemSource : content.appName,
            title: content.title,
            subtitle: content.subtitle,
            body: content.body,
            action: content.appName.isEmpty ? nil : .activateApp(name: content.appName),
            shownByMacOS: shownByMacOS,
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
