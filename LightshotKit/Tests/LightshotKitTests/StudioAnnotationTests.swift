import Testing
import Foundation
@testable import LightshotKit

// Text annotations (spec 0007, round 2, story 32): added at the playhead, moved, resized,
// restyled and removed — each one undo step — and faded in and out.

private func document(_ duration: Double = 10) -> StudioDocument {
    StudioDocument(edits: StudioEdits(sourceDuration: duration, look: .studio))
}

@Test func anAnnotationAddedAtThePlayheadRunsForTheDefaultLength() {
    var doc = document()
    let id = doc.addAnnotation(atSource: 2)
    let a = doc.edits.annotations.first { $0.id == id }!
    #expect(a.start == 2 && a.end == 2 + TextAnnotation.defaultLength)
    #expect(a.text == "Title")
}

@Test func anAnnotationNearTheEndIsPulledInside() {
    var doc = document(10)
    let id = doc.addAnnotation(atSource: 9.5)
    let a = doc.edits.annotations.first { $0.id == id }!
    #expect(a.end == 10 && a.start == 10 - TextAnnotation.defaultLength)
}

@Test func annotationsMayOverlapAndMoveKeepingTheirLength() {
    var doc = document(10)
    let a = doc.addAnnotation(atSource: 1)
    let b = doc.addAnnotation(atSource: 2)
    #expect(doc.edits.annotations.count == 2)
    doc.moveAnnotation(b, toStart: 9)
    let moved = doc.edits.annotations.first { $0.id == b }!
    #expect(moved.end == 10 && moved.start == 7)
    doc.resizeAnnotation(a, start: 0.5, end: 0.55)                          // never below the minimum
    let resized = doc.edits.annotations.first { $0.id == a }!
    #expect(resized.end - resized.start >= TextAnnotation.minimumLength - 1e-9)
}

@Test func anAnnotationIsRestyledAndClampedAndEachChangeUndoes() {
    var doc = document()
    let id = doc.addAnnotation(atSource: 1)
    doc.updateAnnotation(id) { $0.text = "Step 1"; $0.center = Point(x: 1.5, y: -1); $0.size = 5 }
    let a = doc.edits.annotations[0]
    #expect(a.text == "Step 1" && a.center == Point(x: 1, y: 0) && a.size == 0.25)
    doc.undo()
    #expect(doc.edits.annotations[0].text == "Title")
    doc.removeAnnotation(id)
    #expect(doc.edits.annotations.isEmpty)
    doc.undo()
    #expect(doc.edits.annotations.count == 1)
}

@Test func anAnnotationFadesInAndOut() {
    let a = TextAnnotation(start: 1, end: 3, fade: 0.5)
    #expect(a.opacity(at: 0.9) == 0)
    #expect(abs(a.opacity(at: 1.25) - 0.5) < 1e-9)
    #expect(a.opacity(at: 2) == 1)
    #expect(abs(a.opacity(at: 2.75) - 0.5) < 1e-9)
    #expect(a.opacity(at: 3) == 0)
}
