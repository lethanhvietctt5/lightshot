import Testing
import Foundation
@testable import LightshotKit

// The click-highlight geometry (spec 0006, story 29): halo at the pointer, an expanding, fading
// ring per click, pruning, and the screen-to-frame mapping.

@Test func theHaloFollowsThePointerAndUsesTheSizeAndStyle() {
    var m = ClickHighlightModel(settings: ClickHighlightSettings(style: .filled, size: .large))
    #expect(m.circles(at: 0).isEmpty)                    // pointer unknown: nothing to draw
    m.pointerMoved(to: Point(x: 100, y: 50))
    let halo = m.circles(at: 0)
    #expect(halo == [HighlightCircle(center: Point(x: 100, y: 50), radius: 32, opacity: ClickHighlightModel.haloOpacity, filled: true, strokeWidth: 0)])
    m.pointerMoved(to: Point(x: 120, y: 50))
    #expect(m.circles(at: 1).first?.center == Point(x: 120, y: 50))
}

@Test func theThreeStylesDrawDifferentHalos() {
    func halo(_ style: CursorHighlightStyle) -> HighlightCircle {
        var m = ClickHighlightModel(settings: ClickHighlightSettings(style: style, size: .medium))
        m.pointerMoved(to: Point(x: 0, y: 0))
        return m.circles(at: 0)[0]
    }
    let ring = halo(.ring), filled = halo(.filled), outline = halo(.outline)
    #expect(!ring.filled && ring.strokeWidth == 22 * 0.18)      // stroked only
    #expect(filled.filled && filled.strokeWidth == 0)          // filled only
    #expect(outline.filled && outline.strokeWidth == 22 * 0.18) // both
    #expect(HighlightCircle.strokeWidth(for: 5) == 2)          // never thinner than 2 pt
    #expect(ring.bounds == Rect(x: -22, y: -22, width: 44, height: 44))
}

@Test func aClickSpawnsARingThatGrowsAndFadesThenDisappears() {
    var m = ClickHighlightModel(settings: ClickHighlightSettings(style: .ring, size: .small, animateClicks: true))
    m.clicked(at: Point(x: 10, y: 10), time: 5)
    let start = m.circles(at: 5)
    #expect(start.count == 2)
    #expect(start[1] == HighlightCircle(center: Point(x: 10, y: 10), radius: 14, opacity: 1, filled: false, strokeWidth: 14 * 0.18))

    let half = m.circles(at: 5.2)[1]
    #expect(abs(half.radius - 14 * (1 + 1.4 * 0.5)) < 0.001)
    #expect(abs(half.opacity - 0.5) < 0.001)

    #expect(m.circles(at: 5.4).count == 1)               // the ring's 0.4 s are up
    m.prune(at: 5.4)
    #expect(m == ClickHighlightModel(settings: m.settings).withPointer(Point(x: 10, y: 10)))
}

@Test func animationOffMeansAClickOnlyMovesTheHalo() {
    var m = ClickHighlightModel(settings: ClickHighlightSettings(animateClicks: false))
    m.clicked(at: Point(x: 3, y: 4), time: 0)
    #expect(m.circles(at: 0).count == 1)
    #expect(m.pointer == Point(x: 3, y: 4))
}

@Test func mappingConvertsScreenPointsToFramePixels() {
    // A 400×300-pt region at (100, 50) recorded at 2× → 800×600 px.
    let mapping = FrameMapping(regionOrigin: Point(x: 100, y: 50), pixelsPerPointX: 2, pixelsPerPointY: 2)
    #expect(mapping.pixelPoint(for: Point(x: 100, y: 50)) == Point(x: 0, y: 0))
    #expect(mapping.pixelPoint(for: Point(x: 300, y: 200)) == Point(x: 400, y: 300))
    let circle = mapping.pixelCircle(for: HighlightCircle(center: Point(x: 110, y: 60), radius: 22, opacity: 1, filled: false, strokeWidth: 3))
    #expect(circle == HighlightCircle(center: Point(x: 20, y: 20), radius: 44, opacity: 1, filled: false, strokeWidth: 6))
    // Capped output: 1280 px wide for a 2560-pt-wide display → 0.5 px per point.
    let capped = FrameMapping(regionOrigin: Point(x: 0, y: 0), pixelsPerPointX: 0.5, pixelsPerPointY: 0.5)
    #expect(capped.pixelPoint(for: Point(x: 2560, y: 1440)) == Point(x: 1280, y: 720))
}

private extension ClickHighlightModel {
    func withPointer(_ point: Point) -> ClickHighlightModel {
        var copy = self
        copy.pointerMoved(to: point)
        return copy
    }
}
