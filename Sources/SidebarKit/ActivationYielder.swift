import AppKit

/// Hands activation back to the app the user was in whenever something other than a click on the font panel
/// activates the sidebar.
///
/// Launch Services activates an app it launches or opens a URL in unless the opener asks it not to (`open -g`), so
/// a web page's link or a Shortcuts action that pushes an `aerospace-sidebar://` notification, and `open` at launch,
/// make this app the active one. The sidebar and Settings are non-activating panels that never need it to be, and
/// while it is, the app the user was typing in has no key window: keystrokes go nowhere until the user clicks back.
///
/// Only regular apps are handed activation back. Launchers such as Spotlight, Raycast and Alfred, common ways to
/// open such a URL, are accessory apps that are in front for a moment and close their window as they run the
/// command, so activating one would again leave no key window.
///
/// A click on the font panel leaves activation alone: it is the one window that activates the app when clicked,
/// and its fields need the app active to take the keyboard. The pointer is still over it when AppKit reports the
/// activation, however long the main thread took, while the mouse buttons may already be up.
@MainActor
public final class ActivationYielder {
    private let workspaceCenter: NotificationCenter
    private let processIdentifier: pid_t
    private let isPointerOverFontPanel: @MainActor () -> Bool
    private let handOver: @MainActor (NSRunningApplication) -> Bool
    private let deactivate: @MainActor () -> Void
    private var activationObserver: NSObjectProtocol?
    /// The regular app most recently in front other than this one.
    private(set) var previousApp: NSRunningApplication?

    /// - Parameters:
    ///   - frontmostApp: The app in front now.
    ///   - processIdentifier: This app's process.
    ///   - handOver: Activates the app it is given in place of this one; false when the system refuses.
    ///   - deactivate: Deactivates this app, so that the system activates the next one.
    public init(
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        frontmostApp: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
        processIdentifier: pid_t = getpid(),
        isPointerOverFontPanel: @escaping @MainActor () -> Bool = ActivationYielder.isPointerOverFontPanel,
        handOver: @escaping @MainActor (NSRunningApplication) -> Bool = ActivationYielder.yieldActivation(to:),
        deactivate: @escaping @MainActor () -> Void = { NSApp.deactivate() }
    ) {
        self.workspaceCenter = workspaceCenter
        self.processIdentifier = processIdentifier
        self.isPointerOverFontPanel = isPointerOverFontPanel
        self.handOver = handOver
        self.deactivate = deactivate
        follow(frontmostApp)
        activationObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.follow(app) }
        }
    }

    isolated deinit {
        activationObserver.map(workspaceCenter.removeObserver)
    }

    /// Hands activation back to the previous app unless the user clicked the font panel. Without an app to hand
    /// it to, or when the system refuses, such as for an app that has quit since, this app deactivates and the
    /// system picks the next one, rather than leaving this app active without a key window.
    public func appDidBecomeActive() {
        guard !isPointerOverFontPanel() else { return }
        if let previousApp, handOver(previousApp) { return }
        deactivate()
    }

    private func follow(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != processIdentifier, app.activationPolicy == .regular else { return }
        previousApp = app
    }

    /// Whether the pointer is over the font panel while it shows. Checking does not create the shared panel.
    public static func isPointerOverFontPanel() -> Bool {
        isPoint(NSEvent.mouseLocation, over: NSFontPanel.sharedFontPanelExists ? NSFontPanel.shared : nil)
    }

    /// Whether `point`, in screen coordinates, is over `window` while it shows.
    static func isPoint(_ point: NSPoint, over window: NSWindow?) -> Bool {
        guard let window, window.isVisible else { return false }
        return window.frame.contains(point)
    }

    /// Cooperative activation: only the active app can pass activation on, by yielding to the app before
    /// activating it.
    public static func yieldActivation(to app: NSRunningApplication) -> Bool {
        NSApp.yieldActivation(to: app)
        return app.activate(from: .current)
    }
}
