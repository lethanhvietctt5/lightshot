import Testing
import Foundation
@testable import LightshotKit

// The Studio editor's pure engines (spec 0007): time mapping across cuts and speeds, the zoom
// camera, the smoothed cursor, auto zoom, and the canvas layout.

private func clip(_ start: Double, _ end: Double, speed: Double = 1) -> StudioClip {
    StudioClip(start: start, end: end, speed: speed)
}

private func approx(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

// MARK: - StudioTimeline

@Test func outputTimeMapsBackToSourceAcrossACut() {
    let timeline = StudioTimeline(clips: [clip(0, 3), clip(6, 10)])
    #expect(timeline.outputDuration == 7)
    #expect(timeline.sourceTime(atOutput: 2) == 2)
    #expect(timeline.sourceTime(atOutput: 3) == 6)                  // the boundary belongs to the next clip
    #expect(timeline.sourceTime(atOutput: 5) == 8)
    #expect(timeline.sourceTime(atOutput: 99) == 10)                // clamped to the end
    #expect(timeline.outputTime(atSource: 8) == 5)
    #expect(timeline.outputTime(atSource: 4.5) == nil)              // inside the cut
}

@Test func aFasterClipTakesLessOutputTime() {
    let timeline = StudioTimeline(clips: [clip(0, 4, speed: 2), clip(4, 6)])
    #expect(timeline.outputDuration == 4)
    #expect(timeline.sourceTime(atOutput: 1) == 2)
    #expect(timeline.sourceTime(atOutput: 3) == 5)
    #expect(timeline.outputTime(atSource: 3) == 1.5)
    #expect(timeline.segments.map(\.outputStart) == [0, 2])
}

// MARK: - CursorPath

private let moveRight = [
    TimedPoint(time: 0, point: Point(x: 0, y: 0)),
    TimedPoint(time: 1, point: Point(x: 100, y: 0)),
]

@Test func withoutSmoothingTheCursorFollowsTheSamplesLinearly() {
    let path = CursorPath(samples: moveRight, clicks: [], duration: 2, smoothing: 0)
    #expect(approx(path.position(at: 0.5)!.x, 50, 0.5))
    #expect(path.position(at: 1.5)!.x == 100)                        // holds the last sample
    #expect(approx(path.velocity(at: 0.5).x, 100, 2))
}

@Test func smoothingLagsBehindThenSettlesOnTheTarget() {
    let raw = CursorPath(samples: moveRight, clicks: [], duration: 3, smoothing: 0)
    let smooth = CursorPath(samples: moveRight, clicks: [], duration: 3, smoothing: 0.8)
    #expect(smooth.position(at: 0.5)!.x < raw.position(at: 0.5)!.x)
    #expect(approx(smooth.position(at: 2.9)!.x, 100, 0.5))
}

@Test func aCursorWithNoSamplesHasNoPosition() {
    #expect(CursorPath(samples: [], clicks: [], duration: 2, smoothing: 0.5).position(at: 1) == nil)
}

@Test func theCursorFadesOutAfterItStopsMovingForTheIdleDelay() {
    let path = CursorPath(samples: moveRight, clicks: [], duration: 6, smoothing: 0)
    #expect(path.idleOpacity(at: 0.5, delay: 2) == 1)
    #expect(path.idleOpacity(at: 2.9, delay: 2) == 1)                 // stopped at 1 s; 1.9 s idle
    #expect(path.idleOpacity(at: 5, delay: 2) == 0)
}

@Test func aClickIsReportedForHalfASecondWithItsProgress() {
    let path = CursorPath(samples: moveRight, clicks: [TimedPoint(time: 1, point: Point(x: 100, y: 0))], duration: 3, smoothing: 0)
    #expect(path.clicks(at: 0.9).isEmpty)
    #expect(approx(path.clicks(at: 1.25).first!.progress, 0.5))
    #expect(path.clicks(at: 1.6).isEmpty)
}

// MARK: - ZoomCamera

private let frame = Size(width: 1000, height: 500)

private func camera(_ zooms: [ZoomRegion], cursor: CursorPath? = nil, transition: Double = 0.5) -> ZoomCamera {
    ZoomCamera(zooms: zooms, transition: transition, cursor: cursor, regionSize: frame)
}

@Test func withNoZoomTheViewportIsTheWholeFrame() {
    let v = camera([]).viewport(at: 3)
    #expect(v.scale == 1)
    #expect(v.rect == Rect(x: 0, y: 0, width: 1, height: 1))
}

@Test func aZoomEasesInHoldsAndEasesOut() {
    let zoom = ZoomRegion(start: 1, end: 3, scale: 2, focus: .point(Point(x: 0.5, y: 0.5)))
    let cam = camera([zoom])
    #expect(cam.viewport(at: 0.9).scale == 1)
    #expect(approx(cam.viewport(at: 1.25).scale, 1.5))               // eased midpoint of the way in
    #expect(cam.viewport(at: 2).scale == 2)
    #expect(approx(cam.viewport(at: 3.25).scale, 1.5))
    #expect(cam.viewport(at: 3.6).scale == 1)
}

@Test func aFocusNearTheEdgeIsClampedSoTheViewportStaysInTheFrame() {
    let zoom = ZoomRegion(start: 0, end: 4, scale: 2, focus: .point(Point(x: 0.95, y: 0.02)))
    let rect = camera([zoom]).viewport(at: 2).rect
    #expect(approx(rect.minX + rect.width, 1) && approx(rect.minY, 0))
    #expect(approx(rect.width, 0.5))
}

@Test func followCursorKeepsTheCursorInsideTheViewport() {
    let samples = stride(from: 0.0, through: 4, by: 0.05).map {
        TimedPoint(time: $0, point: Point(x: 100 + 200 * $0, y: 250))
    }
    let path = CursorPath(samples: samples, clicks: [], duration: 4, smoothing: 0)
    let zoom = ZoomRegion(start: 0, end: 4, scale: 3, focus: .followCursor)
    let cam = camera([zoom], cursor: path)
    for t in stride(from: 1.0, through: 3.5, by: 0.5) {
        let rect = cam.viewport(at: t).rect
        let cursorX = path.position(at: t)!.x / frame.width
        #expect(cursorX >= rect.minX && cursorX <= rect.minX + rect.width, "t=\(t)")
    }
}

@Test func smallCursorMovesInsideTheDeadZoneDoNotPan() {
    let samples = stride(from: 0.0, through: 4, by: 0.05).map {
        TimedPoint(time: $0, point: Point(x: 500 + 10 * sin($0 * 6), y: 250))
    }
    let path = CursorPath(samples: samples, clicks: [], duration: 4, smoothing: 0)
    let cam = camera([ZoomRegion(start: 0, end: 4, scale: 2, focus: .followCursor)], cursor: path)
    #expect(approx(cam.viewport(at: 1.5).rect.minX, cam.viewport(at: 3).rect.minX, 1e-3))
}

@Test func backToBackZoomsBlendWithoutZoomingOutInBetween() {
    let a = ZoomRegion(start: 0, end: 2, scale: 2, focus: .point(Point(x: 0.3, y: 0.5)))
    let b = ZoomRegion(start: 2.2, end: 4, scale: 2, focus: .point(Point(x: 0.7, y: 0.5)))
    let cam = camera([a, b])
    for t in stride(from: 1.0, through: 3.5, by: 0.1) {
        #expect(cam.viewport(at: t).scale >= 2 - 1e-9, "t=\(t)")
    }
    #expect(cam.viewport(at: 2.2).rect.midX < cam.viewport(at: 3).rect.midX)
}

// MARK: - AutoZoom

@Test func autoZoomMakesOneFollowCursorZoomPerClusterOfClicks() {
    let clicks = [1.0, 2.0, 2.5, 9.0, 9.4].map { TimedPoint(time: $0, point: Point(x: 0, y: 0)) }
    let zooms = AutoZoom.suggest(clicks: clicks, duration: 20)
    #expect(zooms.count == 2)
    #expect(approx(zooms[0].start, 1 - AutoZoom.leadIn) && approx(zooms[0].end, 2.5 + AutoZoom.tail))
    #expect(zooms.allSatisfy { $0.focus == .followCursor && $0.scale == AutoZoom.scale })
}

@Test func autoZoomRegionsAreClampedToTheSource() {
    let clicks = [0.2, 6.8].map { TimedPoint(time: $0, point: Point(x: 0, y: 0)) }
    let zooms = AutoZoom.suggest(clicks: clicks, duration: 7)
    #expect(zooms.count == 2)
    #expect(zooms[0].start == 0 && zooms[1].end == 7)
}

// MARK: - CanvasLayout

@Test func autoAspectWithNoPaddingIsTheSourceItself() {
    let layout = CanvasLayout(sourceSize: Size(width: 1920, height: 1080), style: CanvasStyle(padding: 0, aspect: .auto), resolution: .source)
    #expect(layout.canvas == Size(width: 1920, height: 1080))
    #expect(layout.content == Rect(x: 0, y: 0, width: 1920, height: 1080))
}

@Test func paddingInsetsTheContentByAFractionOfTheShorterSide() {
    let layout = CanvasLayout(sourceSize: Size(width: 1920, height: 1080), style: CanvasStyle(padding: 0.1, aspect: .wide), resolution: .p1080)
    #expect(layout.canvas == Size(width: 1920, height: 1080))
    #expect(approx(layout.content.minY, 108))
    #expect(approx(layout.content.height, 864))
    #expect(approx(layout.content.width, 864 * 16 / 9))
    #expect(approx(layout.content.midX, 960))
}

@Test func aVerticalCanvasFitsALandscapeSourceAcrossItsWidth() {
    let layout = CanvasLayout(sourceSize: Size(width: 2560, height: 1440), style: CanvasStyle(padding: 0, aspect: .vertical), resolution: .p1080)
    #expect(layout.canvas == Size(width: 1080, height: 1920))
    #expect(approx(layout.content.width, 1080))
    #expect(approx(layout.content.height, 1080 * 1440 / 2560))
    #expect(approx(layout.content.midY, 960))
}

@Test func theCanvasNeverOutgrowsTheSourcesShorterSideAndKeepsEvenEdges() {
    let layout = CanvasLayout(sourceSize: Size(width: 1001, height: 721), style: CanvasStyle(padding: 0.05, aspect: .square), resolution: .p2160)
    #expect(layout.canvas.width == layout.canvas.height)
    #expect(layout.canvas.width <= 721)
    #expect(Int(layout.canvas.width) % 2 == 0)
}

@Test func cornerRadiusAndShadowScaleWithTheContent() {
    let small = CanvasLayout(sourceSize: Size(width: 1280, height: 720), style: CanvasStyle(padding: 0.1, cornerRadius: 0.05, shadow: 1, aspect: .wide), resolution: .p720)
    let large = CanvasLayout(sourceSize: Size(width: 2560, height: 1440), style: CanvasStyle(padding: 0.1, cornerRadius: 0.05, shadow: 1, aspect: .wide), resolution: .p1440)
    #expect(approx(large.cornerRadius, small.cornerRadius * 2, 1e-6))
    #expect(approx(large.shadowRadius, small.shadowRadius * 2, 1e-6))
}

// MARK: - StudioInput

@Test func studioInputRoundTripsThroughJSON() throws {
    let input = StudioInput(
        regionSize: Size(width: 800, height: 600),
        samples: moveRight,
        clicks: [TimedPoint(time: 0.5, point: Point(x: 50, y: 0))],
        keys: [TimedKeyEvent(time: 0.7, event: .keyDown(KeyPress(label: "S", modifiers: [.command])))]
    )
    let decoded = try JSONDecoder().decode(StudioInput.self, from: JSONEncoder().encode(input))
    #expect(decoded == input)
    #expect(decoded.version == StudioInput.currentVersion)
}

@Test func inputFromBeforeCursorInVideoDecodesAsACleanScreen() throws {
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(StudioInput(regionSize: Size(width: 4, height: 4)))) as! [String: Any]
    json.removeValue(forKey: "cursorInVideo")
    let decoded = try JSONDecoder().decode(StudioInput.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.cursorInVideo == false)
}
