import Testing
import Foundation
@testable import LightshotKit

// Shape facts for the four arrow styles. These assert properties a person would name when
// describing the arrow (it tapers, the head follows the curve, both ends are headed) —
// never the exact outline — so the constants stay free to be tuned by eye.

private func points(_ shape: ArrowShape) -> [Point] {
    shape.path.compactMap { element in
        switch element {
        case let .move(p), let .line(p): return p
        case let .quadCurve(to, _): return to
        case .close: return nil
        }
    }
}

private let tail = Point(x: 0, y: 0)
private let tip = Point(x: 200, y: 0)

@Suite struct ArrowGeometryTests {
    @Test(arguments: [ArrowStyle.standard, .fancy])
    func taperedStylesWidenFromTailToHead(style: ArrowStyle) {
        let outline = points(arrowShape(from: tail, to: tip, bend: nil, style: style, lineWidth: 6))
        // The outline runs tail → neck → barb → tip and back; the two tail points are its ends.
        let tailWidth = outline.first!.distance(to: outline.last!)
        let neckWidth = outline[1].distance(to: outline[outline.count - 2])
        let headWidth = outline[2].distance(to: outline[4])
        #expect(tailWidth < neckWidth)
        #expect(neckWidth < headWidth)
    }

    @Test func fancyHeadSweepsItsBarbsBackPastTheNeck() {
        let outline = points(arrowShape(from: tail, to: tip, bend: nil, style: .fancy, lineWidth: 6))
        // Barbs sit further from the tip than the notch where the shaft joins the head.
        #expect(outline[2].distance(to: tip) > outline[1].distance(to: tip))
        #expect(outline.contains(tip))
    }

    @Test func aShortArrowShrinksItsHeadInsteadOfOvershootingTheTail() {
        let shortTip = Point(x: 10, y: 0)
        let outline = points(arrowShape(from: tail, to: shortTip, bend: nil, style: .standard, lineWidth: 12))
        #expect(outline.allSatisfy { $0.x >= -0.001 && $0.x <= 10.001 })
    }

    @Test func curvedHeadFollowsTheShaftsTangentAtTheTip() {
        let straight = points(arrowShape(from: tail, to: tip, bend: nil, style: .curved, lineWidth: 6))
        let bent = points(arrowShape(from: tail, to: tip, bend: Point(x: 100, y: -60), style: .curved, lineWidth: 6))
        // Straight: the head's arms mirror each other across the shaft. Bent upward: the
        // shaft arrives at the tip heading downward, so the whole head rotates with it.
        #expect(abs(straight[2].y + straight[4].y) < 0.001)
        #expect(abs(bent[2].y + bent[4].y) > 1)
        // Either way both arms are the same length.
        #expect(abs(bent[2].distance(to: tip) - bent[4].distance(to: tip)) < 0.001)
    }

    @Test func doubleStyleHeadsBothEnds() {
        func heads(_ style: ArrowStyle) -> Int {
            arrowShape(from: tail, to: tip, bend: nil, style: style, lineWidth: 6)
                .path.filter { if case .move = $0 { return true } else { return false } }.count - 1
        }
        #expect(heads(.curved) == 1)
        #expect(heads(.double) == 2)
    }

    @Test func zeroLengthArrowHasNoOutline() {
        #expect(arrowShape(from: tail, to: tail, bend: nil, style: .standard, lineWidth: 6).path.isEmpty)
    }

    @Test(arguments: ArrowStyle.allCases)
    func scalingTheInputsScalesTheOutline(style: ArrowStyle) {
        // The canvas draws in view space and the export in image space; the two agree only
        // if the shape is purely proportional to its inputs.
        let bend: Point? = style.isBendable ? Point(x: 100, y: -40) : nil
        let one = points(arrowShape(from: tail, to: tip, bend: bend, style: style, lineWidth: 6))
        let two = points(arrowShape(
            from: tail, to: Point(x: 400, y: 0), bend: bend.map { Point(x: $0.x * 2, y: $0.y * 2) },
            style: style, lineWidth: 12
        ))
        #expect(one.count == two.count)
        for (a, b) in zip(one, two) {
            #expect(abs(a.x * 2 - b.x) < 0.001 && abs(a.y * 2 - b.y) < 0.001)
        }
    }

    @Test func centerlinePassesThroughTheBend() {
        let bend = Point(x: 100, y: -60)
        let line = arrowCenterline(from: tail, to: tip, bend: bend)
        #expect(line.first == tail && line.last == tip)
        #expect(line.contains { $0.distance(to: bend) < 0.001 })
    }
}
