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
/// - The `AXDescription` joins the posting app's name, title, subtitle and body with
///   `NotificationCenterLabels.separator` (vorssaint-utils, SignalLadder). macOS's own notifications, such
///   as Disk Not Ejected Properly, have no app: their description starts with the title. A description may
///   lag behind its texts, such as a countdown in the body, so it is not always an exact match.
/// - Text elements carry an `AXIdentifier` of `title`, `subtitle` or `body`, plus `header` and `date`
///   for texts that are not part of the content (roycetech/applescript-core, talon-axkit).
/// - A plain banner exposes only `AXPress` and the localized Show Details, Show and Close actions;
///   notification actions such as Snooze, Join or Reply appear as additional named actions or as
///   controls inside the banner. Action buttons carry the identifier `action_button` (agent-desktop), and
///   hovering an alert adds Close and Show buttons to it (SignalLadder).
/// - Alert-style notifications (`AXNotificationCenterAlert`) stay on screen until dismissed, like the
///   sidebar's own cards. They are judged by their actions and controls like any banner. Their choices,
///   such as "Allow…" on macOS's "Privacy & Security" alert, are named actions with no button until the
///   alert is hovered. Hovering shows one choice as a button and two or more under one "Options" menu
///   button, whose items are not in the accessibility tree. An alert whose NSUserNotification sets an
///   actions menu also lists the menu's header as a named action, just before Close: the localized Show
///   by default, else the app's own label; performing it closes the alert without answering it.
@MainActor
public enum NotificationBanners {
    /// Accessibility actions every element may offer; the localized ones come from `NotificationCenterLabels`.
    static let standardActions: Set<String> = ["AXPress", "AXShowMenu", "AXScrollToVisible"]
    static let actionButtonIdentifier = "action_button"
    /// The most choices an alert may have for the sidebar to offer them. An actions menu adds its header
    /// as a choice that only closes the alert, and a menu has at least two items, so with a custom header
    /// it shows up as three or more choices; such alerts stay with macOS, which draws the real menu.
    static let maxChoices = 2
    /// Texts that are not part of the content.
    static let ignoredTextIdentifiers: Set<String> = ["header", "date"]
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

