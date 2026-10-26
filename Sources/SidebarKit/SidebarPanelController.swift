import AppKit
import SwiftUI

/// Owns the sidebar panel and keeps it pinned to the reserved strip on the target screen.
@MainActor
public final class SidebarPanelController: NSObject {
    /// Visible frame of the primary screen: the one with the menu bar, which AeroSpace calls `main`.
    public static let primaryScreenVisibleFrame: @MainActor () -> CGRect? = {
        NSScreen.screens.first?.visibleFrame
    }

    public let panel: NSPanel
    private let layout: @MainActor () -> SidebarLayout
    private let targetVisibleFrame: @MainActor () -> CGRect?

    /// - Parameters:
    ///   - model: State the sidebar renders.
    ///   - layout: Resolved on every pin, so screen changes also pick up a changed AeroSpace gap.
    ///   - terminate: Called with `nil` when the user quits from the sidebar.
    public init(
        model: SidebarModel,
        layout: @escaping @MainActor () -> SidebarLayout = { SidebarLayout.fromAeroSpaceConfig() },
        targetVisibleFrame: @escaping @MainActor () -> CGRect? = SidebarPanelController.primaryScreenVisibleFrame,
        notificationCenter: NotificationCenter = .default,
        terminate: @escaping @MainActor (Any?) -> Void = NSApplication.shared.terminate
    ) {
        self.layout = layout
        self.targetVisibleFrame = targetVisibleFrame
        self.panel = Self.makePanel(model: model, quit: { terminate(nil) })
        super.init()
        notificationCenter.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Moves the panel onto the reserved strip and shows it, or hides it when no target screen exists.
    public func pin() {
        guard let visibleFrame = targetVisibleFrame() else {
            panel.orderOut(nil)
            return
        }
        panel.setFrame(layout().frame(in: visibleFrame), display: true)
        panel.orderFrontRegardless()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        pin()
    }

    private static func makePanel(model: SidebarModel, quit: @escaping @MainActor () -> Void) -> NSPanel {
        // Borderless with no close button: combined with LSUIElement, AeroSpace classifies
        // the window as a popup and neither tiles it nor hides it on workspace switches.
        let panel = SidebarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        // The app never becomes active, so follow-window-state would render it permanently inactive.
        background.state = .active

        let content = NSHostingView(rootView: SidebarView(model: model, quit: quit))
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        return panel
    }
}

/// Borderless windows refuse key status by default, which blocks clicks from focusing
/// the sidebar and keyboard input from reaching it. `.nonactivatingPanel` lets it become
/// key without activating the app or stealing activation from the frontmost app.
private final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
