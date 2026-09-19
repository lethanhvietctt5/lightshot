import Testing
import Foundation
@testable import LightshotKit

// Pure view↔image coordinate mapping (spec 0001, Key contracts: "the editor view maps
// to/from view space"). No SwiftUI here — the projection is plain geometry.

@Suite struct CanvasProjectionTests {
    @Test func fitsWideImageAndCentersVertically() {
        // 200×100 image in a 200×200 view: scale 1, letter-boxed with 50pt top/bottom.
        let p = CanvasProjection(imageSize: Size(width: 200, height: 100), viewSize: Size(width: 200, height: 200))
        #expect(p.scale == 1)
        #expect(p.imageOrigin == Point(x: 0, y: 50))
        #expect(p.toView(Point(x: 0, y: 0)) == Point(x: 0, y: 50))
    }

    @Test func scalesDownToFitAndRoundTrips() {
        // 400×400 image into a 200×200 view halves everything.
        let p = CanvasProjection(imageSize: Size(width: 400, height: 400), viewSize: Size(width: 200, height: 200))
        #expect(p.scale == 0.5)
        let imagePoint = Point(x: 120, y: 300)
        let viewPoint = p.toView(imagePoint)
        let back = p.toImage(viewPoint)
        #expect(abs(back.x - imagePoint.x) < 1e-9)
        #expect(abs(back.y - imagePoint.y) < 1e-9)
    }

    @Test func projectsRectExtentByScale() {
        let p = CanvasProjection(imageSize: Size(width: 100, height: 100), viewSize: Size(width: 50, height: 50))
        let r = p.toView(Rect(x: 10, y: 20, width: 40, height: 60))
        #expect(r == Rect(x: 5, y: 10, width: 20, height: 30))
    }

    @Test func degenerateViewMapsToOriginInsteadOfDividingByZero() {
        let p = CanvasProjection(imageSize: Size(width: 100, height: 100), viewSize: Size(width: 0, height: 0))
        #expect(p.toImage(Point(x: 10, y: 10)) == Point(x: 0, y: 0))
    }
}
