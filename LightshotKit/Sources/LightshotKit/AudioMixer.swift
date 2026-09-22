import Foundation

/// Sums two PCM streams into one by sample time (spec 0006, story 22, "record on a single track").
///
/// Pure arithmetic over interleaved float frames, so it is unit-tested on synthetic buffers: each
/// source pushes frames stamped with the index of their first frame; the mixer keeps one
/// contiguous run per source (a gap between pushes is filled with silence, an overlap is dropped),
/// and `drain` returns the stretch every active source has delivered — summed and clipped to
/// `-1...1` — advancing its output cursor. Per-source gain is applied by the pusher with
/// `applyGain`. A source that goes away (a lost microphone) is marked inactive so the other keeps
/// flowing alone; a source that merely stalls holds the mix back for at most `maxLag` frames, after
/// which its missing stretch is taken as silence rather than buffering the other source forever.
public struct AudioMixer: Equatable, Sendable {
    public enum Source: Hashable, Sendable {
        case microphone
        case computer
    }

    private struct Run: Equatable, Sendable {
        var start: Int64
        var samples: [Float]   // interleaved
    }

    public let channels: Int
    /// How far ahead the leading source may run before the lagging one is treated as silent.
    public let maxLag: Int64
    private var runs: [Source: Run] = [:]
    private var active: Set<Source>
    /// The next frame index to output; set by the first push.
    private var cursor: Int64?

    /// `maxLag` defaults to two seconds at 48 kHz.
    public init(channels: Int, sources: Set<Source>, maxLag: Int64 = 96_000) {
        self.channels = max(1, channels)
        self.active = sources
        self.maxLag = max(0, maxLag)
    }

    /// Scale and clip samples to `-1...1` — the per-source volume, applied before mixing.
    public static func applyGain(_ gain: Float, to samples: inout [Float]) {
        guard gain != 1 else { return }
        for i in samples.indices { samples[i] = max(-1, min(1, samples[i] * gain)) }
    }

    public var activeSources: Set<Source> { active }

    /// Append `frames` (interleaved, `channels` per frame) from `source`, the first of which is
    /// frame `index`. Frames already behind the output cursor are never output.
    public mutating func push(_ source: Source, frames: [Float], at index: Int64) {
        guard active.contains(source), !frames.isEmpty else { return }
        if cursor == nil { cursor = index }
        var run = runs[source] ?? Run(start: index, samples: [])
        let end = run.start + Int64(run.samples.count / channels)
        if run.samples.isEmpty {
            run.start = index
            run.samples = frames
        } else if index >= end {
            // A gap is silence; contiguous pushes just append.
            run.samples.append(contentsOf: [Float](repeating: 0, count: Int(index - end) * channels))
            run.samples.append(contentsOf: frames)
        } else {
            // Overlapping frames were already delivered: keep only the new tail.
            let skip = Int(end - index) * channels
            if skip < frames.count { run.samples.append(contentsOf: frames[skip...]) }
        }
        runs[source] = run
    }

    /// The source will deliver nothing more; the mix no longer waits for it.
    public mutating func setInactive(_ source: Source) {
        active.remove(source)
    }

    /// Everything every active source has delivered from the cursor on, or `nil` when some active
    /// source has not caught up yet (or nothing has been pushed). A source more than `maxLag`
    /// frames behind the leader no longer holds the mix back.
    public mutating func drain() -> (start: Int64, frames: [Float])? {
        guard let cursor else { return nil }
        var slowest = Int64.max
        var fastest = cursor
        for source in active {
            let run = runs[source]
            let end = run.map { $0.start + Int64($0.samples.count / channels) } ?? cursor
            slowest = min(slowest, end)
            fastest = max(fastest, end)
        }
        var upTo = active.isEmpty
            ? (runs.values.map { $0.start + Int64($0.samples.count / channels) }.max() ?? cursor)
            : max(slowest, fastest - maxLag)
        upTo = max(upTo, cursor)
        guard upTo > cursor else { return nil }

        let count = Int(upTo - cursor) * channels
        var mixed = [Float](repeating: 0, count: count)
        for (source, run) in runs {
            for i in 0..<count {
                let frame = cursor + Int64(i / channels)
                let local = Int(frame - run.start) * channels + i % channels
                if frame >= run.start, local < run.samples.count { mixed[i] += run.samples[local] }
            }
            // Drop what was consumed, keeping the run anchored at the new cursor.
            var trimmed = run
            let consumed = Int(min(max(upTo - run.start, 0), Int64(run.samples.count / channels)))
            trimmed.samples.removeFirst(consumed * channels)
            trimmed.start = max(run.start, upTo)
            runs[source] = trimmed
        }
        for i in 0..<count { mixed[i] = max(-1, min(1, mixed[i])) }
        self.cursor = upTo
        return (cursor, mixed)
    }
}
