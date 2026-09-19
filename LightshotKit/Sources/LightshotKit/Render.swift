import Foundation

/// The flattened output of `render` — base image plus (eventually) all annotations, rasterized.
///
/// Kept distinct from `CapturedImage` because a render is an *output* (what gets copied/saved),
/// whereas `CapturedImage` is the *input* that flows in from a capture or an opened file. Like the
/// input it carries native pixel dimensions and opaque encoded bytes, so the core avoids image
/// frameworks.
public struct RenderedImage: Equatable, Sendable {
    /// Native (Retina) pixel width of the flattened output.
    public var pixelWidth: Int
    /// Native (Retina) pixel height of the flattened output.
    public var pixelHeight: Int
    /// Encoded image bytes (PNG in v1).
    public var data: Data

    public init(pixelWidth: Int, pixelHeight: Int, data: Data) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.data = data
    }
}

/// Flatten a captured image into a `RenderedImage`.
///
/// This tracer-bullet version is **base-only**: with no annotations or crop yet, the output is the
/// base image at its native size. When `AnnotationDocument` lands, this widens to
/// `render(_ document:)` — a deterministic flatten of base + elements respecting crop and z-order.
/// Keeping it a free pure function preserves that contract: same input, same output, no OS reliance.
public func render(_ base: CapturedImage) -> RenderedImage {
    RenderedImage(pixelWidth: base.pixelWidth, pixelHeight: base.pixelHeight, data: base.data)
}
