import Testing
import Foundation
@testable import LightshotKit

// The recording overlay's selection geometry (spec 0006, stories 3–4): draw, handles, move, nudge,
// typed sizes and the aspect-ratio lock — all pure, all clamped to the display bounds.

private let bounds = Rect(x: 0, y: 0, width: 1000, height: 800)

private func drawn(_ a: Point, _ b: Point, ratio: AspectRatio = .freeform, square: Bool = false) -> EditableSelection {
    var s = EditableSelection(bounds: bounds, ratio: ratio)
    s.dragBegan(at: a)
    s.dragEnded(at: b, forceSquare: square)
    return s
}

// MARK: - Drawing

@Test func aDragDrawsAStandardizedRectAndReleaseKeepsItEditable() {
    let s = drawn(Point(x: 300, y: 200), Point(x: 100, y: 50))
    #expect(s.rect == Rect(x: 100, y: 50, width: 200, height: 150))
    #expect(s.hasSelection)
    #expect(!s.isDragging)
    #expect(s.dragKind(at: Point(x: 200, y: 100)) == .move)      // still editable after release
}

@Test func aDegenerateDragLeavesNoSelection() {
    let s = drawn(Point(x: 10, y: 10), Point(x: 12, y: 11))
    #expect(s.rect == nil)
    #expect(!s.hasSelection)
}

@Test func drawingIsClampedToTheBounds() {
    let s = drawn(Point(x: 900, y: 700), Point(x: 1500, y: 1200))
    #expect(s.rect == Rect(x: 900, y: 700, width: 100, height: 100))
}

@Test func aRatioLockConstrainsTheInitialDragFromTheAnchor() {
    let s = drawn(Point(x: 100, y: 100), Point(x: 420, y: 150), ratio: .r16x9)
    #expect(s.rect == Rect(x: 100, y: 100, width: 320, height: 180))
    // Dragging up-left keeps the anchor at the bottom-right.
    let up = drawn(Point(x: 500, y: 500), Point(x: 340, y: 450), ratio: .r16x9)
    #expect(up.rect == Rect(x: 340, y: 410, width: 160, height: 90))
}

@Test func aRatioLockedDragShrinksToFitTheBoundsInsteadOfUnlocking() {
    let s = drawn(Point(x: 800, y: 100), Point(x: 1000, y: 900), ratio: .r1x1)
    #expect(s.rect == Rect(x: 800, y: 100, width: 200, height: 200))
    #expect(s.rect!.width == s.rect!.height)
}

@Test func optionForcesASquareForThatDragOnly() {
    let s = drawn(Point(x: 0, y: 0), Point(x: 300, y: 100), square: true)
    #expect(s.rect == Rect(x: 0, y: 0, width: 300, height: 300))
    #expect(s.ratio == .freeform)
}

// MARK: - Handles

@Test func handlesAreHitWithinTheGrabRadiusAndTheInsideMoves() {
    let s = drawn(Point(x: 100, y: 100), Point(x: 300, y: 200))
    #expect(s.dragKind(at: Point(x: 305, y: 205)) == .resize(.bottomRight))
    #expect(s.dragKind(at: Point(x: 200, y: 96)) == .resize(.top))
    #expect(s.dragKind(at: Point(x: 200, y: 150)) == .move)
    #expect(s.dragKind(at: Point(x: 500, y: 500)) == .draw)
}

@Test func draggingAnEdgeMovesItAndAnchorsTheOppositeEdge() {
    var s = drawn(Point(x: 100, y: 100), Point(x: 300, y: 200))
    s.dragBegan(at: Point(x: 300, y: 150))          // right edge
    s.dragEnded(at: Point(x: 450, y: 999))          // y is irrelevant for an edge
    #expect(s.rect == Rect(x: 100, y: 100, width: 350, height: 100))

    s.dragBegan(at: Point(x: 100, y: 150))          // left edge, dragged past the right one
    s.dragEnded(at: Point(x: 500, y: 150))
    #expect(s.rect == Rect(x: 450, y: 100, width: 50, height: 100))
}

@Test func draggingACornerAnchorsTheOppositeCorner() {
    var s = drawn(Point(x: 100, y: 100), Point(x: 300, y: 200))
    s.dragBegan(at: Point(x: 100, y: 100))          // top-left
    s.dragEnded(at: Point(x: 50, y: 20))
    #expect(s.rect == Rect(x: 50, y: 20, width: 250, height: 180))
}

@Test func ratioLockedHandleDragsKeepTheLockWithTheOtherAxisFollowing() {
    var s = drawn(Point(x: 100, y: 100), Point(x: 420, y: 280), ratio: .r16x9)   // 320×180
    s.dragBegan(at: Point(x: 420, y: 190))          // right edge → height follows, top anchored
    s.dragEnded(at: Point(x: 260, y: 190))
    #expect(s.rect == Rect(x: 100, y: 100, width: 160, height: 90))

    s.dragBegan(at: Point(x: 260, y: 190))          // bottom-right corner
    s.dragEnded(at: Point(x: 740, y: 400))
    #expect(s.rect == Rect(x: 100, y: 100, width: 640, height: 360))
}

