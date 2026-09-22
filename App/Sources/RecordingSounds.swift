import AppKit

/// The recorder's audible cues (spec 0006, story 10 / R4): a countdown tick and the start, stop and
/// pause chimes. System sounds, so nothing is bundled; every call honours the "Play sounds"
/// setting the caller passes.
enum RecordingSounds {
    enum Cue {
        case tick, start, stop, pause

        fileprivate var systemName: NSSound.Name {
            switch self {
            case .tick: return "Tink"
            case .start: return "Pop"
            case .stop: return "Purr"
            case .pause: return "Morse"
            }
        }
    }

    static func play(_ cue: Cue, enabled: Bool) {
        guard enabled, let sound = NSSound(named: cue.systemName) else { return }
        sound.play()
    }
}
