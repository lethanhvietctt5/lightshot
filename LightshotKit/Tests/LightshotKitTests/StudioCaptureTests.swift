import Testing
import Foundation
@testable import LightshotKit

// Studio takes (spec 0007, stories 1–4): input recorded on the take's own clock, and studio
// projects created, saved, loaded and listed on disk.

// MARK: - StudioInputRecorder

private func recorder() -> StudioInputRecorder {
    StudioInputRecorder(regionOrigin: Point(x: 100, y: 50), regionSize: Size(width: 800, height: 600))
}

@Test func eventsAreTimedFromTheFirstFrameInRegionPoints() {
    var r = recorder()
    r.start(at: 10)
    r.record(.pointer(.moved(Point(x: 150, y: 80))), at: 11.5)
    r.record(.pointer(.down(Point(x: 160, y: 90))), at: 12)
    let input = r.finish()
    #expect(input.regionSize == Size(width: 800, height: 600))
    #expect(input.samples.contains(TimedPoint(time: 1.5, point: Point(x: 50, y: 30))))
    #expect(input.clicks == [TimedPoint(time: 2, point: Point(x: 60, y: 40))])
    #expect(input.samples.last == TimedPoint(time: 2, point: Point(x: 60, y: 40)))   // a click is also where the pointer is
}

@Test func thePointerBeforeTheFirstFrameBecomesTheSampleAtZero() {
    var r = recorder()
    r.record(.pointer(.moved(Point(x: 500, y: 350))), at: 9)
    r.start(at: 10)
    #expect(r.finish().samples.first == TimedPoint(time: 0, point: Point(x: 400, y: 300)))
}

@Test func pausedTimeIsLeftOutAndEventsWhilePausedAreDropped() {
    var r = recorder()
    r.start(at: 0)
    r.record(.pointer(.moved(Point(x: 100, y: 50))), at: 1)
    r.pause(at: 2)
    r.record(.pointer(.down(Point(x: 300, y: 300))), at: 3)            // dropped
    r.record(.key(.keyDown(KeyPress(label: "a"))), at: 4)              // dropped
    r.resume(at: 7)                                                    // 5 s paused
    r.record(.key(.keyDown(KeyPress(label: "b"))), at: 8)
    let input = r.finish()
    #expect(input.clicks.isEmpty)
    #expect(input.keys == [TimedKeyEvent(time: 3, event: .keyDown(KeyPress(label: "b")))])
    #expect(r.sourceTime(at: 8) == 3)
    // The pointer moved while paused: its position at resume is re-sampled at the resume time.
    #expect(input.samples.contains(TimedPoint(time: 2, point: Point(x: 200, y: 250))))
}

@Test func nothingIsRecordedBeforeTheTakeStarts() {
    var r = recorder()
    r.record(.key(.keyDown(KeyPress(label: "x"))), at: 1)
    r.record(.pointer(.down(Point(x: 120, y: 60))), at: 1)
    r.start(at: 2)
    let input = r.finish()
    #expect(input.keys.isEmpty && input.clicks.isEmpty)
    #expect(r.sourceTime(at: 1) == nil)
}

// MARK: - StudioProjectStore

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("studio-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A fake studio take in scratch: screen + input (+ camera).
private func take(in directory: URL, camera: Bool = true) throws -> URL {
    let screen = directory.appendingPathComponent("take.mp4")
    try Data("screen".utf8).write(to: screen)
    let input = StudioInput(regionSize: Size(width: 10, height: 10), samples: [TimedPoint(time: 0, point: Point(x: 1, y: 2))])
    try JSONEncoder().encode(input).write(to: StudioTake.inputURL(forScreen: screen))
    if camera { try Data("camera".utf8).write(to: StudioTake.cameraURL(forScreen: screen)) }
    return screen
}

@Test func creatingAProjectMovesTheTakesFilesIntoItsFolder() throws {
    let scratch = tempDirectory()
    let store = StudioProjectStore(directory: tempDirectory())
    let screen = try take(in: scratch)
    let project = try store.create(fromTake: screen, name: "Demo")
    #expect(project.url.pathExtension == StudioProjectStore.folderExtension)
    #expect(project.name == "Demo")
    #expect(FileManager.default.fileExists(atPath: project.screenURL.path))
    #expect(project.cameraURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    #expect(!FileManager.default.fileExists(atPath: screen.path))                 // moved, not copied
    #expect(!FileManager.default.fileExists(atPath: StudioTake.inputURL(forScreen: screen).path))
    #expect(store.loadInput(project)?.samples.count == 1)
}

@Test func aTakeWithoutCameraOrInputStillMakesAProject() throws {
    let scratch = tempDirectory()
    let store = StudioProjectStore(directory: tempDirectory())
    let screen = scratch.appendingPathComponent("plain.mp4")
    try Data("screen".utf8).write(to: screen)
    let project = try store.create(fromTake: screen, name: "Plain")
    #expect(project.cameraURL == nil)
    #expect(store.loadInput(project) == nil)
}

@Test func twoProjectsWithTheSameNameGetDistinctFolders() throws {
    let scratch = tempDirectory()
    let store = StudioProjectStore(directory: tempDirectory())
    let a = try store.create(fromTake: try take(in: scratch), name: "Demo")
    let b = try store.create(fromTake: try take(in: scratch), name: "Demo")
    #expect(a.url != b.url)
}

@Test func editsAreSavedAndLoadedBack() throws {
    let store = StudioProjectStore(directory: tempDirectory())
    let project = try store.create(fromTake: try take(in: tempDirectory()), name: "Demo")
    #expect(store.loadEdits(project) == nil)
    var edits = StudioEdits(sourceDuration: 8, look: .studio)
    edits.canvas.padding = 0.2
    try store.save(edits, to: project)
    #expect(store.loadEdits(project) == edits)
}

@Test func recentProjectsAreNewestFirstAndReopenable() throws {
    let store = StudioProjectStore(directory: tempDirectory())
    let scratch = tempDirectory()
    let old = try store.create(fromTake: try take(in: scratch), name: "Old")
    let new = try store.create(fromTake: try take(in: scratch), name: "New")
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: old.url.path)
    let recent = store.recent(limit: 10)
    #expect(recent.map(\.url) == [new.url, old.url])
    #expect(store.recent(limit: 1).count == 1)
    #expect(store.open(new.url)?.screenURL == new.screenURL)
}

@Test func aTranscriptIsSavedAndLoadedWithTheProject() throws {
    let store = StudioProjectStore(directory: tempDirectory())
    let project = try store.create(fromTake: try take(in: tempDirectory()), name: "Talk")
    #expect(store.loadTranscript(project) == nil)
    let transcript = StudioTranscript(locale: "en-US", words: [TranscriptWord(text: "hello", start: 0.2, end: 0.6)])
    try store.save(transcript, to: project)
    #expect(store.loadTranscript(project) == transcript)
}
