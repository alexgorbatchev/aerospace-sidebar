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
    public let tabs: NSTabViewController
    let editor: SettingsEditor
    private let onboarding: OnboardingModel

    /// - Parameter reveal: Shows a file in Finder.
    public init(
        store: SettingsStore,
        onboarding: OnboardingModel,
        reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    ) {
        self.onboarding = onboarding
        editor = SettingsEditor(store: store)
        tabs = NSTabViewController()
        window = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        let close: () -> Void = { [weak self] in self?.window.orderOut(nil) }
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        tabs.addTabViewItem(Self.item(
            "Setup", symbol: "checklist",
            SetupPane(onboarding: onboarding, editor: editor, close: close)
        ))
        tabs.addTabViewItem(Self.item(
            "General", symbol: "gearshape",
            GeneralPane(editor: editor, configURL: store.file.url, reveal: reveal, close: close)
        ))

        window.title = "Settings"
        window.toolbarStyle = .preference
        window.contentViewController = tabs
        window.isReleasedWhenClosed = false
        // Panels hide when their app deactivates by default; this app is never active.
        window.hidesOnDeactivate = false
        window.delegate = self
        sizeToLargestPane()
    }

    /// Opens on the Setup tab with a fresh draft and status.
    public func show() {
        editor.revert()
        onboarding.refresh()
        tabs.selectedTabViewItemIndex = 0
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// Closing the window discards unsaved edits, like Cancel.
    public func windowWillClose(_ notification: Notification) {
        editor.revert()
    }

    /// Every pane gets the size of the largest one, so switching tabs never resizes the window.
    private func sizeToLargestPane() {
        let sizes = tabs.tabViewItems.compactMap { $0.viewController?.view.fittingSize }
        let size = NSSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0)
        for item in tabs.tabViewItems {
            item.viewController?.preferredContentSize = size
        }
        window.setContentSize(size)
        window.contentMinSize = size
        window.center()
    }

    private static func item(_ label: String, symbol: String, _ view: some View) -> NSTabViewItem {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.intrinsicContentSize]
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }
}
