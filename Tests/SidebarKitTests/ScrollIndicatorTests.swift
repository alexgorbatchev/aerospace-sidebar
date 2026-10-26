import Foundation
@testable import SidebarKit
import SwiftUI
import Testing
import ViewInspector

struct ScrollMetricsTests {
    @Test func readsScrollGeometryIncludingInsets() {
        let geometry = ScrollGeometry(
            contentOffset: CGPoint(x: 0, y: 90),
            contentSize: CGSize(width: 300, height: 1000),
            contentInsets: EdgeInsets(top: 10, leading: 0, bottom: 20, trailing: 0),
            containerSize: CGSize(width: 300, height: 400)
        )

        #expect(ScrollMetrics(geometry) == ScrollMetrics(contentHeight: 1030, visibleHeight: 400, offset: 100))
    }

    @Test func contentThatFitsIsNotScrollable() {
        let fits = ScrollMetrics(contentHeight: 400, visibleHeight: 400)

        #expect(!fits.isScrollable)
        #expect(fits.knob(trackLength: 392, minLength: 24) == (0, 392))
        #expect(fits.offset(draggingKnobBy: 50, from: 0, trackLength: 392, minLength: 24) == 0)
        #expect(ScrollMetrics(contentHeight: 1000, visibleHeight: 400).knob(trackLength: -8, minLength: 24) == (0, 0))
    }

    @Test func knobLengthFollowsVisibleShareAndPositionFollowsOffset() {
        let top = ScrollMetrics(contentHeight: 1000, visibleHeight: 400, offset: 0)
        var bottom = top
        bottom.offset = 600
        var overscrolled = top
        overscrolled.offset = -50

        #expect(top.knob(trackLength: 400, minLength: 24) == (0, 160))
        #expect(bottom.knob(trackLength: 400, minLength: 24) == (240, 160))
        #expect(overscrolled.knob(trackLength: 400, minLength: 24) == (0, 160))
        #expect(ScrollMetrics(contentHeight: 100_000, visibleHeight: 400).knob(trackLength: 400, minLength: 24).length == 24)
    }

    @Test func draggingTheKnobMapsTrackDistanceToContentAndClamps() {
        let metrics = ScrollMetrics(contentHeight: 1000, visibleHeight: 400, offset: 0)

        #expect(metrics.offset(draggingKnobBy: 120, from: 0, trackLength: 400, minLength: 24) == 300)
        #expect(metrics.offset(draggingKnobBy: -120, from: 450, trackLength: 400, minLength: 24) == 150)
        #expect(metrics.offset(draggingKnobBy: 1000, from: 0, trackLength: 400, minLength: 24) == 600)
        #expect(metrics.offset(draggingKnobBy: -1000, from: 300, trackLength: 400, minLength: 24) == 0)
    }
}

@MainActor
struct ScrollIndicatorTests {
    @Test func draggingScrollsFromTheOffsetWhereTheDragStarted() throws {
        var targets: [CGFloat] = []
        // Track 400 (408 − 2 × inset) with a 160pt knob leaves 240pt of travel for 612pt of scrolling.
        let indicator = ScrollIndicator(
            metrics: ScrollMetrics(contentHeight: 1020, visibleHeight: 408, offset: 300),
            isScrolling: false
        ) { targets.append($0) }
        let gesture = try indicator.inspect().shape().gesture(DragGesture.self)

        for dy in [0.0, 40, -400] {
            try gesture.callOnChanged(value: DragGesture.Value(
                time: Date(), location: CGPoint(x: 0, y: dy), startLocation: .zero, velocity: .zero
            ))
        }

        #expect(targets.map { $0.rounded() } == [300, 402, 0])
    }
}
