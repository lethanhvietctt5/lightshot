import AppKit
import LightshotKit

/// `NSPasteboard`-backed `ImageSink` (the OS side of the output seam).
///
/// Writes the rendered PNG bytes to the general pasteboard as an image, so a paste into chat or a
/// doc yields the flattened result. A thin wrapper — the coordinator's copy step is what tests
/// verify (against a fake sink); this just performs the AppKit write.
final class PasteboardImageSink: ImageSink {
    func copyToClipboard(_ image: RenderedImage) {
        guard let nsImage = NSImage(data: image.data) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }
}
