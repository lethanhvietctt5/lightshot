import Testing
@testable import LightshotKit

// Direct manipulation (spec 0007, round 2, story 33): drags snap to nearby edges; the waveform
// is peak data per bucket.

@Test func aValueSnapsToTheNearestTargetWithinTolerance() {
    #expect(TimelineSnap.snap(4.93, to: [2, 5, 9], tolerance: 0.1) == 5)
    #expect(TimelineSnap.snap(4.5, to: [2, 5, 9], tolerance: 0.1) == 4.5)
    #expect(TimelineSnap.snap(5.04, to: [5.1, 5], tolerance: 0.2) == 5)          // the nearest wins
    #expect(TimelineSnap.snap(3, to: [], tolerance: 1) == 3)
}

@Test func aSpanSnapsByWhicheverEdgeIsCloserKeepingItsLength() {
    // A 2 s pill dragged to start at 3.95: its start snaps to 4.
    #expect(TimelineSnap.snapSpan(start: 3.95, length: 2, to: [4, 10], tolerance: 0.1) == 4)
    // Its end (7.97) is near 8: the start moves to 6.
    #expect(TimelineSnap.snapSpan(start: 5.97, length: 2, to: [8], tolerance: 0.1) == 6)
    #expect(TimelineSnap.snapSpan(start: 5.5, length: 2, to: [8], tolerance: 0.1) == 5.5)
}

@Test func peaksAreTheLoudestSampleOfEachBucketNormalised() {
    let samples: [Float] = [0.1, -0.5, 0.2, 0.25, 0, 0, -0.1, 0.05]
    let peaks = WaveformPeaks.buckets(samples, count: 4)
    #expect(peaks.count == 4)
    #expect(peaks[0] == 1)                                  // 0.5 is the loudest overall
    #expect(abs(peaks[1] - 0.5) < 1e-6)                     // 0.25 / 0.5
    #expect(peaks[2] == 0)
    #expect(abs(peaks[3] - 0.2) < 1e-6)
}

@Test func silenceHasFlatPeaks() {
    #expect(WaveformPeaks.buckets([Float](repeating: 0, count: 100), count: 10) == [Float](repeating: 0, count: 10))
    #expect(WaveformPeaks.buckets([], count: 5).isEmpty)
}
