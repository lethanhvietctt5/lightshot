import Testing
import Foundation
@testable import LightshotKit

// The pure recording state machine (spec 0006, R1). Every transition is driven with injected
// clock values — no timers, no OS — which is what makes the elapsed-time and illegal-transition
// rules testable in milliseconds.

private let url = URL(fileURLWithPath: "/tmp/take.mp4")
private let display = CaptureRegion.display(id: 1)

private func options(countdown: Int = 0) -> RecordingOptions {
    RecordingOptions(region: display, output: .video(.standard), countdownSeconds: countdown)
}

/// A session already recording since t=0 with no countdown.
private func recordingSession() throws -> RecordingSession {
    var s = RecordingSession()
    try s.start(options(), writingTo: url, at: 0)
    return s
}

// MARK: - Happy path

@Test func startWithoutCountdownGoesStraightToRecording() throws {
    let s = try recordingSession()
    #expect(s.state == .recording)
    #expect(s.options == options())
    #expect(s.outputURL == url)
    #expect(s.isActive)
}

@Test func startWithCountdownWaitsForBeginRecording() throws {
    var s = RecordingSession()
    try s.start(options(countdown: 3), writingTo: url, at: 0)
    #expect(s.state == .countdown)
    #expect(s.elapsed(at: 10) == 0)   // nothing recorded while counting down
    try s.beginRecording(at: 10)
    #expect(s.state == .recording)
    #expect(s.elapsed(at: 12) == 2)
}

@Test func stopThenFinishProducesTheFile() throws {
    var s = try recordingSession()
    #expect(try s.stop(at: 5) == .stopping)
    #expect(s.state == .stopping)
    #expect(s.elapsed(at: 100) == 5)  // the clock is frozen once stopping
    try s.finish(url)
    #expect(s.state == .finished(url))
    #expect(!s.isActive)
}

@Test func aFinishedOrFailedSessionCanStartAgain() throws {
    var s = try recordingSession()
    _ = try s.stop(at: 1)
    try s.finish(url)
    try s.start(options(), writingTo: url, at: 20)
    #expect(s.state == .recording)
    #expect(s.elapsed(at: 21) == 1)   // the previous take's time is gone

    try s.fail(.diskFull)
    #expect(s.state == .failed(.diskFull))
    try s.start(options(), writingTo: url, at: 30)
    #expect(s.state == .recording)
}

// MARK: - Elapsed time across pauses (story 13)

@Test func elapsedExcludesPausedIntervalsAcrossSeveralCycles() throws {
    var s = try recordingSession()
    try s.pause(at: 4)                 // 4 s recorded
    #expect(s.elapsed(at: 50) == 4)    // paused: clock does not advance
    try s.resume(at: 50)
    #expect(s.elapsed(at: 53) == 7)
    try s.pause(at: 53)
    try s.resume(at: 60)
    try s.pause(at: 62)                // 4 + 3 + 2
    #expect(s.elapsed(at: 999) == 9)
    #expect(try s.stop(at: 999) == .stopping)
    #expect(s.elapsed(at: 1000) == 9)  // stopping from paused banks nothing extra
}

@Test func elapsedNeverGoesNegativeWithAnEarlierClock() throws {
    var s = RecordingSession()
    try s.start(options(), writingTo: url, at: 10)
    #expect(s.elapsed(at: 5) == 0)
}

// MARK: - Restart and discard (story 14)

@Test func restartResetsTheClockAndReturnsThePartialFile() throws {
    var s = try recordingSession()
    try s.pause(at: 8)
    let partial = try s.restart(at: 20)
    #expect(partial == url)
    #expect(s.state == .recording)        // no countdown configured → straight back to recording
    #expect(s.elapsed(at: 23) == 3)       // the 8 s of the old take are gone
    #expect(s.options == options())       // same options
}

@Test func restartReentersTheCountdownWhenOneIsConfigured() throws {
    var s = RecordingSession()
    try s.start(options(countdown: 3), writingTo: url, at: 0)
    try s.beginRecording(at: 3)
    try s.restart(at: 10)
    #expect(s.state == .countdown)
    #expect(s.elapsed(at: 11) == 0)
}

