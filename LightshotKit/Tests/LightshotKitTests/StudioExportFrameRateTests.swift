import Testing
import Foundation
@testable import LightshotKit

// A new edit's export frame rate (spec 0007, story 25; LIG-75). Takes record at 30 fps by
// default, and exporting them at 60 renders and encodes twice the frames they have. The screen
// movie can't say what it was recorded at — ScreenCaptureKit only sends a frame when the screen
// changes, so its average rate runs anywhere from 0.5 to 56 fps — so the take keeps it as data.

@Test func aNewEditExportsAtTheRateItWasRecordedAt() {
    #expect(StudioOutput.defaultFPS(recorded: 30) == 30)
    #expect(StudioOutput.defaultFPS(recorded: 60) == 60)
    #expect(StudioOutput.defaultFPS(recorded: 24) == 24)
}

@Test func aRateBetweenTheChoicesRoundsUpSoNoFrameIsDropped() {
    #expect(StudioOutput.defaultFPS(recorded: 15) == 24)
    #expect(StudioOutput.defaultFPS(recorded: 25) == 30)
    #expect(StudioOutput.defaultFPS(recorded: 50) == 60)
    #expect(StudioOutput.defaultFPS(recorded: 120) == 60)
}

@Test func aTakeWithoutARecordedRateKeepsSixty() {
    #expect(StudioOutput.defaultFPS(recorded: nil) == 60)
    #expect(StudioOutput.defaultFPS(recorded: 0) == 60)
}

@Test func theRecorderKeepsTheTakesFrameRate() {
    var recorder = StudioInputRecorder(regionOrigin: Point(x: 0, y: 0), regionSize: Size(width: 800, height: 600))
    recorder.frameRate = 30
    #expect(recorder.finish().frameRate == 30)
}

@Test func inputFromBeforeTheFrameRateDecodesWithoutOne() throws {
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(StudioInput(regionSize: Size(width: 4, height: 4), frameRate: 30))) as! [String: Any]
    #expect(json["frameRate"] as? Int == 30)
    json.removeValue(forKey: "frameRate")
    let decoded = try JSONDecoder().decode(StudioInput.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.frameRate == nil)
}
