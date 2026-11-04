import Foundation
@testable import SidebarKit
import SwiftUI
import Testing

struct NotificationMarkdownTests {
    /// Each run of `text` with its characters, inline styles and link.
    func runs(_ text: AttributedString) -> [(String, InlinePresentationIntent?, URL?)] {
        text.runs.map { (String(text[$0.range].characters), $0.inlinePresentationIntent, $0.link) }
    }

    /// Bold, italic, code and strikethrough come out as inline styles, without their syntax.
    @Test func parsesInlineStyles() throws {
        let text = try #require(NotificationMarkdown.parse("**bold** *italic* `code` ~~gone~~"))

        #expect(String(text.characters) == "bold italic code gone")
        let styled = runs(text).filter { $0.1 != nil }.map { ($0.0, $0.1) }
        #expect(styled.map(\.0) == ["bold", "italic", "code", "gone"])
        #expect(styled.map(\.1) == [.stronglyEmphasized, .emphasized, .code, .strikethrough])
    }

    /// Lists, headings, tables and HTML stay as written: a card lays out no blocks, and markup is no markup.
    @Test(arguments: ["line\n- item\n\n# Heading", "| a | b |", "<b>html</b>", "unclosed **bold"])
    func keepsEverythingElseAsWritten(markdown: String) {
        #expect(NotificationMarkdown.plainText(markdown) == markdown)
    }

    /// Only web links with a host stay links; any other keeps its text alone, so a body cannot launch apps.
    @Test func keepsOnlyWebLinks() throws {
        let text = try #require(NotificationMarkdown.parse(
            "[web](https://example.com/a) [js](javascript:alert(1)) [app](slack://open) [rel](zoom.us) <http://auto.example>"
        ))

        let links = runs(text).filter { $0.2 != nil }.map { ($0.0, $0.2?.absoluteString) }
        #expect(links.map(\.0) == ["web", "http://auto.example"])
        #expect(links.map(\.1) == ["https://example.com/a", "http://auto.example"])
        #expect(String(text.characters) == "web js app rel http://auto.example")
    }

    /// Code takes the configured font's fixed-width variant instead of SwiftUI's own fixed-width font; the other
    /// styles stay with the text's font.
    @Test func setsCodeInTheGivenFont() throws {
        let codeFont = Font.custom("Menlo", fixedSize: 12).monospaced()

        let text = NotificationMarkdown.styled("run **`make test`** now", codeFont: codeFont)

        let code = try #require(text.runs.first { String(text[$0.range].characters) == "make test" })
        #expect(code.swiftUI.font == codeFont)
        #expect(code.inlinePresentationIntent == .stronglyEmphasized)
        #expect(text.runs.filter { $0.swiftUI.font != nil }.count == 1)
    }

    @Test func plainTextDropsTheSyntax() {
        #expect(NotificationMarkdown.plainText("**Done** in [CI](https://ci.example)") == "Done in CI")
    }

    /// Rules and VoiceOver read a markdown body as the card shows it, and any other body as it is.
    @Test func displaysBodiesWithoutMarkdownSyntaxOnlyWhenMarked() {
        #expect(SidebarNotification(source: "s", title: "t", body: "**x**", markdown: true).displayedBody == "x")
        #expect(SidebarNotification(source: "s", title: "t", body: "**x**").displayedBody == "**x**")
    }

    /// Bare web links in a markdown body become links too, but not inside its own links or code, and every link
    /// gets the underline.
    @Test func linksBareURLsOutsideLinksAndCode() throws {
        let underline = Color.primary.opacity(0.35)
        let body = NotificationMarkdown.styled(
            "See https://a.example, [docs at https://b.example](https://c.example) and `curl https://d.example`",
            codeFont: .system(size: 12).monospaced()
        )

        let linked = NotificationLinks.linked(body, underline: underline)

        let links = linked.runs[\.link].compactMap { link, range in
            link.map { (String(linked[range].characters), $0.absoluteString) }
        }
        #expect(links.map(\.0) == ["https://a.example", "docs at https://b.example"])
        #expect(links.map(\.1) == ["https://a.example", "https://c.example"])
        for (link, range) in linked.runs[\.link] {
            let underlined = linked[range].runs.allSatisfy { $0.underlineStyle == Text.LineStyle(pattern: .solid, color: underline) }
            #expect(underlined == (link != nil))
        }
    }

    @Test func recognizesWebLinks() throws {
        #expect(NotificationLinks.isWebLink(try #require(URL(string: "HTTPS://example.com"))))
        #expect(!NotificationLinks.isWebLink(try #require(URL(string: "https:///path"))))
        #expect(!NotificationLinks.isWebLink(try #require(URL(string: "mailto:a@example.com"))))
        #expect(!NotificationLinks.isWebLink(try #require(URL(string: "relative/path"))))
    }
}
