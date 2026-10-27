import AppKit
import SwiftUI

/// Owns the Settings window: toolbar tabs (Setup, General) over a Cancel/Save button bar.
///
/// The app never activates (its sidebar is a non-activating panel), and since macOS 14
/// `NSApp.activate()` from a background app is only a request the system may decline. Switching
/// the activation policy to `.regular` while Settings is open would make AeroSpace re-classify the
/// sidebar panel as a window. Settings is therefore a non-activating panel too: it orders itself
/// in front and takes keyboard focus without activating the app.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    public let window: NSPanel
    public let tabs: SettingsTabsController
    let editor: SettingsEditor
    private let store: SettingsStore
    private let onboarding: OnboardingModel
    private let aeroSpace: AeroSpaceSync
    private let fontChooser: FontChooser
    private let workspaceCenter: NotificationCenter
    private var activationObserver: NSObjectProtocol?
    static let systemSettingsBundleID = "com.apple.systempreferences"

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
        panelType: NSPanel.Type = NSPanel.self,
        reveal: @escaping (URL) -> Void,
        terminate: @escaping @MainActor (Any?) -> Void = NSApplication.shared.terminate
    ) {
        self.store = store
        self.onboarding = onboarding
        self.aeroSpace = aeroSpace
        self.fontChooser = fontChooser
        self.workspaceCenter = workspaceCenter
        editor = SettingsEditor(store: store)
        tabs = SettingsTabsController()
        window = panelType.init(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        let close: () -> Void = { [weak self] in
            self?.window.orderOut(nil)
            self?.fontChooser.close()
        }
        tabs.onSelectedSizeChange = { [weak self] animate in self?.sizeWindowToSelectedPane(animate: animate) }
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        tabs.addTabViewItem(Self.item(
            "Setup", symbol: "checklist",
            SetupPane(onboarding: onboarding, aeroSpace: aeroSpace, reveal: reveal).typography(store)
        ))
        tabs.addTabViewItem(Self.item(
            "General", symbol: "gearshape",
            GeneralPane(
                editor: editor, aeroSpace: aeroSpace, configURL: store.file.url, reveal: reveal,
                chooseFont: { [weak self] in self?.chooseFont() }, quit: { terminate(nil) }, close: close
            ).typography(store)
        ))

        window.title = "Settings"
        window.toolbarStyle = .preference
        window.contentViewController = tabs
        window.isReleasedWhenClosed = false
        // Panels hide when their app deactivates by default; this app is never active.
        window.hidesOnDeactivate = false
        // Settings stays above other apps' windows until it is closed, except System Settings, where the
        // Setup steps send the user: floating over it, Settings would cover the permission lists and their
        // switches.
        window.isFloatingPanel = NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Self.systemSettingsBundleID
        activationObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleIdentifier = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.follow(frontmostApp: bundleIdentifier) }
        }
        window.delegate = self
        sizePanes()
        window.center()
        // Text sizes follow the font, previewed or saved, so the panes grow and shrink with it.
        store.observeFont { [weak self] _ in self?.sizePanes() }
    }

    isolated deinit {
        activationObserver.map(workspaceCenter.removeObserver)
    }

    /// Floats unless System Settings is in front. A window keeps its place in the stack when its level
    /// changes, so it is also ordered behind or in front explicitly.
    func follow(frontmostApp bundleIdentifier: String?) {
        let floats = bundleIdentifier != Self.systemSettingsBundleID
        guard window.isFloatingPanel != floats else { return }
        window.isFloatingPanel = floats
        guard window.isVisible else { return }
        if floats {
            window.orderFrontRegardless()
        } else {
            window.orderBack(nil)
        }
    }

    /// Opens on the Setup tab with a fresh draft and status.
    public func show() {
        editor.revert()
        onboarding.refresh()
        aeroSpace.refresh()
        tabs.selectedTabViewItemIndex = 0
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

    /// Each pane reports its content size as its `preferredContentSize`, which changes with its content
    /// and font; the window takes the selected pane's size.
    private func sizePanes() {
        // A layout pass applies pending SwiftUI updates, such as a font change, so the sizes are current.
        tabs.tabViewItems.forEach { $0.viewController?.view.layoutSubtreeIfNeeded() }
        sizeWindowToSelectedPane(animate: false)
    }

    /// Fits the window to the selected pane, keeping its top edge in place.
    private func sizeWindowToSelectedPane(animate: Bool) {
        let index = tabs.selectedTabViewItemIndex
        guard tabs.tabViewItems.indices.contains(index), let selected = tabs.tabViewItems[index].viewController else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let frame = window.frameRect(forContentRect: NSRect(origin: content.origin, size: selected.preferredContentSize))
        let top = window.frame.maxY
        window.setFrame(
            NSRect(x: window.frame.minX, y: top - frame.height, width: frame.width, height: frame.height),
            display: true,
            animate: animate && window.isVisible
        )
    }

    private static func item(_ label: String, symbol: String, _ view: some View) -> NSTabViewItem {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }
}

/// Reports when the selected pane's size changes, by switching tabs or by its content, because
/// `NSTabViewController` does not resize the window for either.
public final class SettingsTabsController: NSTabViewController {
    /// Called with `true` for a tab switch, which animates, and `false` for a content change.
    var onSelectedSizeChange: ((_ animate: Bool) -> Void)?

    override public func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelectedSizeChange?(true)
    }

    override public func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        if tabViewItems.indices.contains(selectedTabViewItemIndex), tabViewItems[selectedTabViewItemIndex].viewController === viewController {
            onSelectedSizeChange?(false)
        }
    }
}
