import CoreText
import Foundation
import os

/// App icons from sketchybar-app-font (github.com/kvndrsslr/sketchybar-app-font), which draws each icon as a
/// ligature: the text `:slack:` set in the font is a single Slack glyph. The app bundle carries the font and its
/// `icon_map.json` in `Contents/Resources/sketchybar-app-font` (vendored in `Resources/`, see `just update-app-font`).
public struct AppIconFont: Sendable {
    public static let family = "sketchybar-app-font"
    static let directoryName = "sketchybar-app-font"
    private static let logger = Logger(category: "icons")

    /// The font's icon ids, without their surrounding colons.
    let ids: Set<String>

    init(ids: Set<String>) {
        self.ids = ids
    }

    /// Reads `icon_map.json` from `directory` and registers `sketchybar-app-font.ttf` for this process.
    public init(directory: URL) throws {
        struct Entry: Decodable {
            let iconName: String
        }
        let entries = try JSONDecoder().decode(
            [Entry].self,
            from: Data(contentsOf: directory.appendingPathComponent("icon_map.json"))
        )
        var error: Unmanaged<CFError>?
        let font = directory.appendingPathComponent("\(Self.family).ttf") as CFURL
        if !CTFontManagerRegisterFontsForURL(font, .process, &error), let error = error?.takeRetainedValue(),
           CFErrorGetCode(error) != CTFontManagerError.alreadyRegistered.rawValue {
            throw error
        }
        ids = Set(entries.map { Self.id($0.iconName) })
    }

    /// The icons bundled with the app. Without them every icon id is unknown, which notifications report.
    public static func bundled(in bundle: Bundle = .main) -> AppIconFont {
        do {
            guard let directory = bundle.url(forResource: directoryName, withExtension: nil) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: directoryName])
            }
            return try AppIconFont(directory: directory)
        } catch {
            logger.error("App icons unavailable: \(String(describing: error), privacy: .public)")
            return AppIconFont(ids: [])
        }
    }

    /// The icon `value` names, written as `slack` or `:slack:` in any case; `nil` when the font has no such icon.
    public func icon(for value: String) -> SidebarNotification.Icon? {
        let id = Self.id(value.trimmingCharacters(in: .whitespaces).lowercased())
        return ids.contains(id) ? SidebarNotification.Icon(id: id) : nil
    }

    private static func id(_ name: String) -> String {
        name.hasPrefix(":") && name.hasSuffix(":") && name.count > 1 ? String(name.dropFirst().dropLast()) : name
    }
}
