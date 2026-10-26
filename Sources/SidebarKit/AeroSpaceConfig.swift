import CoreGraphics
import Foundation
import TOMLDecoder

/// The sidebar strip reserved by AeroSpace's `gaps.outer.right` on the `main` monitor.
///
/// AeroSpace's config is the single source of truth for the sidebar width:
/// `outer.right = [{ monitor.main = 305 }, 5]` reserves 305pt on the main monitor and 5pt
/// elsewhere, so the sidebar is 300pt wide and keeps the regular 5pt gap to tiled windows.
public struct AeroSpaceConfig: Equatable, Sendable {
    public enum Error: Swift.Error, Equatable {
        case notFound(searched: [URL])
        case ambiguous([URL])
        case noMainMonitorGap
        case gapNotWiderThanFallback(main: Int, fallback: Int)
    }

    public let sidebarWidth: CGFloat

    /// Parses AeroSpace config TOML and derives the sidebar width from `gaps.outer.right`.
    public init(toml: String) throws {
        let config = try TOMLDecoder().decode(ConfigFile.self, from: toml)
        guard case .perMonitor(let entries)? = config.gaps?.outer?.right,
              case .value(let fallback)? = entries.last,
              let main = entries.lazy.compactMap({ $0.mainMonitorValue }).first
        else {
            throw Error.noMainMonitorGap
        }
        guard main > fallback else {
            throw Error.gapNotWiderThanFallback(main: main, fallback: fallback)
        }
        sidebarWidth = CGFloat(main - fallback)
    }

    /// Loads the config AeroSpace itself would load, using the same discovery rules:
    /// `~/.aerospace.toml` or `${XDG_CONFIG_HOME:-~/.config}/aerospace/aerospace.toml`,
    /// and an error when both exist.
    public static func load(home: URL, environment: [String: String]) throws -> AeroSpaceConfig {
        let configHome = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        let candidates = [
            home.appendingPathComponent(".aerospace.toml"),
            configHome.appendingPathComponent("aerospace/aerospace.toml"),
        ]
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        switch existing.count {
        case 0: throw Error.notFound(searched: candidates)
        case 1: return try AeroSpaceConfig(toml: String(contentsOf: existing[0], encoding: .utf8))
        default: throw Error.ambiguous(existing)
        }
    }
}

private struct ConfigFile: Decodable {
    struct Gaps: Decodable {
        let outer: Outer?
    }

    struct Outer: Decodable {
        let right: GapSetting?
    }

    let gaps: Gaps?
}

/// `gaps.outer.*` is either a constant or an array of `{ monitor.<pattern> = n }` tables ending in a fallback.
private enum GapSetting: Decodable {
    case constant(Int)
    case perMonitor([GapEntry])

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(Int.self) {
            self = .constant(value)
            return
        }
        var container = try decoder.unkeyedContainer()
        var entries: [GapEntry] = []
        while !container.isAtEnd {
            entries.append(try container.decode(GapEntry.self))
        }
        self = .perMonitor(entries)
    }
}

private enum GapEntry: Decodable {
    case value(Int)
    case monitor([String: Int])

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(Int.self) {
            self = .value(value)
        } else {
            self = .monitor(try MonitorTable(from: decoder).monitor)
        }
    }

    var mainMonitorValue: Int? {
        if case .monitor(let patterns) = self { patterns["main"] } else { nil }
    }

    private struct MonitorTable: Decodable {
        let monitor: [String: Int]
    }
}
