import Foundation

/// The output seam: where a `RenderedImage` goes once the user is done.
///
/// Fronted as a protocol so clipboard/disk/drag stay out of the render tests — a fake captures the
/// calls, the real implementation (app target) uses `NSPasteboard` / file APIs. This tracer bullet
/// only needs `copyToClipboard` (stories 40/44); `write(_:to:format:)` and the drag provider join
/// as their tickets are picked up.
public protocol ImageSink {
    /// Place the rendered image on the system clipboard.
    func copyToClipboard(_ image: RenderedImage)
}
