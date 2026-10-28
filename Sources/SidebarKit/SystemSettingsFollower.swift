import AppKit

/// Keeps a window at its level above other apps' windows, except while System Settings is the frontmost app.
/// The Permissions steps send the user there, and AeroSpace floats System Settings (it has no full screen
/// button), so its window can sit anywhere, under the sidebar's strip too: floating over it, the window would
/// cover the permission lists, their switches and PermissionFlow's drag panel, which floats only at
/// `.floating`. A window keeps its place in the stack when its level changes, so it is also ordered behind or
/// in front explicitly.
@MainActor
final class SystemSettingsFollower {
    static let systemSettingsBundleID = "com.apple.systempreferences"

    private let window: NSWindow
    private let level: NSWindow.Level
    private let workspaceCenter: NotificationCenter
    private var activationObserver: NSObjectProtocol?

    /// - Parameter frontmostApp: The bundle identifier of the app in front now.
    init(
        window: NSWindow,
        level: NSWindow.Level,
        workspaceCenter: NotificationCenter,
        frontmostApp: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    ) {
        self.window = window
        self.level = level
        self.workspaceCenter = workspaceCenter
        window.level = Self.floats(frontmostApp) ? level : .normal
        activationObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleIdentifier = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.follow(frontmostApp: bundleIdentifier) }
        }
    }

    isolated deinit {
        activationObserver.map(workspaceCenter.removeObserver)
    }

    /// Whether the window is at its own level rather than behind System Settings.
    var floats: Bool { window.level == level }

    /// Floats the window unless System Settings is in front.
    func follow(frontmostApp bundleIdentifier: String?) {
        let floats = Self.floats(bundleIdentifier)
        guard self.floats != floats else { return }
        window.level = floats ? level : .normal
        guard window.isVisible else { return }
        orderIn()
    }

    /// Orders the window in where it belongs: in front, or behind System Settings while that is in front.
    func orderIn() {
        if floats {
            window.orderFrontRegardless()
        } else {
            window.orderBack(nil)
        }
    }

    private static func floats(_ frontmostApp: String?) -> Bool {
        frontmostApp != systemSettingsBundleID
    }
}
