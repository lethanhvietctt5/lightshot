import Testing
import Foundation
@testable import LightshotKit

// A label's box (LIG-47): padding, natural width while typing, wrapping at a hand-set width,
// side handles set the width, the corner scales the text.

private func blank() -> AnnotationDocument {
    AnnotationDocument(baseImage: CapturedImage(pixelWidth: 400, pixelHeight: 300, data: Data()))
}

private func label(_ doc: inout AnnotationDocument, fontSize: Double = 20) -> ElementID {
    let box = TextLayout.box(for: "", fontSize: fontSize, origin: Point(x: 50, y: 40))
    return doc.add(AnnotationElement(kind: .text("", box: box), style: Style(fontSize: fontSize)))
}

private func box(_ doc: AnnotationDocument, _ id: ElementID) -> Rect {
    doc.element(id: id)!.kind.boundingBox
}

@Test func aNewLabelIsOneLineTallAndGrowsAsItIsTyped() {
    var doc = blank()
    let id = label(&doc)
    let empty = box(doc, id)
    let pad = TextLayout.padding(for: 20)
    #expect(empty.origin == Point(x: 50, y: 40))
    #expect(empty.width == TextLayout.minimumWidth(for: 20))
    #expect(empty.height > 20 && empty.height < 20 * 1.6 + 2 * pad)
    doc.updateText(id, to: "Campaign Start")
    let typed = box(doc, id)
    #expect(typed.width > empty.width)                         // grew with the text…
    #expect(typed.height == empty.height)                      // …on one line
    #expect(TextLayout.hasNaturalWidth(typed, string: "Campaign Start", fontSize: 20))
}

@Test func aSideHandleSetsTheWidthAndTheTextWraps() {
    var doc = blank()
    let id = label(&doc)
    doc.updateText(id, to: "Campaign Start")
    let natural = box(doc, id)
    doc.transform(id, by: .resize(handle: .right, dx: -natural.width / 2, dy: 0))
    let narrow = box(doc, id)
    #expect(narrow.minX == natural.minX)                       // the left edge stays put
    #expect(abs(narrow.width - natural.width / 2) < 0.001)
    #expect(narrow.height > natural.height)                    // wrapped onto a second line
    // Typing more keeps the hand-set width.
    doc.updateText(id, to: "Campaign Start!")
    #expect(abs(box(doc, id).width - narrow.width) < 0.001)
    // The left handle moves the left edge, the right one stays.
    doc.transform(id, by: .resize(handle: .left, dx: -20, dy: 0))
    #expect(box(doc, id).maxX == narrow.maxX && box(doc, id).minX == narrow.minX - 20)
    // Never narrower than the minimum.
    doc.transform(id, by: .resize(handle: .right, dx: -1_000, dy: 0))
    #expect(box(doc, id).width == TextLayout.minimumWidth(for: 20))
}

@Test func theCornerScalesTheTextAndOtherHandlesLeaveALabelAlone() {
    var doc = blank()
    let id = label(&doc)
    doc.updateText(id, to: "Hi")
    let before = box(doc, id)
    doc.transform(id, by: .resize(handle: .bottomRight, dx: before.width, dy: 0))   // twice as wide
    #expect(doc.element(id: id)!.style.fontSize == 40)
    let after = box(doc, id)
    #expect(after.origin == before.origin && after.height > before.height * 1.5)
    doc.transform(id, by: .resize(handle: .top, dx: 30, dy: 30))
    #expect(box(doc, id) == after)
}

@Test func aNewFontSizeRefitsTheBox() {
    var doc = blank()
    let id = label(&doc)
    doc.updateText(id, to: "Hello")
    let small = box(doc, id)
    var style = doc.element(id: id)!.style
    style.fontSize = 30
    doc.setStyle(id, style)
    let large = box(doc, id)
    #expect(large.width > small.width && large.height > small.height)
    #expect(TextLayout.hasNaturalWidth(large, string: "Hello", fontSize: 30))
}
