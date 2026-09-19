import SwiftUI
import AppKit
import Carbon.HIToolbox
import LightshotKit

/// A SwiftUI control that records a global-hotkey chord (story 56).
///
/// Click to arm, then press the desired combination; the next chord (at least one of ⌘/⌥/⌃, or a
/// function key) is captured and reported. Escape cancels an in-progress recording, Delete clears the
/// existing binding. Backed by an `NSView` because a global hotkey must be captured from the raw
/// key/keyEquivalent events — SwiftUI has no first-class key-capture surface.
struct HotkeyRecorderView: NSViewRepresentable {
    var binding: HotkeyBinding?
    /// Called with the newly captured chord, or `nil` when the user clears it.
    var onChange: (HotkeyBinding?) -> Void

    func makeNSView(context: Context) -> RecorderControl {
        let control = RecorderControl()
        control.binding = binding
        control.onResult = onChange
        return control
    }

    func updateNSView(_ control: RecorderControl, context: Context) {
        control.onResult = onChange
        if !control.isRecording {
            control.binding = binding
            control.needsDisplay = true
        }
    }
}

/// The `NSView` doing the actual key capture and drawing for `HotkeyRecorderView`.
final class RecorderControl: NSView {
    var binding: HotkeyBinding?
    var onResult: ((HotkeyBinding?) -> Void)?
    private(set) var isRecording = false

    override var acceptsFirstResponder: Bool { isRecording }
    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 24) }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func stopRecording() {
        isRecording = false
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        _ = handle(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        return handle(event)
    }

    override func flagsChanged(with event: NSEvent) {
        if isRecording { needsDisplay = true }
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            needsDisplay = true
        }
        return true
    }

    /// Resolve a key event into a chord (or a cancel/clear). Returns `true` when the event was
    /// consumed so it never leaks through to the rest of the app while recording.
    private func handle(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:                 // abandon this recording, keep the old chord
            stopRecording()
            return true
        case kVK_Delete, kVK_ForwardDelete:  // clear the binding entirely
            binding = nil
            onResult?(nil)
            stopRecording()
            return true
        default:
            break
        }

        guard let captured = Self.binding(from: event) else {
            return true   // ignore an incomplete chord (e.g. a bare letter) but stay recording
        }
        binding = captured
        onResult?(captured)
        stopRecording()
        return true
    }

    // MARK: - Event → binding

    private static func binding(from event: NSEvent) -> HotkeyBinding? {
        let modifiers = hotkeyModifiers(event.modifierFlags)
        let keyCode = event.keyCode
        let isFunctionKey = functionKeyLabels[Int(keyCode)] != nil

        // A global hotkey needs a real modifier (⌘/⌥/⌃) — shift alone is too easy to trigger — with
        // the exception of the function-key row, which stands on its own.
        let hasHardModifier = !modifiers.isDisjoint(with: [.command, .option, .control])
        guard hasHardModifier || isFunctionKey else { return nil }

        return HotkeyBinding(keyCode: keyCode, modifiers: modifiers, keyLabel: label(for: event))
    }

    private static func hotkeyModifiers(_ flags: NSEvent.ModifierFlags) -> HotkeyModifiers {
        var modifiers: HotkeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    private static func label(for event: NSEvent) -> String {
        if let special = specialKeyLabels[Int(event.keyCode)] { return special }
        if let function = functionKeyLabels[Int(event.keyCode)] { return function }
        let chars = event.charactersIgnoringModifiers ?? ""
        return chars.isEmpty ? "Key \(event.keyCode)" : chars.uppercased()
    }

    /// Printable labels for keys whose characters don't read well (arrows, whitespace, etc.).
    private static let specialKeyLabels: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞",
        kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_DownArrow: "↓", kVK_UpArrow: "↑",
    ]

    private static let functionKeyLabels: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                     : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 1.5 : 1
        path.stroke()

        let text = displayText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: text.isPlaceholder ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let string = NSAttributedString(string: text.value, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                y: (bounds.height - size.height) / 2))
    }

    private var displayText: (value: String, isPlaceholder: Bool) {
        if isRecording { return ("Type shortcut…", true) }
        if let binding { return (binding.displayString, false) }
        return ("Click to record", true)
    }
}
