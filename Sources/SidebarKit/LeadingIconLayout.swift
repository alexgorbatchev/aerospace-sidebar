import SwiftUI

/// Places an icon in a square at the top left and the lines that follow it beside it, stacked like a
/// leading-aligned `VStack`. The square is as tall as the first `spannedLines` lines would be on one line
/// each, so the icon spans exactly those lines; text that wraps, and every later line, stays in the column
/// beside it.
///
/// The square's size comes from each line's one-line height, which does not depend on the width left
/// beside the icon, so wrapping cannot feed back into the icon's size.
struct LeadingIconLayout: Layout {
    /// How many lines the icon spans.
    let spannedLines: Int
    /// Space between the lines.
    let lineSpacing: CGFloat
    /// Space between the icon and the lines.
    let iconSpacing: CGFloat

    struct Arrangement {
        let side: CGFloat
        let lineFrames: [CGRect]
        let size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let icon = subviews.first else { return }
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        icon.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: arrangement.side, height: arrangement.side)
        )
        for (line, frame) in zip(subviews.dropFirst(), arrangement.lineFrames) {
            line.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    /// The icon's side, each line's frame and the total size for `width`, or for the lines' ideal widths
    /// when there is no width.
    func arrange(width: CGFloat?, subviews: Subviews) -> Arrangement {
        let lines = subviews.dropFirst()
        let oneLineSizes = lines.map { $0.sizeThatFits(.unspecified) }
        let spanned = oneLineSizes.prefix(spannedLines)
        let side = spanned.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(spanned.count - 1, 0))
        let indent = side + iconSpacing
        let columnWidth = width.map { max($0 - indent, 0) } ?? (oneLineSizes.map(\.width).max() ?? 0)
        var lineFrames: [CGRect] = []
        var y: CGFloat = 0
        for line in lines {
            let size = line.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            lineFrames.append(CGRect(x: indent, y: y, width: columnWidth, height: size.height))
            y += size.height + lineSpacing
        }
        let linesHeight = max(y - lineSpacing, 0)
        return Arrangement(side: side, lineFrames: lineFrames, size: CGSize(width: indent + columnWidth, height: max(side, linesHeight)))
    }
}
