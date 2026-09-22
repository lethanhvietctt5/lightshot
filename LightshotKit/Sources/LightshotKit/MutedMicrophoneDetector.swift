import Foundation

/// Decides when to warn that the microphone might be muted (spec 0006, story 24): the take has
/// been going for a while and nothing above the silence floor has come in yet. Pure, so the rule
/// is tested without a microphone; the app feeds it the meter's readings.
///
/// The warning shows once `silentSeconds` of un-paused, near-silent readings have accumulated with
/// no sound heard, and disappears for good the first time a reading rises above the floor.
public struct MutedMicrophoneDetector: Equatable, Sendable {
    public static let silenceFloor: Float = 0.04
    public static let defaultSilentSeconds: TimeInterval = 3

    private let silentSeconds: TimeInterval
    private var silentFor: TimeInterval = 0
    private var heardSound = false
    public private(set) var showsWarning = false

    public init(silentSeconds: TimeInterval = MutedMicrophoneDetector.defaultSilentSeconds) {
        self.silentSeconds = silentSeconds
    }

    /// Feed one reading (`0...1`) covering `interval` seconds of the take; paused readings are ignored.
    public mutating func observe(level: Float, over interval: TimeInterval, paused: Bool = false) {
        if level > Self.silenceFloor {
            heardSound = true
            showsWarning = false
            return
        }
        guard !heardSound, !paused else { return }
        silentFor += interval
        // Readings accumulate in floating point (ten 0.1 s ticks fall a hair short of 1 s).
        if silentFor + 1e-6 >= silentSeconds { showsWarning = true }
    }
}
