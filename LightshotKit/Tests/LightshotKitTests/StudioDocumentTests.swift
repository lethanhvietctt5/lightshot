import Testing
import Foundation
@testable import LightshotKit

// The Studio editor's undoable edits (spec 0007, stories 5–13 and the look settings): clips cut,
// trimmed and sped up; zoom pills added, moved, resized; every change undoable.

private func document(_ duration: Double = 10) -> StudioDocument {
    StudioDocument(edits: StudioEdits(sourceDuration: duration, look: .studio))
}

// MARK: - Clips

@Test func aNewDocumentIsOneClipOverTheWholeSourceAtNormalSpeed() {
    let doc = document(10)
    #expect(doc.edits.clips.count == 1)
    #expect(doc.edits.clips[0].start == 0 && doc.edits.clips[0].end == 10 && doc.edits.clips[0].speed == 1)
}

@Test func splittingAtThePlayheadMakesTwoClipsThatMeetThere() {
    var doc = document(10)
    let second = doc.split(atOutput: 4)
    #expect(second != nil)
    #expect(doc.edits.clips.map { [$0.start, $0.end] } == [[0, 4], [4, 10]])
    #expect(doc.edits.clips[1].id == second)
}

@Test func splittingTooCloseToAClipEdgeDoesNothing() {
    var doc = document(10)
    #expect(doc.split(atOutput: 0.05) == nil)
    #expect(doc.edits.clips.count == 1)
}

@Test func deletingAClipCutsItsRangeOutOfTheOutput() {
    var doc = document(10)
    doc.split(atOutput: 3)
    doc.split(atOutput: 6)
    let middle = doc.edits.clips[1].id                // 3…6
    doc.deleteClip(middle)
    #expect(doc.edits.clips.map { [$0.start, $0.end] } == [[0, 3], [6, 10]])
    #expect(StudioTimeline(clips: doc.edits.clips).outputDuration == 7)
}

@Test func theLastClipCannotBeDeleted() {
    var doc = document(10)
    doc.deleteClip(doc.edits.clips[0].id)
    #expect(doc.edits.clips.count == 1)
}

@Test func trimmingAClipIsClampedToItsNeighboursAndTheSource() {
    var doc = document(10)
    let second = doc.split(atOutput: 5)!
    let first = doc.edits.clips[0].id
    doc.trimClip(first, start: -2, end: 7)        // can't pass the source start or the next clip
    #expect(doc.edits.clips[0].start == 0 && doc.edits.clips[0].end == 5)
    doc.trimClip(second, start: 6, end: 20)
    #expect(doc.edits.clips[1].start == 6 && doc.edits.clips[1].end == 10)
    doc.trimClip(second, start: 9.99, end: 10)    // never shorter than the minimum
    #expect(doc.edits.clips[1].end - doc.edits.clips[1].start >= StudioClip.minimumLength - 1e-9)
}

@Test func speedIsClampedToAQuarterToFourTimes() {
    var doc = document(10)
    let id = doc.edits.clips[0].id
    doc.setSpeed(id, 10)
    #expect(doc.edits.clips[0].speed == 4)
    doc.setSpeed(id, 0.1)
    #expect(doc.edits.clips[0].speed == 0.25)
}

// MARK: - Zooms

@Test func aZoomAddedAtThePlayheadStartsThereWithTheDefaultLengthAndScale() {
    var doc = document(10)
    let id = doc.addZoom(atSource: 2)!
    let zoom = doc.edits.zooms.first { $0.id == id }!
    #expect(zoom.start == 2 && zoom.end == 2 + ZoomRegion.defaultLength)
    #expect(zoom.scale == ZoomRegion.defaultScale)
    #expect(zoom.focus == .followCursor)
}

@Test func aZoomNearTheEndIsPulledInsideTheSource() {
    var doc = document(10)
    let id = doc.addZoom(atSource: 9.5)!
    let zoom = doc.edits.zooms.first { $0.id == id }!
    #expect(zoom.end == 10 && zoom.start == 10 - ZoomRegion.defaultLength)
}

