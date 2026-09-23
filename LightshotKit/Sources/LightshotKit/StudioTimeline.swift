import Foundation

/// Output time ↔ source time across trims and speed changes (spec 0007). The clips play one after
/// another; a clip at speed 2 takes half its source length in the output.
public struct StudioTimeline: Equatable, Sendable {
    /// One clip placed on the output timeline.
    public struct Segment: Equatable, Sendable {
        public let sourceStart: Double
        public let sourceEnd: Double
        public let outputStart: Double
        public let outputEnd: Double
        public let speed: Double

        public var outputLength: Double { outputEnd - outputStart }
    }

    public let segments: [Segment]

    public init(clips: [StudioClip]) {
        var output = 0.0
        segments = clips.map { clip in
            let segment = Segment(
                sourceStart: clip.start, sourceEnd: clip.end,
                outputStart: output, outputEnd: output + clip.outputLength, speed: clip.speed
            )
            output = segment.outputEnd
            return segment
        }
    }

    public var outputDuration: Double { segments.last?.outputEnd ?? 0 }

    /// The segment playing at an output time; a boundary belongs to the segment that starts there,
    /// the very end to the last segment.
    public func segment(atOutput time: Double) -> Segment? {
        guard let last = segments.last else { return nil }
        if time >= last.outputEnd { return last }
        return segments.first { time < $0.outputEnd } ?? last
    }

    /// The source time shown at an output time (clamped to the timeline).
    public func sourceTime(atOutput time: Double) -> Double {
        guard let segment = segment(atOutput: max(0, time)) else { return 0 }
        let offset = min(max(time - segment.outputStart, 0), segment.outputLength)
        return segment.sourceStart + offset * segment.speed
    }

    /// Where a source time plays in the output, or `nil` when it was cut.
    public func outputTime(atSource time: Double) -> Double? {
        guard let segment = segments.first(where: { time >= $0.sourceStart && time < $0.sourceEnd })
                ?? segments.last(where: { time == $0.sourceEnd }) else { return nil }
        return segment.outputStart + (time - segment.sourceStart) / segment.speed
    }

    /// Where playback is when the playhead is put at a source time: the time itself, or — inside a
    /// trim — where the output resumes after it (round 3, story 34).
    public func playableOutputTime(atSource time: Double) -> Double {
        outputTime(atSource: time)
            ?? segments.first { $0.sourceStart >= time }?.outputStart
            ?? outputDuration
    }
}
