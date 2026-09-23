import Testing
import Foundation
@testable import LightshotKit

// Captions and transcript editing (spec 0007, round 2, stories 29–31): words grouped into caption
// lines, speech cut by deleting words, silences removed, older projects still loading.

private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
    TranscriptWord(text: text, start: start, end: end)
}

private func document(_ duration: Double = 20) -> StudioDocument {
    StudioDocument(edits: StudioEdits(sourceDuration: duration, look: .studio))
}

private func spans(_ doc: StudioDocument) -> [[Double]] {
    doc.edits.clips.map { [($0.start * 100).rounded() / 100, ($0.end * 100).rounded() / 100] }
}

// MARK: - CaptionBuilder

@Test func wordsBecomeLinesAtPausesAndSentenceEnds() {
    let words = [
        word("Open", 0, 0.3), word("the", 0.35, 0.5), word("dashboard.", 0.55, 1.0),
        word("Then", 1.1, 1.3), word("click", 1.35, 1.6), word("export", 1.65, 2.0),
        word("now", 3.0, 3.3),                                         // after a 1 s pause
    ]
    let lines = CaptionBuilder.lines(from: words)
    #expect(lines.map(\.text) == ["Open the dashboard.", "Then click export", "now"])
    #expect(lines[0].start == 0 && lines[0].end == 1.0)
    #expect(lines[2].start == 3.0)
}

@Test func aLongRunOfWordsWrapsAtTheCharacterLimit() {
    let words = (0..<20).map { word("word\($0)", Double($0) * 0.3, Double($0) * 0.3 + 0.25) }
    let lines = CaptionBuilder.lines(from: words, maxCharacters: 30)
    #expect(lines.count > 1)
    #expect(lines.allSatisfy { $0.text.count <= 30 })
    #expect(lines.flatMap { $0.text.split(separator: " ") }.count == 20)
}

// MARK: - Cutting source ranges

@Test func cuttingInsideAClipSplitsIt() {
    var doc = document(10)
    doc.cut(sourceRange: 3...5)
    #expect(spans(doc) == [[0, 3], [5, 10]])
    #expect(doc.timeline.outputDuration == 8)
}

@Test func cuttingAcrossTrimsMergesThem() {
    var doc = document(10)
    doc.cut(sourceRange: 4...5)
    doc.cut(sourceRange: 6...6.5)                                       // [0,4] [5,6] [6.5,10]
    doc.cut(sourceRange: 3...7)
    #expect(spans(doc) == [[0, 3], [7, 10]])
    #expect(doc.edits.trims.map { [$0.start, $0.end] } == [[3, 7]])
}

@Test func aSliverLeftBetweenCutsIsCutToo() {
    var doc = document(10)
    doc.cut(sourceRange: 2...4)
    doc.cut(sourceRange: 4.05...6)
    #expect(spans(doc) == [[0, 2], [6, 10]])
}

@Test func cuttingEverythingIsRefused() {
    var doc = document(10)
    doc.cut(sourceRange: 0...10)
    #expect(spans(doc) == [[0, 10]])
    #expect(!doc.canUndo)
}

@Test func cuttingWordsRemovesTheirSpanAndIsOneUndoStep() {
    var doc = document(10)
    let words = [word("um", 2.0, 2.4), word("so", 2.5, 2.8)]
    doc.cut(words: words)
    #expect(spans(doc) == [[0, 2], [2.8, 10]])
    doc.undo()
    #expect(spans(doc) == [[0, 10]])
}

@Test func removingSilencesCutsLongGapsKeepingPadding() {
    var doc = document(12)
    let words = [word("one", 1, 1.5), word("two", 1.6, 2), word("three", 5, 5.5), word("four", 5.6, 6)]
    let cuts = doc.removeSilences(words: words, minimumGap: 1, padding: 0.2)
    // Leading 0–1 s, the 2–5 s pause, and the trailing 6–12 s go (with 0.2 s kept either side).
    #expect(cuts == 3)
    #expect(spans(doc) == [[0.8, 2.2], [4.8, 6.2]])
    doc.undo()
    #expect(spans(doc) == [[0, 12]])
}

@Test func shortPausesAreKept() {
    var doc = document(4)
    let words = [word("a", 0, 1), word("b", 1.5, 2.5), word("c", 3, 4)]
    #expect(doc.removeSilences(words: words, minimumGap: 1, padding: 0.1) == 0)
    #expect(!doc.canUndo)
}

// MARK: - Caption edits

@Test func captionTextIsEditableAndUndoable() {
    var doc = document(10)
    doc.set(\.captions.lines, CaptionBuilder.lines(from: [word("helo", 1, 1.5), word("world", 1.6, 2)]))
    let id = doc.edits.captions.lines[0].id
    doc.editCaption(id, text: "Hello world")
    #expect(doc.edits.captions.lines[0].text == "Hello world")
    doc.undo()
    #expect(doc.edits.captions.lines[0].text == "helo world")
}

@Test func theCaptionAtASourceTimeIsTheLineCoveringIt() {
    var captions = StudioCaptions()
    captions.lines = [CaptionLine(start: 1, end: 2, text: "a"), CaptionLine(start: 3, end: 4, text: "b")]
    #expect(captions.line(at: 1.5)?.text == "a")
    #expect(captions.line(at: 2.5) == nil)
    #expect(captions.line(at: 3.2)?.text == "b")
}

// MARK: - Persistence

@Test func aRoundOneProjectWithoutCaptionsOrAnnotationsStillLoads() throws {
    var edits = StudioEdits(sourceDuration: 8, look: .studio)
    edits.canvas.padding = 0.2
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edits)) as! [String: Any]
    json.removeValue(forKey: "captions")
    json.removeValue(forKey: "annotations")
    let decoded = try JSONDecoder().decode(StudioEdits.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.canvas.padding == 0.2)
    #expect(decoded.captions == StudioCaptions())
    #expect(decoded.annotations.isEmpty)
}

@Test func aTranscriptRoundTripsThroughJSON() throws {
    let transcript = StudioTranscript(locale: "en-US", words: [word("hi", 0, 0.4)])
    let decoded = try JSONDecoder().decode(StudioTranscript.self, from: JSONEncoder().encode(transcript))
    #expect(decoded == transcript)
}