@Test func discardEndsInIdleFromCountdownRecordingAndPaused() throws {
    for prepare in [
        { (s: inout RecordingSession) throws in try s.start(options(countdown: 3), writingTo: url, at: 0) },
        { (s: inout RecordingSession) throws in try s.start(options(), writingTo: url, at: 0) },
        { (s: inout RecordingSession) throws in try s.start(options(), writingTo: url, at: 0); try s.pause(at: 1) },
    ] {
        var s = RecordingSession()
        try prepare(&s)
        #expect(try s.discard() == url)
        #expect(s == RecordingSession())   // fully back to idle: no options, no URL, no time
    }
}

@Test func stopDuringCountdownBehavesLikeDiscard() throws {
    var s = RecordingSession()
    try s.start(options(countdown: 3), writingTo: url, at: 0)
    #expect(try s.stop(at: 1) == .discarded(partialFile: url))
    #expect(s.state == .idle)
}

// MARK: - Illegal transitions never mutate

@Test func illegalCommandsThrowAndLeaveTheSessionUnchanged() throws {
    var idle = RecordingSession()
    let idleAttempts: [(RecordingSession.Command, (inout RecordingSession) throws -> Void)] = [
        (.beginRecording, { try $0.beginRecording(at: 0) }),
        (.pause, { try $0.pause(at: 0) }),
        (.resume, { try $0.resume(at: 0) }),
        (.stop, { _ = try $0.stop(at: 0) }),
        (.finish, { try $0.finish(url) }),
        (.fail, { try $0.fail(.diskFull) }),
        (.restart, { _ = try $0.restart(at: 0) }),
        (.discard, { _ = try $0.discard() }),
    ]
    for (command, attempt) in idleAttempts {
        #expect(throws: RecordingSession.IllegalTransition(state: .idle, command: command)) {
            try attempt(&idle)
        }
        #expect(idle == RecordingSession())
    }

    var recording = try recordingSession()
    let before = recording
    #expect(throws: RecordingSession.IllegalTransition(state: .recording, command: .start)) {
        try recording.start(options(), writingTo: url, at: 1)
    }
    #expect(throws: RecordingSession.IllegalTransition(state: .recording, command: .resume)) {
        try recording.resume(at: 1)
    }
    #expect(throws: RecordingSession.IllegalTransition(state: .recording, command: .finish)) {
        try recording.finish(url)
    }
    #expect(recording == before)

    var paused = try recordingSession()
    try paused.pause(at: 1)
    #expect(throws: RecordingSession.IllegalTransition(state: .paused, command: .pause)) {
        try paused.pause(at: 2)
    }

    var stopping = try recordingSession()
    _ = try stopping.stop(at: 1)
    for (command, attempt) in [
        (RecordingSession.Command.restart, { (s: inout RecordingSession) throws in _ = try s.restart(at: 2) }),
        (.discard, { (s: inout RecordingSession) throws in _ = try s.discard() }),
        (.pause, { (s: inout RecordingSession) throws in try s.pause(at: 2) }),
    ] {
        #expect(throws: RecordingSession.IllegalTransition(state: .stopping, command: command)) {
            try attempt(&stopping)
        }
        #expect(stopping.state == .stopping)
    }
}

@Test func failIsLegalFromEveryActiveStateOnly() throws {
    var s = RecordingSession()
    try s.start(options(countdown: 2), writingTo: url, at: 0)
    try s.fail(.noDisplayAvailable)
    #expect(s.state == .failed(.noDisplayAvailable))
    #expect(throws: RecordingSession.IllegalTransition(state: .failed(.noDisplayAvailable), command: .fail)) {
        try s.fail(.diskFull)
    }

    var stopping = try recordingSession()
    _ = try stopping.stop(at: 3)
    try stopping.fail(.systemFailure("writer"))
    #expect(stopping.state == .failed(.systemFailure("writer")))
    #expect(stopping.elapsed(at: 9) == 3)   // kept for diagnostics
}
