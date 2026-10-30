import Foundation
import Observation
import os

/// Current settings, kept in sync with `config.toml` in both directions.
///
/// The store watches the file, so edits made by hand or by another tool apply right away, whether
/// they write the file in place or replace it atomically. An invalid file keeps the last valid settings, or the
/// defaults when nothing valid has loaded since launch, and reports the problem in `loadError`.
@MainActor
@Observable
public final class SettingsStore {
    private static let logger = Logger(category: "settings")

    public private(set) var settings: SidebarSettings
    public private(set) var loadError: String?
    /// Whether `settings` came from `config.toml` or a save, rather than being the defaults an invalid file left
    /// at launch.
    private var hasLoaded = false
    public private(set) var saveError: String?
    /// A font shown in place of the saved one while Settings edits it; never written to `config.toml`.
    public private(set) var fontPreview: SidebarSettings.Font?
    /// A background shown in place of the saved one while Settings edits it; never written to `config.toml`.
    public private(set) var backgroundPreview: SidebarSettings.Background?
    public let file: SettingsFile

    @ObservationIgnored private var onChange: [@MainActor (SidebarSettings) -> Void] = []
    @ObservationIgnored private var onFontChange: [@MainActor (SidebarSettings.Font) -> Void] = []
    @ObservationIgnored private var onBackgroundChange: [@MainActor (SidebarSettings.Background) -> Void] = []
    @ObservationIgnored private var watcher: FileWatcher?

    public init(file: SettingsFile) {
        self.file = file
        do {
            settings = try file.load()
            hasLoaded = true
        } catch {
            settings = SidebarSettings()
            loadError = Self.describe(error)
        }
    }

    /// Calls `observer` now and after every change.
    public func observe(_ observer: @escaping @MainActor (SidebarSettings) -> Void) {
        onChange.append(observer)
        observer(settings)
    }

    /// `loadError` as a sentence that also says which settings are in effect meanwhile: the last valid ones, or
    /// the defaults when the file has not loaded since launch.
    public var loadProblem: String? {
        loadError.map { error in
            hasLoaded
                ? "config.toml is invalid, so the previous settings stay in effect: \(error)"
                : "config.toml is invalid, so the default settings are in effect: \(error)"
        }
    }

    /// The font to render: the preview while there is one, otherwise the saved font.
    public var font: SidebarSettings.Font { fontPreview ?? settings.font }

    /// Calls `observer` whenever `font` changes, by a preview or by the settings.
    public func observeFont(_ observer: @escaping @MainActor (SidebarSettings.Font) -> Void) {
        onFontChange.append(observer)
    }

    /// Shows `font` instead of the saved font until `nil` ends the preview.
    public func preview(font: SidebarSettings.Font?) {
        let before = self.font
        fontPreview = font
        notifyIfFontChanged(from: before)
    }

    /// The background to show: the preview while there is one, otherwise the saved background.
    public var background: SidebarSettings.Background { backgroundPreview ?? settings.background }

    /// Calls `observer` whenever `background` changes, by a preview or by the settings.
    public func observeBackground(_ observer: @escaping @MainActor (SidebarSettings.Background) -> Void) {
        onBackgroundChange.append(observer)
    }

    /// Shows `background` instead of the saved background until `nil` ends the preview.
    public func preview(background: SidebarSettings.Background?) {
        let before = self.background
        backgroundPreview = background
        notifyIfBackgroundChanged(from: before)
    }

    /// Changes settings and writes `config.toml`. Settings the file does not hold, because a save failed or
    /// the file does not load, are written even when the change leaves them as they are, so `saveError`
    /// tells whether they are on disk.
    public func update(_ change: (inout SidebarSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings || saveError != nil || loadError != nil else { return }
        do {
            try file.save(updated)
            saveError = nil
            // The file now holds these settings, whatever made it invalid before.
            loadError = nil
            hasLoaded = true
        } catch {
            saveError = Self.describe(error)
            Self.logger.error("Cannot save settings: \(self.saveError ?? "", privacy: .public)")
        }
        apply(updated)
    }

    /// Re-reads `config.toml`.
    public func reload() {
        do {
            let loaded = try file.load()
            loadError = nil
            hasLoaded = true
            apply(loaded)
        } catch {
            loadError = Self.describe(error)
            Self.logger.error("Cannot read settings: \(self.loadError ?? "", privacy: .public)")
        }
    }

    /// Reloads whenever `config.toml` changes, once it has been unchanged for a moment so a file still
    /// being written is not read; creates the directory if needed, so the file's creation is seen too.
    public func startWatching() throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        watcher?.stop()
        let watcher = FileWatcher(url: file.url, delay: .milliseconds(100)) { [weak self] in self?.reload() }
        watcher.start()
        self.watcher = watcher
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    private func apply(_ updated: SidebarSettings) {
        guard updated != settings else { return }
        let font = self.font
        let background = self.background
        settings = updated
        onChange.forEach { $0(updated) }
        notifyIfFontChanged(from: font)
        notifyIfBackgroundChanged(from: background)
    }

    private func notifyIfFontChanged(from before: SidebarSettings.Font) {
        let font = self.font
        guard font != before else { return }
        onFontChange.forEach { $0(font) }
    }

    private func notifyIfBackgroundChanged(from before: SidebarSettings.Background) {
        let background = self.background
        guard background != before else { return }
        onBackgroundChange.forEach { $0(background) }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? DecodingError {
            switch error {
            case .dataCorrupted(let context), .keyNotFound(_, let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
                // Array elements read as `rules[2]`, not `rules.Index 2`.
                let path = context.codingPath.reduce(into: "") { path, key in
                    if let index = key.intValue {
                        path += "[\(index)]"
                    } else {
                        path += (path.isEmpty ? "" : ".") + key.stringValue
                    }
                }
                return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
            @unknown default:
                return String(describing: error)
            }
        }
        return String(describing: error)
    }
}
