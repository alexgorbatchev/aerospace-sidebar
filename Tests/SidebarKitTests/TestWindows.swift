import AppKit
import PermissionFlow
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

extension Trait where Self == ConditionTrait {
    /// Runs a test that shows a window on a display, which only the window server can check, only when
    /// `AEROSPACE_SIDEBAR_SCREEN_TESTS` is 1 and a display exists. CI sets it; on a desk such windows flash in front
    /// of the user's work, so local runs leave them out unless asked.
    static var showsWindowsOnScreen: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["AEROSPACE_SIDEBAR_SCREEN_TESTS"] == "1" && !NSScreen.screens.isEmpty,
            "shows windows on screen; set AEROSPACE_SIDEBAR_SCREEN_TESTS=1"
        )
    }
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

    /// Keeps the frame a test sets: tests pretend screens that can be larger than the displays of the machine they
    /// run on (CI's is), and AppKit would constrain the window to those (`TestSidebarPanel`).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The sidebar's panel, keeping the frames tests pin it to whatever displays the machine has. AppKit moves a
/// borderless window taller than the display it overlaps down to the display's bottom edge (measured on macOS 26.6:
/// asked for y = 40, it ends at y = 0), and a titled one onto the display as it is ordered in.
final class TestSidebarPanel: SidebarPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension SettingsWindowController {
    /// A Settings window in a `TestPanel`, revealing and quitting nothing.
    static func forTesting(
        store: SettingsStore,
        onboarding: OnboardingModel = .fake(),
        appNotifications: AppNotificationsModel = .fake(),
        aeroSpace: AeroSpaceSync,
        fontChooser: FontChooser = FontChooser(),
        workspaceCenter: NotificationCenter = NotificationCenter(),
        sidebarScreenFrame: @escaping @MainActor () -> CGRect? = SidebarPanelController.primaryScreenVisibleFrame,
        terminate: @escaping @MainActor (Any?) -> Void = { _ in },
        history: @escaping @MainActor () -> [SidebarNotification] = { [] }
    ) -> SettingsWindowController {
        SettingsWindowController(
            store: store, onboarding: onboarding, appNotifications: appNotifications, aeroSpace: aeroSpace,
            fontChooser: fontChooser, workspaceCenter: workspaceCenter, sidebarScreenFrame: sidebarScreenFrame, panelType: TestPanel.self,
            history: history, reveal: { _ in }, terminate: terminate
        )
    }
}

extension SidebarPanelController {
    /// A controller whose panel is transparent, so pinning it neither covers the desktop nor takes clicks, and that
    /// keeps the frames it is pinned to on any display (`TestSidebarPanel`). The panel never takes keyboard focus on
    /// its own: it is borderless, and nothing in tests makes it key.
    static func forTesting(
        model: SidebarModel,
        settings: SettingsStore,
        targetVisibleFrame: @escaping @MainActor () -> CGRect? = SidebarPanelController.primaryScreenVisibleFrame,
        targetScreenFrame: @escaping @MainActor () -> CGRect? = SidebarPanelController.primaryScreenFrame,
        notificationCenter: NotificationCenter = NotificationCenter(),
        workspaceCenter: NotificationCenter = NotificationCenter(),
        escapeKey: FakeEscapeKey = FakeEscapeKey(),
        openSettings: @escaping @MainActor (SettingsGroup) -> Void = { _ in },
        setUp: @escaping @MainActor (PermissionFlowPane, CGRect?) -> Void = { _, _ in }
    ) -> SidebarPanelController {
        let controller = SidebarPanelController(
            model: model, settings: settings, targetVisibleFrame: targetVisibleFrame, targetScreenFrame: targetScreenFrame,
            notificationCenter: notificationCenter, workspaceCenter: workspaceCenter, panelType: TestSidebarPanel.self,
            escapeKey: escapeKey.escapeKey, openSettings: openSettings, setUp: setUp
        )
        controller.panel.alphaValue = 0
        controller.background.window.alphaValue = 0
        controller.annoyancePanel.panel.alphaValue = 0
        return controller
    }
}

/// Stands in for `EscapeKey.system`, which would take Escape from every app on the machine while tests run.
@MainActor
final class FakeEscapeKey {
    private final class Registration {}

    private weak var registration: Registration?
    private var handler: (@MainActor () -> Void)?
    /// How many times Escape was registered.
    private(set) var registrations = 0
    /// Refuses registrations, as the system does when another app holds Escape.
    var refuses = false

    /// Whether Escape is registered: its registration is still held.
    var isRegistered: Bool { registration != nil }

    var escapeKey: EscapeKey {
        EscapeKey { [self] handler in
            guard !refuses else { return nil }
            let registration = Registration()
            self.registration = registration
            self.handler = handler
            registrations += 1
            return registration
        }
    }

    /// Presses Escape, which reaches the handler only while it is registered.
    func press() {
        guard isRegistered else { return }
        handler?()
    }
}
