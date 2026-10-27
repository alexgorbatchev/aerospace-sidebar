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
    @ObservationIgnored private var watcher: FileWatcher?

    /// - Parameter sidebar: The saved side and width, which the AeroSpace gap must match.
    public init(
        setup: AeroSpaceSetup,
        sidebar: @escaping @MainActor () -> SidebarSettings.Sidebar,
        copy: @escaping @MainActor (String) -> Void = AeroSpaceSync.copyToPasteboard
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

    /// Edits the config to reserve the saved sidebar and reloads AeroSpace.
    public func update() async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            switch try await setup.apply(sidebar: sidebar()) {
            case .updated(let backup):
                message = "Updated and reloaded AeroSpace. The previous config is in \(backup.lastPathComponent)."
            case .updatedWithoutReload(let backup):
                message = "Updated the config (previous one in \(backup.lastPathComponent)), but the aerospace command was not found. Reload AeroSpace yourself."
            case .updatedWhileStopped(let backup):
                message = "Updated the config (previous one in \(backup.lastPathComponent)). AeroSpace is not running and reads it when it starts."
            }
        } catch {
            message = Self.describe(error)
        }
        refresh()
    }

    /// Updates the config when it no longer reserves the saved sidebar or lacks the float rule, such as
    /// after the sidebar's side or width changed or a generator rewrote the config. A missing or
    /// unreadable config is left to Setup. A change that arrives during an update is synced once that
    /// update ends.
    public func sync() async {
        guard !isUpdating else {
            isSyncPending = true
            return
        }
        repeat {
            isSyncPending = false
            refresh()
            guard case .ready(let analysis, _) = state, !analysis.isConfigured else { continue }
            await update()
        } while isSyncPending
    }

    /// Syncs now and whenever the config changes on disk, once it has been unchanged for `delay`.
    public func start(delay: Duration = .seconds(1)) {
        watcher?.stop()
        let watcher = FileWatcher(url: setup.configToWatch(), delay: delay) { [weak self] in
            Task { await self?.sync() }
        }
        watcher.start()
        self.watcher = watcher
        Task { await sync() }
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Copies the TOML to add by hand.
    public func copySnippet() {
        copy(AeroSpaceConfigEditor.snippet(for: sidebar()))
        message = "Copied the AeroSpace settings. Put the block in your config's [gaps] table, add the rule, and run `aerospace reload-config`."
    }

    public static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func describe(_ error: AeroSpaceSetup.SetupError) -> String {
        switch error {
        case .notFound:
            "No AeroSpace config found. Create ~/.config/aerospace/aerospace.toml from AeroSpace's default config first."
        case .unsupported(let reason):
            "Cannot edit the config automatically: \(reason). Add the settings by hand (Copy Settings)."
        case .rejected(let output):
            "AeroSpace rejected the change, so the original config was restored: \(output)"
        case .io(let reason):
            "Cannot update the config: \(reason)"
        }
    }
}
