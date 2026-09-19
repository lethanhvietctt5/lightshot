import Foundation
import CoreGraphics
import ImageIO

/// Where a capture originated — recorded so the history view can label each item (and so a
/// later feature could filter by kind). Area/window/fullscreen map to the capture modes; a
/// file opened in the editor (LIG-16) is `.file`.
public enum CaptureSource: String, Codable, Equatable, Sendable {
    case fullscreen
    case area
    case window
    case file
}

/// One entry in the local capture history (stories 50–53): a screenshot the user took, with
/// enough to list it (thumbnail + when/how it was captured) and to re-open or reveal it.
///
/// A pure value type. `fileURL` points at the full-resolution image the store owns; `thumbnailURL`
/// at a small preview the store generated. Both live inside the store's directory — the store
/// resolves the absolute URLs, so a record is self-contained for the UI (reveal-in-Finder, reopen)
/// while the on-disk index stays portable (it persists filenames, not absolute paths).
public struct CaptureRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// When the capture was taken — the history view's sort key (newest first).
    public let timestamp: Date
    /// Which capture mode produced it.
    public let source: CaptureSource
    /// Native (Retina) pixel dimensions of the full-resolution image, so reopening rebuilds an
    /// exact `CapturedImage` without re-decoding to measure.
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// The full-resolution image on disk (reopen / reveal-in-Finder use this).
    public let fileURL: URL
    /// The small preview on disk (the history list shows this).
    public let thumbnailURL: URL

    public init(
        id: UUID,
        timestamp: Date,
        source: CaptureSource,
        pixelWidth: Int,
        pixelHeight: Int,
        fileURL: URL,
        thumbnailURL: URL
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileURL = fileURL
        self.thumbnailURL = thumbnailURL
    }
}

/// The local capture history (stories 50–54): records captures as they happen, lists them for the
/// history view, re-opens/removes them, and enforces a retention cap that trims the oldest.
///
/// Backed by files in a single directory plus a lightweight `index.json` — no cloud, no accounts
/// (a v1 guardrail). The store **owns** the bytes it writes (its own copy of each capture plus a
/// generated thumbnail), which is what lets retention-trim and `clear` delete files without ever
/// touching a file the user saved themselves. Retention persists in the index, so both the list and
/// the configured limit survive an app relaunch.
///
/// It uses Foundation + CoreGraphics/ImageIO only (the same screen-free, permission-free frameworks
/// `render` uses) and imports no AppKit/ScreenCaptureKit, so it is fully testable against a temp
/// directory.
public final class HistoryStore {
    /// Default number of captures kept when a store is first created (no persisted index yet).
    public static let defaultRetention = 50
    /// Longest edge of a generated thumbnail, in pixels.
    private static let thumbnailMaxPixelSize = 320

    private let directory: URL
    private let indexURL: URL
    private let fileManager: FileManager

    /// Entries oldest-first (append newest at the end); `all()` reverses to newest-first. Trimming
    /// the oldest is then a `removeFirst`.
    private var entries: [StoredEntry]

    /// The configured cap; adding past it trims the oldest. Never negative. Persisted in the index.
    public private(set) var retention: Int

    /// Opens (or creates) a history store rooted at `directory`. If an `index.json` already exists
    /// there its records **and** its persisted retention are loaded — the app relaunch case — and
    /// the `retention` argument is ignored; otherwise `retention` seeds a fresh store.
    public init(
        directory: URL,
        retention: Int = HistoryStore.defaultRetention,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.indexURL = directory.appendingPathComponent("index.json")

        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder().decode(StoredIndex.self, from: data) {
            self.entries = index.records
            self.retention = max(0, index.retention)
        } else {
            self.entries = []
            self.retention = max(0, retention)
        }
    }

    // MARK: - Reading

    /// Every recorded capture, **newest first** — the order the history view lists them.
    public func all() -> [CaptureRecord] {
        entries.reversed().map(record(from:))
    }

    /// Rebuilds the full-resolution `CapturedImage` for a record, for re-opening it in the editor
    /// (story 51). Reads the owned file from disk; the pixel dimensions come from the record, so the
    /// result is byte-for-byte the same value that would flow from a fresh capture. Returns `nil` if
    /// the file is missing or unreadable (e.g. deleted underneath us).
    public func capturedImage(for record: CaptureRecord) -> CapturedImage? {
        guard let data = try? Data(contentsOf: record.fileURL) else { return nil }
        return CapturedImage(pixelWidth: record.pixelWidth, pixelHeight: record.pixelHeight, data: data)
    }

