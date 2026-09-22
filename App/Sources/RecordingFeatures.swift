import LightshotKit

/// Which of the recorder toolbar's toggles have their feature built (spec 0006, story 8). A toggle
/// whose ticket has not landed is hidden, not disabled: R7 added the microphone, R8 computer
/// audio, R10 click highlighting; R9 adds the camera, R11 keystrokes.
enum RecordingFeatures {
    static let availableToggles: Set<RecordingToggle> = [.microphone, .computerAudio, .highlightClicks]
}
