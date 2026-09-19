import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import LightshotKit

// Pure export helpers behind save / drag-out (stories 42–45): the `ImageFormat` value, filename
// pattern expansion, and the shared `encode(_:as:)` step. No AppKit / ScreenCaptureKit — the seam
// holds.

// MARK: - ImageFormat

@Suite struct ImageFormatTests {
    @Test func extensionsAndTypesMatchTheFormat() {
        #expect(ImageFormat.png.fileExtension == "png")
        #expect(ImageFormat.jpeg(quality: 0.5).fileExtension == "jpg")
        #expect(ImageFormat.png.utiIdentifier == "public.png")
        #expect(ImageFormat.jpeg(quality: 0.5).utiIdentifier == "public.jpeg")
    }

    @Test func clampingFactoryNormalizesQualityIntoRange() {
        #expect(ImageFormat.jpeg(clamping: 1.7) == .jpeg(quality: 1.0))
        #expect(ImageFormat.jpeg(clamping: -0.3) == .jpeg(quality: 0.0))
        #expect(ImageFormat.jpeg(clamping: 0.6) == .jpeg(quality: 0.6))
    }
}

// MARK: - Filename pattern

@Suite struct FilenameFormatterTests {
    /// A gregorian/UTC calendar and a fixed instant, so expansion is deterministic.
    private func fixture() -> (FilenameFormatter, Date) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 7, minute: 3, second: 9))!
        return (FilenameFormatter(pattern: "Screenshot %Y-%m-%d at %H.%M.%S", calendar: utc), date)
    }

    @Test func expandsTokensZeroPadded() {
        let (formatter, date) = fixture()
        #expect(formatter.filename(at: date) == "Screenshot 2026-09-05 at 07.03.09")
    }

    @Test func passesUnknownTokensAndLonePercentThrough() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        #expect(FilenameFormatter(pattern: "100%_shot_%q_%Y", calendar: utc).filename(at: date) == "100%_shot_%q_2026")
    }

    @Test func destinationURLJoinsLocationNameAndExtension() {
        let (formatter, date) = fixture()
        let dir = URL(fileURLWithPath: "/tmp/shots", isDirectory: true)
        let png = formatter.destinationURL(in: dir, format: .png, at: date)
        let jpg = formatter.destinationURL(in: dir, format: .jpeg(quality: 0.9), at: date)
        #expect(png.lastPathComponent == "Screenshot 2026-09-05 at 07.03.09.png")
        #expect(jpg.lastPathComponent == "Screenshot 2026-09-05 at 07.03.09.jpg")
        #expect(png.deletingLastPathComponent().path == "/tmp/shots")
    }
}

// MARK: - Encoding

@Suite struct EncodeTests {
    /// A tiny solid-color rendered image to encode.
    private func rendered() -> RenderedImage {
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return RenderedImage(pixelWidth: 8, pixelHeight: 8, data: out as Data)
    }

    @Test func pngEncodePassesTheRenderBytesThrough() {
        let image = rendered()
        #expect(encode(image, as: .png) == image.data)
    }

    @Test func jpegEncodeProducesDecodableJPEGBytes() {
        let image = rendered()
        let data = encode(image, as: .jpeg(quality: 0.7))
        #expect(!data.isEmpty)
        #expect(data != image.data)  // re-encoded, not the PNG bytes
        // The bytes are a real JPEG that decodes back to the same dimensions.
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        #expect(CGImageSourceGetType(source) == "public.jpeg" as CFString)
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        #expect(decoded.width == 8 && decoded.height == 8)
    }
}
