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
    public let file: SettingsFile

    @ObservationIgnored private var onChange: [@MainActor (SidebarSettings) -> Void] = []
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
        settings = updated
        onChange.forEach { $0(updated) }
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
