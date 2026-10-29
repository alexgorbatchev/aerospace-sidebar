import AppKit
import PermissionFlow
import SwiftUI

/// Owns the sidebar panel and keeps it pinned to the reserved strip on the target screen.
@MainActor
public final class SidebarPanelController: NSObject {
    /// Visible frame of the primary screen: the one with the menu bar, which AeroSpace calls `main`.
    public static let primaryScreenVisibleFrame: @MainActor () -> CGRect? = {
        NSScreen.screens.first?.visibleFrame
    }

    /// The panel's window level, above other apps' windows and the menu bar.
    public static let level: NSWindow.Level = .statusBar

    public let panel: NSPanel
    /// Steps behind System Settings while it is in front.
    let follower: SystemSettingsFollower
    private let settings: SettingsStore
    private let targetVisibleFrame: @MainActor () -> CGRect?
    private var pinnedSidebar: SidebarSettings.Sidebar

    /// - Parameters:
    ///   - model: State the sidebar renders.
    ///   - settings: Supplies the sidebar's side, width and font; side and width changes re-pin the panel.
    ///   - workspaceCenter: Reports which app is in front.
    ///   - openSettings: Shows the Settings window on a group.
    ///   - setUp: Starts granting a permission from a button at a frame on screen.
    public init(
        model: SidebarModel,
        settings: SettingsStore,
        targetVisibleFrame: @escaping @MainActor () -> CGRect? = SidebarPanelController.primaryScreenVisibleFrame,
        notificationCenter: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        openSettings: @escaping @MainActor (SettingsGroup) -> Void = { _ in },
        setUp: @escaping @MainActor (PermissionFlowPane, CGRect?) -> Void = { _, _ in }
    ) {
        self.settings = settings
        self.targetVisibleFrame = targetVisibleFrame
        self.pinnedSidebar = settings.settings.sidebar
        // SwiftUI lays the content out first at the panel's initial size. Starting on the strip keeps that
        // layout final, so a change the sidebar animates soon after launch does not also grow every card
        // from zero width.
        let strip = targetVisibleFrame().map { SidebarLayout(settings.settings.sidebar).frame(in: $0) } ?? .zero
        self.panel = Self.makePanel(
            contentRect: strip, model: model, settings: settings, openSettings: openSettings, setUp: setUp
        )
        follower = SystemSettingsFollower(window: panel, level: Self.level, workspaceCenter: workspaceCenter)
        super.init()
        settings.observe { [weak self] settings in
            guard let self, settings.sidebar != self.pinnedSidebar else { return }
            self.pin()
        }
        notificationCenter.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Moves the panel onto the reserved strip and shows it, or hides it when no target screen exists.
    public func pin() {
        pinnedSidebar = settings.settings.sidebar
        guard let visibleFrame = targetVisibleFrame() else {
            panel.orderOut(nil)
            return
        }
        panel.setFrame(SidebarLayout(pinnedSidebar).frame(in: visibleFrame), display: true)
        follower.orderIn()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        pin()
    }

    private static func makePanel(
        contentRect: CGRect,
        model: SidebarModel,
        settings: SettingsStore,
        openSettings: @escaping @MainActor (SettingsGroup) -> Void,
        setUp: @escaping @MainActor (PermissionFlowPane, CGRect?) -> Void
    ) -> NSPanel {
        // Borderless with no close button: combined with LSUIElement, AeroSpace classifies
        // the window as a popup and neither tiles it nor hides it on workspace switches.
        let panel = SidebarPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        // WindowServer passes mouse events through fully transparent pixels before view hit testing.
        // Keep a nearly invisible backing across the strip so scrolling survives gaps between cards.
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        panel.hasShadow = false

        let content = NSHostingView(rootView: SidebarPanelContent(
            model: model, settings: settings, openSettings: openSettings, setUp: setUp,
            requestKeyboard: { [weak panel] in panel?.takeKeyboard() }
        ))
        panel.contentView = content
        return panel
    }
}

/// Renders `SidebarView` on the configured side; reading the settings in a view body keeps it current.
struct SidebarPanelContent: View {
    let model: SidebarModel
    let settings: SettingsStore
    let openSettings: (SettingsGroup) -> Void
    let setUp: (PermissionFlowPane, CGRect?) -> Void
    /// Makes the panel the key window, so that typing reaches a field the user opened (`requestKeyboard`).
    let requestKeyboard: @MainActor () -> Void

    var body: some View {
        SidebarView(model: model, side: settings.settings.sidebar.side, openSettings: openSettings, setUp: setUp)
            .typography(settings)
            .environment(\.requestKeyboard, requestKeyboard)
    }
}

/// Borderless windows refuse key status by default, which blocks clicks from focusing
/// the sidebar and keyboard input from reaching it. `.nonactivatingPanel` lets it become
/// key without activating the app or stealing activation from the frontmost app.
///
/// The panel takes key status only for a click on it, or when the user opens a field to type into, such as a
/// reply on a card, which VoiceOver does without a click (`takeKeyboard()`). Once key, it stays key until another
/// window takes over, whatever `canBecomeKey` says later (measured on macOS 26.6). AppKit makes the first visible
/// window that can become key the key window once the app finishes launching, and picks another when a key window
/// closes, such as Settings; either would move the user's keyboard focus to the sidebar unasked.
final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { acceptsKeyStatus(during: currentEvent) }

    /// Set only while `takeKeyboard()` makes the panel key.
    private(set) var grantsKeyStatus = false
    /// Makes the panel the key window; tests record it instead, since a key test window takes the user's keyboard.
    var becomeKey: @MainActor (NSWindow) -> Void = { $0.makeKey() }

    /// Whether the panel takes key status: while `takeKeyboard()` asks for it, or for `event`, the event being
    /// handled, when that is a click on the panel.
    func acceptsKeyStatus(during event: NSEvent?) -> Bool {
        if grantsKeyStatus { return true }
        guard let event else { return false }
        return event.windowNumber == windowNumber && Self.clicks.contains(event.type)
    }

    /// Makes the panel the key window, without activating the app, so that typing reaches a field the user
    /// opened.
    func takeKeyboard() {
        grantsKeyStatus = true
        becomeKey(self)
        grantsKeyStatus = false
    }

    private static let clicks: Set<NSEvent.EventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
}

extension EnvironmentValues {
    /// Makes the sidebar panel the key window when the user opens a field to type into
    /// (`SidebarPanel.takeKeyboard()`).
    @Entry var requestKeyboard: @MainActor () -> Void = {}
}
