import AppKit
@testable import SidebarKit
import SwiftUI
import Testing
import ViewInspector

@MainActor
struct SidebarTooltipTests {
    /// A tooltip shows once the pointer has rested on its view for the delay, and goes as soon as it leaves; leaving
    /// before the delay shows none.
    @Test func showsAfterThePointerRestsAndHidesWhenItLeaves() async throws {
        let hover = SidebarTooltipHover(delay: .milliseconds(50))

        hover.hover(true)
        #expect(!hover.isShown)
        hover.hover(false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!hover.isShown)

        hover.hover(true)
        for _ in 0..<100 where !hover.isShown {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(hover.isShown)
        hover.hover(false)
        #expect(!hover.isShown)
    }

    /// Under the view from its leading edge, kept inside the margins, and above the view near the bottom.
    @Test(arguments: [
        // Room below: under the view, from its leading edge.
        (CGRect(x: 40, y: 50, width: 20, height: 20), CGRect(x: 40, y: 76, width: 100, height: 40)),
        // Too close to the trailing edge: moved left to the margin.
        (CGRect(x: 250, y: 50, width: 20, height: 20), CGRect(x: 184, y: 76, width: 100, height: 40)),
        // Too close to the leading edge: kept at the margin.
        (CGRect(x: 2, y: 50, width: 20, height: 20), CGRect(x: 16, y: 76, width: 100, height: 40)),
        // No room below: above the view.
        (CGRect(x: 40, y: 560, width: 20, height: 20), CGRect(x: 40, y: 514, width: 100, height: 40)),
    ])
    func placesTheTooltipBesideItsView(anchor: CGRect, expected: CGRect) {
        let container = CGRect(x: 0, y: 0, width: 300, height: 600)

        #expect(SidebarTooltipPlacement.frame(of: CGSize(width: 100, height: 40), under: anchor, in: container, margin: 16, gap: 6) == expected)
    }

    /// The layout wraps the text at its widest and places it where `frame(of:under:in:margin:gap:)` says.
    @Test func laysOutTheBubbleWithinItsWidth() {
        var frame = CGRect.null
        let text = "A tooltip long enough to wrap inside the narrow sidebar it is shown in"
        let view = SidebarTooltipPlacement(anchor: CGRect(x: 40, y: 20, width: 20, height: 20), maxWidth: 120) {
            Text(text).onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame = $0 }
        }
        .frame(width: 300, height: 400)
        let host = NSHostingView(rootView: view)
        host.frame.size = CGSize(width: 300, height: 400)
        host.layoutSubtreeIfNeeded()

        #expect(frame.minX == 40)
        #expect(frame.minY == 46)
        #expect(frame.width <= 120)
        #expect(frame.height > NSHostingView(rootView: Text("Hg")).fittingSize.height)
    }

    /// A marked view reports its tooltip only while it shows, and the sidebar draws it under the view.
    @Test(arguments: [false, true])
    func drawsTheTooltipOfTheViewUnderThePointer(isShown: Bool) {
        var reported: [String] = []
        let view = ZStack(alignment: .topLeading) {
            Color.clear
            Color.clear.frame(width: 20, height: 20)
                .modifier(SidebarTooltipModifier(text: "Notifications are off", hover: SidebarTooltipHover(isShown: isShown)))
                .offset(x: 30, y: 30)
        }
        .frame(width: 240, height: 240)
        .onPreferenceChange(SidebarTooltipKey.self) { reported = $0.map(\.text) }
        .sidebarTooltips()
        let host = NSHostingView(rootView: view)
        host.frame.size = CGSize(width: 240, height: 240)
        host.layoutSubtreeIfNeeded()

        #expect(reported == (isShown ? ["Notifications are off"] : []))
        // The bubble under the view draws; nothing draws above the view.
        #expect((opaquePixels(in: host, rows: 60..<100) > 0) == isShown)
        #expect(opaquePixels(in: host, rows: 0..<20) == 0)
    }

    /// The marked view's VoiceOver hint reads the tooltip, which VoiceOver does not reach itself.
    @Test func hintsTheTooltipToVoiceOver() throws {
        let sut = try Color.clear.sidebarTooltip("Notifications are off").inspect()

        #expect(try sut.find(where: { (try? $0.accessibilityHint()) != nil }).accessibilityHint().string() == "Notifications are off")
    }

    /// The number of pixels with any opacity in `rows`, counted from the top.
    func opaquePixels(in host: NSView, rows: Range<Int>) -> Int {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / host.bounds.height
        var count = 0
        for y in Int(CGFloat(rows.lowerBound) * scale)..<Int(CGFloat(rows.upperBound) * scale) {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                count += 1
            }
        }
        return count
    }
}
