import Testing
@testable import LightshotKit

// What a recording streams for each region (spec 0006, story 5): always an area of the display,
// never one window's own pixels — so an app opened over the region mid-take is in the recording,
// as it is in CleanShot X.

@Test func aPickedWindowRecordsItsAreaOfTheDisplayNotTheWindowAlone() {
    let frame = Rect(x: 300, y: 200, width: 800, height: 500)
    #expect(CaptureRegion.window(id: 4242, frame: frame).recordedArea == .area(frame))
}

@Test func aDrawnRectRecordsThatAreaStandardized() {
    let flipped = Rect(x: 1100, y: 700, width: -800, height: -500)
    #expect(CaptureRegion.rect(flipped).recordedArea == .area(Rect(x: 300, y: 200, width: 800, height: 500)))
}

@Test func aDisplayRecordsTheWholeDisplay() {
    #expect(CaptureRegion.display(id: 7).recordedArea == .display(id: 7))
}
