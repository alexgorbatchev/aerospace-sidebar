import AppKit
@testable import SidebarKit
import SwiftUI
import Testing

@MainActor
struct LinkedTextTests {
    /// `text` rendered black on black, which leaves only a white underline visible, `width` points wide, with
    /// its layout as `LinkedText` reads it. Unless `settled` is false, animations end before the frame is drawn.
    func render(_ text: some View, width: CGFloat, settled: Bool = true) throws -> (image: NSBitmapImageRep, layouts: [(origin: CGPoint, layout: Text.Layout)]) {
        var layouts: [(origin: CGPoint, layout: Text.Layout)] = []
        let view = text
            .foregroundStyle(.black)
            .frame(width: width, alignment: .leading)
            .backgroundPreferenceValue(Text.LayoutKey.self) { found in
                GeometryReader { proxy in
                    let _ = layouts = found.map { (proxy[$0.origin], $0.layout) }
                    Color.clear
                }
            }
            .background(.black)
            .environment(\.colorScheme, .light)
            // The renderer draws one frame; without this it shows a hover fade at its start.
            .transaction { if settled { $0.disablesAnimations = true } }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        return (NSBitmapImageRep(cgImage: image), layouts)
    }

    /// The x coordinates, in points, of the white pixels in `image`.
    func whiteColumns(in image: NSBitmapImageRep) -> Set<Int> {
        var columns: Set<Int> = []
        for x in 0..<image.pixelsWide {
            for y in 0..<image.pixelsHigh {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.9 {
                    columns.insert(x / 2)
                }
            }
        }
        return columns
    }

    /// The frames, in points, of the runs of the link that starts at `location`.
    func frames(ofLinkAt location: Int, in layouts: [(origin: CGPoint, layout: Text.Layout)]) -> [CGRect] {
        layouts.flatMap { origin, layout in
            layout.flatMap { $0 }
                .filter { $0[LinkedText.Link.self]?.location == location }
                .map { $0.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y) }
        }
    }

    /// A link is found under the pointer on any line it wraps over; the text around it is not a link.
    @Test func findsTheLinkUnderThePointerOnEveryLineItWrapsOver() throws {
        let text = "Log https://example.com/a/very/long/path/that/wraps end"
        let linked = NotificationLinks.linked(text, underline: NotificationCard.linkUnderline)

        let layouts = try render(LinkedText.text(linked, hovered: nil, hoverUnderline: .white), width: 120).layouts

        let frames = frames(ofLinkAt: 4, in: layouts)
        #expect(frames.count > 1)
        for frame in frames {
            #expect(LinkedText.link(at: CGPoint(x: frame.midX, y: frame.midY), in: layouts) == 4)
        }
        let first = try #require(frames.first)
        let last = try #require(frames.last)
        #expect(LinkedText.link(at: CGPoint(x: first.minX - 5, y: first.midY), in: layouts) == nil)
        #expect(LinkedText.link(at: CGPoint(x: last.maxX + 5, y: last.midY), in: layouts) == nil)
        #expect(LinkedText.link(at: CGPoint(x: first.midX, y: -5), in: layouts) == nil)
    }

    /// Only the hovered link's underline turns white; the other link keeps the faint one.
    @Test func whitensOnlyTheHoveredLinksUnderline() throws {
        let text = "https://a.example and https://b.example"
        let linked = NotificationLinks.linked(text, underline: NotificationCard.linkUnderline)
        let second = text.distance(from: text.startIndex, to: try #require(text.range(of: "https://b.example")).lowerBound)

        let plain = try render(LinkedText.text(linked, hovered: nil, hoverUnderline: .white), width: 400)
        let hovered = try render(LinkedText.text(linked, hovered: second, hoverUnderline: .white), width: 400)

        #expect(whiteColumns(in: plain.image).isEmpty)
        let frame = try #require(frames(ofLinkAt: second, in: hovered.layouts).first)
        let columns = whiteColumns(in: hovered.image)
        // The underline skips descenders.
        #expect(CGFloat(columns.count) > frame.width / 2)
        #expect(columns.allSatisfy { CGFloat($0) >= frame.minX.rounded(.down) && CGFloat($0) <= frame.maxX })
    }

    /// Without the pointer on it, a link keeps its faint underline.
    @Test func keepsLinksFaintWithoutThePointer() throws {
        let text = "Log: https://ci.example.com/runs/42"
        let linked = NotificationLinks.linked(text, underline: NotificationCard.linkUnderline)

        let rendered = try render(LinkedText(text: linked, hoverUnderline: .white), width: 400)

        #expect(frames(ofLinkAt: 5, in: rendered.layouts).count == 1)
        #expect(whiteColumns(in: rendered.image).isEmpty)
    }

    /// With the pointer on a link, the view whitens that link's underline.
    @Test func whitensTheLinkUnderThePointer() throws {
        let text = "Log: https://ci.example.com/runs/42"
        let linked = NotificationLinks.linked(text, underline: NotificationCard.linkUnderline)
        let frame = try #require(frames(ofLinkAt: 5, in: render(LinkedText(text: linked, hoverUnderline: .white), width: 400).layouts).first)

        let rendered = try render(LinkedText(text: linked, hoverUnderline: .white, pointer: CGPoint(x: frame.midX, y: frame.midY)), width: 400)

        let columns = whiteColumns(in: rendered.image)
        #expect(CGFloat(columns.count) > frame.width / 2)
        #expect(columns.allSatisfy { CGFloat($0) >= frame.minX.rounded(.down) && CGFloat($0) <= frame.maxX })
    }

    /// The underline fades to white rather than switching: its first frame under the pointer is still faint.
    @Test func fadesTheUnderlineIn() throws {
        let text = "Log: https://ci.example.com/runs/42"
        let linked = NotificationLinks.linked(text, underline: NotificationCard.linkUnderline)
        let frame = try #require(frames(ofLinkAt: 5, in: render(LinkedText(text: linked, hoverUnderline: .white), width: 400).layouts).first)

        let rendered = try render(
            LinkedText(text: linked, hoverUnderline: .white, pointer: CGPoint(x: frame.midX, y: frame.midY)),
            width: 400,
            settled: false
        )

        #expect(whiteColumns(in: rendered.image).isEmpty)
    }

    /// The text reads the same with its links marked as without.
    @Test func keepsTheTextAndItsLinks() throws {
        let text = "Log: https://ci.example.com/runs/42 failed"
        let linked = NotificationLinks.linked(text, underline: NotificationCard.linkUnderline)

        let layouts = try render(LinkedText.text(linked, hovered: nil, hoverUnderline: .white), width: 400).layouts

        let runs = layouts.flatMap { $0.layout.flatMap { $0 } }
        #expect(runs.compactMap { $0[LinkedText.Link.self]?.location } == [5])
        #expect(runs.reduce(0) { $0 + $1.characterIndices.count } == text.count)
    }
}
