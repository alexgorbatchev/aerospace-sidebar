import Foundation
import TOML

/// `config.toml` in `${XDG_CONFIG_HOME:-~/.config}/aerospace-sidebar/`.
public struct SettingsFile: Sendable {
    static let header = """
        # aerospace-sidebar settings. Edits apply immediately.
        # Saving from the Settings window rewrites this file and drops comments.


        """

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(home: URL, environment: [String: String]) {
        let configHome = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        self.init(url: configHome.appendingPathComponent("aerospace-sidebar/config.toml"))
    }

    /// The defaults when the file does not exist.
    /// - Throws: When the file cannot be read or holds invalid settings.
    public func load() throws -> SidebarSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return SidebarSettings() }
        return try TOMLDecoder().decode(SidebarSettings.self, from: String(contentsOf: url, encoding: .utf8))
    }

    /// Writes the settings atomically; an existing file keeps its permissions. A symlinked file, such as one kept in a
    /// dotfiles repository, is written at its target, also when that is missing, and stays a symlink: an atomic
    /// write at the link would replace it with a file of its own.
    public func save(_ settings: SidebarSettings) throws {
        let encoder = TOMLEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encodeToString(settings)
        let destination = url.symlinkTarget ?? url
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (Self.header + body).write(to: destination, atomically: true, encoding: .utf8)
    }
}
