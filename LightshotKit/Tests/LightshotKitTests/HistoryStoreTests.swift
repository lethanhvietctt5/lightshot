import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import LightshotKit

// Behavior of `HistoryStore` — the local-history persistence seam (stories 50–54). Everything runs
// against a throwaway temp directory with **no AppKit / ScreenCaptureKit imports**; CoreGraphics /
// ImageIO only build the PNG fixtures, mirroring the render tests, so the seam still holds.

// MARK: - Fixtures

/// A temp directory that deletes itself when the test is done, so each case is isolated on disk.
private final class TempDir {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A solid-color PNG `CapturedImage`, so thumbnail generation exercises the real ImageIO path.
private func solidImage(width: Int = 40, height: Int = 30, rgb: (Double, Double, Double) = (1, 0, 0)) -> CapturedImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let cgImage = context.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cgImage, nil)
    CGImageDestinationFinalize(dest)
    return CapturedImage(pixelWidth: width, pixelHeight: height, data: data as Data)
}

/// Distinct, increasing instants so ordering is unambiguous.
private func instant(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: 1_000_000 + offset)
}

// MARK: - Recording & listing

@Test func addRecordsCapturesAndListsThemNewestFirst() throws {
    let dir = TempDir()
    let store = HistoryStore(directory: dir.url)

    let first = try store.add(solidImage(), source: .fullscreen, at: instant(0))
    let second = try store.add(solidImage(), source: .area, at: instant(10))
    let third = try store.add(solidImage(), source: .window, at: instant(20))

    let all = store.all()
    #expect(all.map(\.id) == [third.id, second.id, first.id])   // newest first
    #expect(all.map(\.source) == [.window, .area, .fullscreen])
}

@Test func addWritesTheImageAndAThumbnailToDisk() throws {
    let dir = TempDir()
    let store = HistoryStore(directory: dir.url)

    let record = try store.add(solidImage(width: 64, height: 48), source: .fullscreen)

    #expect(FileManager.default.fileExists(atPath: record.fileURL.path))
    #expect(FileManager.default.fileExists(atPath: record.thumbnailURL.path))
    #expect(record.pixelWidth == 64)
    #expect(record.pixelHeight == 48)
    // The thumbnail is a real, decodable image (not the record's placeholder bytes).
    let source = CGImageSourceCreateWithData(try Data(contentsOf: record.thumbnailURL) as CFData, nil)
    #expect(source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil)
}

@Test func capturedImageReopensWithOriginalBytesAndDimensions() throws {
    let dir = TempDir()
    let store = HistoryStore(directory: dir.url)
    let image = solidImage(width: 50, height: 20)

    let record = try store.add(image, source: .fullscreen)
    let reopened = store.capturedImage(for: record)

    #expect(reopened == image)   // byte-for-byte the same value a fresh capture would yield
}

// MARK: - Removing

@Test func removeDeletesTheItemAndItsFiles() throws {
    let dir = TempDir()
    let store = HistoryStore(directory: dir.url)
    let keep = try store.add(solidImage(), source: .fullscreen, at: instant(0))
    let drop = try store.add(solidImage(), source: .area, at: instant(10))

    try store.remove(drop)

    #expect(store.all().map(\.id) == [keep.id])
    #expect(!FileManager.default.fileExists(atPath: drop.fileURL.path))
    #expect(!FileManager.default.fileExists(atPath: drop.thumbnailURL.path))
    #expect(FileManager.default.fileExists(atPath: keep.fileURL.path))
}

@Test func clearEmptiesHistoryAndDeletesEveryFile() throws {
    let dir = TempDir()
    let store = HistoryStore(directory: dir.url)
    let a = try store.add(solidImage(), source: .fullscreen, at: instant(0))
    let b = try store.add(solidImage(), source: .area, at: instant(10))

    try store.clear()

    #expect(store.all().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: a.fileURL.path))
    #expect(!FileManager.default.fileExists(atPath: b.thumbnailURL.path))
}

// MARK: - Retention (story 54)

@Test func retentionTrimsOldestBeyondTheLimit() throws {
    let dir = TempDir()
    let store = HistoryStore(directory: dir.url, retention: 2)

    let oldest = try store.add(solidImage(), source: .fullscreen, at: instant(0))
    let middle = try store.add(solidImage(), source: .area, at: instant(10))
    let newest = try store.add(solidImage(), source: .window, at: instant(20))

    #expect(store.all().map(\.id) == [newest.id, middle.id])   // oldest trimmed
    #expect(!FileManager.default.fileExists(atPath: oldest.fileURL.path))
    #expect(!FileManager.default.fileExists(atPath: oldest.thumbnailURL.path))
}

