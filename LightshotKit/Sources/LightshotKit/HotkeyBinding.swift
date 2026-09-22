import Foundation

/// The modifier keys held for a global hotkey — an OS-agnostic value the app maps to Carbon/AppKit
/// flags at the edge, so the domain core never imports either framework.
public struct HotkeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = HotkeyModifiers(rawValue: 1 << 0)
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    public static let shift = HotkeyModifiers(rawValue: 1 << 2)
    public static let command = HotkeyModifiers(rawValue: 1 << 3)

    /// The modifier glyphs in the canonical macOS order (⌃⌥⇧⌘), e.g. `⇧⌘`.
    public var displayString: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

/// A single global-hotkey chord: a physical key plus its modifiers (story 56).
///
/// `keyCode` is the hardware virtual key code (the same numbering `NSEvent.keyCode` and Carbon's
/// `RegisterEventHotKey` use), which is what the app registers. `keyLabel` is the human-readable key
/// captured alongside it (`"4"`, `"Space"`, `"↩"`) so the settings UI can render the chord without a
/// keyCode→label table in the pure core.
public struct HotkeyBinding: Equatable, Hashable, Codable, Sendable {
    public var keyCode: UInt16
    public var modifiers: HotkeyModifiers
    public var keyLabel: String

    public init(keyCode: UInt16, modifiers: HotkeyModifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// The chord as displayed to the user, e.g. `⇧⌘4`.
    public var displayString: String { modifiers.displayString + displayKey }

    /// The key as the system writes it. A chord recorded before the recorder asked for the unshifted
    /// character stored Shift's symbol (`⇧⌘4` saved as `"$"`); on the US digit row that symbol is
    /// read back as its digit.
    private var displayKey: String {
        if modifiers.contains(.shift), let digit = Self.shiftedDigits[keyLabel] { return digit }
        return keyLabel.uppercased()
    }

    private static let shiftedDigits: [String: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    ]
}

/// Two-or-more actions that resolve to the same chord — the shape the settings UI surfaces so a
/// clash is shown, never silently letting one action shadow another (acceptance criterion 1).
public struct HotkeyConflict: Equatable, Sendable {
    /// The shared chord.
    public let binding: HotkeyBinding
    /// The actions competing for it, in declaration order.
    public let actions: [CaptureAction]

    public init(binding: HotkeyBinding, actions: [CaptureAction]) {
        self.binding = binding
        self.actions = actions
    }
}

/// The full set of action→chord assignments the app registers and the settings window edits.
///
/// A pure value type so binding edits, defaults, and — crucially — **conflict detection** are all
/// testable without a display or Carbon. A chord is compared on key + modifiers only (`keyLabel` is
/// cosmetic), so the same physical shortcut written two ways still collides.
public struct HotkeyBindings: Equatable, Sendable {
    private var storage: [CaptureAction: HotkeyBinding]

    public init(_ storage: [CaptureAction: HotkeyBinding] = [:]) {
        self.storage = storage
    }

    /// The current assignment for an action, or `nil` when it is unbound.
    public subscript(action: CaptureAction) -> HotkeyBinding? {
        get { storage[action] }
        set { storage[action] = newValue }
    }

    /// All non-nil assignments (the set the hotkey service registers).
    public var assignments: [CaptureAction: HotkeyBinding] { storage }

    /// Defaults echoing macOS's screenshot keys but with **Control added** so they don't collide with
    /// the system's own ⇧⌘3/⇧⌘4 — those are reserved, and a global registration for them would fail
    /// on every Mac. So: ⌃⌘3 fullscreen, ⌃⌘4 area. `window` capture works (LIG-14) but ships **unbound
    /// by default** — the user can assign it in settings, so we don't claim a third global chord for it.
    public static let defaults = HotkeyBindings([
        .fullscreen: HotkeyBinding(keyCode: 20, modifiers: [.command, .control], keyLabel: "3"),
        .area: HotkeyBinding(keyCode: 21, modifiers: [.command, .control], keyLabel: "4"),
    ])

    /// Groups of actions sharing an identical chord, one `HotkeyConflict` per clashing chord. Empty
    /// when every binding is unique. This is what "conflicts are surfaced, not silently dropped"
    /// reduces to (acceptance criterion 1).
    public var conflicts: [HotkeyConflict] {
        var byChord: [Chord: [CaptureAction]] = [:]
        for (action, binding) in storage {
            byChord[Chord(binding), default: []].append(action)
        }
        return byChord
            .filter { $0.value.count > 1 }
            .map { HotkeyConflict(binding: $0.key.binding, actions: $0.value.sorted()) }
            .sorted { ($0.actions.first ?? .area) < ($1.actions.first ?? .area) }
    }

    /// The other action already holding `binding`'s chord, if assigning it to `action` would clash —
    /// so a recorder can warn (or refuse) at the moment of capture rather than after the fact.
    public func conflictingAction(for binding: HotkeyBinding, excluding action: CaptureAction) -> CaptureAction? {
        let chord = Chord(binding)
        return storage
            .first { $0.key != action && Chord($0.value) == chord }?
            .key
    }
}

/// Chord identity for conflict detection: key + modifiers, ignoring the cosmetic `keyLabel`.
private struct Chord: Hashable {
    let binding: HotkeyBinding
    init(_ binding: HotkeyBinding) { self.binding = binding }
    static func == (lhs: Chord, rhs: Chord) -> Bool {
        lhs.binding.keyCode == rhs.binding.keyCode && lhs.binding.modifiers == rhs.binding.modifiers
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(binding.keyCode)
        hasher.combine(binding.modifiers.rawValue)
    }
}
