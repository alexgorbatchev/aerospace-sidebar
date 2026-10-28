import AppKit
import CoreText
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

    /// `icon` as a template image whose glyph is centered on its ink, set at `artwork` of the image's height
    /// as its font size, which the vendored glyphs' ink fills at most. Set as text, the glyph would sit off-center: a ligature's advance
    /// is wider than its ink (142 points for a 100-point `:slack:`), and some glyphs are narrower or shorter
    /// than the em. Drawn on demand, so it stays sharp at any size; nothing is drawn while the font is not
    /// registered.
    @MainActor
    static func image(for icon: SidebarNotification.Icon, artwork: CGFloat) -> NSImage {
        let key = "\(icon.id)@\(artwork)"
        if let cached = images[key] { return cached }
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            guard let font = NSFont(name: family, size: rect.height * artwork),
                  let context = NSGraphicsContext.current?.cgContext else { return false }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: icon.glyph, attributes: [.font: font]))
            let ink = inkBounds(of: line, in: font)
            context.textPosition = CGPoint(x: rect.midX - ink.midX, y: rect.midY - ink.midY)
            CTLineDraw(line, context)
            return true
        }
        image.isTemplate = true
        images[key] = image
        return image
    }

    @MainActor private static var images: [String: NSImage] = [:]

    /// The bounds of the outlines `line` draws. `CTLineGetImageBounds` uses the font's glyph boxes, which
    /// can be looser than the outline (`:mail:`'s reaches down to the baseline, 12.5 points below its ink).
    private static func inkBounds(of line: CTLine, in font: NSFont) -> CGRect {
        var bounds = CGRect.null
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                guard let outline = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                bounds = bounds.union(outline.boundingBoxOfPath.offsetBy(dx: position.x, dy: position.y))
            }
        }
        return bounds
    }

    private static func id(_ name: String) -> String {
        name.hasPrefix(":") && name.hasSuffix(":") && name.count > 1 ? String(name.dropFirst().dropLast()) : name
    }
}