@Test func setRetentionTrimsImmediatelyWhenLoweredBelowCount() throws {
    let dir = TempDir()
    let store = HistoryStore(directory: dir.url, retention: 10)
    let a = try store.add(solidImage(), source: .fullscreen, at: instant(0))
    let b = try store.add(solidImage(), source: .area, at: instant(10))
    let c = try store.add(solidImage(), source: .window, at: instant(20))

    try store.setRetention(1)

    #expect(store.retention == 1)
    #expect(store.all().map(\.id) == [c.id])
    #expect(!FileManager.default.fileExists(atPath: a.fileURL.path))
    #expect(!FileManager.default.fileExists(atPath: b.fileURL.path))
}

// MARK: - Persistence across relaunch (story 54)

@Test func recordsSurviveAReloadAndTheCallerSuppliesRetention() throws {
    let dir = TempDir()
    do {
        let store = HistoryStore(directory: dir.url, retention: 10)
        _ = try store.add(solidImage(), source: .fullscreen, at: instant(0))
        _ = try store.add(solidImage(), source: .area, at: instant(10))
        _ = try store.add(solidImage(), source: .window, at: instant(20))
    }

    // A brand-new store over the same directory — the app-relaunch case. Retention is supplied by
    // the caller (SettingsStore owns/persists it), not read back from the index; loaded records are
    // kept as-is until the cap is enforced.
    let reloaded = HistoryStore(directory: dir.url, retention: 2)

    #expect(reloaded.retention == 2)                                     // the seed the caller passed
    #expect(reloaded.all().map(\.source) == [.window, .area, .fullscreen])  // records survived intact
    #expect(reloaded.capturedImage(for: reloaded.all()[0]) != nil)       // still readable on disk

    // Enforcing the cap trims the oldest, exactly as the app does at launch via setRetention.
    try reloaded.setRetention(2)
    #expect(reloaded.all().map(\.source) == [.window, .area])
}


// MARK: - Recordings (spec 0006, story 39)

/// A two-frame GIF fixture with known delays, built with ImageIO.
private func gifFixture(in dir: TempDir, width: Int = 60, height: Int = 40, delays: [Double] = [0.1, 0.25]) -> URL {
    let url = dir.url.appendingPathComponent("take.gif")
    try? FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, delays.count, nil)!
    for (i, delay) in delays.enumerated() {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: i == 0 ? 1 : 0, green: 0, blue: i == 0 ? 0 : 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        CGImageDestinationAddImage(destination, context.makeImage()!, properties)
    }
    CGImageDestinationFinalize(destination)
    return url
}

private func movieFixture(in dir: TempDir, bytes: [UInt8] = [0, 1, 2, 3]) -> URL {
    try? FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
    let url = dir.url.appendingPathComponent("take.mp4")
    try! Data(bytes).write(to: url)
    return url
}

@Test func addMediaMovesTheFileInKeepsItsExtensionAndRecordsWhatTheCallerKnows() throws {
    let dir = TempDir()
    let store = HistoryStore(directory: dir.url.appendingPathComponent("history"))
    let take = movieFixture(in: dir)
    let thumbnail = solidImage(width: 8, height: 6).data
    let record = try store.add(mediaAt: take, kind: .video, pixelWidth: 1920, pixelHeight: 1080, duration: 12.5, thumbnail: thumbnail, source: .recording, at: instant(1))

    #expect(!FileManager.default.fileExists(atPath: take.path))              // moved, not copied
    #expect(record.fileURL.pathExtension == "mp4" && FileManager.default.fileExists(atPath: record.fileURL.path))
    #expect(record.kind == .video && record.duration == 12.5 && record.source == .recording)
    #expect(record.pixelWidth == 1920 && record.pixelHeight == 1080)
    #expect(try Data(contentsOf: record.thumbnailURL) == thumbnail)         // served back as supplied
    #expect(store.capturedImage(for: record) == nil)                         // not an image
    #expect(store.all().map(\.id) == [record.id])
}

