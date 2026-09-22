import Testing
import Foundation
@testable import LightshotKit

// The keystroke overlay rules (spec 0006, stories 30–31; LIG-45): one pill per burst of typing,
// how presses join it, mode filtering, repeats, hold-then-fade, held modifiers, the secure-input
// blackout, labels and placement.

private let cmdZ = KeyPress(label: "Z", modifiers: .command)

@Test func aPressShowsModifierGlyphsThenTheKeyAndFadesAfterItsHold() {
    var m = KeystrokeOverlayModel(settings: .standard)
    #expect(m.items(at: 0).isEmpty)
    m.keyDown(KeyPress(label: "S", modifiers: [.shift, .command, .control, .option, .function]), at: 1)
    let fresh = m.items(at: 1.0)
    #expect(fresh.count == 1 && fresh[0].text == "fn⌃⌥⇧⌘S" && fresh[0].opacity == 1)
    #expect(fresh[0].scale == KeystrokeOverlayModel.bumpScale)   // the press bump
    #expect(m.items(at: 1.5)[0].scale == 1)
    #expect(m.items(at: 2.4)[0].opacity == 1)                     // still held at 1.4 s
    let fading = m.items(at: 2.5 + 0.175)[0].opacity               // half-way through the fade
    #expect(abs(fading - 0.5) < 0.001)
    #expect(m.items(at: 2.9).isEmpty)
    m.prune(at: 2.9)
    #expect(m == KeystrokeOverlayModel(settings: .standard))
}

@Test func commandOnlyModeHidesPlainTypingButShowsChords() {
    var m = KeystrokeOverlayModel(settings: KeystrokeOverlaySettings(mode: .commandOnly))
    m.keyDown(KeyPress(label: "A"), at: 0)
    m.keyDown(KeyPress(label: "A", modifiers: .shift), at: 0)     // ⇧ alone is typing
    #expect(m.items(at: 0).isEmpty)
    m.keyDown(cmdZ, at: 0)
    m.keyDown(KeyPress(label: "→", modifiers: .option), at: 0)
    #expect(m.items(at: 0).map(\.text) == ["⌘Z ⌥→"])

    var all = KeystrokeOverlayModel(settings: KeystrokeOverlaySettings(mode: .allKeys))
    all.keyDown(KeyPress(label: "A"), at: 0)
    #expect(all.items(at: 0).map(\.text) == ["A"])
}

@Test func repeatedPressesCountUpAndReBumpInsteadOfStacking() {
    var m = KeystrokeOverlayModel(settings: .standard)
    m.keyDown(cmdZ, at: 0)
    m.keyDown(cmdZ, at: 0.5)
    m.keyDown(cmdZ, at: 0.9)
    let items = m.items(at: 0.9)
    #expect(items.map(\.text) == ["⌘Z ×3"])
    #expect(items[0].scale == KeystrokeOverlayModel.bumpScale)   // re-bumped on the third press
    m.keyDown(KeyPress(label: "A"), at: 1.2)
    m.keyDown(cmdZ, at: 1.4)                                       // not the last token: a new one
    #expect(m.items(at: 1.4).map(\.text) == ["⌘Z ×3 A ⌘Z"])
}

@Test func aHeldKeyAutoRepeatsWithoutCountingOrBumping() {
    var m = KeystrokeOverlayModel(settings: .standard)
    let left = KeyPress(label: "←")
    m.keyDown(left, at: 0)
    for i in 1...40 { m.keyDown(KeyPress(label: "←", isRepeat: true), at: 0.5 + Double(i) * 0.05) }   // held for 2 s
    let items = m.items(at: 2.5)
    #expect(items.map(\.text) == ["←"])                            // no ×41
    #expect(items[0].opacity == 1 && items[0].scale == 1)          // alive, not re-bumped
    #expect(m.items(at: 4.5).isEmpty)                               // fades after release
    m.keyDown(left, at: 5)                                         // a real second press starts fresh
    #expect(m.items(at: 5).map(\.text) == ["←"])
}

@Test func continuousTypingJoinsOnePillUntilTheTypingStops() {
    var m = KeystrokeOverlayModel(settings: .standard)
    m.keyDown(KeyPress(label: "H", modifiers: .shift), at: 0)       // Shift alone is still typing
    for (i, key) in ["E", "L", "L", "O"].enumerated() { m.keyDown(KeyPress(label: key), at: 0.2 + Double(i) * 0.2) }
    #expect(m.items(at: 1.0).map(\.text) == ["HELLO"])
    // A press while the pill is fading still belongs to the burst, and revives it.
    let fading = 2.4                                                  // 1.6 s after the last key
    m.keyDown(KeyPress(label: "!"), at: fading)
    #expect(m.items(at: fading) == [KeystrokeItem(text: "HELLO!", opacity: 1, scale: KeystrokeOverlayModel.bumpScale)])
    // Once it has faded out, the next key starts a new pill.
    let gone = fading + KeystrokeOverlayModel.holdDuration + KeystrokeOverlayModel.fadeDuration
    #expect(m.items(at: gone).isEmpty)
    m.keyDown(KeyPress(label: "A"), at: gone + 0.1)
    #expect(m.items(at: gone + 0.1).map(\.text) == ["A"])
}

