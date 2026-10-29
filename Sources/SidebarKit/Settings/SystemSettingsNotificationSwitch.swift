import AppKit
import ApplicationServices

/// What switching on an app's notifications in System Settings came to.
public enum AppNotificationSwitchResult: Equatable, Sendable {
    case switchedOn
    case alreadyOn
    /// System Settings did not show the app's page in time, or its page names another app; whatever it shows
    /// is left for the user.
    case pageNotShown
    /// The switch did not turn on when pressed.
    case refused
    /// Without the Accessibility permission the sidebar only opens the app's page.
    case needsAccessibility
}

/// Switches on an app's notifications, which only System Settings can do.
@MainActor
public protocol AppNotificationSwitching {
    /// Opens the app's page in System Settings › Notifications and switches on Allow Notifications there.
    /// - Parameter name: The app's name, which titles its page.
    func allowNotifications(bundleIdentifier: String, name: String) async -> AppNotificationSwitchResult
}

/// `AppNotificationSwitching` through System Settings, as the user would do it: it opens the app's page by
/// URL and presses its Allow Notifications switch (`AXIdentifier` `allow-notifications`) through the
/// Accessibility API. macOS has no API that changes another app's notification settings.
///
/// A URL with a bundle identifier System Settings does not know leaves it on the page it showed, which may
/// belong to another app, so the switch is pressed only on a page titled with the app's name. System Settings
/// knows every app usernoted lists, which is where the identifiers come from, so the URL opens the right page
/// even when another app goes by the same name, like Google Chrome and its alerts helper. The pane's URL without
/// an identifier keeps the page it shows, so there is no way back to the list of apps first (measured on macOS 26.6).
@MainActor
public struct SystemSettingsNotificationSwitch: AppNotificationSwitching {
    static let systemSettingsBundleIdentifier = "com.apple.systempreferences"
    static let switchIdentifier = "allow-notifications"
    /// How many times a page is looked for, `pollInterval` apart, before giving up.
    static let attempts = 50
    static let pollInterval: Duration = .milliseconds(100)
    /// Deep enough for the switch, which sits about ten levels below the window on macOS 26.
    static let searchDepth = 25

    private let isTrusted: @MainActor () -> Bool
    private let open: @MainActor (URL) -> Void
    private let windows: @MainActor () -> [any AccessibilityElement]
    private let sleep: @MainActor (Duration) async -> Void

    /// - Parameters:
    ///   - windows: System Settings' windows, empty while it is not running.
    ///   - sleep: Waits between looks at System Settings.
    public init(
        isTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        open: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        windows: @escaping @MainActor () -> [any AccessibilityElement] = SystemSettingsNotificationSwitch.systemSettingsWindows,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.isTrusted = isTrusted
        self.open = open
        self.windows = windows
        self.sleep = sleep
    }

    /// System Settings › Notifications, on the page of the app with `bundleIdentifier`.
    static func pageURL(bundleIdentifier: String) -> URL {
        var components = URLComponents()
        components.scheme = "x-apple.systempreferences"
        components.path = "com.apple.Notifications-Settings.extension"
        components.queryItems = [URLQueryItem(name: "id", value: bundleIdentifier)]
        return components.url!
    }

    public static func systemSettingsWindows() -> [any AccessibilityElement] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: systemSettingsBundleIdentifier).first else {
            return []
        }
        return SystemAccessibility().windows(ofProcess: app.processIdentifier)
    }

    public func allowNotifications(bundleIdentifier: String, name: String) async -> AppNotificationSwitchResult {
        open(Self.pageURL(bundleIdentifier: bundleIdentifier))
        guard isTrusted() else { return .needsAccessibility }
        guard let toggle = await poll({ switchOnPage(titled: name) }) else { return .pageNotShown }
        if toggle.bool(kAXValueAttribute) == true { return .alreadyOn }
        toggle.perform(kAXPressAction)
        return await poll({ toggle.bool(kAXValueAttribute) == true ? true : nil }) != nil ? .switchedOn : .refused
    }

    /// Calls `find` until it returns something, `pollInterval` apart, at most `attempts` times.
    private func poll<T>(_ find: () -> T?) async -> T? {
        for _ in 0..<Self.attempts {
            if let found = find() { return found }
            await sleep(Self.pollInterval)
        }
        return find()
    }

    /// The Allow Notifications switch on the page System Settings shows, when that page is titled `title`.
    private func switchOnPage(titled title: String) -> (any AccessibilityElement)? {
        for window in windows() where window.string(kAXTitleAttribute) == title {
            if let toggle = Self.element(identified: Self.switchIdentifier, in: window, depth: Self.searchDepth) {
                return toggle
            }
        }
        return nil
    }

    private static func element(identified identifier: String, in element: any AccessibilityElement, depth: Int) -> (any AccessibilityElement)? {
        if element.string(kAXIdentifierAttribute) == identifier { return element }
        guard depth > 0 else { return nil }
        for child in element.children {
            if let found = Self.element(identified: identifier, in: child, depth: depth - 1) { return found }
        }
        return nil
    }
}