@Test func addGIFReadsDimensionsThumbnailAndDurationThroughImageIO() throws {
    let dir = TempDir()
    let store = HistoryStore(directory: dir.url.appendingPathComponent("history"))
    let gif = gifFixture(in: dir)
    let record = try store.addGIF(at: gif, source: .recording)
    #expect(record.kind == .gif)
    #expect(record.pixelWidth == 60 && record.pixelHeight == 40)
    #expect(abs((record.duration ?? 0) - 0.35) < 0.001)
    #expect(record.fileURL.pathExtension == "gif" && !FileManager.default.fileExists(atPath: gif.path))
    // Frame 0 is red: the thumbnail decodes to that size and colour.
    let thumbnailData = try Data(contentsOf: record.thumbnailURL)
    let source = CGImageSourceCreateWithData(thumbnailData as CFData, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    #expect(image.width == 60 && image.height == 40)
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let pixel = context.data!.assumingMemoryBound(to: UInt8.self)
    #expect(pixel[0] > 200 && pixel[2] < 50)
    #expect(store.capturedImage(for: record) == nil)

    let notAGIF = movieFixture(in: dir)
    #expect(throws: HistoryError.unreadableMedia(notAGIF)) { try store.addGIF(at: notAGIF, source: .recording) }
    #expect(FileManager.default.fileExists(atPath: notAGIF.path))            // left where it was
}

@Test func removeClearAndRetentionDeleteRecordingsExactlyLikeScreenshots() throws {
    let dir = TempDir()
    let store = HistoryStore(directory: dir.url.appendingPathComponent("history"), retention: 2)
    let video = try store.add(mediaAt: movieFixture(in: dir), kind: .video, pixelWidth: 10, pixelHeight: 10, duration: 1, thumbnail: solidImage().data, source: .recording, at: instant(1))
    let shot = try store.add(solidImage(), source: .area, at: instant(2))
    let gif = try store.addGIF(at: gifFixture(in: dir), source: .recording, at: instant(3))   // retention 2: the video goes
    #expect(store.all().map(\.id) == [gif.id, shot.id])
    #expect(!FileManager.default.fileExists(atPath: video.fileURL.path) && !FileManager.default.fileExists(atPath: video.thumbnailURL.path))

    try store.remove(gif)
    #expect(!FileManager.default.fileExists(atPath: gif.fileURL.path) && !FileManager.default.fileExists(atPath: gif.thumbnailURL.path))
    #expect(store.record(id: gif.id) == nil && store.record(id: shot.id) != nil)
    try store.clear()
    #expect(store.all().isEmpty && !FileManager.default.fileExists(atPath: shot.fileURL.path))
}

@Test func aPre0006IndexDecodesEveryRecordAsAScreenshot() throws {
    let dir = TempDir()
    let history = dir.url.appendingPathComponent("history")
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    let id = UUID()
    let index = """
    {"records":[{"id":"\(id.uuidString)","timestamp":700000000,"source":"area","pixelWidth":40,"pixelHeight":30,"imageFile":"a.png","thumbnailFile":"a-thumb.png"}]}
    """
    try index.write(to: history.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
    try solidImage().data.write(to: history.appendingPathComponent("a.png"))
    let store = HistoryStore(directory: history)
    let records = store.all()
    #expect(records.count == 1)
    #expect(records[0].id == id && records[0].kind == .screenshot && records[0].duration == nil)
    #expect(store.capturedImage(for: records[0])?.pixelWidth == 40)
    // Once re-persisted, the new fields are present and the old ones untouched.
    try store.setRetention(10)
    let reloaded = HistoryStore(directory: history).all()
    #expect(reloaded.first?.kind == .screenshot && reloaded.first?.fileURL.lastPathComponent == "a.png")
}

@Test func addMediaRefusesWhenRetentionIsOffAndRollsBackAFailedIndexWrite() throws {
    let dir = TempDir()
    let off = HistoryStore(directory: dir.url.appendingPathComponent("history"), retention: 0)
    let take = movieFixture(in: dir)
    #expect(throws: HistoryError.historyOff) {
        try off.add(mediaAt: take, kind: .video, pixelWidth: 1, pixelHeight: 1, duration: 1, thumbnail: solidImage().data, source: .recording)
    }
    #expect(FileManager.default.fileExists(atPath: take.path))              // left where it was

    // The index cannot be written (its path is a directory): the file comes back, no record.
    let blocked = dir.url.appendingPathComponent("blocked")
    try FileManager.default.createDirectory(at: blocked.appendingPathComponent("index.json"), withIntermediateDirectories: true)
    let store = HistoryStore(directory: blocked)
    #expect(throws: (any Error).self) {
        try store.add(mediaAt: take, kind: .video, pixelWidth: 1, pixelHeight: 1, duration: 1, thumbnail: solidImage().data, source: .recording)
    }
    #expect(FileManager.default.fileExists(atPath: take.path))
    #expect(store.all().isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: blocked.path).filter { $0.hasSuffix("-thumb.png") }.isEmpty)
}

@Test func aTakesInputSidecarMovesInWithItAndIsDeletedWithIt() throws {
    let dir = TempDir()
    let store = HistoryStore(directory: dir.url.appendingPathComponent("history"))
    let take = movieFixture(in: dir)
    try Data("{}".utf8).write(to: StudioTake.inputURL(forScreen: take))
    let record = try store.add(mediaAt: take, kind: .video, pixelWidth: 10, pixelHeight: 10, duration: 1, thumbnail: solidImage().data, source: .recording)
    let sidecar = StudioTake.inputURL(forScreen: record.fileURL)
    #expect(FileManager.default.fileExists(atPath: sidecar.path))
    #expect(!FileManager.default.fileExists(atPath: StudioTake.inputURL(forScreen: take).path))
    try store.remove(record)
    #expect(!FileManager.default.fileExists(atPath: sidecar.path))
}
