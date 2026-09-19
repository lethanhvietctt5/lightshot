import Testing
import Foundation
@testable import LightshotKit

// Behavioral suite for the AnnotationDocument domain module (LIG-8).
//
// Every test drives the **public command API** and asserts observable outcomes —
// element count, selection, geometry, step numbers, undo/redo results, crop frame —
// never internal representation. This target imports no AppKit/ScreenCaptureKit,
// which is the structural signal that the domain seam holds.

private func makeDocument(width: Int = 400, height: Int = 300) -> AnnotationDocument {
    AnnotationDocument(baseImage: CapturedImage(pixelWidth: width, pixelHeight: height, data: Data()))
}

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect {
    Rect(x: x, y: y, width: w, height: h)
}

// MARK: - Add, select, delete

@Suite struct AddSelectDeleteTests {
    @Test func addAppendsAndReturnsAddressableID() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .rectangle(rect(10, 10, 50, 40))))
        #expect(doc.elements.count == 1)
        #expect(doc.element(id: id)?.id == id)
    }

    @Test func addDoesNotChangeSelection() {
        var doc = makeDocument()
        _ = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        #expect(doc.selectedID == nil)
    }

    @Test func selectRecordsAKnownElementAndClearsOnNil() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        doc.select(id)
        #expect(doc.selectedID == id)
        doc.select(nil)
        #expect(doc.selectedID == nil)
    }

    @Test func selectIgnoresUnknownIdentity() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        doc.select(id)
        doc.select(ElementID())        // unknown id
        #expect(doc.selectedID == id)  // leaves the valid selection intact, does not wipe it
    }

    @Test func deleteRemovesElementAndClearsItsSelection() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        doc.select(id)
        doc.delete(id)
        #expect(doc.elements.isEmpty)
        #expect(doc.selectedID == nil)
    }
}

// MARK: - Move & resize

@Suite struct TransformTests {
    @Test func moveTranslatesEveryCoordinate() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .arrow(from: Point(x: 10, y: 10), to: Point(x: 30, y: 40))))
        doc.transform(id, by: .move(dx: 5, dy: -3))
        guard case let .arrow(from, to) = doc.element(id: id)?.kind else { Issue.record("kind"); return }
        #expect(from == Point(x: 15, y: 7))
        #expect(to == Point(x: 35, y: 37))
    }

    @Test func resizeFromBottomRightGrowsBoundingBox() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 100, 100))))
        doc.transform(id, by: .resize(handle: .bottomRight, dx: 50, dy: 20))
        let box = doc.element(id: id)!.kind.boundingBox
        #expect(box == rect(0, 0, 150, 120))
    }

    @Test func resizeScalesInteriorPointsProportionally() {
        var doc = makeDocument()
        // Endpoints span the full 100x100 box; doubling the width doubles their x-spread.
        let id = doc.add(AnnotationElement(kind: .line(from: Point(x: 0, y: 0), to: Point(x: 100, y: 100))))
        doc.transform(id, by: .resize(handle: .right, dx: 100, dy: 0))
        guard case let .line(from, to) = doc.element(id: id)?.kind else { Issue.record("kind"); return }
        #expect(from == Point(x: 0, y: 0))
        #expect(to == Point(x: 200, y: 100))
    }

    @Test func resizeKeepsStepMarkerCircular() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .stepMarker(number: 1, center: Point(x: 50, y: 50), radius: 10)))
        doc.transform(id, by: .resize(handle: .bottomRight, dx: 20, dy: 0))
        guard case let .stepMarker(_, center, radius) = doc.element(id: id)?.kind else { Issue.record("kind"); return }
        // Box became 40 wide x 20 tall; radius follows the shorter side, center recentered.
        #expect(radius == 10)
        #expect(center == Point(x: 60, y: 50))
    }

    @Test func transformOnUnknownIdIsANoOp() {
        var doc = makeDocument()
        _ = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        doc.transform(ElementID(), by: .move(dx: 100, dy: 100))
        // The no-op pushed no history: undoing the lone `add` empties the stack.
        doc.undo()
        #expect(doc.elements.isEmpty)
        #expect(doc.canUndo == false)
    }
}

// MARK: - Style & text

@Suite struct StyleAndTextTests {
    @Test func setStyleReplacesAppearanceOnly() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        let box = doc.element(id: id)!.kind.boundingBox
        doc.setStyle(id, Style(color: .black, strokeWidth: 8))
        #expect(doc.element(id: id)?.style.strokeWidth == 8)
        #expect(doc.element(id: id)?.kind.boundingBox == box)
    }

    @Test func updateTextRewritesStringKeepingBox() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .text("before", box: rect(0, 0, 80, 20))))
        doc.updateText(id, to: "after")
        guard case let .text(string, box) = doc.element(id: id)?.kind else { Issue.record("kind"); return }
        #expect(string == "after")
        #expect(box == rect(0, 0, 80, 20))
    }

    @Test func updateTextOnNonTextElementIsANoOp() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        doc.updateText(id, to: "nope")
        // No history beyond the `add`: undoing it empties the stack.
        doc.undo()
        #expect(doc.elements.isEmpty)
        #expect(doc.canUndo == false)
    }
}

