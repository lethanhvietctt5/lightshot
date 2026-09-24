import Testing
@testable import LightshotKit

// OCR Text (spec 0010): turning recognised lines into the plain text that lands on the clipboard.
// Inputs are hand-built lines with image-space boxes, so nothing here touches Vision or a screen.

/// A recognised line whose single word spans its whole text and `box`.
private func line(_ text: String, x: Double = 0, y: Double, width: Double = 100, height: Double = 20) -> RecognizedLine {
    RecognizedLine(
        text: text,
        words: [RecognizedWord(range: 0..<text.utf16.count, box: Rect(x: x, y: y, width: width, height: height))]
    )
}

@Test func linesGivenOutOfOrderComeBackTopToBottom() {
    let text = TextCapture.plainText(from: [
        line("third", y: 100),
        line("first", y: 0),
        line("second", y: 50),
    ])
    #expect(text == "first\nsecond\nthird")
}

@Test func linesSharingARowJoinWithASpaceLeftToRight() {
    let text = TextCapture.plainText(from: [
        line("Enabled", x: 400, y: 10),
        line("Notifications", x: 20, y: 10),
        line("Sounds", x: 20, y: 60),
    ])
    #expect(text == "Notifications Enabled\nSounds")
}

@Test func slightlySkewedLinesOverlappingByHalfShareARow() {
    // 20 px tall; the right one sits 10 px lower, overlapping exactly half.
    let text = TextCapture.plainText(from: [
        line("left", x: 0, y: 0),
        line("right", x: 200, y: 10),
    ])
    #expect(text == "left right")
}

@Test func linesOverlappingByLessThanHalfAreSeparateRows() {
    let text = TextCapture.plainText(from: [
        line("right", x: 200, y: 11),
        line("left", x: 0, y: 0),
    ])
    #expect(text == "left\nright")
}

@Test func theResultIsTrimmedAndEmptyInputIsEmpty() {
    #expect(TextCapture.plainText(from: []) == "")
    #expect(TextCapture.plainText(from: [line("   ", y: 0), line("\t", y: 40)]) == "")
    #expect(TextCapture.plainText(from: [line("  hello ", y: 0), line(" ", y: 40)]) == "hello")
}

@Test func eachLineKeepsItsRecognisedText() {
    let text = TextCapture.plainText(from: [line("let x = 1  // note", y: 0)])
    #expect(text == "let x = 1  // note")
}
