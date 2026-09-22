import Testing
import Foundation
@testable import LightshotKit

// The studio editor's timeline geometry (LIG-43): time ↔ x, the ruler, the filmstrip.

@Test func timeAndPositionMapBothWaysClampedToTheClip() {
    let scale = TimelineScale(duration: 8, width: 800)
    #expect(scale.x(for: 4) == 400)
    #expect(scale.x(for: -1) == 0 && scale.x(for: 20) == 800)
    #expect(scale.time(at: 200) == 2)
    #expect(scale.time(at: -5) == 0 && scale.time(at: 900) == 8)
    // An empty clip or track maps everything to zero instead of dividing by it.
    #expect(TimelineScale(duration: 0, width: 800).x(for: 3) == 0)
    #expect(TimelineScale(duration: 8, width: 0).time(at: 3) == 0)
}

@Test func theRulerPicksTheFinestStepThatKeepsLabelsApart() {
    // 100 pt a second: every second fits.
    #expect(TimelineScale(duration: 8, width: 800).tickStep() == 1)
    #expect(TimelineScale(duration: 8, width: 800).ticks() == [0, 1, 2, 3, 4, 5, 6, 7, 8])
    // 10 pt a second: 10 s is the first step 72 pt wide.
    #expect(TimelineScale(duration: 60, width: 600).tickStep() == 10)
    // Zooming in (a wider track) refines the step.
    #expect(TimelineScale(duration: 60, width: 4_800).tickStep() == 1)
    // A very long clip on a narrow track stops at the coarsest step.
    #expect(TimelineScale(duration: 36_000, width: 100).tickStep() == 3_600)
}

@Test func labelsReadAsMinutesAndSecondsAndHoursPastAnHour() {
    #expect(TimelineScale.label(4.9) == "00:04")
    #expect(TimelineScale.label(75) == "01:15")
    #expect(TimelineScale.label(3_723) == "1:02:03")
    #expect(TimelineScale.label(-2) == "00:00")
}

@Test func filmstripSlotsTakeTheNearestFrameAndRepeatWhenThereAreMoreSlots() {
    #expect(TimelineScale.filmstripFrames(slots: 4, frames: 40) == [5, 15, 25, 35])
    #expect(TimelineScale.filmstripFrames(slots: 4, frames: 2) == [0, 0, 1, 1])
    #expect(TimelineScale.filmstripFrames(slots: 0, frames: 10).isEmpty)
    #expect(TimelineScale.filmstripFrames(slots: 3, frames: 0).isEmpty)
}
