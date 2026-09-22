import Testing
import Foundation
@testable import LightshotKit

// The pure hotkey model (story 56): chord display, defaults, and conflict detection. No AppKit /
// Carbon here — that is the point of keeping bindings a value type. The concrete `HotkeyService`
// (Carbon) and the recorder UI are OS wrappers, verified manually.

// MARK: - Display

@Test func chordRendersModifiersInCanonicalOrderThenKey() {
    let binding = HotkeyBinding(keyCode: 21, modifiers: [.command, .shift], keyLabel: "4")
    #expect(binding.displayString == "⇧⌘4")
}

@Test func allModifiersRenderControlOptionShiftCommand() {
    let binding = HotkeyBinding(
        keyCode: 0, modifiers: [.control, .option, .shift, .command], keyLabel: "a"
    )
    #expect(binding.displayString == "⌃⌥⇧⌘A")   // key label is upper-cased for display
}

// MARK: - Defaults

@Test func defaultsBindAreaAndFullscreenWithoutConflicts() {
    let defaults = HotkeyBindings.defaults
    // Control-prefixed to dodge the system's own ⇧⌘3/⇧⌘4, which are reserved and unregisterable.
    #expect(defaults[.fullscreen]?.displayString == "⌃⌘3")
    #expect(defaults[.area]?.displayString == "⌃⌘4")
    #expect(defaults[.window] == nil)          // window ships unbound
    #expect(defaults[.repeatLast] == nil)      // repeat-last ships unbound (story 9) — user binds it
    // Recording actions (spec 0006) ship unbound too — no extra global chords are claimed.
    #expect(defaults[.recordScreen] == nil)
    #expect(defaults[.pauseResumeRecording] == nil)
    #expect(defaults[.restartRecording] == nil)
    #expect(defaults.conflicts.isEmpty)        // shipped defaults never clash
}

// MARK: - Conflict detection (acceptance criterion 1)

@Test func recordingActionsTakePartInConflictDetection() {
    var bindings = HotkeyBindings.defaults
    bindings[.recordScreen] = HotkeyBinding(keyCode: 21, modifiers: [.command, .control], keyLabel: "4")
    #expect(bindings.conflicts == [
        HotkeyConflict(binding: bindings[.area]!, actions: [.area, .recordScreen])
    ])
    #expect(bindings.conflictingAction(for: bindings[.recordScreen]!, excluding: .recordScreen) == .area)
}

@Test func distinctChordsProduceNoConflict() {
    var bindings = HotkeyBindings()
    bindings[.area] = HotkeyBinding(keyCode: 21, modifiers: [.command], keyLabel: "4")
    bindings[.fullscreen] = HotkeyBinding(keyCode: 20, modifiers: [.command], keyLabel: "3")
    #expect(bindings.conflicts.isEmpty)
}

@Test func twoActionsSharingAChordAreSurfacedAsAConflict() {
    let shared = HotkeyBinding(keyCode: 21, modifiers: [.command, .shift], keyLabel: "4")
    var bindings = HotkeyBindings()
    bindings[.area] = shared
    bindings[.fullscreen] = shared

    let conflicts = bindings.conflicts
    #expect(conflicts.count == 1)
    #expect(conflicts.first?.binding == shared)
    #expect(conflicts.first?.actions == [.area, .fullscreen])   // sorted in declaration order
}

@Test func conflictComparesKeyAndModifiersNotTheCosmeticLabel() {
    // Same key + modifiers, different label text still clash.
    var bindings = HotkeyBindings()
    bindings[.area] = HotkeyBinding(keyCode: 49, modifiers: [.command], keyLabel: "Space")
    bindings[.fullscreen] = HotkeyBinding(keyCode: 49, modifiers: [.command], keyLabel: " ")
    #expect(bindings.conflicts.count == 1)
}

@Test func differingModifiersDoNotConflict() {
    var bindings = HotkeyBindings()
    bindings[.area] = HotkeyBinding(keyCode: 21, modifiers: [.command, .shift], keyLabel: "4")
    bindings[.fullscreen] = HotkeyBinding(keyCode: 21, modifiers: [.command], keyLabel: "4")
    #expect(bindings.conflicts.isEmpty)
}

@Test func conflictingActionLookupPointsAtTheClashingSibling() {
    var bindings = HotkeyBindings()
    let chord = HotkeyBinding(keyCode: 21, modifiers: [.command, .shift], keyLabel: "4")
    bindings[.area] = chord

    // Assigning the same chord to fullscreen reports area as the clashing holder…
    #expect(bindings.conflictingAction(for: chord, excluding: .fullscreen) == .area)
    // …but re-assigning it to the action that already owns it is not a self-clash.
    #expect(bindings.conflictingAction(for: chord, excluding: .area) == nil)
}

@Test func aChordSavedWithShiftsSymbolReadsAsItsDigit() {
    // Recorded before the recorder asked for the unshifted key: ⇧⌘4 was stored as "$".
    #expect(HotkeyBinding(keyCode: 21, modifiers: [.shift, .command], keyLabel: "$").displayString == "⇧⌘4")
    #expect(HotkeyBinding(keyCode: 29, modifiers: [.shift, .option], keyLabel: ")").displayString == "⌥⇧0")
    // Without Shift the symbol is what was pressed, so it stays.
    #expect(HotkeyBinding(keyCode: 21, modifiers: [.command], keyLabel: "$").displayString == "⌘$")
}
