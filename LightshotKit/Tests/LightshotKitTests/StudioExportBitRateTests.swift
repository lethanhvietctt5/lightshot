import Testing
@testable import LightshotKit

// A Studio export's bit rate (spec 0007, story 25). The recorder's curve (0.1 bit per pixel per
// frame, linear in fps) made a 94 s, 2556×1366, 60 fps edit estimate 230 MB and encode 95 MB —
// three times the 32 MB take. Screen content needs far less, and frames at 60 fps differ less
// from each other than at 30.

private let take = Size(width: 2556, height: 1366)

@Test func aDefaultStudioExportOfARetinaTakeAt60FpsIsAboutSixMegabits() {
    let rate = StudioOutput(fps: 60, codec: .h264).videoBitsPerSecond(canvas: take)
    #expect(rate > 5_000_000 && rate < 7_000_000)
}

@Test func hevcGetsLessThanH264ForTheSameLook() {
    let h264 = StudioOutput(fps: 60, codec: .h264).videoBitsPerSecond(canvas: take)
    let hevc = StudioOutput(fps: 60, codec: .hevc).videoBitsPerSecond(canvas: take)
    #expect(hevc < h264 * 0.8)
    #expect(hevc > 3_500_000)
}

@Test func doublingTheFrameRateCostsLessThanDoubleTheBits() {
    let at30 = StudioOutput(fps: 30).videoBitsPerSecond(canvas: take)
    let at60 = StudioOutput(fps: 60).videoBitsPerSecond(canvas: take)
    #expect(at60 > at30 && at60 < at30 * 1.5)
}

/// The top of the quality slider still reaches what the old default actually encoded to
/// (~9.7 Mb/s H.264, ~8.1 Mb/s HEVC for this take).
@Test func fullQualityReachesWhatTheOldDefaultEncodedTo() {
    #expect(StudioOutput(fps: 60, codec: .h264, quality: 1).videoBitsPerSecond(canvas: take) >= 10_000_000)
    #expect(StudioOutput(fps: 60, codec: .hevc, quality: 1).videoBitsPerSecond(canvas: take) >= 8_100_000)
}

@Test func qualityStillRaisesTheRateAndATinyCanvasKeepsTheFloor() {
    let low = StudioOutput(quality: 0.25).videoBitsPerSecond(canvas: take)
    let high = StudioOutput(quality: 0.75).videoBitsPerSecond(canvas: take)
    #expect(low < high)
    #expect(StudioOutput(fps: 24, quality: 0).videoBitsPerSecond(canvas: Size(width: 100, height: 100)) == VideoBitRate.minimumBitsPerSecond)
}
