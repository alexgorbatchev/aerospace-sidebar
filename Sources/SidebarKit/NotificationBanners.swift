import ApplicationServices
import CoreGraphics

/// Accessibility access to one UI element. `AXElement` wraps `AXUIElement`; tests use fakes.
@MainActor
public protocol AccessibilityElement {
    func string(_ attribute: String) -> String?
    var children: [any AccessibilityElement] { get }
    var actionNames: [String] { get }
    @discardableResult func perform(_ action: String) -> Bool
    var position: CGPoint? { get }
    @discardableResult func setPosition(_ point: CGPoint) -> Bool
}

/// Text read from one NotificationCenter banner.
public struct BannerContent: Equatable, Sendable {
    public var appName = ""
    public var title = ""
    public var subtitle = ""
    public var body = ""

    var isEmpty: Bool { title.isEmpty && body.isEmpty }
}

/// Reads and dismisses NotificationCenter banners through the accessibility tree.
///
/// Observed NotificationCenter behavior on macOS 26:
/// - Banners are elements with one of `bannerSubroles`, nested a few levels below the hosting window.
/// - The banner's `AXDescription` starts with the posting app's name, followed by ", ".
/// - Text elements carry an `AXIdentifier` of `title`, `subtitle` or `body`.
/// - A plain banner exposes exactly the actions in `plainBannerActions`; notification actions such as
///   Snooze, Join or Reply appear as additional named actions or as controls inside the banner.
@MainActor
public enum NotificationBanners {
    public static let plainBannerActions: Set<String> = ["AXPress", "AXShowMenu", "AXScrollToVisible", "Show Details", "Show", "Close"]
    static let interactiveRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXCheckBoxRole,
    ]

    public static let bannerSubroles: Set<String> = [
        "AXNotificationCenterBanner",
        "AXNotificationCenterBannerWindow",
        "AXNotificationCenterAlert",
        "AXNotificationCenterNotification",
    ]

    /// Banner elements under `root`, without descending into a banner.
    public static func find(in root: any AccessibilityElement, maxDepth: Int = 6) -> [any AccessibilityElement] {
        if let subrole = root.string(kAXSubroleAttribute), bannerSubroles.contains(subrole) {
            return [root]
        }
        guard maxDepth > 0 else { return [] }
        return root.children.flatMap { find(in: $0, maxDepth: maxDepth - 1) }
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
        return content
    }

    /// Whether the notification offers buttons, a reply field or other actions that only macOS can
    /// present: alert-style notifications, unknown actions, or controls other than a close button.
    public static func needsInteraction(_ banner: any AccessibilityElement) -> Bool {
        if banner.string(kAXSubroleAttribute) == "AXNotificationCenterAlert" { return true }
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
            let isCloseButton = child.string(kAXSubroleAttribute) == kAXCloseButtonSubrole
            if let role = child.string(kAXRoleAttribute), interactiveRoles.contains(role), !isCloseButton {
                return true
            }
            return containsControl(child)
        }
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