// MARK: - Z-order & reorder

@Suite struct ReorderTests {
    @Test func addsStackInInsertionOrder() {
        var doc = makeDocument()
        let a = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        let b = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        #expect(doc.elements.map(\.id) == [a, b])
    }

    @Test func reorderMovesElementToNewIndex() {
        var doc = makeDocument()
        let a = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        let b = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        let c = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        doc.reorder(a, to: 2) // send bottom element to the top
        #expect(doc.elements.map(\.id) == [b, c, a])
    }

    @Test func reorderClampsOutOfRangeIndex() {
        var doc = makeDocument()
        let a = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        let b = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        doc.reorder(a, to: 99)
        #expect(doc.elements.map(\.id) == [b, a])
    }
}

// MARK: - Hit-testing

@Suite struct HitTestingTests {
    @Test func returnsTopmostElementAtPoint() {
        var doc = makeDocument()
        let bottom = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 100, 100))))
        let top = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 100, 100))))
        #expect(doc.elementID(at: Point(x: 50, y: 50)) == top)
        _ = bottom
    }

    @Test func reorderChangesWhichElementIsHit() {
        var doc = makeDocument()
        let bottom = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 100, 100))))
        let top = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 100, 100))))
        doc.reorder(bottom, to: 1) // bottom now on top
        #expect(doc.elementID(at: Point(x: 50, y: 50)) == bottom)
        _ = top
    }

    @Test func missReturnsNil() {
        var doc = makeDocument()
        _ = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 20, 20))))
        #expect(doc.elementID(at: Point(x: 200, y: 200)) == nil)
    }

    @Test func thinLineIsHitWithinStrokeTolerance() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .line(from: Point(x: 0, y: 0), to: Point(x: 100, y: 0))))
        #expect(doc.elementID(at: Point(x: 50, y: 4)) == id)   // near the segment
        #expect(doc.elementID(at: Point(x: 50, y: 40)) == nil) // far from it
    }

    @Test func ellipseUsesRadialContainmentNotBoundingBox() {
        var doc = makeDocument()
        _ = doc.add(AnnotationElement(kind: .ellipse(rect(0, 0, 100, 100))))
        #expect(doc.elementID(at: Point(x: 50, y: 50)) != nil) // center hits
        #expect(doc.elementID(at: Point(x: 2, y: 2)) == nil)   // corner of bbox misses
    }
}

// MARK: - Step markers

@Suite struct StepMarkerTests {
    private func addMarker(_ doc: inout AnnotationDocument, at x: Double = 0) -> ElementID {
        doc.add(AnnotationElement(kind: .stepMarker(number: 0, center: Point(x: x, y: 0), radius: 12)))
    }

    private func number(_ doc: AnnotationDocument, _ id: ElementID) -> Int? {
        if case let .stepMarker(number, _, _) = doc.element(id: id)?.kind { return number }
        return nil
    }

    @Test func numbersAutoIncrementOnAdd() {
        var doc = makeDocument()
        let a = addMarker(&doc, at: 0)
        let b = addMarker(&doc, at: 20)
        let c = addMarker(&doc, at: 40)
        #expect(number(doc, a) == 1)
        #expect(number(doc, b) == 2)
        #expect(number(doc, c) == 3)
    }

    @Test func addIgnoresCallerSuppliedNumber() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .stepMarker(number: 99, center: Point(x: 0, y: 0), radius: 12)))
        #expect(number(doc, id) == 1)
    }

    @Test func deletingAMarkerDoesNotRenumberSurvivors() {
        var doc = makeDocument()
        let a = addMarker(&doc, at: 0)
        let b = addMarker(&doc, at: 20)
        let c = addMarker(&doc, at: 40)
        doc.delete(b)
        #expect(number(doc, a) == 1)
        #expect(number(doc, c) == 3) // unchanged, no renumber
        // Next marker continues past the highest survivor, never reusing 2.
        let d = addMarker(&doc, at: 60)
        #expect(number(doc, d) == 4)
    }

    @Test func deletingHighestMarkerFreesItsNumberForReuse() {
        // Spec 0001: numbering is "based on existing markers" (max + 1). Deleting the
        // highest marker therefore frees its number, unlike deleting a middle one.
        var doc = makeDocument()
        _ = addMarker(&doc, at: 0)          // 1
        _ = addMarker(&doc, at: 20)         // 2
        let c = addMarker(&doc, at: 40)     // 3
        doc.delete(c)
        let d = addMarker(&doc, at: 60)
        #expect(number(doc, d) == 3)        // reuses the freed top number
    }

    @Test func numberingResetsOnceAllMarkersGone() {
        var doc = makeDocument()
        let a = addMarker(&doc, at: 0)
        doc.delete(a)
        let b = addMarker(&doc, at: 0)
        #expect(number(doc, b) == 1)
    }
}

// MARK: - Undo / redo

