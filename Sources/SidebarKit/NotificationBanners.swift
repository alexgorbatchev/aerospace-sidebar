import ApplicationServices
import CoreGraphics

/// Accessibility access to one UI element. `AXElement` wraps `AXUIElement`; tests use fakes.
@MainActor
public protocol AccessibilityElement {
    func string(_ attribute: String) -> String?
    /// A boolean attribute such as `AXExpanded`.
    func bool(_ attribute: String) -> Bool?
    var children: [any AccessibilityElement] { get }
    var actionNames: [String] { get }
    @discardableResult func perform(_ action: String) -> Bool
    var position: CGPoint? { get }
    @discardableResult func setPosition(_ point: CGPoint) -> Bool
}

/// Text read from one NotificationCenter banner.
public struct BannerContent: Equatable, Sendable {
    /// The posting app, or empty for a notification from macOS itself.
    public var appName = ""
    public var title = ""
    public var subtitle = ""
    public var body = ""

    var isEmpty: Bool { title.isEmpty && body.isEmpty }
}

/// Reads, expands and dismisses NotificationCenter notifications through the accessibility tree.
///
/// Observed NotificationCenter behavior on macOS 26:
/// - Notifications are elements with one of the subroles in `kinds`, nested a few levels below the
///   "Notification Center" window (subrole `AXSystemDialog`). Every banner and alert on screen shares
///   that one window, and so does the history panel while it is open.
/// - Alerts from one app collapse into an `AXNotificationCenterAlertStack` that exposes only the newest
///   alert's text and ends its description with ", stacked". Pressing the stack expands it into one
///   `AXNotificationCenterAlert` per notification, next to a heading and "Show Less" and "Clear" buttons.
///   `AXNotificationCenterBannerStack` groups entries in the history panel (macos-notification-cli,
///   AriSweedler/dotfiles notif-center, SignalLadder, OmniWM).
/// - The banner's `AXDescription` starts with the posting app's name, followed by ", ". macOS's own
///   notifications, such as Disk Not Ejected Properly, have no app: their description starts with the title.
/// - Text elements carry an `AXIdentifier` of `title`, `subtitle` or `body`.
/// - A plain banner exposes exactly the actions in `plainBannerActions`; notification actions such as
///   Snooze, Join or Reply appear as additional named actions or as controls inside the banner.
/// - Alert-style notifications (`AXNotificationCenterAlert`) stay on screen until dismissed, like the
///   sidebar's own cards. They are judged by their actions and controls like any banner.
@MainActor
public enum NotificationBanners {
    public static let plainBannerActions: Set<String> = ["AXPress", "AXShowMenu", "AXScrollToVisible", "Show Details", "Show", "Close"]
    static let interactiveRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXCheckBoxRole,
    ]

    public enum Kind: Equatable, Sendable {
        /// A temporary notification that slides away on its own.
        case banner
        /// A persistent notification that stays until dismissed.
        case alert
        /// Several notifications from one app, collapsed into one entry.
        case stack
    }

    /// Matched exactly: NotificationCenter has other `AXNotificationCenter…` subroles, such as
    /// `AXNotificationCenterNextFocus` (AnyDoor).
    public static let kinds: [String: Kind] = [
        "AXNotificationCenterBanner": .banner,
        "AXNotificationCenterAlert": .alert,
        "AXNotificationCenterBannerStack": .stack,
        "AXNotificationCenterAlertStack": .stack,
    ]

    /// Present only while Notification Center's history panel is open (AnyDoor, OmniWM).
    static let panelMarker = "widget-editor-button"

    public static func kind(of element: any AccessibilityElement) -> Kind? {
        element.string(kAXSubroleAttribute).flatMap { kinds[$0] }
    }

    /// Notification elements under `root`, without descending into a notification.
    public static func find(in root: any AccessibilityElement, maxDepth: Int = 6) -> [any AccessibilityElement] {
        if kind(of: root) != nil {
            return [root]
        }
        guard maxDepth > 0 else { return [] }
        return root.children.flatMap { find(in: $0, maxDepth: maxDepth - 1) }
    }

    /// Whether Notification Center's history panel is open. Its entries share the banners' window and
    /// subroles, so they must be left alone: closing them would delete the user's history. The
    /// NotificationCenter application reports `AXExpanded` while the panel is open (AnyDoor), and the panel
    /// shows an Edit Widgets button with `panelMarker` as its identifier (AnyDoor, OmniWM).
    public static func isPanelOpen(application: (any AccessibilityElement)?, windows: [any AccessibilityElement]) -> Bool {
        application?.bool("AXExpanded") == true || windows.contains { contains(identifier: panelMarker, in: $0, maxDepth: 6) }
    }

    private static func contains(identifier: String, in element: any AccessibilityElement, maxDepth: Int) -> Bool {
        if element.string(kAXIdentifierAttribute) == identifier { return true }
        guard maxDepth > 0 else { return false }
        return element.children.contains { contains(identifier: identifier, in: $0, maxDepth: maxDepth - 1) }
    }

    public static func content(of banner: any AccessibilityElement) -> BannerContent {
        var content = BannerContent()
        if let description = banner.string(kAXDescriptionAttribute),
           let appName = description.components(separatedBy: ", ").first {
            content.appName = appName
        }
        var unlabeled: [String] = []
        collectTexts(in: banner) { identifier, value in
            switch identifier {
            case "title": content.title = value
            case "subtitle": content.subtitle = value
            case "body": content.body = value
            default: unlabeled.append(value)
            }
        }
        // Texts without an identifier fill the remaining fields in reading order.
        for value in unlabeled {
            if content.title.isEmpty {
                content.title = value
            } else if content.subtitle.isEmpty {
                content.subtitle = value
            } else if content.body.isEmpty {
                content.body = value
            }
        }
        if content.appName == content.title {
            content.appName = ""
        }
        return content
    }

    /// Whether the notification offers a choice that only macOS can present: an action other than
    /// opening or closing it, a reply field, or a control other than a close, Show or Show Details button.
    public static func needsInteraction(_ banner: any AccessibilityElement) -> Bool {
        if banner.actionNames.map(actionName).contains(where: { !plainBannerActions.contains($0) }) { return true }
        return containsControl(banner)
    }

    /// `AXUIElementCopyActionNames` reports custom actions as "Name:<title>\nTarget:…\nSelector:…".
    static func actionName(_ raw: String) -> String {
        let firstLine = raw.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? raw
        return firstLine.hasPrefix("Name:") ? String(firstLine.dropFirst(5)) : firstLine
    }

    private static func containsControl(_ element: any AccessibilityElement) -> Bool {
        element.children.contains { child in
            if let role = child.string(kAXRoleAttribute), interactiveRoles.contains(role), !isPlainButton(child) {
                return true
            }
            return containsControl(child)
        }
    }

    /// A close button, or a button that does what one of `plainBannerActions` does, such as Close or Show.
    private static func isPlainButton(_ element: any AccessibilityElement) -> Bool {
        guard element.string(kAXRoleAttribute) == kAXButtonRole else { return false }
        if element.string(kAXSubroleAttribute) == kAXCloseButtonSubrole { return true }
        let name = element.string(kAXTitleAttribute) ?? element.string(kAXDescriptionAttribute)
        return name.map(plainBannerActions.contains) ?? false
    }

    /// Closes the banner with its close action, or by pressing its close button.
    @discardableResult
    public static func dismiss(_ banner: any AccessibilityElement) -> Bool {
        if let close = banner.actionNames.first(where: { $0.contains("Close") || $0 == "AXCancel" }),
           banner.perform(close) {
            return true
        }
        let closeButton = banner.children.first {
            $0.string(kAXRoleAttribute) == kAXButtonRole
                && ($0.string(kAXSubroleAttribute) == kAXCloseButtonSubrole || $0.string(kAXTitleAttribute) == "Close")
        }
        return closeButton?.perform(kAXPressAction) ?? false
    }

    private static func collectTexts(in element: any AccessibilityElement, _ visit: (String?, String) -> Void) {
        if let value = element.string(kAXValueAttribute), !value.isEmpty {
            visit(element.string(kAXIdentifierAttribute), value)
        }
        for child in element.children {
            collectTexts(in: child, visit)
        }
    }
}
