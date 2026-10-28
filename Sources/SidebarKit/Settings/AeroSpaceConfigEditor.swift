import Foundation
import SidebarProtocol

/// Adds what the sidebar needs to an AeroSpace config by editing its text in place, so comments
/// and formatting outside the sidebar's lines survive:
/// - a managed block in the gaps table that owns `outer.left` and `outer.right`, with a `monitor.main`
///   entry on the sidebar's side that reserves its width plus that side's fallback gap
/// - an `on-window-detected` rule that floats the sidebar's bundle id
///
/// The block is rewritten as a whole; its other monitor entries and fallbacks are kept. A config
/// without the block has its `outer.left`/`outer.right` assignments moved into one, and their comments
/// (the lines right above each, and a comment after the value) move above the block. Every result is
/// parsed again and must reserve the requested strip; layouts this editor does not recognize fail
/// with `EditError.unsupported` instead of being rewritten.
public enum AeroSpaceConfigEditor {
    public typealias Side = SidebarSettings.Sidebar.Side

    public enum EditError: Error, Equatable {
        case unsupported(String)
    }

    public static let blockStart = "# >>> aerospace-sidebar: managed block, rewritten when the sidebar's side or width changes >>>"
    public static let blockEnd = "# <<< aerospace-sidebar <<<"
    static let blockStartPrefix = "# >>> aerospace-sidebar"
    static let blockEndPrefix = "# <<< aerospace-sidebar"

    public static let floatRule = """
        [[on-window-detected]]
        if = 'test %{app-bundle-id} = \(SidebarApp.bundleIdentifier)'
        run = 'layout floating'
        """
    static let floatRuleComment = "# Added by aerospace-sidebar: keeps AeroSpace from tiling the sidebar."

    /// How the config compares with the sidebar's settings.
    public struct Analysis: Equatable, Sendable {
        /// The strip the config should reserve.
        public var sidebar: SidebarSettings.Sidebar
        /// The width the config reserves on the sidebar's side, when it reserves one.
        public var reservedWidth: Int?
        /// The width the config reserves on the other side, when it reserves one.
        public var oppositeReservedWidth: Int?
        public var missingFloatRule: Bool
        public var warnings: [String]

        public var gapMatches: Bool { reservedWidth == sidebar.width && oppositeReservedWidth == nil }
        public var isConfigured: Bool { gapMatches && !missingFloatRule }
    }

    public static func analyze(_ text: String, sidebar: SidebarSettings.Sidebar) -> Analysis {
        let config = try? AeroSpaceConfig(toml: text)
        var warnings: [String] = []
        if activeLines(text).contains(where: { $0.contains("--no-outer-gaps") }) {
            warnings.append("A binding uses `fullscreen --no-outer-gaps`, which covers the sidebar; drop the flag.")
        }
        return Analysis(
            sidebar: sidebar,
            reservedWidth: config?.gap(on: sidebar.side).reservedWidth,
            oppositeReservedWidth: config?.gap(on: sidebar.side.opposite).reservedWidth,
            missingFloatRule: !activeLines(text).contains { $0.contains(SidebarApp.bundleIdentifier) },
            warnings: warnings
        )
    }

    /// The config with the sidebar's strip reserved and the float rule added where needed.
    /// - Parameter rewritingBlock: Writes the managed block even when the gap already matches.
    public static func apply(to text: String, sidebar: SidebarSettings.Sidebar, rewritingBlock: Bool = false) throws -> String {
        let analysis = analyze(text, sidebar: sidebar)
        var result = text
        if rewritingBlock || !analysis.gapMatches {
            result = try writeBlock(for: sidebar, in: result)
        }
        if analysis.missingFloatRule {
            result = (result.hasSuffix("\n") ? result : result + "\n") + "\n" + floatRuleComment + "\n" + floatRule + "\n"
        }
        do {
            _ = try AeroSpaceConfig(toml: result)
        } catch {
            throw EditError.unsupported("the edited config does not parse: \(error)")
        }
        guard analyze(result, sidebar: sidebar).isConfigured else {
            throw EditError.unsupported("the edited config does not reserve the sidebar")
        }
        return result
    }

