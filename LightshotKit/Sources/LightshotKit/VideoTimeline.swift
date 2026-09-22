import Foundation

/// The video editor's timeline geometry (LIG-43, after CleanShot's studio editor): a clip laid
/// across a track `width` points wide — time ↔ x both ways, the ruler's tick step and labels, and
/// which filmstrip frame fills each slot.
public struct TimelineScale: Equatable, Sendable {
    /// Tick steps the ruler picks from, in seconds; never finer than a second, so no two labels read
    /// the same.
    public static let tickSteps: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600]

    public let duration: TimeInterval
    public let width: Double

    public init(duration: TimeInterval, width: Double) {
        self.duration = max(duration, 0)
        self.width = max(width, 0)
    }

    /// Where `time` sits on the track, clamped to the clip.
    public func x(for time: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(time, 0), duration) / duration * width
    }

    /// The time under `x`, clamped to the clip.
    public func time(at x: Double) -> TimeInterval {
        guard width > 0 else { return 0 }
        return min(max(x, 0), width) / width * duration
    }

    /// The finest step whose labels stay at least `minimumSpacing` points apart.
    public func tickStep(minimumSpacing: Double = 72) -> TimeInterval {
        guard duration > 0, width > 0 else { return Self.tickSteps[0] }
        let pointsPerSecond = width / duration
        return Self.tickSteps.first { $0 * pointsPerSecond >= minimumSpacing } ?? Self.tickSteps[Self.tickSteps.count - 1]
    }

    /// The ruler's ticks: every `tickStep` from zero up to the clip's end.
    public func ticks(minimumSpacing: Double = 72) -> [TimeInterval] {
        let step = tickStep(minimumSpacing: minimumSpacing)
        return Array(stride(from: 0, through: duration, by: step))
    }

    /// `00:04` as the ruler and the transport show it; `1:02:03` past an hour.
    public static func label(_ time: TimeInterval) -> String {
        let total = Int(max(time, 0).rounded(.down))
        let hours = total / 3_600, minutes = total / 60 % 60, seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// For each of `slots` filmstrip slots, the index of the frame (out of `frames` taken evenly
    /// across the clip) nearest the slot's middle.
    public static func filmstripFrames(slots: Int, frames: Int) -> [Int] {
        guard slots > 0, frames > 0 else { return [] }
        return (0..<slots).map { slot in
            min(frames - 1, Int((Double(slot) + 0.5) / Double(slots) * Double(frames)))
        }
    }
}