@Suite struct UndoRedoTests {
    @Test func undoRedoReversesAndReappliesAdd() {
        var doc = makeDocument()
        _ = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        #expect(doc.canUndo)
        doc.undo()
        #expect(doc.elements.isEmpty)
        doc.redo()
        #expect(doc.elements.count == 1)
    }

    @Test func undoRestoresDeletedElement() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        doc.delete(id)
        doc.undo()
        #expect(doc.element(id: id) != nil)
    }

    @Test func undoRevertsMoveGeometry() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .arrow(from: Point(x: 0, y: 0), to: Point(x: 10, y: 10))))
        doc.transform(id, by: .move(dx: 25, dy: 25))
        doc.undo()
        guard case let .arrow(from, _) = doc.element(id: id)?.kind else { Issue.record("kind"); return }
        #expect(from == Point(x: 0, y: 0))
    }

    @Test func undoRevertsStyleAndText() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .text("v1", box: rect(0, 0, 40, 20))))
        doc.setStyle(id, Style(strokeWidth: 9))
        doc.updateText(id, to: "v2")
        doc.undo() // text
        doc.undo() // style
        #expect(doc.element(id: id)?.style.strokeWidth == Style.default.strokeWidth)
        if case let .text(string, _) = doc.element(id: id)?.kind { #expect(string == "v1") }
    }

    @Test func redoReappliesANonAddCommand() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .arrow(from: Point(x: 0, y: 0), to: Point(x: 10, y: 10))))
        doc.transform(id, by: .move(dx: 25, dy: 25))
        doc.undo() // revert the move
        doc.redo() // reapply it
        guard case let .arrow(from, _) = doc.element(id: id)?.kind else { Issue.record("kind"); return }
        #expect(from == Point(x: 25, y: 25))
    }

    @Test func undoRevertsReorder() {
        var doc = makeDocument()
        let a = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        let b = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        doc.reorder(a, to: 1)
        doc.undo()
        #expect(doc.elements.map(\.id) == [a, b])
    }

    @Test func newCommandAfterUndoInvalidatesRedoStack() {
        var doc = makeDocument()
        _ = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        doc.undo()
        #expect(doc.canRedo)
        _ = doc.add(AnnotationElement(kind: .ellipse(rect(0, 0, 10, 10)))) // new branch
        #expect(doc.canRedo == false)
        doc.redo() // no-op, nothing to redo
        #expect(doc.elements.count == 1)
    }

    @Test func undoAndRedoAreNoOpsWhenStacksEmpty() {
        var doc = makeDocument()
        doc.undo()
        doc.redo()
        #expect(doc.elements.isEmpty)
        #expect(doc.canUndo == false)
        #expect(doc.canRedo == false)
    }

    @Test func selectIsNotUndoable() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .rectangle(rect(0, 0, 10, 10))))
        doc.select(id)
        #expect(doc.canUndo) // only the add is on the stack
        doc.undo()          // undoes the add, not the selection
        #expect(doc.elements.isEmpty)
        #expect(doc.selectedID == nil) // dangling selection sanitized
    }
}

// MARK: - Crop

@Suite struct CropTests {
    @Test func visibleFrameDefaultsToFullImage() {
        let doc = makeDocument(width: 400, height: 300)
        #expect(doc.cropRect == nil)
        #expect(doc.visibleFrame == rect(0, 0, 400, 300))
    }

    @Test func applyCropRecordsTheVisibleFrame() {
        var doc = makeDocument()
        doc.applyCrop(rect(50, 40, 100, 80))
        #expect(doc.visibleFrame == rect(50, 40, 100, 80))
    }

    @Test func applyCropClampsToImageBounds() {
        var doc = makeDocument(width: 400, height: 300)
        doc.applyCrop(rect(-50, -50, 1000, 1000))
        #expect(doc.visibleFrame == rect(0, 0, 400, 300))
    }

    @Test func cropDoesNotMoveElementGeometry() {
        var doc = makeDocument()
        let id = doc.add(AnnotationElement(kind: .rectangle(rect(120, 100, 40, 30))))
        doc.applyCrop(rect(100, 90, 120, 90))
        // Geometry stays in original image space, unaffected by the crop.
        #expect(doc.element(id: id)?.kind.boundingBox == rect(120, 100, 40, 30))
    }

    @Test func cropAppliedThenReversedLeavesElementsIntactInImageSpace() {
        var doc = makeDocument()
        let a = doc.add(AnnotationElement(kind: .rectangle(rect(10, 10, 40, 30))))
        let b = doc.add(AnnotationElement(kind: .arrow(from: Point(x: 200, y: 150), to: Point(x: 260, y: 190))))
        let before = doc.elements
        doc.applyCrop(rect(0, 0, 150, 120))
        doc.undo() // reverse the crop
        #expect(doc.cropRect == nil)
        #expect(doc.visibleFrame == doc.imageBounds)
        #expect(doc.elements == before)
        #expect(doc.element(id: a)?.kind.boundingBox == rect(10, 10, 40, 30))
        #expect(doc.element(id: b) != nil)
    }
}
