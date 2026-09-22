import Testing
@testable import LightshotKit

// Which style controls the editor's toolbar shows for an element kind (LIG-46).

@Test func eachKindShowsOnlyTheStyleItIsDrawnWith() {
    let a = Point(x: 0, y: 0), b = Point(x: 10, y: 10), box = Rect(x: 0, y: 0, width: 10, height: 10)
    #expect(StyleFields.fields(for: .arrow(from: a, to: b)) == [.color, .strokeWidth, .arrowStyle])
    #expect(StyleFields.fields(for: .line(from: a, to: b)) == [.color, .strokeWidth])
    #expect(StyleFields.fields(for: .rectangle(box)) == [.color, .strokeWidth])
    #expect(StyleFields.fields(for: .ellipse(box)) == [.color, .strokeWidth])
    #expect(StyleFields.fields(for: .freehand(points: [a, b])) == [.color, .strokeWidth])
    #expect(StyleFields.fields(for: .text("Hi", box: box)) == [.color, .fontSize])
    #expect(StyleFields.fields(for: .highlight(box)) == [.color])
    #expect(StyleFields.fields(for: .stepMarker(number: 1, center: a, radius: 12)) == [.color, .fontSize])
    #expect(StyleFields.fields(for: .redaction(box, style: .blackout)) == [.redaction])
}
