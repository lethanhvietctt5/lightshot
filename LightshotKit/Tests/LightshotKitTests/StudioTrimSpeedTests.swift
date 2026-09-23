import Testing
import Foundation
@testable import LightshotKit

// Trim and speed pills (spec 0007, round 3, stories 34–35): trims are skipped, speed regions
// change the rate, and the played clips are derived from both; older projects migrate.

private func document(_ duration: Double = 10) -> StudioDocument {
    StudioDocument(edits: StudioEdits(sourceDuration: duration, look: .studio))
}

private func spans(_ edits: StudioEdits) -> [[Double]] {
    edits.clips.map { [($0.start * 100).rounded() / 100, ($0.end * 100).rounded() / 100, $0.speed] }
}

// MARK: - Trims

@Test func aTrimAddedAtThePlayheadIsSkipped() {
    var doc = document(10)
    let id = doc.addTrim(atSource: 3)
    #expect(id != nil)
    let trim = doc.edits.trims[0]
    #expect(trim.start == 3 && trim.end == 3 + TrimRegion.defaultLength)
    #expect(spans(doc.edits) == [[0, 3, 1], [5, 10, 1]])
    #expect(doc.timeline.outputDuration == 8)
    #expect(doc.timeline.outputTime(atSource: 4) == nil)
}

@Test func movingAndResizingATrimMovesTheSkip() {
    var doc = document(10)
    let id = doc.addTrim(atSource: 3)!
    doc.moveTrim(id, toStart: 6)
    #expect(spans(doc.edits) == [[0, 6, 1], [8, 10, 1]])
    doc.resizeTrim(id, start: 6, end: 20)                           // stays inside the source
    #expect(spans(doc.edits) == [[0, 6, 1]])
    doc.removeTrim(id)
    #expect(spans(doc.edits) == [[0, 10, 1]])
}

@Test func trimsNeverOverlap() {
    var doc = document(10)
    let a = doc.addTrim(atSource: 1)!                               // 1…3
    let b = doc.addTrim(atSource: 2)!                               // the gap after a: 3…5
    #expect(doc.edits.trims.first { $0.id == b }!.start >= 3)
    doc.resizeTrim(a, start: 0, end: 9)                             // stops at b's start
    #expect(doc.edits.trims.first { $0.id == a }!.end == 3)
}

@Test func aTrimThatWouldLeaveNothingIsRefused() {
    var doc = document(2)
    #expect(doc.addTrim(atSource: 0) == nil)                        // 2 s default over a 2 s source
    #expect(doc.edits.trims.isEmpty && !doc.canUndo)
    let id = doc.addTrim(atSource: 0, length: 1)!
    doc.resizeTrim(id, start: 0, end: 2)
    #expect(doc.edits.trims[0].end == 1)
}

// MARK: - Speed

@Test func aSpeedRegionChangesTheRateOfItsSpan() {
    var doc = document(10)
    let id = doc.addSpeed(atSource: 2, speed: 2)!
    #expect(spans(doc.edits) == [[0, 2, 1], [2, 4, 2], [4, 10, 1]])
    #expect(doc.timeline.outputDuration == 9)
    doc.setSpeed(id, 0.5)
    #expect(doc.timeline.outputDuration == 12)
}

@Test func speedIsClampedToAQuarterToFourTimes() {
    var doc = document(10)
    let id = doc.addSpeed(atSource: 0, speed: 2)!
    doc.setSpeed(id, 10)
    #expect(doc.edits.speeds[0].speed == 4)
    doc.setSpeed(id, 0.1)
    #expect(doc.edits.speeds[0].speed == 0.25)
}

@Test func aTrimInsideASpeedRegionCutsItAndKeepsTheRateAroundIt() {
    var doc = document(10)
    doc.addSpeed(atSource: 2, length: 6, speed: 2)                  // 2…8 at 2×
    doc.addTrim(atSource: 4, length: 1)                             // 4…5 skipped
    #expect(spans(doc.edits) == [[0, 2, 1], [2, 4, 2], [5, 8, 2], [8, 10, 1]])
}

