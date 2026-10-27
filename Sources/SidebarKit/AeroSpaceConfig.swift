import Foundation
import TOMLDecoder

/// The `gaps.outer.left` and `gaps.outer.right` settings of an AeroSpace config.
///
/// AeroSpace reserves the sidebar's strip with a `monitor.main` entry on the sidebar's side:
/// `outer.right = [{ monitor.main = 305 }, 5]` reserves 305pt on the main monitor and 5pt elsewhere,
/// which leaves a 300pt sidebar and the regular 5pt gap to tiled windows.
public struct AeroSpaceConfig: Equatable, Sendable {
    public enum Error: Swift.Error, Equatable {
        case notFound(searched: [URL])
        case ambiguous([URL])
        /// A per-monitor gap array that does not end in a fallback number, or has a table with several monitors.
        case unsupportedGap(side: SidebarSettings.Sidebar.Side)
    }

    /// One `{ monitor.<pattern> = <value> }` entry of a per-monitor gap.
    public struct MonitorGap: Equatable, Sendable {
        public var pattern: String
        public var value: Int
    }

    /// One side's outer gap.
    public struct Gap: Equatable, Sendable {
        /// The gap on monitors without their own entry; 0 when the side is unset.
        public var fallback: Int
        /// The per-monitor entries in order; empty for a constant gap.
        public var monitors: [MonitorGap] = []

        /// The `monitor.main` entry, when there is one.
        public var main: Int? { monitors.first { $0.pattern == "main" }?.value }

        /// The strip the `monitor.main` entry reserves beyond the fallback; nil when it reserves none.
        public var reservedWidth: Int? {
            guard let main, main > fallback else { return nil }
            return main - fallback
        }
    }

    public let left: Gap
    public let right: Gap

    public func gap(on side: SidebarSettings.Sidebar.Side) -> Gap {
        side == .left ? left : right
    }

    /// Parses AeroSpace config TOML.
    public init(toml: String) throws {
        let outer = try TOMLDecoder().decode(ConfigFile.self, from: toml).gaps?.outer
        left = try Self.gap(outer?.left, side: .left)
        right = try Self.gap(outer?.right, side: .right)
    }

    /// The config file AeroSpace reads, found by AeroSpace's own rules: `~/.aerospace.toml` or
    /// `${XDG_CONFIG_HOME:-~/.config}/aerospace/aerospace.toml`, and an error when both exist.
    public static func locate(home: URL, environment: [String: String]) throws(Error) -> URL {
        let candidates = candidates(home: home, environment: environment)
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        switch existing.count {
        case 0: throw .notFound(searched: candidates)
        case 1: return existing[0]
        default: throw .ambiguous(existing)
        }
    }

    /// Where AeroSpace looks for its config, in order.
    static func candidates(home: URL, environment: [String: String]) -> [URL] {
        let configHome = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        return [
            home.appendingPathComponent(".aerospace.toml"),
            configHome.appendingPathComponent("aerospace/aerospace.toml"),
        ]
    }

    private static func gap(_ setting: GapSetting?, side: SidebarSettings.Sidebar.Side) throws(Error) -> Gap {
        switch setting {
        case nil: return Gap(fallback: 0)
        case .constant(let value): return Gap(fallback: value)
        case .perMonitor(let entries):
            guard case .value(let fallback)? = entries.last else { throw .unsupportedGap(side: side) }
            var monitors: [MonitorGap] = []
            for entry in entries.dropLast() {
                guard case .monitor(let patterns) = entry, patterns.count == 1, let (pattern, value) = patterns.first else {
                    throw .unsupportedGap(side: side)
                }
                monitors.append(MonitorGap(pattern: pattern, value: value))
            }
            return Gap(fallback: fallback, monitors: monitors)
        }
    }
}

private struct ConfigFile: Decodable {
    struct Gaps: Decodable {
        let outer: Outer?
    }

    struct Outer: Decodable {
        let left: GapSetting?
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

    private struct MonitorTable: Decodable {
        let monitor: [String: Int]
    }
}
