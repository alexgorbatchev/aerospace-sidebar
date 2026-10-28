import AppKit
@testable import SidebarKit
import SwiftUI
import Testing

@MainActor
struct LeadingIconLayoutTests {
    /// Frames reported by the laid-out views, in the hosting view's coordinates.
    final class Frames {
        var icon = CGRect.null
        var lines: [Int: CGRect] = [:]
        var size = CGSize.zero
    }

    static let font = Font.system(size: 13)

    /// Lays out an icon beside `lines` in `width` points, reporting where each one went.
    func layOut(_ lines: [String], width: CGFloat) -> Frames {
        let frames = Frames()
        let view = LeadingIconLayout(spannedLines: 2, lineSpacing: 4, iconSpacing: 8) {
            Color.clear.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frames.icon = $0 }
            ForEach(lines.indices, id: \.self) { index in
                Text(lines[index])
                    .font(Self.font)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frames.lines[index] = $0 }
            }
        }
        .frame(width: width)
        let host = NSHostingView(rootView: view)
        frames.size = host.fittingSize
        host.frame.size = frames.size
        host.layoutSubtreeIfNeeded()
        return frames
    }

    var lineHeight: CGFloat { NSHostingView(rootView: Text("Hg").font(Self.font)).fittingSize.height }

    /// The icon is a square as tall as the lines beside it, which start after it.
    @Test func spansTheLinesBesideIt() {
        let frames = layOut(["Slack  12:59", "New message"], width: 300)

        let side = lineHeight * 2 + 4
        #expect(frames.icon == CGRect(x: 0, y: 0, width: side, height: side))
        #expect(frames.lines[0]?.origin == CGPoint(x: side + 8, y: 0))
        #expect(frames.lines[1]?.origin == CGPoint(x: side + 8, y: lineHeight + 4))
        #expect(frames.size == CGSize(width: 300, height: side))
    }

    /// Lines after the spanned ones stay in the column beside the icon, below it once they pass it.
    @Test func indentsTheLinesAfterTheSpannedOnes() {
        let frames = layOut(["Slack  12:59", "New message", "From #general", "Shown by macOS"], width: 300)

        let side = lineHeight * 2 + 4
        #expect(frames.icon == CGRect(x: 0, y: 0, width: side, height: side))
        #expect(frames.lines[2]?.origin == CGPoint(x: side + 8, y: (lineHeight + 4) * 2))
        #expect(frames.lines[3]?.origin == CGPoint(x: side + 8, y: (lineHeight + 4) * 3))
        #expect(frames.size == CGSize(width: 300, height: lineHeight * 4 + 4 * 3))
    }

    /// With fewer lines than it spans, the icon spans the lines there are.
    @Test func spansOnlyTheLinesThereAre() {
        let frames = layOut(["Slack  12:59"], width: 300)

        #expect(frames.icon == CGRect(x: 0, y: 0, width: lineHeight, height: lineHeight))
        #expect(frames.size == CGSize(width: 300, height: lineHeight))
    }

    /// A line that wraps continues beside the icon, which keeps its size at the top.
    @Test func keepsItsSizeWhenALineWraps() throws {
        let title = "A long message that cannot fit on one line beside the icon"
        let frames = layOut(["Slack  12:59", title], width: 160)

        let side = lineHeight * 2 + 4
        let wrapped = try #require(frames.lines[1])
        #expect(frames.icon == CGRect(x: 0, y: 0, width: side, height: side))
        #expect(wrapped.minX == side + 8)
        #expect(wrapped.maxX <= 160)
        #expect(wrapped.height > lineHeight)
        #expect(frames.size.height == lineHeight + 4 + wrapped.height)
    }

    /// Without a width, the lines keep their one-line widths.
    @Test func takesTheWidestLineWithoutAWidth() {
        let view = LeadingIconLayout(spannedLines: 2, lineSpacing: 4, iconSpacing: 8) {
            Color.clear
            Text("Short").font(Self.font)
            Text("A somewhat longer line").font(Self.font)
        }
        let size = NSHostingView(rootView: view).fittingSize
        let longest = NSHostingView(rootView: Text("A somewhat longer line").font(Self.font)).fittingSize.width

        #expect(size.width == lineHeight * 2 + 4 + 8 + longest)
    }
}
