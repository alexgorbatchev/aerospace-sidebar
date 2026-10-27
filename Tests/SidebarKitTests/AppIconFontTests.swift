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
}
