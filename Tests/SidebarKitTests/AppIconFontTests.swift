import AppKit
import CoreText
import Foundation
@testable import SidebarKit
import Testing

extension AppIconFont {
    /// The font vendored in `Resources/`, which `just bundle` copies into the app.
    static let vendoredDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/sketchybar-app-font")
    static let vendored = try! AppIconFont(directory: vendoredDirectory)
}

/// Serialized: run in parallel, `:slack:` occasionally shaped as seven glyphs while another test registered a copy
/// of the font.
@Suite(.serialized)
struct AppIconFontTests {
    @Test(arguments: ["slack", ":slack:", " Slack ", ":SLACK:"])
    func resolvesIdsWithOrWithoutColons(value: String) {
        #expect(AppIconFont.vendored.icon(for: value) == SidebarNotification.Icon(id: "slack"))
    }

    @Test(arguments: ["no_such_app", "", ":", "::", "slack:"])
    func unknownIdsHaveNoIcon(value: String) {
        #expect(AppIconFont.vendored.icon(for: value) == nil)
    }

    @Test func registersTheFontSoIdsDrawAsOneGlyph() throws {
        _ = AppIconFont.vendored
        let font = try #require(NSFont(name: AppIconFont.family, size: 13), "font not registered")

        func glyphCount(_ text: String) -> Int {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            return (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).map(CTRunGetGlyphCount).reduce(0, +)
        }

        #expect(glyphCount(SidebarNotification.Icon(id: "slack").glyph) == 1)
    }

    @Test func loadingTwiceKeepsTheRegisteredFont() throws {
        _ = AppIconFont.vendored

        #expect(try AppIconFont(directory: AppIconFont.vendoredDirectory).icon(for: "ghostty") == SidebarNotification.Icon(id: "ghostty"))
    }

    @Test func missingIconMapThrows() throws {
        let directory = try TemporaryDirectory()

        #expect(throws: (any Error).self) { try AppIconFont(directory: directory.url) }
    }

    @Test func unreadableFontThrows() throws {
        let directory = try TemporaryDirectory()
        try FileManager.default.copyItem(
            at: AppIconFont.vendoredDirectory.appendingPathComponent("icon_map.json"),
            to: directory.url.appendingPathComponent("icon_map.json")
        )
        try Data("not a font".utf8).write(to: directory.url.appendingPathComponent("\(AppIconFont.family).ttf"))

        #expect(throws: CFError.self) { try AppIconFont(directory: directory.url) }
    }

    @Test func bundledReadsTheAppBundlesResources() throws {
        let directory = try TemporaryDirectory()
        let app = directory.url.appendingPathComponent("Test.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: AppIconFont.vendoredDirectory,
            to: resources.appendingPathComponent(AppIconFont.directoryName)
        )
        let bundle = try #require(Bundle(url: app))
        let copy = resources.appendingPathComponent("\(AppIconFont.directoryName)/\(AppIconFont.family).ttf") as CFURL
        defer { CTFontManagerUnregisterFontsForURL(copy, .process, nil) }

        #expect(AppIconFont.bundled(in: bundle).icon(for: "mail") == SidebarNotification.Icon(id: "mail"))
    }

    @Test func bundledWithoutResourcesKnowsNoIcons() {
        #expect(AppIconFont.bundled(in: .main).ids.isEmpty)
    }

    /// The bounds of the pixels `image` draws when rendered `side` pixels square, top-left origin.
    @MainActor
    func inkBounds(of image: NSImage, side: Int) throws -> CGRect {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var ink = CGRect.null
        for y in 0..<side {
            for x in 0..<side where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                ink = ink.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ink
    }

    /// Glyphs are centered on their ink, which a ligature's wider advance would push left as text, and
    /// fill the artwork's share of the height; narrow and short glyphs keep their proportions.
    @MainActor
    @Test(arguments: [("slack", 80.0, 80.0), ("ghostty", 63.0, 78.4), ("mail", 80.0, 60.0)])
    func drawsGlyphsCenteredOnTheirInk(id: String, width: CGFloat, height: CGFloat) throws {
        _ = AppIconFont.vendored
        let image = AppIconFont.image(for: .init(id: id), artwork: 0.8)

        let ink = try inkBounds(of: image, side: 100)

        #expect(image.isTemplate)
        #expect(abs(ink.midX - 50) <= 1)
        #expect(abs(ink.midY - 50) <= 1)
        #expect(abs(ink.width - width) <= 2)
        #expect(abs(ink.height - height) <= 2)
        #expect(AppIconFont.image(for: .init(id: id), artwork: 0.8) === image)
    }
}
