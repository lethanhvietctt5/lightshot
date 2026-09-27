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
    /// The recognised lines and QR codes / barcodes (spec 0012), in image pixel coordinates
    /// (top-left origin), or why recognition failed. Nothing readable is a success with no lines
    /// and no codes, not a failure.
    func recognizeText(in image: CapturedImage) async -> Result<TextRecognition, TextRecognitionError>
}

/// What one recognition pass found in a captured area: its lines of text and its codes.
public struct TextRecognition: Equatable, Sendable {
    public var lines: [RecognizedLine]
    public var codes: [RecognizedCode]

    public init(lines: [RecognizedLine] = [], codes: [RecognizedCode] = []) {
        self.lines = lines
        self.codes = codes
    }
}

/// A QR code or barcode decoded from a captured area (spec 0012). Only codes whose content is text
/// are reported; binary payloads never reach the core.
public struct RecognizedCode: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case qrCode
        case barcode
    }

    public var payload: String
    public var kind: Kind
    /// In image pixels, top-left origin.
    public var box: Rect

    public init(payload: String, kind: Kind, box: Rect) {
        self.payload = payload
        self.kind = kind
        self.box = box
    }
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
    /// The content of the area's QR codes or barcodes is now on the clipboard (spec 0012); the kind
    /// is the first code's, in reading order.
    case codeCopied(String, RecognizedCode.Kind)
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
    ///
    /// With `keepingLineBreaks` off (spec 0012) the rows are joined with a space instead, into one
    /// paragraph.
    public static func plainText(from lines: [RecognizedLine], keepingLineBreaks: Bool = true) -> String {
        let placed = lines.compactMap { line in line.box.map { (text: line.text, box: $0) } }
        return readingOrder(placed, box: \.box)
            .map { row in row.map(\.text).joined(separator: " ") }
            .joined(separator: keepingLineBreaks ? "\n" : " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The content of the area's codes (spec 0012), one per line in the same reading order as text.
    /// Blank payloads and exact repeats of an earlier one are dropped; the rest are copied as
    /// decoded, untrimmed, so a multi-line payload keeps its lines. `""` when nothing is left.
    public static func codeText(from codes: [RecognizedCode]) -> String {
        var seen = Set<String>()
        return readable(codes)
            .filter { seen.insert($0.payload).inserted }
            .map(\.payload)
            .joined(separator: "\n")
    }

    /// The kind of the first code `codeText` copies, for the notice's wording; `nil` when it copies
    /// nothing.
    public static func firstCodeKind(in codes: [RecognizedCode]) -> RecognizedCode.Kind? {
        readable(codes).first?.kind
    }

    private static func readable(_ codes: [RecognizedCode]) -> [RecognizedCode] {
        readingOrder(codes.filter { !$0.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, box: \.box)
            .flatMap { $0 }
    }

    /// Items grouped into rows top to bottom, each row left to right. Each row is anchored on its
    /// first (topmost) item, so a run of slightly skewed lines can't chain into one another down
    /// the page.
    private static func readingOrder<Item>(_ items: [Item], box: (Item) -> Rect) -> [[Item]] {
        var rows: [(anchor: Rect, items: [Item])] = []
        for item in items.sorted(by: { box($0).minY < box($1).minY }) {
            if let last = rows.indices.last, sharesRow(box(item), rows[last].anchor) {
                rows[last].items.append(item)
            } else {
                rows.append((box(item), [item]))
            }
        }
        return rows.map { row in row.items.sorted { box($0).minX < box($1).minX } }
    }

    private static func sharesRow(_ a: Rect, _ b: Rect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap >= 0.5 * min(a.height, b.height)
    }
}
