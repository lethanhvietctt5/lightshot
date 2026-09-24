import Foundation

// OCR Text (spec 0010): a selected screen area becomes plain text on the clipboard.
//
// Recognition is the OS's job — the app's Vision recogniser turns the captured image into
// `RecognizedLine`s (the same value type auto redact scans). Putting those lines back into
// reading order is pure and lives here; `AppCoordinator.captureText()` sequences the rest.

/// Reads the text in a captured image. The app implements it with Vision, on-device; tests use a
/// fake so the coordinator's routing runs without a screen.
@MainActor
public protocol TextRecognizer {
    /// The recognised lines, in image pixel coordinates (top-left origin), or why recognition failed.
    /// No text at all is a success with no lines, not a failure.
    func recognizeText(in image: CapturedImage) async -> Result<[RecognizedLine], TextRecognitionError>
}

/// Recognition itself failed — distinct from an area with nothing readable in it.
public struct TextRecognitionError: Error, Equatable, Sendable {
    /// User-facing, already localised.
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Where a text capture is, for the notice the app shows: `reading` while recognition runs (the
/// first run after launch can take many seconds while Vision loads its models), then how it ended.
public enum TextCaptureStatus: Equatable, Sendable {
    /// The area was captured and its text is being recognised.
    case reading
    /// This text is now on the clipboard.
    case copied(String)
    /// Nothing readable was found; the clipboard was left alone.
    case noText
    /// Recognition failed with this message; the clipboard was left alone.
    case failed(String)
}

public enum TextCapture {
    /// The recognised lines as plain text in reading order: rows top to bottom, one per output line;
    /// lines side by side on a row joined with a space, left to right. Two lines share a row when
    /// their vertical extents overlap by at least half the shorter one's height. The result is
    /// trimmed, so an area with only whitespace yields `""`. Lines without a box are dropped.
    public static func plainText(from lines: [RecognizedLine]) -> String {
        let placed = lines
            .compactMap { line in line.box.map { (text: line.text, box: $0) } }
            .sorted { $0.box.minY < $1.box.minY }

        // Each row is anchored on its first (topmost) line, so a run of slightly skewed lines
        // can't chain into one another down the page.
        var rows: [(anchor: Rect, lines: [(text: String, box: Rect)])] = []
        for line in placed {
            if let last = rows.indices.last, sharesRow(line.box, rows[last].anchor) {
                rows[last].lines.append(line)
            } else {
                rows.append((line.box, [line]))
            }
        }

        return rows
            .map { row in row.lines.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sharesRow(_ a: Rect, _ b: Rect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap >= 0.5 * min(a.height, b.height)
    }
}
