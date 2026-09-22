import Testing
import Foundation
@testable import LightshotKit

// The camera bubble's layout (spec 0006, stories 26–28): size from the region, the default
// corner, a dragged anchor, clamping, shape radii, aspect-fill, and preview/output agreement.

private let region = Size(width: 1200, height: 800)

@Test func theBubbleSizeFollowsTheRegionsShorterSideWithAFloor() {
    #expect(CameraBubbleLayout.side(for: .medium, in: region) == 200)     // 25 % of 800
    #expect(CameraBubbleLayout.side(for: .huge, in: region) == 360)
    #expect(CameraBubbleLayout.side(for: .tiny, in: region) == 96)
    #expect(CameraBubbleLayout.side(for: .tiny, in: Size(width: 300, height: 300)) == 80)   // the floor
    #expect(CameraBubbleLayout.side(for: .huge, in: Size(width: 60, height: 40)) == 40)     // never past the region
}

@Test func theDefaultCornerIsBottomRightWithAMargin() {
    let frame = CameraBubbleLayout.frame(.standard, in: region)
    #expect(frame == Rect(x: 1200 - 16 - 200, y: 800 - 16 - 200, width: 200, height: 200))
}

@Test func aDraggedAnchorPlacesTheBubbleAndIsClampedInsideTheRegion() {
    let centered = CameraBubbleSettings(anchor: Point(x: 0.5, y: 0.5))
    #expect(CameraBubbleLayout.frame(centered, in: region) == Rect(x: 500, y: 300, width: 200, height: 200))
    let offTop = CameraBubbleSettings(anchor: Point(x: 0, y: 0))
    #expect(CameraBubbleLayout.frame(offTop, in: region) == Rect(x: 0, y: 0, width: 200, height: 200))
    #expect(CameraBubbleLayout.anchor(forCenter: Point(x: 600, y: 400), in: region) == Point(x: 0.5, y: 0.5))
    #expect(CameraBubbleLayout.anchor(forCenter: Point(x: -50, y: 900), in: region) == Point(x: 0, y: 1))
}

@Test func fullscreenCoversTheRegionSquareCornered() {
    #expect(CameraBubbleLayout.frame(.standard, in: region, fullscreen: true) == Rect(x: 0, y: 0, width: 1200, height: 800))
    #expect(CameraBubbleLayout.cornerRadius(for: .circle, side: 200, fullscreen: true) == 0)
}

@Test func shapesMapToCornerRadii() {
    #expect(CameraBubbleLayout.cornerRadius(for: .circle, side: 200) == 100)
    #expect(CameraBubbleLayout.cornerRadius(for: .rounded, side: 200) == 36)
    #expect(CameraBubbleLayout.cornerRadius(for: .square, side: 200) == 0)
}

@Test func aspectFillCoversTheBubbleCentred() {
    let bubble = Rect(x: 100, y: 100, width: 200, height: 200)
    let wide = CameraBubbleLayout.coverRect(imageAspect: 16.0 / 9.0, in: bubble)
    #expect(abs(wide.width - 200 * 16 / 9) < 0.001 && wide.height == 200)
    #expect(abs(wide.midX - 200) < 0.001 && wide.midY == 200)
    let tall = CameraBubbleLayout.coverRect(imageAspect: 0.5, in: bubble)
    #expect(tall.width == 200 && tall.height == 400 && tall.midY == 200)
}

@Test func previewAndOutputAgreeWithinAPixelAt1xAnd2x() {
    // The preview places a window: region + bubble, flipped into AppKit's bottom-left space and
    // snapped to whole points by the window server. The compositor maps the same bubble through
    // `FrameMapping` into frame pixels. Read the window back through the flip and compare.
    let settings = CameraBubbleSettings(size: .small, anchor: Point(x: 0.333, y: 0.777))
    let regionOrigin = Point(x: 137, y: 91), screenHeight = 1117.0
    let local = CameraBubbleLayout.frame(settings, in: region)
    for scale in [1.0, 2.0] {
        // Preview: AppKit frame (bottom-left, whole points), then back to top-left screen points.
        let appKitY = (screenHeight - (regionOrigin.y + local.maxY)).rounded()
        let windowTop = screenHeight - (appKitY + local.height.rounded())
        let previewPixels = Point(x: ((regionOrigin.x + local.minX).rounded() - regionOrigin.x) * scale,
                                  y: (windowTop - regionOrigin.y) * scale)
        // Output: the compositor's frame-pixel rect for the same bubble.
        let mapping = FrameMapping(regionOrigin: regionOrigin, pixelsPerPointX: scale, pixelsPerPointY: scale)
        let outputPixels = mapping.pixelPoint(for: Point(x: regionOrigin.x + local.minX, y: regionOrigin.y + local.minY))
        #expect(abs(previewPixels.x - outputPixels.x) <= scale && abs(previewPixels.y - outputPixels.y) <= scale)
    }
}
