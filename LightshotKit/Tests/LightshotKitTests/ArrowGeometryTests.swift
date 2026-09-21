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

    @Test func anUnbentCurvedArrowIsTheStandardArrow() {
        let standard = points(arrowShape(from: tail, to: tip, bend: nil, style: .standard, lineWidth: 6))
        for bend in [nil, arrowMidpoint(tail, tip)] {
            let curved = points(arrowShape(from: tail, to: tip, bend: bend, style: .curved, lineWidth: 6))
            // Every corner of the standard outline is a corner of the curved one…
            for corner in standard {
                #expect(curved.contains { $0.distance(to: corner) < 0.001 })
            }
            // …and the extra points along its shaft lie on the standard arrow's straight edges.
            let (tailHalf, neck) = (standard[0].y, standard[1])
            for point in curved where point.x < neck.x - 0.001 {
                let edge = tailHalf + (neck.y - tailHalf) * (point.x - standard[0].x) / (neck.x - standard[0].x)
                #expect(abs(abs(point.y) - edge) < 0.001)
            }
        }
    }

    @Test func aNewBendableArrowStartsStraight() {
        #expect(defaultArrowBend(from: tail, to: tip) == arrowMidpoint(tail, tip))
    }

    @Test func curvedHeadFollowsTheShaftsTangentAtTheTip() {
        /// The head's two barbs: the outline points either side of the tip.
        func barbs(_ outline: [Point]) -> (Point, Point) {
            let i = outline.indices.min { outline[$0].distance(to: tip) < outline[$1].distance(to: tip) }!
            return (outline[i - 1], outline[i + 1])
        }
        let straight = barbs(points(arrowShape(from: tail, to: tip, bend: nil, style: .curved, lineWidth: 6)))
        let bent = barbs(points(arrowShape(from: tail, to: tip, bend: Point(x: 100, y: -60), style: .curved, lineWidth: 6)))
        // Straight: the barbs mirror each other across the shaft. Bent upward: the shaft
        // arrives at the tip heading downward, so the whole head rotates with it.
        #expect(abs(straight.0.y + straight.1.y) < 0.001)
        #expect(abs(bent.0.y + bent.1.y) > 1)
        // Either way both barbs are the same distance from the tip.
        #expect(abs(bent.0.distance(to: tip) - bent.1.distance(to: tip)) < 0.001)
    }

    @Test func aBentCurvedArrowStillWidensFromTailToHead() {
        let bend = Point(x: 100, y: -60)
        let outline = points(arrowShape(from: tail, to: tip, bend: bend, style: .curved, lineWidth: 6))
        // The outline runs up one edge of the shaft, round the head, and back down the other,
        // so points equally far from either end face each other across the shaft.
        func width(_ i: Int) -> Double { outline[i].distance(to: outline[outline.count - 1 - i]) }
        let neck = outline.count / 2 - 2
        #expect(width(0) < width(neck / 2))
        #expect(width(neck / 2) < width(neck))
        #expect(width(neck) < width(neck + 1))
        // …and the shaft follows the curve: its middle sits up by the bend, off the chord.
        #expect(outline[neck / 2].y < -30)
    }

    @Test func doubleStyleCarriesTheStandardHeadAtBothEnds() {
        let standard = points(arrowShape(from: tail, to: tip, bend: nil, style: .standard, lineWidth: 6))
        let double = points(arrowShape(from: tail, to: tip, bend: nil, style: .double, lineWidth: 6))
        // The tip end is the standard arrow's head: its neck, both barbs, and the tip…
        for corner in standard[1...5] {
            #expect(double.contains { $0.distance(to: corner) < 0.001 })
        }
        // …and the tail end is that same head mirrored about the arrow's middle.
        for corner in standard[1...5] {
            let mirrored = Point(x: tail.x + tip.x - corner.x, y: corner.y)
            #expect(double.contains { $0.distance(to: mirrored) < 0.001 })
        }
    }

    @Test func aShortDoubleArrowsHeadsNeverMeet() {
        let shortTip = Point(x: 10, y: 0)
        let outline = points(arrowShape(from: tail, to: shortTip, bend: nil, style: .double, lineWidth: 12))
        #expect(outline.allSatisfy { $0.x >= -0.001 && $0.x <= 10.001 })
        // Each head stays on its own half.
        let barbs = outline.filter { abs($0.y) > 1.5 }.map(\.x)
        #expect(barbs.contains { $0 < 5 } && barbs.contains { $0 > 5 })
        #expect(!barbs.contains { abs($0 - 5) < 0.5 })
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