@Test func ratioLockedEdgeDragsNeverLeaveTheBounds() {
    var s = drawn(Point(x: 100, y: 100), Point(x: 300, y: 200), ratio: .r1x1)   // a locked drag: 200×200
    #expect(s.rect == Rect(x: 100, y: 100, width: 200, height: 200))
    s.dragBegan(at: Point(x: 100, y: 200))          // left edge, dragged far past the right one
    s.dragEnded(at: Point(x: 900, y: 200))
    #expect(s.rect == Rect(x: 300, y: 100, width: 600, height: 600))
    #expect(s.rect!.maxX <= 1000 && s.rect!.maxY <= 800)

    s.dragBegan(at: Point(x: 900, y: 400))          // right edge, dragged off the right of the screen
    s.dragEnded(at: Point(x: 1500, y: 400))
    #expect(s.rect!.maxX <= 1000 && s.rect!.maxY <= 800)
    #expect(s.rect!.width == s.rect!.height)
}

@Test func ratioLockedTopAndBottomEdgeDragsFollowWithTheWidth() {
    var s = drawn(Point(x: 100, y: 100), Point(x: 420, y: 280), ratio: .r16x9)   // 320×180
    s.dragBegan(at: Point(x: 260, y: 280))          // bottom edge → width follows, left anchored
    s.dragEnded(at: Point(x: 260, y: 190))
    #expect(s.rect == Rect(x: 100, y: 100, width: 160, height: 90))
    s.dragBegan(at: Point(x: 180, y: 100))          // top edge dragged to the screen's top edge
    s.dragEnded(at: Point(x: 180, y: 0))
    let r = s.rect!
    #expect(r.minX == 100 && r.minY == 0 && r.height == 190)   // bottom edge anchored at y = 190
    #expect(abs(r.width - 190 * 16 / 9) < 0.001)               // width follows the height
}

// MARK: - Move, nudge, typed size, ratio change

@Test func moveNudgeAndTypedSizesStayInsideTheBounds() {
    var s = drawn(Point(x: 100, y: 100), Point(x: 300, y: 200))
    s.dragBegan(at: Point(x: 200, y: 150))
    s.dragEnded(at: Point(x: 1100, y: 150))          // dragged off the right edge
    #expect(s.rect == Rect(x: 800, y: 100, width: 200, height: 100))

    s.nudge(dx: -10, dy: 5)
    #expect(s.rect == Rect(x: 790, y: 105, width: 200, height: 100))
    s.nudge(dx: 0, dy: -999)
    #expect(s.rect?.minY == 0)

    s.setWidth(500)                                  // only 210 fit from x = 790
    #expect(s.rect == Rect(x: 790, y: 0, width: 210, height: 100))
    s.setHeight(3)                                   // below the minimum
    #expect(s.rect?.height == EditableSelection.minimumSide)
}

@Test func typedSizesAndShiftArrowsFollowTheRatioLock() {
    var s = drawn(Point(x: 0, y: 0), Point(x: 160, y: 90), ratio: .r16x9)
    s.setWidth(320)
    #expect(s.rect == Rect(x: 0, y: 0, width: 320, height: 180))
    s.setHeight(45)
    #expect(s.rect == Rect(x: 0, y: 0, width: 80, height: 45))
    s.resize(dw: 80, dh: 0)
    #expect(s.rect == Rect(x: 0, y: 0, width: 160, height: 90))
    s.resize(dw: 0, dh: 90)                          // ⇧↓ drives the height under a lock
    #expect(s.rect == Rect(x: 0, y: 0, width: 320, height: 180))
}

@Test func changingTheRatioRefitsFromTheTopLeftAndShrinksToFit() {
    var s = drawn(Point(x: 0, y: 700), Point(x: 400, y: 800))   // 400×100 at the bottom
    s.setRatio(.r1x1)
    #expect(s.ratio == .r1x1)
    #expect(s.rect == Rect(x: 0, y: 700, width: 100, height: 100))   // only 100 of height left
    s.setRatio(.freeform)
    #expect(s.rect == Rect(x: 0, y: 700, width: 100, height: 100))   // freeform keeps it as is
}

// MARK: - Snap and remembered rects

@Test func snappingToAWindowReplacesTheSelectionClippedToTheBounds() {
    var s = drawn(Point(x: 0, y: 0), Point(x: 50, y: 50))
    s.snap(to: Rect(x: 900, y: 700, width: 300, height: 300))
    #expect(s.rect == Rect(x: 900, y: 700, width: 100, height: 100))
}

@Test func aRememberedRectIsKeptOnlyIfItStillFits() {
    #expect(EditableSelection(bounds: bounds, rect: Rect(x: 10, y: 10, width: 100, height: 50)).rect
            == Rect(x: 10, y: 10, width: 100, height: 50))
    #expect(EditableSelection(bounds: bounds, rect: Rect(x: 2000, y: 2000, width: 100, height: 50)).rect == nil)
    // Partly off-screen is clipped to what still fits; too little left is discarded.
    #expect(EditableSelection(bounds: bounds, rect: Rect(x: 900, y: 700, width: 300, height: 300)).rect
            == Rect(x: 900, y: 700, width: 100, height: 100))
    #expect(EditableSelection(bounds: bounds, rect: Rect(x: 998, y: 798, width: 100, height: 50)).rect == nil)
}
