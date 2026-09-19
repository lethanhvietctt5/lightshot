import AppKit
import LightshotKit

/// System `ImageSink` (the OS side of the output seam): clipboard via `NSPasteboard`, disk via a
/// file write.
///
/// `copyToClipboard` writes the rendered image to the general pasteboard, so a paste into chat or a
/// doc yields the flattened result. `write(_:to:format:)` runs the render bytes through the shared
/// `encode(_:as:)` and writes them to `url`, so the chosen `ImageFormat` — PNG or `jpeg(quality:)`
/// — is exactly what lands on disk. A thin wrapper: the coordinator's output steps are what tests
/// verify against a fake sink; this just performs the AppKit / file work.
final class SystemImageSink: ImageSink {
    func copyToClipboard(_ image: RenderedImage) {
        guard let nsImage = NSImage(data: image.data) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }

    func write(_ image: RenderedImage, to url: URL, format: ImageFormat) throws {
        try encode(image, as: format).write(to: url, options: .atomic)
    }
}
