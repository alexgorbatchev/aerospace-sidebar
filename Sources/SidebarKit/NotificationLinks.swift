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

/// Text whose links change their underline to `hoverUnderline` while the pointer is on them. Text has no
/// hover per link, so the pointer is matched against the laid-out text (`Text.LayoutKey`), where each
/// link's runs carry `LinkedText.Link`; the underline stays the text's own, only its color changes.
struct LinkedText: View {
    let text: AttributedString
    let hoverUnderline: Color

    /// Where the pointer is on the text, while it is.
    @State private var pointer: CGPoint?
    /// The link under the pointer, by `Link.location`.
    @State private var hovered: Int?

    /// `pointer` places the pointer on the text before it moves, which tests cannot do through hover events.
    init(text: AttributedString, hoverUnderline: Color, pointer: CGPoint? = nil) {
        self.text = text
        self.hoverUnderline = hoverUnderline
        _pointer = State(initialValue: pointer)
    }

    /// Marks a link's runs in the laid-out text with where the link starts, which tells it from other links,
    /// even ones to the same URL, across the lines it wraps over.
    struct Link: TextAttribute {
        let location: Int
    }

    var body: some View {
        Self.text(text, hovered: hovered, hoverUnderline: hoverUnderline)
            // Text cross-fades its old and new content; only the underline differs, so it fades between colors.
            .animation(.snappy(duration: 0.2), value: hovered)
            .onContinuousHover { phase in
                if case .active(let location) = phase { pointer = location } else { pointer = nil }
            }
            .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    let link = pointer.flatMap { Self.link(at: $0, in: layouts.map { (proxy[$0.origin], $0.layout) }) }
                    Color.clear.onChange(of: link, initial: true) { hovered = link }
                }
            }
    }

    /// `text` with each link's runs marked by `Link`, and the link starting at `hovered` underlined in
    /// `hoverUnderline`.
    static func text(_ text: AttributedString, hovered: Int?, hoverUnderline: Color) -> Text {
        text.runs.reduce(Text(verbatim: "")) { result, run in
            var segment = AttributedString(text[run.range])
            guard run.link != nil else { return Text("\(result)\(Text(segment))") }
            let location = text.characters.distance(from: text.startIndex, to: run.range.lowerBound)
            if location == hovered {
                segment.underlineStyle = Text.LineStyle(pattern: .solid, color: hoverUnderline)
            }
            return Text("\(result)\(Text(segment).customAttribute(Link(location: location)))")
        }
    }

    /// The link whose text is at `point`, by `Link.location`, in text laid out as `layouts`, each with its
    /// origin in the coordinates of `point`.
    static func link(at point: CGPoint, in layouts: [(origin: CGPoint, layout: Text.Layout)]) -> Int? {
        for (origin, layout) in layouts {
            for line in layout {
                for run in line where run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y).contains(point) {
                    return run[Link.self]?.location
                }
            }
        }
        return nil
    }
}
