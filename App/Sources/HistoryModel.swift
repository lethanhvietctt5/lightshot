import SwiftUI
import AppKit
import LightshotKit

/// UI-facing state for the capture-history window (stories 50–54), kept out of the SwiftUI view so
/// the view is a thin projection.
///
/// Wraps the domain `HistoryStore` (which owns persistence, thumbnails, and retention) and exposes a
/// published snapshot the list renders. Reopen and copy need the editor / render pipeline, so they
/// delegate to closures the `AppController` wires; reveal-in-Finder and the store mutations
/// (delete / clear / set-retention) live here because they are plain AppKit / store calls.
@MainActor
@Observable
final class HistoryModel {
    private let store: HistoryStore
    private let onReopen: (CapturedImage) -> Void
    private let onCopy: (CapturedImage) -> Void

    /// The current history, newest first — refreshed after every mutation.
    private(set) var records: [CaptureRecord]
    /// The retention cap, bound to the stepper. Setting it trims and persists through the store.
    var retention: Int {
        didSet {
            guard retention != oldValue else { return }
            try? store.setRetention(retention)
            records = store.all()
        }
    }

    init(
        store: HistoryStore,
        onReopen: @escaping (CapturedImage) -> Void,
        onCopy: @escaping (CapturedImage) -> Void
    ) {
        self.store = store
        self.onReopen = onReopen
        self.onCopy = onCopy
        self.records = store.all()
        self.retention = store.retention
    }

    /// Pull a fresh snapshot from the store — call when the window reappears, since captures can be
    /// recorded while it is closed.
    func refresh() {
        records = store.all()
        retention = store.retention
    }

    /// Re-open a history item in the editor to annotate or re-export it (story 51).
    func reopen(_ record: CaptureRecord) {
        guard let image = store.capturedImage(for: record) else { return }
        onReopen(image)
    }

    /// Copy a history item to the clipboard, ready to paste (story 52).
    func copy(_ record: CaptureRecord) {
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
