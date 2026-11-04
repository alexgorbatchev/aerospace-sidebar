import Foundation
import SwiftUI

/// Markdown in a pushed notification's body (`NotificationPayload.markdown`). Only inline syntax counts: bold,
/// italic, code, strikethrough and links. Lists, headings, tables and HTML stay as written, so a card never lays
/// out blocks. Links keep the rule of `NotificationLinks`: the body comes from any process and, through the URL
/// scheme, any web page, so only `http` and `https` links with a host stay links; any other keeps its text alone.
enum NotificationMarkdown {
    private static let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    /// `markdown` with its inline styles and web links; nil when Foundation cannot parse it.
    static func parse(_ markdown: String) -> AttributedString? {
        guard var text = try? AttributedString(markdown: markdown, options: options) else { return nil }
        let unsafe = text.runs[\.link].compactMap { link, range in
            link.map { NotificationLinks.isWebLink($0) } == false ? range : nil
        }
        for range in unsafe {
            text[range].link = nil
        }
        return text
    }

    /// The text a card shows for `markdown`, without its syntax: what VoiceOver reads and rules match.
    static func plainText(_ markdown: String) -> String {
        parse(markdown).map { String($0.characters) } ?? markdown
    }

    /// `markdown` as a card shows it: inline code in `codeFont`, the configured font's fixed-width variant, and
    /// anything Foundation cannot parse as plain text.
    static func styled(_ markdown: String, codeFont: Font) -> AttributedString {
        guard var text = parse(markdown) else { return AttributedString(markdown) }
        let code = text.runs[\.inlinePresentationIntent].compactMap { intent, range in
            intent.flatMap { $0.contains(.code) ? (range, $0) : nil }
        }
        for (range, intent) in code {
            // SwiftUI draws `.code` in the system's fixed-width font; the explicit font keeps the configured family.
            text[range].inlinePresentationIntent = intent.subtracting(.code)
            text[range].swiftUI.font = codeFont
        }
        return text
    }
}

extension SidebarNotification {
    /// The body as the card shows it, without markdown syntax: what VoiceOver reads and rules match.
    var displayedBody: String {
        markdown ? NotificationMarkdown.plainText(body) : body
    }
}
