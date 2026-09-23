import Foundation

/// Snapping for timeline drags (spec 0007, round 2, story 33): a dragged edge or pill jumps to the
/// playhead or another edge when it comes within `tolerance` (the view passes 8 points' worth of
/// seconds), so cuts and zooms line up exactly.
public enum TimelineSnap {
    /// `value`, or the nearest target within `tolerance` of it.
    public static func snap(_ value: Double, to targets: [Double], tolerance: Double) -> Double {
        guard let nearest = targets.min(by: { abs($0 - value) < abs($1 - value) }), abs(nearest - value) <= tolerance else { return value }
        return nearest
    }

    /// The start of a `length`-long span dragged to `start`, snapped by whichever of its two edges
    /// is closer to a target.
    public static func snapSpan(start: Double, length: Double, to targets: [Double], tolerance: Double) -> Double {
        let byStart = snap(start, to: targets, tolerance: tolerance)
        let byEnd = snap(start + length, to: targets, tolerance: tolerance) - length
        let startMoved = abs(byStart - start), endMoved = abs(byEnd - start)
        switch (byStart != start, byEnd != start) {
        case (true, true): return startMoved <= endMoved ? byStart : byEnd
        case (true, false): return byStart
        case (false, true): return byEnd
        case (false, false): return start
        }
    }
}

/// The clip track's waveform (story 33): the loudest sample of each bucket, normalised so the
/// loudest bucket is `1`.
public enum WaveformPeaks {
    public static func buckets(_ samples: [Float], count: Int) -> [Float] {
        guard count > 0, !samples.isEmpty else { return [] }
        var peaks = [Float](repeating: 0, count: count)
        let per = Double(samples.count) / Double(count)
        for i in 0..<count {
            let lower = Int((Double(i) * per).rounded(.down))
            let upper = min(samples.count, max(lower + 1, Int((Double(i + 1) * per).rounded(.down))))
            var peak: Float = 0
            for j in lower..<upper { peak = max(peak, abs(samples[j])) }
            peaks[i] = peak
        }
        let loudest = peaks.max() ?? 0
        return loudest > 0 ? peaks.map { $0 / loudest } : peaks
    }
}
