import LightshotKit

/// Which of the recorder toolbar's toggles have their feature built (spec 0006, story 8): all five
/// since R9 (camera), R10 (click highlighting) and R11 (keystrokes) landed after R7/R8's audio.
enum RecordingFeatures {
    static let availableToggles: Set<RecordingToggle> = Set(RecordingToggle.allCases)
}
