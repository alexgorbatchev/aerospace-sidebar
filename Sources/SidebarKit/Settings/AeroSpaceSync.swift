import AppKit
import Observation

/// Keeps the AeroSpace config in line with the sidebar's saved side and width, and reports on it to
/// Settings. It runs from launch, whether or not Settings was ever opened.
@MainActor
@Observable
public final class AeroSpaceSync {
    public private(set) var state = AeroSpaceSetup.State.notFound
    /// Result of the last update or copy.
    public private(set) var message: String?
    public private(set) var isUpdating = false

    @ObservationIgnored private let setup: AeroSpaceSetup
    @ObservationIgnored private let copy: @MainActor (String) -> Void
    @ObservationIgnored private let sidebar: @MainActor () -> SidebarSettings.Sidebar
    @ObservationIgnored private var isSyncPending = false
    /// The config before the edit AeroSpace rejected, and the sidebar it was edited for, while that was the
    /// last attempt. AeroSpace would reject the same edit again, so syncs leave that config alone until it
    /// or the sidebar changes. A later attempt forgets it: a rejection can pass, such as a check made while
    /// AeroSpace restarted, and an accepted edit shows it has.
    @ObservationIgnored private var rejection: (original: String, sidebar: SidebarSettings.Sidebar)?
    /// One per place AeroSpace looks for its config, and per symlinked config's target.
    @ObservationIgnored private var watchers: [URL: FileWatcher] = [:]
    @ObservationIgnored private var watchDelay = Duration.seconds(1)

    /// - Parameter sidebar: The saved side and width, which the AeroSpace gap must match.
    public init(
        setup: AeroSpaceSetup,
        sidebar: @escaping @MainActor () -> SidebarSettings.Sidebar,
        copy: @escaping @MainActor (String) -> Void = AeroSpaceSync.copying(to: .general)
    ) {
        self.setup = setup
        self.sidebar = sidebar
        self.copy = copy
        refresh()
    }

    public var isConfigured: Bool {
        if case .ready(let analysis, _) = state { analysis.isConfigured } else { false }
    }

    /// The config file AeroSpace loads, when there is a readable one.
    public var configURL: URL? {
        if case .ready(_, let url) = state { url } else { nil }
    }

    public func refresh() {
        state = setup.state(for: sidebar())
    }

    /// Edits the config to reserve the saved sidebar and reloads AeroSpace, for Update Config. It tries again
    /// an edit AeroSpace rejected, and a change that arrives meanwhile is synced once it ends.
    /// - Parameter rewritingBlock: Writes the managed block and reloads even when the config already
    ///   matches, for Write Again.
    public func update(rewritingBlock: Bool = false) async {
        await performUpdate(rewritingBlock: rewritingBlock)
        if isSyncPending {
            await sync()
        }
    }

    /// Updates the config when it no longer reserves the saved sidebar or lacks the float rule, such as
    /// after the sidebar's side or width changed or a generator rewrote the config. A missing or
    /// unreadable config is left to Settings › Sidebar, and so is a config whose edit AeroSpace rejected,
    /// until it or the sidebar changes. A change that arrives during an update is synced once that update
    /// ends.
    public func sync() async {
        guard !isUpdating else {
            isSyncPending = true
            return
        }
        repeat {
            isSyncPending = false
            refresh()
            guard case .ready(let analysis, let url) = state, !analysis.isConfigured, !wasRejected(url) else { continue }
            await performUpdate(rewritingBlock: false)
        } while isSyncPending
    }

    /// Syncs now and whenever the config changes on disk, once it has been unchanged for `delay`: a config
    /// AeroSpace would load created, edited, moved or removed in any place it looks.
    public func start(delay: Duration = .seconds(1)) {
        stop()
        watchDelay = delay
        watchConfigs()
        Task { await sync() }
    }

    public func stop() {
        watchers.values.forEach { $0.stop() }
        watchers = [:]
    }

    private func performUpdate(rewritingBlock: Bool) async {
        isUpdating = true
        defer { isUpdating = false }
        let sidebar = sidebar()
        rejection = nil
        do {
            switch try await setup.apply(sidebar: sidebar, rewritingBlock: rewritingBlock) {
            case .updated(let backup):
                message = "Updated and reloaded AeroSpace. The previous config is in \(backup.lastPathComponent)."
            case .updatedWithExistingProblems(let backup, let problems):
                message = "Updated the config (previous one in \(backup.lastPathComponent)) and asked AeroSpace to reload it. AeroSpace reports problems the config already had: \(problems)"
            case .updatedWithoutReload(let backup):
                message = "Updated the config (previous one in \(backup.lastPathComponent)), but the aerospace command was not found. Reload AeroSpace yourself."
            case .updatedWhileStopped(let backup):
                message = "Updated the config (previous one in \(backup.lastPathComponent)). AeroSpace is not running and reads it when it starts."
            }
        } catch {
            if case .rejected(_, let original) = error {
                rejection = (original, sidebar)
            }
            message = Self.describe(error)
        }
        refresh()
    }

    /// Whether the config at `url` is the one AeroSpace rejected the edit of for the saved sidebar.
    private func wasRejected(_ url: URL) -> Bool {
        guard let rejection, rejection.sidebar == sidebar() else { return false }
        return (try? String(contentsOf: url, encoding: .utf8)) == rejection.original
    }

    /// Watches the files `AeroSpaceSetup.configsToWatch()` names, which change when a config becomes or
    /// stops being a symlink.
    private func watchConfigs() {
        let urls = setup.configsToWatch()
        for (url, watcher) in watchers where !urls.contains(url) {
            watcher.stop()
            watchers[url] = nil
        }
        for url in urls where watchers[url] == nil {
            let watcher = FileWatcher(url: url, delay: watchDelay) { [weak self] in
                self?.watchConfigs()
                Task { await self?.sync() }
            }
            watcher.start()
            watchers[url] = watcher
        }
    }

    /// Copies the TOML to add by hand.
    public func copySnippet() {
        copy(AeroSpaceConfigEditor.snippet(for: sidebar()))
        message = "Copied the AeroSpace settings. Put the block in your config's [gaps] table, add the rule, and run `aerospace reload-config`."
    }

    /// Copies text to `pasteboard`, replacing what it holds. Settings copies to the general pasteboard;
    /// tests pass a private one, which leaves the user's clipboard alone.
    public static func copying(to pasteboard: NSPasteboard) -> @MainActor (String) -> Void {
        { text in
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    static func describe(_ error: AeroSpaceSetup.SetupError) -> String {
        switch error {
        case .notFound:
            "No AeroSpace config found. Create ~/.config/aerospace/aerospace.toml from AeroSpace's default config first."
        case .unsupported(let reason):
            "Cannot edit the config automatically: \(reason). Add the settings by hand (Copy Settings)."
        case .rejected(let problems, _):
            "AeroSpace rejected the change, so the original config was restored: \(problems)"
        case .rejectedAndReplaced(let problems):
            "AeroSpace rejected the change, but the config was saved again meanwhile, so that version was kept: \(problems)"
        case .io(let reason):
            "Cannot update the config: \(reason)"
        }
    }
}
