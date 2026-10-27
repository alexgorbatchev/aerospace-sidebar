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
    private let fontChooser: FontChooser

    /// - Parameter reveal: Shows a file in Finder.
    public convenience init(
        store: SettingsStore,
        onboarding: OnboardingModel,
        reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    ) {
        self.init(store: store, onboarding: onboarding, fontChooser: FontChooser(), reveal: reveal)
    }

    init(store: SettingsStore, onboarding: OnboardingModel, fontChooser: FontChooser, reveal: @escaping (URL) -> Void) {
        self.onboarding = onboarding
        self.fontChooser = fontChooser
        editor = SettingsEditor(store: store)
        tabs = NSTabViewController()
        window = NSPanel(
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
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        tabs.addTabViewItem(Self.item(
            "Setup", symbol: "checklist",
            SetupPane(onboarding: onboarding, editor: editor, close: close).typography(store)
        ))
        tabs.addTabViewItem(Self.item(
            "General", symbol: "gearshape",
            GeneralPane(
                editor: editor, configURL: store.file.url, reveal: reveal,
                chooseFont: { [weak self] in self?.chooseFont() }, close: close
            ).typography(store)
        ))

        window.title = "Settings"
        window.toolbarStyle = .preference
        window.contentViewController = tabs
        window.isReleasedWhenClosed = false
        // Panels hide when their app deactivates by default; this app is never active.
        window.hidesOnDeactivate = false
        // Settings stays above other apps' windows until it is closed, for example while the user
        // grants Accessibility in System Settings.
        window.isFloatingPanel = true
        window.delegate = self
        sizeToLargestPane()
        window.center()
        // Text sizes follow the font, previewed or saved, so the panes grow and shrink with it.
        store.observeFont { [weak self] _ in self?.sizeToLargestPane() }
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
        fontChooser.close()
    }

    /// Fonts picked in the font panel go into the draft, like any other edit.
    func chooseFont() {
        fontChooser.choose(editor.draft.font, beside: window) { [editor] in editor.draft.font = $0 }
    }

    /// Every pane gets the size of the largest one, so switching tabs never resizes the window. The
    /// window keeps its top edge in place.
    private func sizeToLargestPane() {
        let sizes = tabs.tabViewItems.compactMap(\.viewController?.view).map { view in
            // A layout pass applies pending SwiftUI updates, such as a font change, before measuring.
            view.layoutSubtreeIfNeeded()
            return view.intrinsicContentSize
        }
        let size = NSSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0)
        for item in tabs.tabViewItems {
            item.viewController?.preferredContentSize = size
        }
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
        window.contentMinSize = size
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
