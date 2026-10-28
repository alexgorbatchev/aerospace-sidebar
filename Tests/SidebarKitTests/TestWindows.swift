import AppKit
@testable import SidebarKit
import Testing

/// Tests run on the user's desktop. A titled window that can become key takes the user's keyboard focus
/// as soon as it is ordered in, whatever the test process's activation policy and even when transparent,
/// and an opaque window on a display covers it and takes clicks. The test process runs no event loop, so
/// AppKit never learns that the window server made a window key; the trait therefore checks for windows
/// that would be, not for key notifications. Suites that create windows take it: it fails a test that ends
/// with such a window visible, its own or one another test left behind.
struct LeavesDesktopAlone: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await function()
        for window in await Self.disturbingWindows() {
            Issue.record("\(window) disturbs the desktop; order in only TestPanels")
        }
    }

    /// Visible windows that cover a display, or that take or hold keyboard focus, other than the
    /// window-server tests' own.
    @MainActor
    static func disturbingWindows() -> [String] {
        NSApplication.shared.windows
            .filter { window in
                guard window.isVisible, window.identifier != .windowServerProbe else { return false }
                let covers = window.alphaValue > 0 && NSScreen.screens.contains { $0.frame.intersects(window.frame) }
                let takesFocus = window.isKeyWindow || (window.canBecomeKey && window.styleMask.contains(.titled))
                return covers || takesFocus
            }
            .map { "\(type(of: $0)) \"\($0.title)\" at \($0.frame)" }
    }
}

extension Trait where Self == LeavesDesktopAlone {
    /// Fails tests that leave a window covering a display or taking keyboard focus; see `LeavesDesktopAlone`.
    static var leavesDesktopAlone: Self { Self() }
}

extension NSUserInterfaceItemIdentifier {
    /// Marks a window that a test shows on a display on purpose, because only the window server can answer
    /// what it checks. Such a window must never become key and must leave the screen when the test ends.
    static let windowServerProbe = NSUserInterfaceItemIdentifier("windowServerProbe")
}

/// A window that tests can order in without disturbing the user's desktop: it never takes keyboard focus,
/// which a titled window ordered in would move from the frontmost app to the test process, and its
/// transparency keeps it out of sight and lets clicks through to the windows below. AppKit still reports
/// it as visible, and it keeps its frame, level and ordering.
final class TestPanel: NSPanel {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension SettingsWindowController {
    /// A Settings window in a `TestPanel`, revealing and quitting nothing.
    static func forTesting(
        store: SettingsStore,
        onboarding: OnboardingModel = .fake(),
        aeroSpace: AeroSpaceSync,
        fontChooser: FontChooser = FontChooser(),
        workspaceCenter: NotificationCenter = NotificationCenter(),
        sidebarScreenFrame: @escaping @MainActor () -> CGRect? = SidebarPanelController.primaryScreenVisibleFrame,
        terminate: @escaping @MainActor (Any?) -> Void = { _ in }
    ) -> SettingsWindowController {
        SettingsWindowController(
            store: store, onboarding: onboarding, aeroSpace: aeroSpace, fontChooser: fontChooser,
            workspaceCenter: workspaceCenter, sidebarScreenFrame: sidebarScreenFrame, panelType: TestPanel.self,
            reveal: { _ in }, terminate: terminate
        )
    }
}

extension SidebarPanelController {
    /// A controller whose panel is transparent, so pinning it neither covers the desktop nor takes clicks.
    /// The panel never takes keyboard focus on its own: it is borderless, and nothing in tests makes it key.
    static func forTesting(
        model: SidebarModel,
        settings: SettingsStore,
        targetVisibleFrame: @escaping @MainActor () -> CGRect? = SidebarPanelController.primaryScreenVisibleFrame,
        notificationCenter: NotificationCenter = NotificationCenter(),
        openSettings: @escaping @MainActor () -> Void = {}
    ) -> SidebarPanelController {
        let controller = SidebarPanelController(
            model: model, settings: settings, targetVisibleFrame: targetVisibleFrame,
            notificationCenter: notificationCenter, openSettings: openSettings
        )
        controller.panel.alphaValue = 0
        return controller
    }
}
