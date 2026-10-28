import AppKit
import SwiftUI

/// Owns the Settings window: a sidebar listing the groups (`SettingsGroup`) beside the selected group's
/// pane. The panes sit in a tab view controller without tabs, which switches between them.
///
/// The app never activates (its sidebar is a non-activating panel), and since macOS 14
/// `NSApp.activate()` from a background app is only a request the system may decline. Switching
/// the activation policy to `.regular` while Settings is open would make AeroSpace re-classify the
/// sidebar panel as a window. Settings is therefore a non-activating panel too: it orders itself
/// in front and takes keyboard focus without activating the app.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    public let window: NSPanel
    public let tabs = NSTabViewController()
    let navigation = SettingsNavigation()
    private let split = NSSplitViewController()
    private let detail = BelowTitleBarController()
    /// What the group list needs to show every group, as `SettingsSidebar` last reported it.
    private var sidebarHeight: CGFloat = 0
    let editor: SettingsEditor
    private let store: SettingsStore
    private let onboarding: OnboardingModel
    private let aeroSpace: AeroSpaceSync
    private let fontChooser: FontChooser
    private let workspaceCenter: NotificationCenter
    /// Visible frame of the screen the sidebar is on.
    private let sidebarScreenFrame: @MainActor () -> CGRect?
    private var activationObserver: NSObjectProtocol?
    /// What each pane needs to show all of its content, as it last reported it.
    private var paneSizes: [SettingsGroup: CGSize] = [:]
    /// Set by opening the window until `sizeWindow` can center it: panes report their sizes after the
    /// event that opens it.
    private var centersOnNextSize = false
    /// Where `sizeWindow` last centered the window. While the window is still there, size changes keep it
    /// centered; once moved, it keeps its top edge instead.
    private var centeredFrame: NSRect?
    static let systemSettingsBundleID = "com.apple.systempreferences"
    /// Above the sidebar, which would otherwise cover the part of Settings over its strip.
    static let level = NSWindow.Level(rawValue: SidebarPanelController.level.rawValue + 1)
    /// A window size larger than the title bar and sidebar, for measuring them.
    private static let measuringSize = NSSize(width: 800, height: 600)

    /// - Parameters:
    ///   - reveal: Shows a file in Finder.
    ///   - terminate: Called with `nil` when the user quits from Settings.
    public convenience init(
        store: SettingsStore,
        onboarding: OnboardingModel,
        aeroSpace: AeroSpaceSync,
        reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        terminate: @escaping @MainActor (Any?) -> Void = NSApplication.shared.terminate
    ) {
        self.init(
            store: store, onboarding: onboarding, aeroSpace: aeroSpace, fontChooser: FontChooser(),
            workspaceCenter: NSWorkspace.shared.notificationCenter, reveal: reveal, terminate: terminate
        )
    }

    /// - Parameter panelType: The window's class. Tests pass one that never takes keyboard focus: a titled
    ///   panel becomes key when it is ordered in, which moves the user's keyboard focus to the test process.
    init(
        store: SettingsStore,
        onboarding: OnboardingModel,
        aeroSpace: AeroSpaceSync,
        fontChooser: FontChooser,
        workspaceCenter: NotificationCenter,
        sidebarScreenFrame: @escaping @MainActor () -> CGRect? = SidebarPanelController.primaryScreenVisibleFrame,
        panelType: NSPanel.Type = NSPanel.self,
        reveal: @escaping (URL) -> Void,
        terminate: @escaping @MainActor (Any?) -> Void = NSApplication.shared.terminate
    ) {
        self.store = store
        self.onboarding = onboarding
        self.aeroSpace = aeroSpace
        self.fontChooser = fontChooser
        self.workspaceCenter = workspaceCenter
        self.sidebarScreenFrame = sidebarScreenFrame
        editor = SettingsEditor(store: store)
        window = panelType.init(
            contentRect: .zero,
            // The sidebar runs the full height of the window, under the title bar.
            styleMask: [.titled, .closable, .miniaturizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        let close: () -> Void = { [weak self] in
            self?.window.orderOut(nil)
            self?.fontChooser.close()
        }
        let chooseFont: () -> Void = { [weak self] in self?.chooseFont() }
        tabs.tabStyle = .unspecified
        tabs.transitionOptions = []
        for group in SettingsGroup.allCases {
            let pane = switch group {
            case .general: pane(group, GeneralPane(configURL: store.file.url, reveal: reveal, quit: { terminate(nil) }))
            case .appearance: pane(group, AppearancePane(editor: editor, chooseFont: chooseFont, close: close))
            case .sidebar: pane(group, SidebarPane(editor: editor, aeroSpace: aeroSpace, reveal: reveal, close: close))
            case .permissions: pane(group, PermissionsPane(onboarding: onboarding))
            case .notifications: pane(group, NotificationsPane(editor: editor, close: close))
            case .history: pane(group, HistoryPane(editor: editor, close: close))
            }
            // The tab view item takes its label from the title.
            pane.title = group.title
            tabs.addTabViewItem(NSTabViewItem(viewController: pane))
        }
        navigation.onSelect = { [weak self] in self?.select($0) }

        let sidebar = SettingsSidebar(navigation: navigation) { [weak self] height in
            self?.sidebarHeight = height
            self?.sizeWindow()
        }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: sidebar.typography(store)))
        sidebarItem.canCollapse = false
        split.addSplitViewItem(sidebarItem)
        detail.addChild(tabs)
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))

        // The selected group in the sidebar names the shown pane; the title, kept for VoiceOver and the
        // window list, is not drawn.
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.contentViewController = split
        // The window takes the split view's size, which is empty until the panes report theirs. `sizeWindow`
        // measures the title bar and sidebar around them, which takes a window larger than those.
        window.setContentSize(Self.measuringSize)
        select(navigation.selection)
        window.isReleasedWhenClosed = false
        // Panels hide when their app deactivates by default; this app is never active.
        window.hidesOnDeactivate = false
        // Settings stays above other apps' windows and the sidebar until it is closed, except System Settings,
        // where the Permissions steps send the user: floating over it, Settings would cover the permission
        // lists and their switches.
        window.level = NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Self.systemSettingsBundleID ? Self.level : .normal
        activationObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleIdentifier = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.follow(frontmostApp: bundleIdentifier) }
        }
        window.delegate = self
        sizePanes()
        // Text sizes follow the font, previewed or saved, so the panes grow and shrink with it.
        store.observeFont { [weak self] _ in self?.sizePanes() }
    }

    isolated deinit {
        activationObserver.map(workspaceCenter.removeObserver)
    }

    /// Floats above the sidebar unless System Settings is in front. A window keeps its place in the stack
    /// when its level changes, so it is also ordered behind or in front explicitly.
    func follow(frontmostApp bundleIdentifier: String?) {
        let floats = bundleIdentifier != Self.systemSettingsBundleID
        guard (window.level == Self.level) != floats else { return }
        window.level = floats ? Self.level : .normal
        guard window.isVisible else { return }
        if floats {
            window.orderFrontRegardless()
        } else {
            window.orderBack(nil)
        }
    }

    /// Opens on `group` with a fresh draft and status, centered on the sidebar's screen unless it is already
    /// open.
    public func show(_ group: SettingsGroup = .general) {
        editor.revert()
        onboarding.refresh()
        aeroSpace.refresh()
        navigation.selection = group
        if !window.isVisible {
            centersOnNextSize = true
            sizeWindow()
            // Until the panes report their sizes, center the window at the size it has.
            if centersOnNextSize, let origin = originOnSidebarScreen(for: window.frame.size) {
                window.setFrameOrigin(origin)
            }
        }
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// Closing the window discards unsaved edits, like Cancel.
    public func windowWillClose(_ notification: Notification) {
        editor.revert()
        fontChooser.close()
    }

    /// Fonts picked in the font panel go into the draft, like any other edit.
    func chooseFont() {
        // The saved side is where the sidebar is; an unsaved one is not applied yet.
        fontChooser.choose(editor.draft.font, beside: window, awayFrom: store.settings.sidebar.side) { [editor] in
            editor.draft.font = $0
        }
    }

    /// The origin that centers a window of `size` on the sidebar's screen, where the gear button that opens
    /// it is. `NSWindow.center()` would pick the screen with keyboard focus, which an app that never
    /// activates does not control, so the window could open on any display.
    private func originOnSidebarScreen(for size: NSSize) -> NSPoint? {
        guard let visibleFrame = sidebarScreenFrame() else { return nil }
        return NSPoint(x: (visibleFrame.midX - size.width / 2).rounded(), y: (visibleFrame.midY - size.height / 2).rounded())
    }

    /// Shows `group`'s pane and names the window after it, for VoiceOver and the window list.
    private func select(_ group: SettingsGroup) {
        tabs.selectedTabViewItemIndex = group.rawValue
        window.title = group.title
    }

    /// Lays out every pane, shown or not, so each reports its size for the current font.
    private func sizePanes() {
        // A layout pass applies pending SwiftUI updates, such as a font change, so the sizes are current.
        tabs.tabViewItems.forEach { $0.viewController?.view.layoutSubtreeIfNeeded() }
        sizeWindow()
    }

    /// Fits the window to the largest pane and the group list, keeping its top edge in place, so switching
    /// groups does not resize it.
    private func sizeWindow() {
        // Panes report their sizes as they load, before the window has its content, and in the running app
        // after the event that created it. Sizing from some of them, or before the split view has laid out
        // its items, measures a degenerate window and moves it off its screen.
        guard window.contentViewController != nil, paneSizes.count == SettingsGroup.allCases.count else { return }
        let pane = NSSize(width: paneSizes.values.map(\.width).max() ?? 0, height: paneSizes.values.map(\.height).max() ?? 0)
        let sidebarItem = split.splitViewItems[0]
        let sidebarWidth = (SettingsMetrics.sidebarWidth * Typography(store.font).scale).rounded()
        sidebarItem.minimumThickness = sidebarWidth
        sidebarItem.maximumThickness = sidebarWidth
        // What the window adds around the panes (title bar, sidebar) and around the group list
        // (the sidebar's margins), measured because the sidebar's margins differ between macOS versions.
        window.contentView?.layoutSubtreeIfNeeded()
        let paneArea = detail.view.safeAreaRect.size
        let sidebarArea = sidebarItem.viewController.view.frame.height
        guard paneArea.width > 0, paneArea.height > 0, sidebarArea > 0 else { return }
        let width = window.frame.width - paneArea.width + pane.width
        let height = max(window.frame.height - paneArea.height + pane.height, window.frame.height - sidebarArea + sidebarHeight)
        var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - height, width: width, height: height)
        let centers = centersOnNextSize || window.frame == centeredFrame
        if centers, let origin = originOnSidebarScreen(for: frame.size) {
            frame.origin = origin
        }
        centersOnNextSize = false
        window.setFrame(frame, display: true)
        centeredFrame = centers ? window.frame : nil
    }

    /// A pane in the configured font that reports the size it needs. Hosting controllers report no sizes of
    /// their own: they update `preferredContentSize` without telling a parent that is not a window.
    private func pane(_ group: SettingsGroup, _ view: some View) -> NSViewController {
        let controller = NSHostingController(rootView: SettingsPaneHost(pane: view, store: store) { [weak self] size in
            self?.paneSizes[group] = size
            self?.sizeWindow()
        })
        // Every pane fills the window; constraints from its own size would fight the window's.
        controller.sizingOptions = []
        return controller
    }
}

/// Lays out its first child's view in its safe area, below the title bar of a window whose content runs
/// under it. A hosting view under the title bar would include its height in its preferred size and adjust
/// it on every layout pass; AppKit gives up on such a window with an exception.
final class BelowTitleBarController: NSViewController {
    // Frames rather than constraints: constraints would also tie the window's size to the shown pane's.
    override func loadView() {
        view = NSView()
        view.addSubview(children[0].view)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        children[0].view.frame = view.safeAreaRect
    }
}

/// A pane's root view: the pane in the configured font, reporting the size it needs. A named root type
/// keeps the hosting controller's Objective-C class name resolvable; with an environment closure in its
/// generic arguments `NSStringFromClass` returns nil, and `NSTabViewItem` throws looking up an image by it.
struct SettingsPaneHost<Pane: View>: View {
    let pane: Pane
    let store: SettingsStore
    let reportSize: @MainActor (CGSize) -> Void

    var body: some View {
        pane
            .typography(store)
            .environment(\.reportPaneSize, reportSize)
    }
}

