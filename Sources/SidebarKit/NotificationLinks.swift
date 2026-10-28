import Foundation
import SwiftUI

/// Web links in notification text, which cards make clickable. Only links written out with `http://` or
/// `https://` count: text arrives from any process and, through the URL scheme, any web page, so a link
/// must not launch apps through their own URL schemes, and a bare name such as `deploy.sh` (a Saint
/// Helena domain to `NSDataDetector`) is not a link.
enum NotificationLinks {
    static let schemes: Set<String> = ["http", "https"]

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The web links in `text`, in order, with where each is written.
    static func links(in text: String) -> [(range: NSRange, url: URL)] {
        let whole = NSRange(text.startIndex..., in: text)
        return (detector?.matches(in: text, range: whole) ?? []).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(), schemes.contains(scheme),
                  let range = Range(match.range, in: text),
                  text[range].lowercased().hasPrefix("\(scheme)://")
            else { return nil }
            return (match.range, url)
        }
    }

    /// `text` with its web links marked as links, each underlined in `underline`.
    static func linked(_ text: String, underline: Color) -> AttributedString {
        var linked = AttributedString(text)
        for link in links(in: text) {
            guard let range = Range(link.range, in: linked) else { continue }
            linked[range].link = link.url
            linked[range].underlineStyle = Text.LineStyle(pattern: .solid, color: underline)
        }
        return linked
    }
}
