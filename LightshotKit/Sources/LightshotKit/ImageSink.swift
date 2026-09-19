import Foundation

/// The output seam: where a `RenderedImage` goes once the user is done.
///
/// Fronted as a protocol so clipboard/disk stay out of the render tests — a fake captures the
/// calls, the real implementation (app target) uses `NSPasteboard` / file APIs. `copyToClipboard`
/// serves stories 40/44; `write(_:to:format:)` adds disk save (stories 41–42, 44). The drag-out
/// path (story 45) is produced as an `ImageDragItem` by `AppCoordinator`, not the sink, because a
/// drag payload is a document→bytes transform (like copy and save) and stays framework-free here.
public protocol ImageSink {
    /// Place the rendered image on the system clipboard.
    func copyToClipboard(_ image: RenderedImage)

    /// Write the rendered image to disk at `url`, encoded as `format` (stories 41–42, 44).
    ///
    /// The exact `ImageFormat` — including `jpeg(quality:)` — flows through unchanged, which is what
    /// the fake sink asserts in tests: the editor's chosen setting reaches the encoder untouched.
    /// Throws if the bytes cannot be written.
    func write(_ image: RenderedImage, to url: URL, format: ImageFormat) throws
}

/// A ready-to-drag payload for the editor's drag-out (story 45): the encoded bytes, the format that
/// produced them (its `utiIdentifier` names the pasteboard type), and a suggested filename for the
/// receiving app — the extension is supplied by the type, so this base name carries none.
///
/// Kept a plain value type so the drag path is produced and asserted in the framework-free core;
/// the app wraps it in an `NSItemProvider` for SwiftUI's `.onDrag`.
public struct ImageDragItem: Equatable, Sendable {
    /// Encoded image bytes in `format`.
    public var data: Data
    /// The format the bytes are encoded as.
    public var format: ImageFormat
    /// Base filename (no extension) offered to the receiving app.
    public var suggestedName: String

    public init(data: Data, format: ImageFormat, suggestedName: String) {
        self.data = data
        self.format = format
        self.suggestedName = suggestedName
    }
}
