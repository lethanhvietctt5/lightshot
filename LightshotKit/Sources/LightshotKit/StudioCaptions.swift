import Foundation

/// One recognised word at its **source** time (spec 0007, round 2, story 29).
public struct TranscriptWord: Equatable, Codable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// What on-device speech recognition heard in a take (`transcript.json` beside the project): an
/// analysis of the recording, not an edit — captions and cuts are made from it.
public struct StudioTranscript: Equatable, Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var locale: String
    public var words: [TranscriptWord]

    public init(locale: String, words: [TranscriptWord]) {
        version = Self.currentVersion
        self.locale = locale
        self.words = words
    }
}

/// One caption line on screen from `start` to `end` (source seconds).
public struct CaptionLine: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: UUID = UUID(), start: Double, end: Double, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum CaptionPosition: String, CaseIterable, Codable, Sendable {
    case bottom, top

    public var title: String { rawValue.capitalized }
}

public enum CaptionSize: String, CaseIterable, Codable, Sendable {
    case small, medium, large

    public var title: String { rawValue.capitalized }

    /// Text height as a fraction of the screen card's height.
    public var fraction: Double {
        switch self {
        case .small: return 0.04
        case .medium: return 0.052
        case .large: return 0.068
        }
    }
}

/// How captions look (story 29).
public struct CaptionStyle: Equatable, Codable, Sendable {
    public var size: CaptionSize
    public var position: CaptionPosition
    public var textColor: RGBAColor
    /// A rounded dark box behind the line.
    public var backdrop: Bool

    public init(size: CaptionSize = .medium, position: CaptionPosition = .bottom,
                textColor: RGBAColor = RGBAColor(red: 1, green: 1, blue: 1), backdrop: Bool = true) {
        self.size = size
        self.position = position
        self.textColor = textColor
        self.backdrop = backdrop
    }
}

/// The captions burned into the video (stories 29–30).
public struct StudioCaptions: Equatable, Codable, Sendable {
    public var visible: Bool
    public var lines: [CaptionLine]
    public var style: CaptionStyle

    public init(visible: Bool = true, lines: [CaptionLine] = [], style: CaptionStyle = CaptionStyle()) {
        self.visible = visible
        self.lines = lines
        self.style = style
    }

    /// The line on screen at a source time.
    public func line(at time: Double) -> CaptionLine? {
        lines.first { time >= $0.start && time < $0.end }
    }
}

/// Groups recognised words into caption lines (story 29): a new line after a pause, after
/// sentence punctuation, or before the line would pass `maxCharacters`.
public enum CaptionBuilder {
    public static let defaultMaxCharacters = 42
    public static let defaultMaxPause = 0.6

    public static func lines(from words: [TranscriptWord], maxCharacters: Int = defaultMaxCharacters, maxPause: Double = defaultMaxPause) -> [CaptionLine] {
        var lines: [CaptionLine] = []
        var current: [TranscriptWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            lines.append(CaptionLine(start: first.start, end: last.end, text: current.map(\.text).joined(separator: " ")))
            current.removeAll()
        }
        for word in words.sorted(by: { $0.start < $1.start }) {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = current.last {
                let length = current.map(\.text.count).reduce(0, +) + current.count + text.count
                let endsSentence = last.text.last.map { ".!?".contains($0) } ?? false
                if word.start - last.end > maxPause || endsSentence || length > maxCharacters { flush() }
            }
            current.append(TranscriptWord(text: text, start: word.start, end: word.end))
        }
        flush()
        return lines
    }
}

/// A text annotation on the video (spec 0007, round 2, story 32): a title card or callout shown
/// from `start` to `end` (source seconds), centred at `center` (normalised to the screen card).
public struct TextAnnotation: Equatable, Codable, Sendable, Identifiable {
    public static let defaultLength = 3.0
    public static let minimumLength = 0.2

    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String
    public var center: Point
    /// Text height as a fraction of the screen card's height.
    public var size: Double
    public var textColor: RGBAColor
    public var background: RGBAColor
    /// Seconds to fade in and out.
    public var fade: Double

    public init(
        id: UUID = UUID(), start: Double, end: Double, text: String = "Title", center: Point = Point(x: 0.5, y: 0.2),
        size: Double = 0.07, textColor: RGBAColor = RGBAColor(red: 1, green: 1, blue: 1),
        background: RGBAColor = RGBAColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 0.85), fade: Double = 0.3
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.center = center
        self.size = size
        self.textColor = textColor
        self.background = background
        self.fade = fade
    }

    /// Opacity at a source time: fades in and out over `fade`, `0` outside the range.
    public func opacity(at time: Double) -> Double {
        guard time >= start, time < end else { return 0 }
        guard fade > 0 else { return 1 }
        return min(1, (time - start) / fade, (end - time) / fade)
    }
}
