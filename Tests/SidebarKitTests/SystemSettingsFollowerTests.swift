import AppKit
@testable import SidebarKit
import Testing

@MainActor
@Suite(.leavesDesktopAlone)
struct SystemSettingsFollowerTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func startsBehindSystemSettingsWhenItIsInFront() {
        let window = TestPanel()

        let follower = SystemSettingsFollower(
            window: window, level: .statusBar, workspaceCenter: NotificationCenter(),
            frontmostApp: SystemSettingsFollower.systemSettingsBundleID
        )

        #expect(window.level == .normal)
        #expect(!follower.floats)
    }

    /// A hidden window only changes level; ordering it in is left to whoever shows it.
    @Test func leavesAHiddenWindowHidden() {
        let window = TestPanel()
        let follower = SystemSettingsFollower(window: window, level: .statusBar, workspaceCenter: NotificationCenter(), frontmostApp: nil)
        #expect(follower.floats)

        follower.follow(frontmostApp: SystemSettingsFollower.systemSettingsBundleID)
        #expect(window.level == .normal)
        #expect(!window.isVisible)

        follower.follow(frontmostApp: "com.apple.finder")
        #expect(window.level == .statusBar)
        #expect(!window.isVisible)
    }

    @Test func ordersAVisibleWindowInWhereItBelongs() {
        let window = TestPanel()
        let follower = SystemSettingsFollower(window: window, level: .statusBar, workspaceCenter: NotificationCenter(), frontmostApp: nil)
        follower.orderIn()
        defer { window.orderOut(nil) }

        follower.follow(frontmostApp: SystemSettingsFollower.systemSettingsBundleID)
        #expect(window.isVisible && window.level == .normal)
        follower.orderIn()
        #expect(window.isVisible)

        follower.follow(frontmostApp: nil)
        #expect(window.isVisible && window.level == .statusBar)
    }
}
