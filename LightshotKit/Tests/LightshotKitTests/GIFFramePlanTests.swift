import Testing
import Foundation
@testable import LightshotKit

// The GIF frame plan (spec 0006, story 37): delay from fps, frame count from duration, sampling
// against a faster or slower source, the downscale, and the quality → colour depth mapping.

@Test func theDelayIsWholeCentisecondsNearestToTheFPS() {
    #expect(GIFFramePlan.delay(forFPS: 15) == 0.07)     // 6.67 → 7 cs
    #expect(GIFFramePlan.delay(forFPS: 10) == 0.10)
    #expect(GIFFramePlan.delay(forFPS: 30) == 0.03)
    #expect(GIFFramePlan.delay(forFPS: 100) == 0.02)    // never under 2 cs
    #expect(GIFFramePlan.delay(forFPS: 0) == 1.0)
}

@Test func theFrameCountCoversTheDurationAndIsNeverZero() {
    let settings = GIFSettings(fps: 10, quality: 1, maxWidth: nil, optimize: false)
    #expect(GIFFramePlan(duration: 2.0, sourceSize: Size(width: 100, height: 100), settings: settings).frameCount == 20)
    #expect(GIFFramePlan(duration: 2.05, sourceSize: Size(width: 100, height: 100), settings: settings).frameCount == 21)
    #expect(GIFFramePlan(duration: 0, sourceSize: Size(width: 100, height: 100), settings: settings).frameCount == 1)
}

@Test func aFasterSourceIsSampledDownAndASlowerOneFillsOneFramePerSourceFrame() {
    let plan = GIFFramePlan(duration: 1, sourceSize: Size(width: 100, height: 100), settings: GIFSettings(fps: 15, quality: 1, maxWidth: nil, optimize: false))
    // 30 fps source: frames at 0, 1/30, 2/30 … — every other one lands (delay 0.07).
    var last: Int?
    var kept: [Int] = []
    for i in 0..<30 {
        if let index = plan.outputIndex(forSourceFrameAt: Double(i) / 30, after: last) { kept.append(i); last = index }
    }
    // Sample times 0, .07, .14 … .98: the first 30-fps frame at or past each; .98 has none.
    #expect(kept == [0, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 24, 26, 28])
    #expect(last == 13 && plan.frameCount == 15)
    // 5 fps source: each frame fills one output frame; the rest is the encoder's repeat.
    var slowLast: Int?
    for i in 0..<5 { slowLast = plan.outputIndex(forSourceFrameAt: Double(i) / 5, after: slowLast) ?? slowLast }
    #expect(slowLast == 4)
    // Past the plan: nothing more is taken.
    #expect(plan.outputIndex(forSourceFrameAt: 5, after: 14) == nil)
    // Float noise on the sample time still lands.
    #expect(plan.outputIndex(forSourceFrameAt: 0.07 - 1e-9, after: 0) == 1)
}

@Test func theOutputIsScaledDownToTheMaxWidthKeepingAspectButNeverUp() {
    let wide = Size(width: 1920, height: 1080)
    #expect(GIFFramePlan(duration: 1, sourceSize: wide, settings: GIFSettings(fps: 15, quality: 1, maxWidth: 800, optimize: true)).outputSize == Size(width: 800, height: 450))
    #expect(GIFFramePlan(duration: 1, sourceSize: wide, settings: GIFSettings(fps: 15, quality: 1, maxWidth: nil, optimize: true)).outputSize == wide)
    #expect(GIFFramePlan(duration: 1, sourceSize: Size(width: 400, height: 300), settings: GIFSettings(fps: 15, quality: 1, maxWidth: 800, optimize: true)).outputSize == Size(width: 400, height: 300))
    #expect(GIFFramePlan(duration: 1, sourceSize: Size(width: 1000, height: 333), settings: GIFSettings(fps: 15, quality: 1, maxWidth: 100, optimize: true)).outputSize == Size(width: 100, height: 33))
}

@Test func qualityMapsToColourDepth() {
    #expect(GIFFramePlan.bitsPerChannel(quality: 1) == 8)
    #expect(GIFFramePlan.bitsPerChannel(quality: 0.8) == 7)
    #expect(GIFFramePlan.bitsPerChannel(quality: 0.5) == 6)
    #expect(GIFFramePlan.bitsPerChannel(quality: 0) == 4)
}
