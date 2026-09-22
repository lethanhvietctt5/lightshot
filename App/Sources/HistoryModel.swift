import SwiftUI
import AppKit
import LightshotKit

/// UI-facing state for the capture-history window (stories 50–54), kept out of the SwiftUI view so
/// the view is a thin projection.
///
/// Wraps the domain `HistoryStore` (which owns persistence and thumbnails) and exposes a published
/// snapshot the list renders. Reopen and copy need the editor / render pipeline, so they delegate to
/// closures the `AppController` wires; reveal-in-Finder and the store mutations (delete / clear) live
/// here because they are plain AppKit / store calls. Retention is *not* here — that value is owned by
/// `SettingsStore` and edited in the settings window (story 54/60); the store just enforces it.
@MainActor
@Observable
final class HistoryModel {
    private let store: HistoryStore
    private let onReopen: (CapturedImage) -> Void
    private let onCopy: (CapturedImage) -> Void
    /// A recording reopens by kind through the coordinator (spec 0006, story 39): a video in the
    /// video editor, a GIF in the post-recording overlay.
    private let onReopenRecording: (CaptureRecord) -> Void

    /// The current history, newest first — refreshed after every mutation.
    private(set) var records: [CaptureRecord]

    init(
        store: HistoryStore,
        onReopen: @escaping (CapturedImage) -> Void,
        onCopy: @escaping (CapturedImage) -> Void,
        onReopenRecording: @escaping (CaptureRecord) -> Void = { _ in }
    ) {
        self.store = store
        self.onReopen = onReopen
        self.onCopy = onCopy
        self.onReopenRecording = onReopenRecording
        self.records = store.all()
    }

    /// Pull a fresh snapshot from the store — call when the window reappears, since captures can be
    /// recorded while it is closed.
    func refresh() {
        records = store.all()
    }

    /// Re-open a history item (story 51): a screenshot in the annotation editor, a recording by
    /// its kind (spec 0006, story 39).
    func reopen(_ record: CaptureRecord) {
        guard record.kind == .screenshot else {
            onReopenRecording(record)
            return
        }
        guard let image = store.capturedImage(for: record) else { return }
        onReopen(image)
    }

    /// Copy a history item to the clipboard, ready to paste (story 52): a screenshot as an image,
    /// a recording as its file.
    func copy(_ record: CaptureRecord) {
        guard record.kind == .screenshot else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([record.fileURL as NSURL])
            return
        }
        guard let image = store.capturedImage(for: record) else { return }
        onCopy(image)
    }

    /// Reveal a history item's file in Finder (story 52).
    func reveal(_ record: CaptureRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.fileURL])
    }

    /// Delete a single history item (story 53).
    func delete(_ record: CaptureRecord) {
        try? store.remove(record)
        records = store.all()
    }

    /// Empty the entire history (story 54).
    func clearAll() {
        try? store.clear()
        records = store.all()
    }
}