@Test func seekingIntoATrimLandsWherePlaybackResumes() {
    var doc = document(10)
    doc.addTrim(atSource: 3)                                        // 3…5
    #expect(doc.timeline.playableOutputTime(atSource: 4) == 3)
    #expect(doc.timeline.playableOutputTime(atSource: 6) == 4)
    doc.addTrim(atSource: 8)                                        // 8…10: the end is trimmed
    #expect(doc.timeline.playableOutputTime(atSource: 9) == doc.timeline.outputDuration)
}

@Test func trimAndSpeedUndoAndRedo() {
    var doc = document(10)
    let original = doc.edits
    doc.addTrim(atSource: 1)
    let trimmed = doc.edits
    doc.addSpeed(atSource: 5, speed: 2)
    doc.undo()
    #expect(doc.edits == trimmed)
    doc.undo()
    #expect(doc.edits == original)
}

// MARK: - Persistence

@Test func trimsAndSpeedsRoundTripThroughJSON() throws {
    var doc = document(12)
    doc.addTrim(atSource: 1)
    doc.addSpeed(atSource: 6, speed: 0.5)
    let decoded = try JSONDecoder().decode(StudioEdits.self, from: JSONEncoder().encode(doc.edits))
    #expect(decoded == doc.edits)
    #expect(decoded.version == StudioEdits.currentVersion)
}

@Test func aProjectSavedWithClipsMigratesToTrimsAndSpeeds() throws {
    let edits = StudioEdits(sourceDuration: 10, look: .studio)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edits)) as! [String: Any]
    json.removeValue(forKey: "trims")
    json.removeValue(forKey: "speeds")
    json["version"] = 1
    json["clips"] = [
        ["id": UUID().uuidString, "start": 0, "end": 3, "speed": 1],
        ["id": UUID().uuidString, "start": 5, "end": 8, "speed": 2],
    ]
    let decoded = try JSONDecoder().decode(StudioEdits.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.trims.map { [$0.start, $0.end] } == [[3, 5], [8, 10]])
    #expect(decoded.speeds.map { [$0.start, $0.end, $0.speed] } == [[5, 8, 2]])
    #expect(spans(decoded) == [[0, 3, 1], [5, 8, 2]])
    #expect(decoded.version == StudioEdits.currentVersion)
}

// MARK: - Cursor style and defaults (stories 36–37)

@Test func aProjectWithoutACursorThemeGetsTheMacOSArrow() throws {
    var edits = StudioEdits(sourceDuration: 5, look: .studio)
    edits.cursor.theme = .neon
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edits)) as! [String: Any]
    var cursor = json["cursor"] as! [String: Any]
    #expect(cursor["theme"] as? String == "neon")
    cursor.removeValue(forKey: "theme")
    json["cursor"] = cursor
    let decoded = try JSONDecoder().decode(StudioEdits.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.cursor.theme == .macOS)
}

@Test func aStudioProjectStartsWithNoPaddingOrCorners() {
    let studio = StudioEdits(sourceDuration: 5, look: .studio)
    #expect(studio.canvas.padding == 0 && studio.canvas.cornerRadius == 0)
}

@Test func theDefaultClickColourIsTheRecordersYellow() {
    let yellow = CursorHighlightColor.yellow.rgb!
    let expected = RGBAColor(red: yellow.red, green: yellow.green, blue: yellow.blue)
    #expect(CursorStyle().clickColor == expected)
    #expect(StudioEdits(sourceDuration: 5, look: .studio).cursor.clickColor == expected)
    let options = RecordingOptions(
        region: .display(id: 1), output: .video(VideoSettings(codec: .h264, fps: 30, maxResolution: .original, scaleRetinaTo1x: false)),
        highlightClicks: true,
        clickHighlight: ClickHighlightSettings(color: .accent)          // no fixed colour: falls back to yellow
    )
    #expect(StudioEdits.flattenLook(options: options, sourceDuration: 5).cursor.clickColor == expected)
}