    // MARK: - Recording & removing

    /// Records a capture as it happens (story 50): writes the store's own copy of the image plus a
    /// generated thumbnail, appends the entry, enforces retention (trimming the oldest), and
    /// persists the index. Returns the created record. Throws only if the bytes can't be written or
    /// the index can't be persisted — a caller in the capture flow should treat a failure as
    /// non-fatal (a capture the user can still see), not block the editor.
    @discardableResult
    public func add(_ image: CapturedImage, source: CaptureSource, at date: Date = Date()) throws -> CaptureRecord {
        try ensureDirectory()

        let id = UUID()
        let imageFile = "\(id.uuidString).png"
        let thumbnailFile = "\(id.uuidString)-thumb.png"

        try image.data.write(to: directory.appendingPathComponent(imageFile), options: .atomic)
        // Best-effort thumbnail: if the bytes don't decode, fall back to the full image so the list
        // still has something to show rather than a broken record.
        let thumbnail = makeThumbnail(from: image.data, maxPixelSize: Self.thumbnailMaxPixelSize) ?? image.data
        try thumbnail.write(to: directory.appendingPathComponent(thumbnailFile), options: .atomic)

        let entry = StoredEntry(
            id: id,
            timestamp: date,
            source: source,
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight,
            imageFile: imageFile,
            thumbnailFile: thumbnailFile
        )
        entries.append(entry)
        // Keep oldest-first even if records arrive with out-of-order timestamps, so trimming and
        // the newest-first listing stay correct.
        entries.sort { $0.timestamp < $1.timestamp }
        trim()
        try persist()
        return record(from: entry)
    }

    /// Deletes a single history item and its owned files (story 53). A record already gone is a
    /// no-op.
    public func remove(_ record: CaptureRecord) throws {
        guard let index = entries.firstIndex(where: { $0.id == record.id }) else { return }
        let entry = entries.remove(at: index)
        deleteFiles(for: entry)
        try persist()
    }

    /// Empties the history and deletes every owned file (story 54's clear-all).
    public func clear() throws {
        for entry in entries { deleteFiles(for: entry) }
        entries.removeAll()
        try persist()
    }

    /// Sets how many captures to keep and trims the oldest immediately if already over (story 54).
    /// Clamped to be non-negative and persisted, so the limit survives a relaunch.
    public func setRetention(_ value: Int) throws {
        retention = max(0, value)
        trim()
        try persist()
    }

    // MARK: - Internals

    /// Drops the oldest entries (and their files) beyond the retention cap.
    private func trim() {
        guard entries.count > retention else { return }
        let overflow = entries.count - retention
        for entry in entries.prefix(overflow) { deleteFiles(for: entry) }
        entries.removeFirst(overflow)
    }

    private func record(from entry: StoredEntry) -> CaptureRecord {
        CaptureRecord(
            id: entry.id,
            timestamp: entry.timestamp,
            source: entry.source,
            pixelWidth: entry.pixelWidth,
            pixelHeight: entry.pixelHeight,
            fileURL: directory.appendingPathComponent(entry.imageFile),
            thumbnailURL: directory.appendingPathComponent(entry.thumbnailFile)
        )
    }

    private func persist() throws {
        try ensureDirectory()
        let index = StoredIndex(retention: retention, records: entries)
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    private func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func deleteFiles(for entry: StoredEntry) {
        try? fileManager.removeItem(at: directory.appendingPathComponent(entry.imageFile))
        try? fileManager.removeItem(at: directory.appendingPathComponent(entry.thumbnailFile))
    }
}

// MARK: - Persistence

/// The on-disk index: retention plus every entry. Stores **filenames**, not absolute paths, so the
/// history directory can be relocated without breaking the index; the store resolves absolute URLs
/// when it hands out `CaptureRecord`s.
private struct StoredIndex: Codable {
    var retention: Int
    var records: [StoredEntry]
}

private struct StoredEntry: Codable {
    var id: UUID
    var timestamp: Date
    var source: CaptureSource
    var pixelWidth: Int
    var pixelHeight: Int
    var imageFile: String
    var thumbnailFile: String
}

/// Generates a small PNG preview from full-resolution image bytes, longest edge capped at
/// `maxPixelSize`. Uses ImageIO's thumbnail path (decodes only what it needs). Returns `nil` if the
/// bytes don't decode as an image, letting the caller fall back.
private func makeThumbnail(from data: Data, maxPixelSize: Int) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, thumbnail, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return out as Data
}
