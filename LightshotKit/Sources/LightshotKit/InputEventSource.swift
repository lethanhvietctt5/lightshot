import Foundation

/// A pointer event the recorder's overlays react to (spec 0006, story 29).
public enum PointerEvent: Equatable, Sendable {
    /// The pointer is at `position` (screen points, top-left origin).
    case moved(Point)
    /// A mouse button went down at `position`.
    case down(Point)
}

/// The modifier keys held with a key press (story 30), in the order macOS prints them.
public struct KeyModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)

    /// The glyphs macOS menus use, in its canonical order: fn ⌃ ⌥ ⇧ ⌘.
    public var glyphs: String {
        var result = ""
        if contains(.function) { result += "fn" }
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }

    /// A "command key" chord in CleanShot's sense: one of ⌘ ⌃ ⌥ is held (⇧ alone is typing).
    public var isCommandChord: Bool { !isDisjoint(with: [.command, .control, .option]) }
}

/// One key going down, already resolved to what the overlay prints (story 30).
public struct KeyPress: Equatable, Sendable {
    /// The key's label: a letter, digit or symbol as typed without modifiers, or a glyph such as
    /// `↩`, `⎋`, `←` (see `KeyLabel`).
    public let label: String
    public let modifiers: KeyModifiers
    /// A key-repeat from holding the key, not a fresh press.
    public let isRepeat: Bool

    public init(label: String, modifiers: KeyModifiers = [], isRepeat: Bool = false) {
        self.label = label
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }

    /// What the pill shows for this press: the modifier glyphs then the key.
    public var text: String { modifiers.glyphs + label }
}

/// A keyboard event from the OS tap (story 30).
public enum KeyEvent: Equatable, Sendable {
    case keyDown(KeyPress)
    /// The held modifiers changed (a modifier went down or up) — `modifiers` is the full new set.
    case modifiersChanged(KeyModifiers)
    /// Secure event input turned on or off (story 31): on while a password field has focus.
    case secureInput(Bool)
}

/// Any input event the recorder's overlays consume.
public enum InputEvent: Equatable, Sendable {
    case pointer(PointerEvent)
    case key(KeyEvent)
}

/// The OS input seam (spec 0006, stories 29–31): streams input events while a take records. A
/// concrete source (app target) delivers one kind — the mouse through a global event monitor,
/// which needs no permission; the keyboard through a listen-only event tap behind Input
/// Monitoring — and the recorder runs one of each.
public protocol InputEventSource: Sendable {
    /// Start delivering events, from any thread, until `stop()`.
    func start(onEvent: @escaping @Sendable (InputEvent) -> Void)
    func stop()
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
        114: "?⃝", 57: "⇪",
    ]

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
