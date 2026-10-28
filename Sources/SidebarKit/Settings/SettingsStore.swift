import Foundation
import Observation
import os

/// Current settings, kept in sync with `config.toml` in both directions.
///
/// The store watches the file, so edits made by hand or by another tool apply right away, whether
/// they write the file in place or replace it atomically. An invalid file keeps the last valid settings and
/// reports the problem in `loadError`.
@MainActor
@Observable
public final class SettingsStore {
    private static let logger = Logger(category: "settings")

    public private(set) var settings: SidebarSettings
    public private(set) var loadError: String?
    public private(set) var saveError: String?
    /// A font shown in place of the saved one while Settings edits it; never written to `config.toml`.
    public private(set) var fontPreview: SidebarSettings.Font?
    public let file: SettingsFile

    @ObservationIgnored private var onChange: [@MainActor (SidebarSettings) -> Void] = []
    @ObservationIgnored private var onFontChange: [@MainActor (SidebarSettings.Font) -> Void] = []
    @ObservationIgnored private var watcher: FileWatcher?

    public init(file: SettingsFile) {
        self.file = file
        do {
            settings = try file.load()
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

    /// Changes settings and writes `config.toml`.
    public func update(_ change: (inout SidebarSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        do {
            try file.save(updated)
            saveError = nil
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
        settings = updated
        onChange.forEach { $0(updated) }
        notifyIfFontChanged(from: font)
    }

    private func notifyIfFontChanged(from before: SidebarSettings.Font) {
        let font = self.font
        guard font != before else { return }
        onFontChange.forEach { $0(font) }
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
