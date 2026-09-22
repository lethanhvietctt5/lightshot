import Testing
import Foundation
@testable import LightshotKit

// The single-track mixer (spec 0006, story 22): sum, gaps, waiting for the lagging source, an
// inactive source, and clipping — on synthetic mono and stereo frames.

@Test func sumsTwoSourcesFrameByFrameAndAdvancesTheCursor() {
    var m = AudioMixer(channels: 1, sources: [.microphone, .computer])
    m.push(.microphone, frames: [0.1, 0.2, 0.3, 0.4], at: 100)
    m.push(.computer, frames: [0.5, 0.5, 0.5, 0.5], at: 100)
    let out = m.drain()
    #expect(out?.start == 100)
    #expect(out?.frames == [0.6, 0.7, 0.8, 0.9])
    #expect(m.drain() == nil)                     // nothing new yet
    m.push(.microphone, frames: [0.1], at: 104)
    m.push(.computer, frames: [0.1], at: 104)
    #expect(m.drain()?.start == 104)
}

@Test func waitsForTheLaggingSourceAndPadsItsGapWithSilence() {
    var m = AudioMixer(channels: 1, sources: [.microphone, .computer])
    m.push(.computer, frames: [1, 1, 1, 1, 1, 1], at: 0)
    #expect(m.drain() == nil)                     // the microphone hasn't delivered yet
    m.push(.microphone, frames: [0.5, 0.5], at: 2) // it started late: frames 0–1 are silence
    let out = m.drain()
    #expect(out?.start == 0)
    #expect(out?.frames == [1, 1, 1, 1])           // up to frame 4, where the mic ends
    m.push(.microphone, frames: [0.5, 0.5], at: 6) // a gap at 4–5 is silence
    #expect(m.drain()?.frames == [1, 1])
}

@Test func anInactiveSourceNoLongerHoldsTheMixBack() {
    var m = AudioMixer(channels: 1, sources: [.microphone, .computer])
    m.push(.computer, frames: [0.2, 0.2, 0.2], at: 10)
    #expect(m.drain() == nil)
    m.setInactive(.microphone)                     // unplugged
    #expect(m.drain()?.frames == [0.2, 0.2, 0.2])
    m.push(.microphone, frames: [9, 9], at: 13)    // late buffers from a dead source are ignored
    m.push(.computer, frames: [0.1], at: 13)
    #expect(m.drain()?.frames == [0.1])
}

@Test func clipsToUnityAndHandlesStereoInterleaving() {
    var m = AudioMixer(channels: 2, sources: [.microphone, .computer])
    m.push(.microphone, frames: [0.8, -0.8, 0.1, 0.1], at: 0)    // 2 frames × 2 channels
    m.push(.computer, frames: [0.5, -0.5, 0.1, 0.1], at: 0)
    #expect(m.drain()?.frames == [1, -1, 0.2, 0.2])
}

@Test func overlappingPushesKeepOnlyTheNewTailAndOldFramesAreDropped() {
    var m = AudioMixer(channels: 1, sources: [.computer])
    m.push(.computer, frames: [0.1, 0.2, 0.3], at: 0)
    m.push(.computer, frames: [0.3, 0.4], at: 2)       // frame 2 already delivered
    #expect(m.drain()?.frames == [0.1, 0.2, 0.3, 0.4])
    m.push(.computer, frames: [0.7], at: 1)            // behind the cursor: dropped
    #expect(m.drain() == nil)
}