@Test func zoomsNeverOverlapWhenAddedMovedOrResized() {
    var doc = document(10)
    let a = doc.addZoom(atSource: 1)!                 // 1…3
    let b = doc.addZoom(atSource: 2)!                 // fits the gap after a: 3…5
    let zb = doc.edits.zooms.first { $0.id == b }!
    #expect(zb.start >= 3)
    doc.moveZoom(b, toStart: 0)                       // stops at a's end
    #expect(doc.edits.zooms.first { $0.id == b }!.start == 3)
    doc.resizeZoom(a, start: 0, end: 8)               // stops at b's start
    #expect(doc.edits.zooms.first { $0.id == a }!.end == 3)
    #expect(doc.edits.zooms.sorted { $0.start < $1.start }.map(\.id) == [a, b])
}

@Test func zoomScaleAndFocusAreSetAndClamped() {
    var doc = document(10)
    let id = doc.addZoom(atSource: 1)!
    doc.setZoomScale(id, 9)
    #expect(doc.edits.zooms[0].scale == ZoomRegion.maximumScale)
    doc.setZoomFocus(id, .point(Point(x: 1.4, y: -0.2)))
    #expect(doc.edits.zooms[0].focus == .point(Point(x: 1, y: 0)))
    doc.removeZoom(id)
    #expect(doc.edits.zooms.isEmpty)
}

// MARK: - Undo / redo

@Test func everyCommandUndoesAndRedoes() {
    var doc = document(10)
    let original = doc.edits
    doc.split(atOutput: 4)
    let split = doc.edits
    doc.addZoom(atSource: 1)
    doc.undo()
    #expect(doc.edits == split)
    doc.undo()
    #expect(doc.edits == original)
    #expect(!doc.canUndo)
    doc.redo()
    #expect(doc.edits == split)
    #expect(doc.canRedo)
    doc.split(atOutput: 7)                            // a new edit drops the redo stack
    #expect(!doc.canRedo)
}

@Test func aNoOpCommandLeavesNoUndoStep() {
    var doc = document(10)
    doc.deleteClip(doc.edits.clips[0].id)
    #expect(!doc.canUndo)
}

@Test func aSliderDragIsOneUndoStep() {
    var doc = document(10)
    let before = doc.edits
    doc.beginChange()
    for p in [0.05, 0.1, 0.2, 0.3] { doc.set(\.canvas.padding, p) }
    doc.endChange()
    #expect(doc.edits.canvas.padding == 0.3)
    doc.undo()
    #expect(doc.edits == before)
}

@Test func lookSettingsAreClampedWhenSet() {
    var doc = document(10)
    doc.set(\.canvas.padding, 2)
    doc.set(\.cursor.size, 0)
    doc.set(\.zoomTransition, 9)
    #expect(doc.edits.canvas.padding == CanvasStyle.maximumPadding)
    #expect(doc.edits.cursor.size == CursorStyle.minimumSize)
    #expect(doc.edits.zoomTransition == StudioEdits.transitionRange.upperBound)
}

// MARK: - Persistence

@Test func editsRoundTripThroughJSONWithTheirVersion() throws {
    var doc = document(12)
    doc.split(atOutput: 5)
    doc.addZoom(atSource: 2)
    doc.set(\.background, .color(RGBAColor(red: 0.2, green: 0.4, blue: 0.6)))
    doc.set(\.audio, .volume(0.5))
    let data = try JSONEncoder().encode(doc.edits)
    let decoded = try JSONDecoder().decode(StudioEdits.self, from: data)
    #expect(decoded == doc.edits)
    #expect(decoded.version == StudioEdits.currentVersion)
}

@Test func aPlainVideoStartsWithNoCanvasDecoration() {
    let plain = StudioEdits(sourceDuration: 5, look: .plain)
    #expect(plain.background == StudioBackground.none)
    #expect(plain.canvas.padding == 0 && plain.canvas.cornerRadius == 0 && plain.canvas.shadow == 0)
    let studio = StudioEdits(sourceDuration: 5, look: .studio)
    #expect(studio.canvas.padding > 0)
}
