import Foundation
import SidebarProtocol

/// Adds what the sidebar needs to an AeroSpace config by editing its text in place, so comments
/// and formatting survive:
/// - a `monitor.main` entry in `gaps.outer.right` that reserves `width` points plus the fallback gap
/// - an `on-window-detected` rule that floats the sidebar's bundle id
///
/// Every result is parsed again and must yield the requested width; layouts this editor does not
/// recognize fail with `EditError.unsupported` instead of being rewritten.
public enum AeroSpaceConfigEditor {
    public enum EditError: Error, Equatable {
        case unsupported(String)
    }

    public static let floatRule = """
        [[on-window-detected]]
        if = 'test %{app-bundle-id} = \(SidebarApp.bundleIdentifier)'
        run = 'layout floating'
        """

    /// What the config is missing.
    public struct Analysis: Equatable, Sendable {
        public var missingGap: Bool
        public var missingFloatRule: Bool
        /// The sidebar width the config reserves, when it does.
        public var width: CGFloat?
        public var warnings: [String]

        public var isConfigured: Bool { !missingGap && !missingFloatRule }
    }

    public static func analyze(_ text: String) -> Analysis {
        let width = try? AeroSpaceConfig(toml: text).sidebarWidth
        var warnings: [String] = []
        if activeLines(text).contains(where: { $0.contains("--no-outer-gaps") }) {
            warnings.append("A binding uses `fullscreen --no-outer-gaps`, which covers the sidebar; drop the flag.")
        }
        if isGenerated(text) {
            warnings.append("This file says it is generated; change its source instead.")
        }
        return Analysis(
            missingGap: width == nil,
            missingFloatRule: !activeLines(text).contains { $0.contains(SidebarApp.bundleIdentifier) },
            width: width,
            warnings: warnings
        )
    }

    /// Text in the file's first lines marks generated configs, which are overwritten on regeneration.
    public static func isGenerated(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).prefix(5).contains { line in
            let lowered = line.lowercased()
            return lowered.hasPrefix("#") && (lowered.contains("generated") || lowered.contains("do not edit"))
        }
    }

    /// The config with the gap and float rule added where missing.
    public static func apply(to text: String, width: Int) throws -> String {
        let analysis = analyze(text)
        var result = text
        if analysis.missingGap {
            result = try addGap(to: result, width: width)
        }
        if analysis.missingFloatRule {
            result = (result.hasSuffix("\n") ? result : result + "\n") + "\n" + floatRule + "\n"
        }
        do {
            guard try AeroSpaceConfig(toml: result).sidebarWidth > 0, !analyze(result).missingFloatRule else {
                throw EditError.unsupported("the edited config does not reserve the sidebar")
            }
        } catch let error as EditError {
            throw error
        } catch {
            throw EditError.unsupported("the edited config does not parse: \(error)")
        }
        return result
    }

    private static func addGap(to text: String, width: Int) throws -> String {
        let fallback: Int
        let hasMainEntry: Bool
        do {
            (fallback, hasMainEntry) = try AeroSpaceConfig.rightGapFallback(toml: text)
        } catch {
            throw EditError.unsupported("gaps.outer.right has a form this editor does not recognize")
        }
        if hasMainEntry {
            throw EditError.unsupported("gaps.outer.right already has a monitor.main entry that does not exceed its fallback")
        }
        let entry = "{ monitor.main = \(width + fallback) }"
        var lines = text.components(separatedBy: "\n")
        var table: String?
        var firstHeader: Int?
        var gapsHeader: Int?
        var outerHeader: Int?
        for index in lines.indices {
            let line = lines[index]
            if let header = tableHeader(line) {
                table = header
                firstHeader = firstHeader ?? index
                if header == "gaps" { gapsHeader = index }
                if header == "gaps.outer" { outerHeader = index }
                continue
            }
            let key = switch table {
            case nil: "gaps.outer.right"
            case "gaps": "outer.right"
            case "gaps.outer": "right"
            default: ""
            }
            guard !key.isEmpty, let match = assignment(of: key, in: line) else { continue }
            let value = match.value
            if value.hasPrefix("[") {
                guard value.filter({ $0 == "[" }).count == value.filter({ $0 == "]" }).count else {
                    throw EditError.unsupported("gaps.outer.right spans several lines")
                }
                lines[index] = match.prefix + "[" + entry + ", " + value.dropFirst() + match.comment
            } else {
                lines[index] = match.prefix + "[\(entry), \(value)]" + match.comment
            }
            return lines.joined(separator: "\n")
        }
        let assignment = "[\(entry), \(fallback)]"
        if let gapsHeader {
            lines.insert("outer.right = \(assignment)", at: gapsHeader + 1)
        } else if let outerHeader {
            lines.insert("right = \(assignment)", at: outerHeader + 1)
        } else {
            // `components(separatedBy:)` yields a trailing empty element for text ending in a newline.
            let end = lines.last == "" ? lines.endIndex - 1 : lines.endIndex
            lines.insert("gaps.outer.right = \(assignment)", at: firstHeader ?? end)
        }
        return lines.joined(separator: "\n")
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

    /// Splits `key = value # comment` into the text before the value, the value, and the comment
    /// with its leading whitespace.
    private static func assignment(of key: String, in line: String) -> (prefix: String, value: String, comment: String)? {
        let pattern = "^(\\s*" + NSRegularExpression.escapedPattern(for: key) + "\\s*=\\s*)([^#]*?)(\\s*#.*)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let prefix = Range(match.range(at: 1), in: line),
              let value = Range(match.range(at: 2), in: line)
        else { return nil }
        let comment = Range(match.range(at: 3), in: line).map { String(line[$0]) } ?? ""
        return (String(line[prefix]), String(line[value]), comment)
    }
}