    public static func content(of banner: any AccessibilityElement, labels: NotificationCenterLabels = .english) -> BannerContent {
        var content = BannerContent()
        var unlabeled: [String] = []
        collectTexts(in: banner) { identifier, value in
            switch identifier {
            case "title": content.title = value
            case "subtitle": content.subtitle = value
            case "body": content.body = value
            case let identifier? where ignoredTextIdentifiers.contains(identifier): break
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
        if let description = banner.string(kAXDescriptionAttribute) {
            content.appName = appName(in: description, content: content, labels: labels)
        }
        return content
    }

    /// The app name that starts `description`: whatever precedes the exact title, subtitle and body
    /// (vorssaint-utils), or else the first part, unless that is the title. Empty for macOS's own
    /// notifications.
    static func appName(in description: String, content: BannerContent, labels: NotificationCenterLabels) -> String {
        var description = description
        if description.hasSuffix(labels.stackedSuffix) {
            description.removeLast(labels.stackedSuffix.count)
        }
        let texts = [content.title, content.subtitle, content.body].filter { !$0.isEmpty }.joined(separator: labels.separator)
        if !texts.isEmpty {
            if description == texts { return "" }
            if description.hasSuffix(labels.separator + texts) {
                return String(description.dropLast(labels.separator.count + texts.count))
            }
        }
        let first = description.components(separatedBy: labels.separator).first ?? ""
        return first == content.title ? "" : first
    }

    /// Whether the notification offers a choice that only macOS can present: an action other than
    /// opening or closing it, a reply field, or a control other than a close, Show or Show Details button.
    public static func needsInteraction(_ banner: any AccessibilityElement, labels: NotificationCenterLabels = .english) -> Bool {
        let plainActions = plainActions(labels)
        if banner.actionNames.map(actionName).contains(where: { !plainActions.contains($0) }) { return true }
        return containsControl(banner, plainActions: plainActions, actionButtons: [])
    }

    /// The choices an alert offers as named actions, such as "Allow…", in NotificationCenter's order. A
    /// named action works wherever the alert's window is, so the sidebar can offer it while the alert is
    /// hidden. Nil for banners, which leave on their own, for alerts without choices or with more than
    /// `maxChoices`, which may include an actions menu's header, and for alerts that also hold a control
    /// other than a button for one of those choices or a plain action, such as a reply field or an Options
    /// menu, which only works on screen.
    public static func choices(of alert: any AccessibilityElement, labels: NotificationCenterLabels = .english) -> [String]? {
        guard kind(of: alert) == .alert else { return nil }
        let plainActions = plainActions(labels)
        let choices = alert.actionNames.map(actionName).filter { !plainActions.contains($0) }
        guard !choices.isEmpty, choices.count <= maxChoices else { return nil }
        // Hovering an alert shows its choices as buttons too; those duplicate the named actions.
        let named = Set(choices)
        guard !containsControl(alert, plainActions: plainActions.union(named), actionButtons: named) else { return nil }
        return choices
    }

    private static func plainActions(_ labels: NotificationCenterLabels) -> Set<String> {
        standardActions.union([labels.close, labels.show, labels.showDetails])
    }

    /// `AXUIElementCopyActionNames` reports custom actions as "Name:<title>\nTarget:…\nSelector:…".
    static func actionName(_ raw: String) -> String {
        let firstLine = raw.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? raw
        return firstLine.hasPrefix("Name:") ? String(firstLine.dropFirst(5)) : firstLine
    }

    /// Whether `element` holds a control other than a button named in `plainActions`; action buttons
    /// count unless named in `actionButtons`.
    private static func containsControl(
        _ element: any AccessibilityElement,
        plainActions: Set<String>,
        actionButtons: Set<String>
    ) -> Bool {
        element.children.contains { child in
            if child.string(kAXIdentifierAttribute) == actionButtonIdentifier {
                guard let name = name(of: child), actionButtons.contains(name) else { return true }
                return false
            }
            if let role = child.string(kAXRoleAttribute), interactiveRoles.contains(role),
               !isPlainButton(child, plainActions: plainActions) {
                return true
            }
            return containsControl(child, plainActions: plainActions, actionButtons: actionButtons)
        }
    }

    /// A close button, or a button that does what one of the plain actions does, such as Close or Show.
    private static func isPlainButton(_ element: any AccessibilityElement, plainActions: Set<String>) -> Bool {
        guard element.string(kAXRoleAttribute) == kAXButtonRole else { return false }
        if element.string(kAXSubroleAttribute) == kAXCloseButtonSubrole { return true }
        return name(of: element).map(plainActions.contains) ?? false
    }

    private static func name(of element: any AccessibilityElement) -> String? {
        element.string(kAXTitleAttribute) ?? element.string(kAXDescriptionAttribute)
    }

    /// Closes the notification with its localized Close action, or by pressing its close button. An
    /// action matches by its exact name, not by containing "Close", which an app's own action such as
    /// "Close Ticket" would; and when two actions or buttons match, nothing is pressed (AnyDoor, MeetingMute).
    @discardableResult
    public static func dismiss(_ banner: any AccessibilityElement, labels: NotificationCenterLabels = .english) -> Bool {
        let closeActions = banner.actionNames.filter { actionName($0) == labels.close || $0 == kAXCancelAction }
        if closeActions.count == 1, banner.perform(closeActions[0]) {
            return true
        }
        let closeButtons = banner.children.filter {
            $0.string(kAXRoleAttribute) == kAXButtonRole
                && ($0.string(kAXSubroleAttribute) == kAXCloseButtonSubrole || name(of: $0) == labels.close)
        }
        guard closeButtons.count == 1 else { return false }
        return closeButtons[0].perform(kAXPressAction)
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
