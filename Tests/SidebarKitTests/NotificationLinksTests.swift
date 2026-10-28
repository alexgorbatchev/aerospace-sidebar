import Foundation
@testable import SidebarKit
import SwiftUI
import Testing

struct NotificationLinksTests {
    /// Written-out web links count, wherever they sit in the text, without the punctuation after them.
    @Test func findsWebLinksWrittenOut() {
        let text = "Build failed: https://ci.example.com/runs/42?tab=log. Docs at HTTP://example.org/guide, see you."

        let urls = NotificationLinks.links(in: text).map(\.url.absoluteString)

        #expect(urls == ["https://ci.example.com/runs/42?tab=log", "HTTP://example.org/guide"])
    }

    /// Other schemes could launch apps, and bare names are not meant as links.
    @Test(arguments: [
        "Run deploy.sh on zoom.us",
        "Mail me at someone@example.com",
        "mailto:someone@example.com",
        "Open aerospace-sidebar://notification/push?title=x",
        "See file:///etc/hosts",
        "No links here",
    ])
    func ignoresAnythingElse(text: String) {
        #expect(NotificationLinks.links(in: text).isEmpty)
    }

    /// Only the link itself is marked and underlined; the text around it is untouched.
    @Test func marksOnlyTheLinks() throws {
        let text = "Open https://example.com/a now"
        let underline = Color.primary.opacity(0.35)

        let linked = NotificationLinks.linked(text, underline: underline)

        #expect(String(linked.characters) == text)
        let runs = linked.runs.map { (String(linked[$0.range].characters), $0.link, $0.underlineStyle) }
        #expect(runs.count == 3)
        #expect(runs[0].0 == "Open " && runs[0].1 == nil && runs[0].2 == nil)
        #expect(runs[1].0 == "https://example.com/a" && runs[1].1 == URL(string: "https://example.com/a"))
        #expect(runs[1].2 == Text.LineStyle(pattern: .solid, color: underline))
        #expect(runs[2].0 == " now" && runs[2].1 == nil && runs[2].2 == nil)
    }
}
