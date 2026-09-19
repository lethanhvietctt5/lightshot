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
