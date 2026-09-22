import Testing
import Foundation
@testable import LightshotKit

// The muted-microphone warning rule (spec 0006, story 24), fed with meter readings.

@Test func warnsAfterThreeSilentSecondsAndClearsForGoodOnSound() {
    var d = MutedMicrophoneDetector()
    for _ in 0..<29 { d.observe(level: 0, over: 0.1) }
    #expect(!d.showsWarning)
    d.observe(level: 0.01, over: 0.1)          // 3.0 s of near-silence
    #expect(d.showsWarning)
    d.observe(level: 0.3, over: 0.1)           // the user spoke
    #expect(!d.showsWarning)
    for _ in 0..<100 { d.observe(level: 0, over: 0.1) }
    #expect(!d.showsWarning)                    // a later quiet stretch is not "muted"
}

@Test func soundBeforeTheDeadlineMeansNoWarning() {
    var d = MutedMicrophoneDetector()
    for _ in 0..<10 { d.observe(level: 0, over: 0.1) }
    d.observe(level: 0.5, over: 0.1)
    for _ in 0..<50 { d.observe(level: 0, over: 0.1) }
    #expect(!d.showsWarning)
}

@Test func pausedReadingsDoNotCountTowardsTheDeadline() {
    var d = MutedMicrophoneDetector(silentSeconds: 1)
    for _ in 0..<20 { d.observe(level: 0, over: 0.1, paused: true) }
    #expect(!d.showsWarning)
    for _ in 0..<10 { d.observe(level: 0, over: 0.1) }
    #expect(d.showsWarning)
}
