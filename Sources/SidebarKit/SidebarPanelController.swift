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

    /// Frame of the primary screen, menu bar and Dock included.
    public static let primaryScreenFrame: @MainActor () -> CGRect? = {
        NSScreen.screens.first?.frame
    }

    /// The panel's window level: just below the menu bar's, above other apps' windows, the Dock and
    /// NotificationCenter's window (layer 21). The screenshot thumbnail's full-screen window sits at the menu bar's
    /// level (layer 24, measured on macOS 26.6), so the thumbnail in the bottom corner shows above the sidebar.
    public static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)

    public let panel: NSPanel
    /// Steps behind System Settings while it is in front.
    let follower: SystemSettingsFollower
    /// Fills the strip from the top of the screen to the bottom when `[background]` asks for it.
    let background = SidebarBackground()
    let annoyancePanel: AnnoyancePanel
    private let settings: SettingsStore
    private let targetVisibleFrame: @MainActor () -> CGRect?
    private let targetScreenFrame: @MainActor () -> CGRect?
    private var pinnedSidebar: SidebarSettings.Sidebar

    /// - Parameters:
    ///   - model: State the sidebar renders.
    ///   - settings: Supplies the sidebar's side, width and font; side and width changes re-pin the panel.
    ///   - workspaceCenter: Reports which app is in front.
    ///   - openSettings: Shows the Settings window on a group.
    ///   - setUp: Starts granting a permission from a button at a frame on screen.
    /// - Parameter escapeKey: Registers Escape for the blackout. The app passes `.system`; tests pass a fake, since
    ///   the real one takes Escape from every app on the machine.
    public convenience init(
        model: SidebarModel,
        settings: SettingsStore,
        escapeKey: EscapeKey,
        targetVisibleFrame: @escaping @MainActor () -> CGRect? = SidebarPanelController.primaryScreenVisibleFrame,
        targetScreenFrame: @escaping @MainActor () -> CGRect? = SidebarPanelController.primaryScreenFrame,
        notificationCenter: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        openSettings: @escaping @MainActor (SettingsGroup) -> Void = { _ in },
        setUp: @escaping @MainActor (PermissionFlowPane, CGRect?) -> Void = { _, _ in }
    ) {
        self.init(
            model: model, settings: settings, targetVisibleFrame: targetVisibleFrame, targetScreenFrame: targetScreenFrame,
            notificationCenter: notificationCenter, workspaceCenter: workspaceCenter, panelType: SidebarPanel.self,
            escapeKey: escapeKey, openSettings: openSettings, setUp: setUp
        )
    }

    /// - Parameters:
    ///   - panelType: The panel's class. Tests pass one that keeps the frames they pin it to on any display.
    ///   - escapeKey: Registers Escape for the blackout.
    init(
        model: SidebarModel,
        settings: SettingsStore,
        targetVisibleFrame: @escaping @MainActor () -> CGRect?,
        targetScreenFrame: @escaping @MainActor () -> CGRect?,
        notificationCenter: NotificationCenter,
        workspaceCenter: NotificationCenter,
        panelType: SidebarPanel.Type,
        escapeKey: EscapeKey,
        openSettings: @escaping @MainActor (SettingsGroup) -> Void,
        setUp: @escaping @MainActor (PermissionFlowPane, CGRect?) -> Void
    ) {
        self.settings = settings
        self.targetVisibleFrame = targetVisibleFrame
        self.targetScreenFrame = targetScreenFrame
        self.pinnedSidebar = settings.settings.sidebar
        // SwiftUI lays the content out first at the panel's initial size. Starting on the strip keeps that
        // layout final, so a change the sidebar animates soon after launch does not also grow every card
        // from zero width.
        let strip = targetVisibleFrame().map { SidebarLayout(settings.settings.sidebar).frame(in: $0) } ?? .zero
        self.panel = Self.makePanel(
            type: panelType, contentRect: strip, model: model, settings: settings, openSettings: openSettings, setUp: setUp
        )
        follower = SystemSettingsFollower(window: panel, level: Self.level, workspaceCenter: workspaceCenter)
        annoyancePanel = AnnoyancePanel(
            model: model, settings: settings, panelType: panelType, screenFrame: targetScreenFrame, escapeKey: escapeKey
        )
        super.init()
        follower.onFollow = { [weak self] in self?.showBackground() }
        settings.observe { [weak self] settings in
            guard let self, settings.sidebar != self.pinnedSidebar else { return }
            self.pin()
        }
        // Settings previews the background while it is edited, before it is saved.
        settings.observeBackground { [weak self] _ in self?.showBackground() }
        notificationCenter.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Moves the panel onto the reserved strip and shows it, or hides it when no target screen exists.
    public func pin() {
        annoyancePanel.refresh()
        pinnedSidebar = settings.settings.sidebar
        // After the panel, which the background goes under.
        defer { showBackground() }
        guard let visibleFrame = targetVisibleFrame() else {
            panel.orderOut(nil)
            return
        }
        panel.setFrame(SidebarLayout(pinnedSidebar).frame(in: visibleFrame), display: true)
        follower.orderIn()
    }

    /// Shows the background on the strip the panel is pinned to, from the top of the screen to the bottom.
    private func showBackground() {
        let frame = targetVisibleFrame().flatMap { visibleFrame in
            targetScreenFrame().map { SidebarLayout(pinnedSidebar).fullHeightFrame(in: visibleFrame, of: $0) }
        }
        background.show(settings.background, in: frame, under: panel, floats: follower.floats)
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        pin()
    }

    private static func makePanel(
        type: SidebarPanel.Type,
        contentRect: CGRect,
        model: SidebarModel,
        settings: SettingsStore,
        openSettings: @escaping @MainActor (SettingsGroup) -> Void,
        setUp: @escaping @MainActor (PermissionFlowPane, CGRect?) -> Void
    ) -> NSPanel {
        // Borderless with no close button: combined with LSUIElement, AeroSpace classifies
        // the window as a popup and neither tiles it nor hides it on workspace switches.
        let panel = type.init(
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
        // A click makes the panel key only on a view that takes typing, such as a reply field; a click on a card
        // leaves the keyboard with the app the user types in.
        panel.becomesKeyOnlyIfNeeded = true

        let content = SidebarHostingView(rootView: SidebarPanelContent(
            model: model, settings: settings, openSettings: openSettings, setUp: setUp,
            requestKeyboard: { [weak panel] in panel?.takeKeyboard() },
            pointerIsOn: { [weak panel] in panel?.hasPointer ?? false }
        ))
        panel.contentView = content
        return panel
    }
}

/// Hosts the sidebar's content. `NSHostingView` reports that a click anywhere on it needs the panel to become key,
/// so with `becomesKeyOnlyIfNeeded` a click on a card would still take the keyboard from the app the user types in,
/// which no click action or activation of that app gives back while it is already active. This view answers no for
/// itself and leaves the decision to the view clicked: SwiftUI's text fields are `NSTextField`s that answer yes.
final class SidebarHostingView<Content: View>: NSHostingView<Content> {
    override var needsPanelToBecomeKey: Bool { false }
}

/// Renders `SidebarView` on the configured side; reading the settings in a view body keeps it current.
struct SidebarPanelContent: View {
    let model: SidebarModel
    let settings: SettingsStore
    let openSettings: (SettingsGroup) -> Void
    let setUp: (PermissionFlowPane, CGRect?) -> Void
    /// Makes the panel the key window, so that typing reaches a field the user opened (`requestKeyboard`).
    let requestKeyboard: @MainActor () -> Void
    /// Whether the pointer is on the panel (`pointerIsOnSidebar`).
    let pointerIsOn: @MainActor () -> Bool

    var body: some View {
        SidebarView(
            model: model, side: settings.settings.sidebar.side, settingsProblem: settings.loadProblem,
            openSettings: openSettings, setUp: setUp
        )
            .typography(settings)
            .environment(\.requestKeyboard, requestKeyboard)
            .environment(\.pointerIsOnSidebar, pointerIsOn)
    }
}

/// Borderless windows refuse key status by default, which blocks clicks from focusing
/// the sidebar and keyboard input from reaching it. `.nonactivatingPanel` lets it become
/// key without activating the app or stealing activation from the frontmost app.
///
/// The panel takes key status only for a click on a view that takes typing (`becomesKeyOnlyIfNeeded`,
/// `SidebarHostingView`), or when the user opens a field to type into, such as a reply on a card, with a click or
/// through VoiceOver (`takeKeyboard()`). Once key, it stays key until another
/// window takes over, whatever `canBecomeKey` says later (measured on macOS 26.6). AppKit makes the first visible
/// window that can become key the key window once the app finishes launching, and picks another when a key window
/// closes, such as Settings; either would move the user's keyboard focus to the sidebar unasked.
class SidebarPanel: NSPanel {
    /// Required so that `SidebarPanelController` can make the panel from its class (`panelType`).
    required override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
    }

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

    /// Where the pointer is, in screen coordinates; tests place it.
    var pointerLocation: @MainActor () -> CGPoint = { NSEvent.mouseLocation }
    /// A press that began on the panel is held, so the pointer drags from it, perhaps past the strip, as when it
    /// drags the scroll indicator's knob.
    private(set) var isPressed = false

    /// Whether the pointer is on the panel: where a click would reach it, or dragging from a press on it.
    var hasPointer: Bool { isPressed || receivesClicks(at: pointerLocation()) }

    /// Whether a click at `point`, in screen coordinates, reaches the panel: anywhere on the strip, gaps between
    /// cards included, where the backing takes the click, unless another window covers the point, such as
    /// System Settings while the panel steps behind it (`SystemSettingsFollower`).
    func receivesClicks(at point: CGPoint) -> Bool {
        NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == windowNumber
    }

    override func sendEvent(_ event: NSEvent) {
        track(event)
        super.sendEvent(event)
    }

    /// Notes a press on the panel and its release. AppKit sends the drags and the release of a press to the window
    /// that took the press, wherever the pointer goes.
    func track(_ event: NSEvent) {
        if Self.clicks.contains(event.type) {
            isPressed = true
        } else if Self.releases.contains(event.type) {
            isPressed = false
        }
    }

    private static let releases: Set<NSEvent.EventType> = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
}

extension EnvironmentValues {
    /// Makes the sidebar panel the key window when the user opens a field to type into
    /// (`SidebarPanel.takeKeyboard()`).
    @Entry var requestKeyboard: @MainActor () -> Void = {}
}
