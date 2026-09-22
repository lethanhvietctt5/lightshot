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
    /// A screen recording (spec 0006, story 39).
    case recording
}

/// What a history entry holds (spec 0006, story 39): a screenshot, a video, or a GIF.
public enum CaptureKind: String, Codable, Equatable, Sendable {
    case screenshot
    case video
    case gif
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
    /// Screenshot, video or GIF (spec 0006, story 39); decides how it reopens.
    public let kind: CaptureKind
    /// Native (Retina) pixel dimensions of the full-resolution media — for a screenshot, so that
    /// reopening rebuilds an exact `CapturedImage` without re-decoding; for a recording, the
    /// frame size read from the asset itself, never from the thumbnail.
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// The recording's length; `nil` for a screenshot.
    public let duration: TimeInterval?
    /// The full-resolution media on disk (reopen / reveal-in-Finder use this).
    public let fileURL: URL
    /// The small preview on disk (the history list shows this).
    public let thumbnailURL: URL

    public init(
        id: UUID,
        timestamp: Date,
        source: CaptureSource,
        kind: CaptureKind = .screenshot,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval? = nil,
        fileURL: URL,
        thumbnailURL: URL
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.kind = kind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
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

    /// The configured cap; adding past it trims the oldest. Never negative. The value is supplied by
    /// the caller (`SettingsStore` owns and persists it) — the store only enforces it.
    public private(set) var retention: Int

    /// Opens (or creates) a history store rooted at `directory`, loading any recorded captures from
    /// an existing `index.json` — the app-relaunch case. The `retention` value is **not** persisted
    /// here: `SettingsStore` owns it (LIG-15), and the app seeds the store from that setting and
    /// re-applies it via `setRetention`. Loaded records are kept as-is; they are trimmed to the cap
    /// on the next `add` or `setRetention`, so construction stays free of disk writes.
    public init(
        directory: URL,
        retention: Int = HistoryStore.defaultRetention,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.indexURL = directory.appendingPathComponent("index.json")
        self.retention = max(0, retention)

        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder().decode(StoredIndex.self, from: data) {
            self.entries = index.records
        } else {
            self.entries = []
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
        // A recording is not an image: it reopens by `fileURL` (video editor / overlay).
        guard record.kind == .screenshot, let data = try? Data(contentsOf: record.fileURL) else { return nil }
        return CapturedImage(pixelWidth: record.pixelWidth, pixelHeight: record.pixelHeight, data: data)
    }

    /// The record for an id, if it is still in history.
    public func record(id: UUID) -> CaptureRecord? {
        entries.first { $0.id == id }.map(record(from:))
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
            kind: .screenshot,
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight,
            duration: nil,
            imageFile: imageFile,
            thumbnailFile: thumbnailFile
        )
        return try append(entry)
    }

    /// Records a finished recording (spec 0006, story 39): **moves** the media file into the
    /// store (keeping its extension — a long take is never duplicated on disk) and writes the
    /// caller-supplied thumbnail. The dimensions and duration come from the caller too, because
    /// only the app can read a video's frame size and first frame (AVFoundation); for a GIF use
    /// `addGIF(at:source:at:)`, which reads them itself through ImageIO.
    @discardableResult
    public func add(
        mediaAt url: URL, kind: CaptureKind, pixelWidth: Int, pixelHeight: Int, duration: TimeInterval?,
        thumbnail: Data, source: CaptureSource, at date: Date = Date()
    ) throws -> CaptureRecord {
        try ensureDirectory()
        let id = UUID()
        let mediaFile = url.pathExtension.isEmpty ? id.uuidString : "\(id.uuidString).\(url.pathExtension)"
        let thumbnailFile = "\(id.uuidString)-thumb.png"
        try fileManager.moveItem(at: url, to: directory.appendingPathComponent(mediaFile))
        try thumbnail.write(to: directory.appendingPathComponent(thumbnailFile), options: .atomic)
        let entry = StoredEntry(
            id: id, timestamp: date, source: source, kind: kind,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: duration,
            imageFile: mediaFile, thumbnailFile: thumbnailFile
        )
        return try append(entry)
    }

    /// Records a GIF (story 39): dimensions from the file's properties, the thumbnail from frame
    /// 0, the duration as the sum of the frame delays — all through ImageIO, so the store needs
    /// nothing from the app. Throws if the file is not a readable GIF.
    @discardableResult
    public func addGIF(at url: URL, source: CaptureSource, at date: Date = Date()) throws -> CaptureRecord {
        guard let metadata = gifMetadata(at: url) else {
            throw HistoryError.unreadableMedia(url)
        }
        return try add(
            mediaAt: url, kind: .gif, pixelWidth: metadata.width, pixelHeight: metadata.height,
            duration: metadata.duration, thumbnail: metadata.thumbnail, source: source, at: date
        )
    }

    private func append(_ entry: StoredEntry) throws -> CaptureRecord {
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
            kind: entry.kind,
            pixelWidth: entry.pixelWidth,
            pixelHeight: entry.pixelHeight,
            duration: entry.duration,
            fileURL: directory.appendingPathComponent(entry.imageFile),
            thumbnailURL: directory.appendingPathComponent(entry.thumbnailFile)
        )
    }

    private func persist() throws {
        try ensureDirectory()
        let index = StoredIndex(records: entries)
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

/// The on-disk index: every recorded capture. Stores **filenames**, not absolute paths, so the
/// history directory can be relocated without breaking the index; the store resolves absolute URLs
/// when it hands out `CaptureRecord`s. Retention is deliberately not stored here — `SettingsStore`
/// owns and persists that value (LIG-15).
private struct StoredIndex: Codable {
    var records: [StoredEntry]
}

/// `imageFile` keeps its pre-0006 name in the index: for a recording it is the media file.
private struct StoredEntry: Codable {
    var id: UUID
    var timestamp: Date
    var source: CaptureSource
    var kind: CaptureKind
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: TimeInterval?
    var imageFile: String
    var thumbnailFile: String

    init(
        id: UUID, timestamp: Date, source: CaptureSource, kind: CaptureKind, pixelWidth: Int, pixelHeight: Int,
        duration: TimeInterval?, imageFile: String, thumbnailFile: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.kind = kind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.imageFile = imageFile
        self.thumbnailFile = thumbnailFile
    }

    /// An `index.json` written before spec 0006 has no `kind` / `duration`: every such record is
    /// a screenshot, so a pre-0006 history still loads in full (an explicit rule, not a hope).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        source = try c.decode(CaptureSource.self, forKey: .source)
        kind = try c.decodeIfPresent(CaptureKind.self, forKey: .kind) ?? .screenshot
        pixelWidth = try c.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decode(Int.self, forKey: .pixelHeight)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        imageFile = try c.decode(String.self, forKey: .imageFile)
        thumbnailFile = try c.decode(String.self, forKey: .thumbnailFile)
    }
}

public enum HistoryError: Error, Equatable {
    /// The file is not media the store can read (a GIF ImageIO cannot open).
    case unreadableMedia(URL)
}

/// A GIF's dimensions, first-frame thumbnail and total duration, through ImageIO.
private func gifMetadata(at url: URL) -> (width: Int, height: Int, duration: TimeInterval, thumbnail: Data)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    var duration: TimeInterval = 0
    for index in 0..<CGImageSourceGetCount(source) {
        let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? TimeInterval) ?? (gif?[kCGImagePropertyGIFDelayTime] as? TimeInterval) ?? 0
        duration += delay
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 320,
    ]
    guard let thumbnailImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, thumbnailImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return (width, height, duration, data as Data)
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