    /// The TOML to paste into a config by hand: the block under `[gaps]` and the float rule.
    public static func snippet(for sidebar: SidebarSettings.Sidebar) -> String {
        let unset = AeroSpaceConfig.Gap(fallback: 0)
        return (["[gaps]"] + block(for: sidebar, left: unset, right: unset, keyPrefix: "outer.") + ["", floatRuleComment, floatRule, ""])
            .joined(separator: "\n")
    }

    /// The managed block's lines: both outer sides, with the `monitor.main` entry first on the sidebar's
    /// side so it wins over other patterns that match the main monitor. A `monitor.main` entry on the
    /// other side is dropped when it reserves a strip, which tiled windows would leave empty.
    static func block(for sidebar: SidebarSettings.Sidebar, left: AeroSpaceConfig.Gap, right: AeroSpaceConfig.Gap, keyPrefix: String) -> [String] {
        let assignments = Side.allCases.map { side in
            let gap = side == .left ? left : right
            var monitors = gap.monitors.filter { $0.pattern != "main" || (side != sidebar.side && $0.value <= gap.fallback) }
            if side == sidebar.side {
                monitors.insert(.init(pattern: "main", value: sidebar.width + gap.fallback), at: 0)
            }
            let entries = monitors.map { "{ monitor.\(tomlKey($0.pattern)) = \($0.value) }" } + ["\(gap.fallback)"]
            return "\(keyPrefix)\(side.rawValue) = " + (monitors.isEmpty ? "\(gap.fallback)" : "[" + entries.joined(separator: ", ") + "]")
        }
        return [blockStart] + assignments + [blockEnd]
    }

    private static func writeBlock(for sidebar: SidebarSettings.Sidebar, in text: String) throws -> String {
        let config: AeroSpaceConfig
        do {
            config = try AeroSpaceConfig(toml: text)
        } catch AeroSpaceConfig.Error.unsupportedGap(let side) {
            throw EditError.unsupported("gaps.outer.\(side.rawValue) has a form this editor does not recognize")
        } catch {
            throw EditError.unsupported("the config does not parse: \(error)")
        }
        var lines = text.components(separatedBy: "\n")
        let found = try scan(lines)
        func block(in table: String?) throws -> [String] {
            Self.block(for: sidebar, left: config.left, right: config.right, keyPrefix: try keyPrefix(in: table))
        }
        if let existing = found.block {
            lines.replaceSubrange(existing.lines, with: try block(in: existing.table))
        } else if let first = found.assignments.min(by: { $0.index < $1.index }) {
            // TOML allows both sides only in the same table, so the block takes the first one's place.
            // Comments above the first assignment already sit above that place; the others' comments
            // move there, and comments after a value become lines of their own.
            var moved: [String] = []
            var removed: [Int] = []
            for assignment in found.assignments.sorted(by: { $0.index < $1.index }) {
                if assignment.index != first.index {
                    var above = assignment.index
                    while above > first.index + 1, isComment(lines[above - 1]), !removed.contains(above - 1) {
                        above -= 1
                    }
                    moved += lines[above..<assignment.index]
                    removed += Array(above..<assignment.index)
                }
                moved += assignment.comment.map { [$0] } ?? []
                removed.append(assignment.index)
            }
            let replacement = moved + (try block(in: first.table))
            for index in removed.sorted(by: >) {
                lines.remove(at: index)
            }
            lines.insert(contentsOf: replacement, at: first.index)
        } else if let gapsHeader = found.gapsHeader {
            lines.insert(contentsOf: try block(in: "gaps"), at: gapsHeader + 1)
        } else if let outerHeader = found.outerHeader {
            lines.insert(contentsOf: try block(in: "gaps.outer"), at: outerHeader + 1)
        } else {
            // `components(separatedBy:)` yields a trailing empty element for text ending in a newline.
            let end = lines.last == "" ? lines.endIndex - 1 : lines.endIndex
            lines.insert(contentsOf: try block(in: nil), at: found.firstHeader ?? end)
        }
        return lines.joined(separator: "\n")
    }

