import Foundation
import Observation
import os

/// Current settings, kept in sync with `config.toml` in both directions.
///
/// The store watches the file's directory, so edits made by hand or by another tool apply
/// immediately, including atomic replacements. An invalid file keeps the last valid settings and
/// reports the problem in `loadError`.
@MainActor
@Observable
public final class SettingsStore {
    private static let logger = Logger(subsystem: "com.alexgorbatchev.aerospace-sidebar", category: "settings")

    public private(set) var settings: SidebarSettings
    public private(set) var loadError: String?
    public private(set) var saveError: String?
    /// A font shown in place of the saved one while Settings edits it; never written to `config.toml`.
    public private(set) var fontPreview: SidebarSettings.Font?
    public let file: SettingsFile

    @ObservationIgnored private var onChange: [@MainActor (SidebarSettings) -> Void] = []
    @ObservationIgnored private var onFontChange: [@MainActor (SidebarSettings.Font) -> Void] = []
    @ObservationIgnored private var watcher: (any DispatchSourceFileSystemObject)?

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

    /// Reloads whenever the settings directory changes; creates the directory if needed.
    public func startWatching() throws {
        let directory = file.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    public func stopWatching() {
        watcher?.cancel()
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
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
            @unknown default:
                return String(describing: error)
            }
        }
        return String(describing: error)
    }
}
