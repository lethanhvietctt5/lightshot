import Foundation

/// Which presses the keystroke pill shows (spec 0006, story 30).
public enum KeystrokeDisplayMode: String, CaseIterable, Codable, Sendable {
    case allKeys
    case commandOnly

    public var title: String {
        switch self {
        case .allKeys: return "All keys"
        case .commandOnly: return "Only command keys"
        }
    }
}

/// Where the pill sits in the frame: top / bottom × left / centre / right.
public enum KeystrokeOverlayPosition: String, CaseIterable, Codable, Sendable {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight

    public var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topCenter: return "Top Center"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomRight: return "Bottom Right"
        }
    }

    public var isTop: Bool { self == .topLeft || self == .topCenter || self == .topRight }

    /// Where a pill group of `size` goes inside a `frame` of the given size, `margin` from the
    /// edges — the pure half of the layout; the app measures the text.
    public func rect(for size: Size, in frame: Size, margin: Double) -> Rect {
        let x: Double
        switch self {
        case .topLeft, .bottomLeft: x = margin
        case .topCenter, .bottomCenter: x = (frame.width - size.width) / 2
        case .topRight, .bottomRight: x = frame.width - margin - size.width
        }
        let y = isTop ? margin : frame.height - margin - size.height
        return Rect(x: x, y: y, width: size.width, height: size.height)
    }
}

public enum KeystrokeOverlaySize: String, CaseIterable, Codable, Sendable {
    case small, medium, large

    /// The pill's font size in screen points; padding and corner radius follow it.
    public var fontSize: Double {
        switch self {
        case .small: return 16
        case .medium: return 22
        case .large: return 30
        }
    }

    public var title: String { rawValue.capitalized }
}

public enum KeystrokeOverlayAppearance: String, CaseIterable, Codable, Sendable {
    case light, dark, system

    public var title: String { rawValue.capitalized }
}

/// The user's keystroke-overlay preferences (story 30), carried into `RecordingOptions`.
public struct KeystrokeOverlaySettings: Equatable, Codable, Sendable {
    public var mode: KeystrokeDisplayMode
    public var position: KeystrokeOverlayPosition
    public var size: KeystrokeOverlaySize
    public var appearance: KeystrokeOverlayAppearance
    /// Blur the frame behind the pill instead of a flat tint.
    public var blurBackground: Bool

    public init(
        mode: KeystrokeDisplayMode = .allKeys, position: KeystrokeOverlayPosition = .bottomCenter,
        size: KeystrokeOverlaySize = .medium, appearance: KeystrokeOverlayAppearance = .system,
        blurBackground: Bool = true
    ) {
        self.mode = mode
        self.position = position
        self.size = size
        self.appearance = appearance
        self.blurBackground = blurBackground
    }

    public static let standard = KeystrokeOverlaySettings()
}

/// One pill to draw, left to right.
public struct KeystrokeItem: Equatable, Sendable {
    public let text: String
    /// `0...1`; entries fade after their hold time.
    public let opacity: Double
    /// A brief bump above `1` right after a press, so repeats are visible (story 30).
    public let scale: Double

    public init(text: String, opacity: Double, scale: Double) {
        self.text = text
        self.opacity = opacity
        self.scale = scale
    }
}

/// Turns the key-event stream into what the keystroke pill shows (stories 30–31). Pure, so the
/// display rules — mode filtering, repeat counting, hold-then-fade, held modifiers, and the
/// secure-input blackout — are tested without a tap; the app's compositor draws `items(at:)`.
///
/// Secure input (story 31) is the safety rule: while it is on, every key is dropped and anything
/// still on screen is cleared, so a password field's keystrokes cannot reach the file even if the
/// OS delivered them. It resumes only when the flag turns off again.
public struct KeystrokeOverlayModel: Equatable, Sendable {
    /// How long a press stays fully visible before fading.
    public static let holdDuration: TimeInterval = 1.5
    public static let fadeDuration: TimeInterval = 0.35
    /// A same-chord press within this window counts as a repeat (`×n`) instead of a new pill.
    public static let repeatWindow: TimeInterval = 1.0
    /// How long the press bump lasts.
    public static let bumpDuration: TimeInterval = 0.15
    public static let bumpScale: Double = 1.12
    /// At most this many pills at once; the oldest goes first.
    public static let maxEntries = 3

    public let settings: KeystrokeOverlaySettings
    public private(set) var secureInput = false
    public private(set) var heldModifiers: KeyModifiers = []
    private var entries: [Entry] = []

    private struct Entry: Equatable, Sendable {
        let text: String
        var lastTime: TimeInterval
        var count: Int
    }

    public init(settings: KeystrokeOverlaySettings) {
        self.settings = settings
    }

    public mutating func handle(_ event: KeyEvent, at time: TimeInterval) {
        switch event {
        case let .keyDown(press): keyDown(press, at: time)
        case let .modifiersChanged(modifiers): modifiersChanged(modifiers)
        case let .secureInput(on): setSecureInput(on)
        }
    }

    public mutating func keyDown(_ press: KeyPress, at time: TimeInterval) {
        guard !secureInput else { return }
        if settings.mode == .commandOnly, !press.modifiers.isCommandChord { return }
        let text = press.text
        if let last = entries.indices.last, entries[last].text == text,
           time - entries[last].lastTime < Self.repeatWindow {
            entries[last].count += 1
            entries[last].lastTime = time
            return
        }
        entries.append(Entry(text: text, lastTime: time, count: 1))
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    public mutating func modifiersChanged(_ modifiers: KeyModifiers) {
        heldModifiers = secureInput ? [] : modifiers
    }

    /// Story 31: on → drop everything and show nothing; off → resume, from empty.
    public mutating func setSecureInput(_ on: Bool) {
        secureInput = on
        if on {
            entries = []
            heldModifiers = []
        }
    }

    /// Forget entries that have finished fading by `time`.
    public mutating func prune(at time: TimeInterval) {
        entries.removeAll { time - $0.lastTime >= Self.holdDuration + Self.fadeDuration }
    }

    /// The pills to draw at `time`, oldest first; held modifiers trail as their own pill while
    /// nothing fresh is showing. Empty while secure input is on.
    public func items(at time: TimeInterval) -> [KeystrokeItem] {
        guard !secureInput else { return [] }
        var result: [KeystrokeItem] = []
        for entry in entries {
            let age = time - entry.lastTime
            guard age >= 0 else { continue }
            let opacity = age < Self.holdDuration
                ? 1 : max(0, 1 - (age - Self.holdDuration) / Self.fadeDuration)
            guard opacity > 0 else { continue }
            let scale = age < Self.bumpDuration ? 1 + (Self.bumpScale - 1) * (1 - age / Self.bumpDuration) : 1
            let text = entry.count > 1 ? "\(entry.text) ×\(entry.count)" : entry.text
            result.append(KeystrokeItem(text: text, opacity: opacity, scale: scale))
        }
        let somethingFresh = entries.contains { time - $0.lastTime < Self.holdDuration }
        if !heldModifiers.isEmpty, !somethingFresh {
            result.append(KeystrokeItem(text: heldModifiers.glyphs, opacity: 1, scale: 1))
        }
        return result
    }
}