    /// The key prefix of `outer.left`/`outer.right` in `table`, where nil is the root table.
    private static func keyPrefix(in table: String?) throws -> String {
        switch table {
        case nil: "gaps.outer."
        case "gaps": "outer."
        case "gaps.outer": ""
        case let table?: throw EditError.unsupported("the aerospace-sidebar block is in [\(table)] instead of [gaps]")
        }
    }

    private struct Scan {
        var block: (lines: ClosedRange<Int>, table: String?)?
        var assignments: [(index: Int, table: String?, comment: String?)] = []
        var firstHeader: Int?
        var gapsHeader: Int?
        var outerHeader: Int?
    }

    /// Finds the managed block, the `outer.left`/`outer.right` assignments outside it, and the table
    /// headers a new block could go under.
    private static func scan(_ lines: [String]) throws -> Scan {
        var found = Scan()
        var table: String?
        var blockStart: Int?
        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(blockStartPrefix) {
                guard blockStart == nil, found.block == nil else {
                    throw EditError.unsupported("the config has more than one aerospace-sidebar block")
                }
                blockStart = index
                continue
            }
            if trimmed.hasPrefix(blockEndPrefix) {
                guard let start = blockStart else { throw EditError.unsupported("the aerospace-sidebar block has no start line") }
                found.block = (start...index, table)
                blockStart = nil
                continue
            }
            if let header = tableHeader(line) {
                guard blockStart == nil else { throw EditError.unsupported("the aerospace-sidebar block contains a table header") }
                table = header
                found.firstHeader = found.firstHeader ?? index
                if header == "gaps" { found.gapsHeader = index }
                if header == "gaps.outer" { found.outerHeader = index }
                continue
            }
            guard let prefix = try? keyPrefix(in: table) else { continue }
            for side in Side.allCases {
                guard let (value, comment) = assignment(of: prefix + side.rawValue, in: line) else { continue }
                if value.filter({ $0 == "[" }).count != value.filter({ $0 == "]" }).count {
                    throw EditError.unsupported("gaps.outer.\(side.rawValue) spans several lines")
                }
                if blockStart == nil {
                    found.assignments.append((index, table, comment))
                }
            }
        }
        if blockStart != nil {
            throw EditError.unsupported("the aerospace-sidebar block has no end line")
        }
        return found
    }

    /// A bare key when TOML allows one; otherwise a literal string, which keeps regex backslashes as
    /// written, or a basic string when the key holds a quote or line break.
    static func tomlKey(_ key: String) -> String {
        if !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
            return key
        }
        if !key.contains("'"), !key.contains(where: \.isNewline) {
            return "'\(key)'"
        }
        let escaped = key.unicodeScalars.map { scalar -> String in
            switch scalar {
            case "\\": "\\\\"
            case "\"": "\\\""
            case "\n": "\\n"
            case "\r": "\\r"
            default: String(scalar)
            }
        }.joined()
        return "\"\(escaped)\""
    }

    /// A comment line other than the block's markers.
    private static func isComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("#") && !trimmed.hasPrefix(blockStartPrefix) && !trimmed.hasPrefix(blockEndPrefix)
    }

    private static func activeLines(_ text: String) -> [Substring] {
        text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }

    /// The name of a `[table]` header line; nil for other lines, including `[[array]]` headers' contents.
    private static func tableHeader(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }
        let isArray = trimmed.hasPrefix("[[")
        let open = isArray ? 2 : 1
        guard let close = trimmed.range(of: isArray ? "]]" : "]") else { return nil }
        let name = trimmed[trimmed.index(trimmed.startIndex, offsetBy: open)..<close.lowerBound]
        return isArray ? "[[\(name.trimmingCharacters(in: .whitespaces))]]" : name.trimmingCharacters(in: .whitespaces)
    }

    /// The value and comment of `key = value # comment`; nil when the line assigns another key.
    private static func assignment(of key: String, in line: String) -> (value: String, comment: String?)? {
        let pattern = "^\\s*" + NSRegularExpression.escapedPattern(for: key) + "\\s*=\\s*([^#]*?)\\s*(#.*)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let value = Range(match.range(at: 1), in: line)
        else { return nil }
        return (String(line[value]), Range(match.range(at: 2), in: line).map { String(line[$0]) })
    }
}
