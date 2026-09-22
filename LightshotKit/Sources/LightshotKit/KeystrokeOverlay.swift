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

/// Turns the key-event stream into what the keystroke pill shows (stories 30–31; LIG-45). Pure, so
/// the display rules — one pill per burst of typing, how presses join it, mode filtering, repeat
/// counting, hold-then-fade, held modifiers, and the secure-input blackout — are tested without a
/// tap; the app's compositor draws `items(at:)`.
///
/// Keys typed continuously share one pill until the typing stops for `holdDuration` (the debounce);
/// the pill then fades, and the next key starts a new one. A key pressed while it is still fading
/// joins it and brings it back. Inside the pill, plain typing runs together (`HELLO`) while chords
/// and named keys stand apart (`⇧⌘F ⌘S`).
///
/// Secure input (story 31) is the safety rule: while it is on, every key is dropped and anything
/// still on screen is cleared, so a password field's keystrokes cannot reach the file even if the
/// OS delivered them. It resumes only when the flag turns off again.
public struct KeystrokeOverlayModel: Equatable, Sendable {
    /// How long the pill stays fully visible after the last press — the debounce that ends a burst.
    public static let holdDuration: TimeInterval = 1.5
    public static let fadeDuration: TimeInterval = 0.35
    /// How long the press bump lasts.
    public static let bumpDuration: TimeInterval = 0.15
    public static let bumpScale: Double = 1.12
    /// The longest text a pill shows; a longer burst keeps its newest characters behind a `…`.
    public static let maxCharacters = 28

    public let settings: KeystrokeOverlaySettings
    public private(set) var secureInput = false
    public private(set) var heldModifiers: KeyModifiers = []
    private var burst: Burst?

    /// The keys of one burst of typing, and when it was last pressed / last bumped.
    private struct Burst: Equatable, Sendable {
        var tokens: [Token]
        var lastTime: TimeInterval
        var bumpTime: TimeInterval
    }

    /// Plain typing (`HELLO`), or one chord / named key, which counts its repeats (`⌘Z ×3`).
    private struct Token: Equatable, Sendable {
        var text: String
        var isTyping: Bool
        var count = 1

        var display: String { count > 1 ? "\(text) ×\(count)" : text }
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
        if let current = burst, time - current.lastTime >= Self.holdDuration + Self.fadeDuration { burst = nil }
        // A held key auto-repeats: it keeps the pill alive, but it is one press.
        if press.isRepeat, burst != nil {
            burst?.lastTime = time
            return
        }
        var current = burst ?? Burst(tokens: [], lastTime: time, bumpTime: time)
        if let typed = Self.typedCharacter(press) {
            if let last = current.tokens.indices.last, current.tokens[last].isTyping {
                current.tokens[last].text += typed
            } else {
                current.tokens.append(Token(text: typed, isTyping: true))
            }
        } else if let last = current.tokens.indices.last, !current.tokens[last].isTyping, current.tokens[last].text == press.text {
            current.tokens[last].count += 1
        } else {
            current.tokens.append(Token(text: press.text, isTyping: false))
        }
        current.lastTime = time
        current.bumpTime = time
        burst = current
    }

    /// What a press adds to running text, or nil when it is a chord or a named key of its own.
    /// Shift alone is still typing; Space shows as `␣` so the gap is visible.
    private static func typedCharacter(_ press: KeyPress) -> String? {
        guard press.modifiers.isEmpty || press.modifiers == .shift else { return nil }
        if press.label == "Space" { return "␣" }
        guard press.label.count == 1, !KeyLabel.isNamed(press.label) else { return nil }
        return press.label
    }

    public mutating func modifiersChanged(_ modifiers: KeyModifiers) {
        heldModifiers = secureInput ? [] : modifiers
    }

    /// Story 31: on → drop everything and show nothing; off → resume, from empty.
    public mutating func setSecureInput(_ on: Bool) {
        secureInput = on
        if on {
            burst = nil
            heldModifiers = []
        }
    }

    /// Forget a burst that has finished fading by `time`.
    public mutating func prune(at time: TimeInterval) {
        if let current = burst, time - current.lastTime >= Self.holdDuration + Self.fadeDuration { burst = nil }
    }

    /// The pill to draw at `time`, then the held modifiers as their own pill while nothing fresh is
    /// showing. Empty while secure input is on.
    public func items(at time: TimeInterval) -> [KeystrokeItem] {
        guard !secureInput else { return [] }
        var result: [KeystrokeItem] = []
        var fresh = false
        if let burst, time >= burst.lastTime {
            let age = time - burst.lastTime
            let opacity = age < Self.holdDuration ? 1 : max(0, 1 - (age - Self.holdDuration) / Self.fadeDuration)
            if opacity > 0 {
                let sinceBump = time - burst.bumpTime
                let scale = sinceBump < Self.bumpDuration ? 1 + (Self.bumpScale - 1) * (1 - sinceBump / Self.bumpDuration) : 1
                result.append(KeystrokeItem(text: Self.clipped(burst.tokens.map(\.display).joined(separator: " ")), opacity: opacity, scale: scale))
            }
            fresh = age < Self.holdDuration
        }
        if !heldModifiers.isEmpty, !fresh {
            result.append(KeystrokeItem(text: heldModifiers.glyphs, opacity: 1, scale: 1))
        }
        return result
    }

    /// The newest `maxCharacters` of `text`, behind a `…` when it had to be cut.
    private static func clipped(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        return "…" + text.suffix(maxCharacters - 1)
    }
}

/// Turns a macOS virtual key code (plus the characters it types unmodified) into the label the
/// keystroke pill prints (story 30): named keys get their standard glyph, everything else the
/// upper-cased character. Pure so the mapping is testable without an event.
public enum KeyLabel {
    private static let named: [Int: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "⎋", 71: "⌧",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
        114: "?⃝",
    ]

    /// Whether `label` is one of the named-key glyphs (`↩`, `⌫`, `←`, `F1` …) rather than a
    /// character the key types.
    public static func isNamed(_ label: String) -> Bool {
        namedLabels.contains(label)
    }

    private static let namedLabels = Set(named.values)

    /// `nil` when the key prints nothing worth showing (a dead key, a bare modifier).
    public static func label(keyCode: Int, characters: String?) -> String? {
        if let name = named[keyCode] { return name }
        guard let characters, let first = characters.unicodeScalars.first else { return nil }
        // Control characters and private-use glyphs come from keys the table should have named;
        // never print them as-is.
        guard first.value >= 0x20, !(0xF700...0xF8FF).contains(first.value) else { return nil }
        return String(first).uppercased()
    }
}
