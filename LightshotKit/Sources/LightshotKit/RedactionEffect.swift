import Foundation
import CoreGraphics
import CoreImage

// The blur / pixelate effect, as one code path shared by the export flatten (`render`) and
// the editor's live canvas preview — so the region you see while dragging is, pixel for
// pixel, the region that exports.
//
// Both styles first **scramble** the region (each coarse cell takes its color from a
// seeded-random neighbor), then pixelate enlarges the cells and blur runs a Gaussian over
// them. Scrambling makes the result harder to reverse, but it is still only visual
// obscuring: **neither style is secure redaction** — only `blackout` erases (see
// `RedactionStyle`).

/// The flattened pixels a redaction sits on: the base image plus every element beneath it,
/// in the document's visible frame. Costly to build, cheap to cut patches from — the editor
/// keeps one per redaction and re-cuts the patch as the region is dragged.
public struct RedactionBackdrop {
    let image: CGImage
    /// The image-space frame `image` covers (the crop rect, or the whole image).
    let frame: Rect

    /// The obscured pixels for a `blur` / `pixelate` redaction over `rect`, clipped to the
    /// frame. `nil` for `blackout` (an opaque fill needs no pixels) or an empty region.
    public func patch(_ rect: Rect, style: RedactionStyle, strength: Double, seed: UInt64) -> RedactionPatch? {
        guard style != .blackout else { return nil }

        // The flattened image shares image space's top-left origin (offset by the frame),
        // so cropping needs no y-flip.
        let s = rect.standardized
        let crop = CGRect(x: s.minX - frame.minX, y: s.minY - frame.minY, width: s.width, height: s.height)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !crop.isNull, crop.width >= 1, crop.height >= 1,
              let region = image.cropping(to: crop) else { return nil }

        let amount = min(max(strength, 0), 1)
        let obscured: CGImage?
        switch style {
        case .blackout:
            return nil
        case .pixelate:
            let block = Self.pixelateBlocks.lowerBound + amount * (Self.pixelateBlocks.upperBound - Self.pixelateBlocks.lowerBound)
            obscured = scrambled(region, block: block, seed: seed)
        case .blur:
            let sigma = Self.blurSigmas.lowerBound + amount * (Self.blurSigmas.upperBound - Self.blurSigmas.lowerBound)
            obscured = scrambled(region, block: max(2, sigma / 2), seed: seed).flatMap { gaussianBlurred($0, sigma: sigma) }
        }
        guard let obscured else { return nil }
        return RedactionPatch(
            image: obscured,
            rect: Rect(x: crop.minX + frame.minX, y: crop.minY + frame.minY, width: crop.width, height: crop.height)
        )
    }

    /// Pixelate block edge, in image pixels, across the strength range.
    private static let pixelateBlocks: ClosedRange<Double> = 6...40
    /// Gaussian sigma, in image pixels, across the strength range.
    private static let blurSigmas: ClosedRange<Double> = 3...30
}

/// Obscured pixels plus the image-space rect they cover (the redaction clipped to the frame).
public struct RedactionPatch {
    public let image: CGImage
    public let rect: Rect
}

/// The backdrop for the redaction at `index` in the document's z-order: base image plus
/// the elements *beneath* it. Pass `document.elements.count` for a redaction still being
/// drawn (it will land on top of everything).
public func redactionBackdrop(_ document: AnnotationDocument, below index: Int) -> RedactionBackdrop? {
    let count = min(max(index, 0), document.elements.count)
    guard let image = flatten(document, elements: document.elements[..<count]) else { return nil }
    return RedactionBackdrop(image: image, frame: document.visibleFrame)
}

// MARK: - Effect

/// Averages `image` down to cells of roughly `block` pixels, swaps each cell's color for a
/// seeded-random neighbor's, and enlarges the cells back to the original size.
private func scrambled(_ image: CGImage, block: Double, seed: UInt64) -> CGImage? {
    let columns = max(1, Int((Double(image.width) / block).rounded(.up)))
    let rows = max(1, Int((Double(image.height) / block).rounded(.up)))
    guard let cells = bitmapContext(width: columns, height: rows) else { return nil }
    cells.interpolationQuality = .high
    cells.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))

    guard let data = cells.data else { return nil }
    let stride = cells.bytesPerRow
    let pixels = data.bindMemory(to: UInt8.self, capacity: stride * rows)
    let original = Array(UnsafeBufferPointer(start: pixels, count: stride * rows))
    var random = SplitMix64(state: seed)
    for y in 0..<rows {
        for x in 0..<columns {
            let sx = min(max(x + Int(random.next() % 3) - 1, 0), columns - 1)
            let sy = min(max(y + Int(random.next() % 3) - 1, 0), rows - 1)
            for channel in 0..<4 {
                pixels[y * stride + x * 4 + channel] = original[sy * stride + sx * 4 + channel]
            }
        }
    }

    guard let small = cells.makeImage(),
          let full = bitmapContext(width: image.width, height: image.height) else { return nil }
    full.interpolationQuality = .none
    full.draw(small, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return full.makeImage()
}

/// A Gaussian blur that samples clamped edges, so the region's border doesn't fade to
/// transparent. Runs on Core Image's software renderer without color management: slower
/// than the GPU, but the same bytes on every machine — `render` stays deterministic.
private func gaussianBlurred(_ image: CGImage, sigma: Double) -> CGImage? {
    let input = CIImage(cgImage: image)
    let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
    return blurContext.createCGImage(blurred, from: input.extent)
}

private let blurContext = CIContext(options: [
    .useSoftwareRenderer: true,
    .workingColorSpace: NSNull(),
    .outputColorSpace: NSNull(),
])

private func bitmapContext(width: Int, height: Int) -> CGContext? {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
}

/// A tiny seedable generator (SplitMix64) — `SystemRandomNumberGenerator` can't be seeded,
/// and the scramble must replay identically for a given element.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
