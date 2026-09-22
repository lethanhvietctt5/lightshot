import Testing
import Foundation
@testable import LightshotKit

// The video editor's pure parts (spec 0006, stories 35–36): the trim range, output dimensions,
// the bit-rate curve and the size estimate.

@Test func aTrimIsClampedToTheClipAndNeverShorterThanHalfASecond() {
    var t = TrimRange(duration: 10)
    #expect(t.isWholeClip && t.length == 10)
    t.setStart(-3)
    #expect(t.start == 0)
    t.setEnd(42)
    #expect(t.end == 10)
    t.setStart(9.8)                          // too close to the out point: stops 0.5 s short
    #expect(t.start == 9.5)
    t.setEnd(9.6)
    #expect(t.end == 10)                     // cannot come within 0.5 s of the in point
    t.setStart(2); t.setEnd(4)
    #expect(t.start == 2 && t.end == 4 && !t.isWholeClip)
    #expect(TrimRange(start: 5, end: 3, duration: 10) == TrimRange(start: 5, end: 5.5, duration: 10))   // crossed handles: out stops short of in
    // A clip shorter than the minimum is still whole.
    let short = TrimRange(start: 0.1, end: 0.2, duration: 0.3)
    #expect(short.start == 0 && short.end == 0.3)
}

@Test func presetsCapTheLongestEdgeKeepingAspectWithEvenEdgesNeverUp() {
    let source = Size(width: 2560, height: 1440)
    #expect(VideoDimensions.size(for: .original, source: source) == source)
    #expect(VideoDimensions.size(for: .p1080, source: source) == Size(width: 1920, height: 1080))
    #expect(VideoDimensions.size(for: .p720, source: source) == Size(width: 1280, height: 720))
    #expect(VideoDimensions.size(for: .p480, source: source) == Size(width: 854, height: 480))
    #expect(VideoDimensions.size(for: .p1080, source: Size(width: 800, height: 600)) == Size(width: 800, height: 600))
    let tall = Size(width: 1080, height: 2340)
    #expect(VideoDimensions.size(for: .p720, source: tall) == Size(width: 590, height: 1280))
    #expect(VideoDimensions.size(for: .original, source: Size(width: 801, height: 601)) == Size(width: 800, height: 600))
}

@Test func aTypedEdgeKeepsTheAspectAndIsClampedToTheSource() {
    let source = Size(width: 1600, height: 900)
    #expect(VideoDimensions.size(width: 800, height: nil, source: source) == Size(width: 800, height: 450))
    #expect(VideoDimensions.size(width: nil, height: 300, source: source) == Size(width: 532, height: 300))   // 533.3 → even, down
    #expect(VideoDimensions.size(width: 4000, height: nil, source: source) == Size(width: 1600, height: 900))
    #expect(VideoDimensions.size(width: 640, height: 640, source: source) == Size(width: 640, height: 360))   // fits the box, never stretched
    #expect(VideoDimensions.size(width: 3200, height: 450, source: source) == Size(width: 800, height: 450))
    #expect(VideoDimensions.size(width: nil, height: nil, source: source) == source)
    #expect(VideoDimensions.size(width: 1, height: nil, source: source) == Size(width: 2, height: 2))
}

@Test func theBitRateCurvePassesThroughTheRecordersRateAtTheDefaultQuality() {
    #expect(VideoBitRate.bitsPerPixel(quality: VideoBitRate.defaultQuality) == 0.1)
    #expect(VideoBitRate.bitsPerPixel(quality: 0) == 0.025)
    #expect(VideoBitRate.bitsPerPixel(quality: 1) == 0.2)
    #expect(VideoBitRate.bitsPerPixel(quality: 0.25) < VideoBitRate.bitsPerPixel(quality: 0.75))
    let rate = VideoBitRate.videoBitsPerSecond(size: Size(width: 1920, height: 1080), fps: 30, quality: 0.5)
    #expect(rate == 1920 * 1080 * 30 * 0.1)
    #expect(VideoBitRate.videoBitsPerSecond(size: Size(width: 100, height: 100), fps: 1, quality: 0) == VideoBitRate.minimumBitsPerSecond)
}

@Test func theEstimateIsBitRateTimesTheCutPlusOverhead() {
    let size = Size(width: 1280, height: 720)
    var settings = VideoEditSettings(trim: TrimRange(start: 2, end: 12, duration: 30), dimensions: size, quality: 0.5, audio: .unchanged)
    let video = 1280.0 * 720 * 30 * 0.1
    #expect(SizeEstimator.estimatedBytes(settings: settings, fps: 30, audioChannels: 2)
            == (video + 2 * 64_000) * 10 / 8 + SizeEstimator.containerOverheadBytes)
    settings.audio = .mono
    #expect(SizeEstimator.estimatedBytes(settings: settings, fps: 30, audioChannels: 2)
            == (video + 64_000) * 10 / 8 + SizeEstimator.containerOverheadBytes)
    settings.audio = .remove
    #expect(SizeEstimator.estimatedBytes(settings: settings, fps: 30, audioChannels: 2)
            == video * 10 / 8 + SizeEstimator.containerOverheadBytes)
    // Smaller, lower quality, shorter: monotonic.
    var smaller = settings
    smaller.dimensions = Size(width: 640, height: 360)
    smaller.quality = 0.2
    smaller.trim = TrimRange(start: 2, end: 5, duration: 30)
    #expect(SizeEstimator.estimatedBytes(settings: smaller, fps: 30, audioChannels: 0) < SizeEstimator.estimatedBytes(settings: settings, fps: 30, audioChannels: 0))
    // A pass-through cut scales the source's own size.
    #expect(SizeEstimator.estimatedTrimOnlyBytes(sourceBytes: 3_000, trim: TrimRange(start: 0, end: 10, duration: 30)) == 1_000)
}