@Test func chordsAndNamedKeysAreTheirOwnTokensAndSpaceShowsInsideText() {
    var m = KeystrokeOverlayModel(settings: .standard)
    m.keyDown(KeyPress(label: "F", modifiers: [.shift, .command]), at: 0)
    m.keyDown(KeyPress(label: "S", modifiers: .command), at: 0.3)
    m.keyDown(KeyPress(label: "H"), at: 0.5)
    m.keyDown(KeyPress(label: "I"), at: 0.6)
    m.keyDown(KeyPress(label: "Space"), at: 0.7)
    m.keyDown(KeyPress(label: "Y"), at: 0.8)
    m.keyDown(KeyPress(label: "↩"), at: 0.9)
    m.keyDown(KeyPress(label: "O"), at: 1.0)
    #expect(m.items(at: 1.0).map(\.text) == ["⇧⌘F ⌘S HI␣Y ↩ O"])
}

@Test func aLongBurstKeepsItsNewestCharacters() {
    var m = KeystrokeOverlayModel(settings: .standard)
    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMN")
    for (i, letter) in letters.enumerated() { m.keyDown(KeyPress(label: String(letter)), at: Double(i) * 0.05) }
    let text = m.items(at: 2)[0].text
    #expect(text.count == KeystrokeOverlayModel.maxCharacters)
    #expect(text.hasPrefix("…") && text.hasSuffix("KLMN"))
}

@Test func heldModifiersShowWhileNothingFreshIsOnScreen() {
    var m = KeystrokeOverlayModel(settings: .standard)
    m.modifiersChanged(.command)
    #expect(m.items(at: 0) == [KeystrokeItem(text: "⌘", opacity: 1, scale: 1)])
    m.keyDown(cmdZ, at: 0.2)
    #expect(m.items(at: 0.2).map(\.text) == ["⌘Z"])              // the chord replaces the bare ⌘
    #expect(m.items(at: 1.8).map(\.text) == ["⌘Z", "⌘"])          // fading, and ⌘ is still held
    m.modifiersChanged([])
    #expect(m.items(at: 1.8).map(\.text) == ["⌘Z"])
}

@Test func secureInputShowsNothingClearsPendingAndResumesOnlyWhenOff() {
    var m = KeystrokeOverlayModel(settings: .standard)
    m.keyDown(cmdZ, at: 0)
    m.modifiersChanged(.command)
    m.setSecureInput(true)
    #expect(m.items(at: 0).isEmpty)                                 // pending entries cleared
    #expect(m.heldModifiers.isEmpty)
    m.keyDown(KeyPress(label: "P"), at: 0.1)                        // anything the tap delivers
    m.keyDown(KeyPress(label: "P", modifiers: .command), at: 0.1)
    m.modifiersChanged(.shift)
    #expect(m.items(at: 0.1).isEmpty)
    m.setSecureInput(false)
    #expect(m.items(at: 0.2).isEmpty)                               // resumes from empty, not from history
    m.keyDown(KeyPress(label: "Q"), at: 0.3)
    #expect(m.items(at: 0.3).map(\.text) == ["Q"])
}

@Test func eventsRouteThroughHandle() {
    var m = KeystrokeOverlayModel(settings: .standard)
    m.handle(.modifiersChanged(.option), at: 0)
    m.handle(.keyDown(KeyPress(label: "X", modifiers: .option)), at: 0)
    #expect(m.items(at: 0).map(\.text) == ["⌥X"])
    m.handle(.secureInput(true), at: 1)
    #expect(m.items(at: 1).isEmpty && m.secureInput)
}

@Test func keyLabelsNameSpecialKeysAndUppercaseTheRest() {
    #expect(KeyLabel.label(keyCode: 36, characters: "\r") == "↩")
    #expect(KeyLabel.label(keyCode: 53, characters: "\u{1B}") == "⎋")
    #expect(KeyLabel.label(keyCode: 123, characters: "\u{F702}") == "←")
    #expect(KeyLabel.label(keyCode: 49, characters: " ") == "Space")
    #expect(KeyLabel.label(keyCode: 122, characters: "\u{F704}") == "F1")
    #expect(KeyLabel.label(keyCode: 0, characters: "a") == "A")
    #expect(KeyLabel.label(keyCode: 27, characters: "-") == "-")
    #expect(KeyLabel.label(keyCode: 0, characters: "\u{F710}") == nil)   // unnamed function-key glyph
    #expect(KeyLabel.label(keyCode: 0, characters: nil) == nil)
}

@Test func thePositionAnchorsThePillGroupInsideTheFrame() {
    let frame = Size(width: 1000, height: 600), pill = Size(width: 200, height: 50)
    #expect(KeystrokeOverlayPosition.topLeft.rect(for: pill, in: frame, margin: 20) == Rect(x: 20, y: 20, width: 200, height: 50))
    #expect(KeystrokeOverlayPosition.bottomCenter.rect(for: pill, in: frame, margin: 20) == Rect(x: 400, y: 530, width: 200, height: 50))
    #expect(KeystrokeOverlayPosition.bottomRight.rect(for: pill, in: frame, margin: 20) == Rect(x: 780, y: 530, width: 200, height: 50))
    #expect(KeystrokeOverlayPosition.topCenter.isTop && !KeystrokeOverlayPosition.bottomLeft.isTop)
}
