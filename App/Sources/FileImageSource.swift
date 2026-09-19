import AppKit
import ImageIO
import UniformTypeIdentifiers
import LightshotKit

/// `NSOpenPanel` + ImageIO-backed `ImageSource` (the OS side of the open-existing-image seam).
///
/// A thin wrapper with no unit tests — it needs a real panel and filesystem; the coordinator
/// routing it feeds is tested against a fake. `openDocument()` runs a modal open panel restricted
/// to image types, then decodes the pick through the same `loadImage(from:)` path a known URL uses,
/// so cancellation and decode failures both surface as a typed `ImageLoadError` — never a blank
/// editor. The decoded pixels are re-encoded as PNG so the resulting `CapturedImage` matches the
/// PNG-bytes invariant a capture produces, keeping the editor entry point source-agnostic.
@MainActor
final class FileImageSource: ImageSource {
    func openDocument() -> Result<CapturedImage, ImageLoadError> {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.readableTypes

        WindowPresenter.activateApp()
        guard panel.runModal() == .OK, let url = panel.url else {
            // The user dismissed the panel — a silent no-op, not an error to surface.
            return .failure(.userCancelled)
        }
        return loadImage(from: url)
    }

    func loadImage(from url: URL) -> Result<CapturedImage, ImageLoadError> {
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.unreadable)
        }
        // Decode via ImageIO, then re-encode as PNG so downstream (`render`, the editor) always
        // sees the same PNG-bytes contract a capture yields, regardless of the source format.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let pngData = Self.pngData(from: image) else {
            return .failure(.unsupportedFormat)
        }
        return .success(
            CapturedImage(pixelWidth: image.width, pixelHeight: image.height, data: pngData)
        )
    }

    /// Image content types the panel offers — the common still formats ImageIO can decode.
    private static let readableTypes: [UTType] = [.png, .jpeg, .tiff, .gif, .bmp, .heic, .webP]

    private static func pngData(from image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
