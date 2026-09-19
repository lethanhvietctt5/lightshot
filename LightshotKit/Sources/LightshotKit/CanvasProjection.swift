import Foundation

/// Pure mapping between an editor's **view space** and the document's **image
/// pixel coordinates**, for an image shown aspect-fit (letter-boxed) in a view.
///
/// The editor stores no geometry of its own: every drag, click, and handle drag is
/// converted straight into image coordinates through this projection before it
/// becomes an `AnnotationDocument` command, and every element is projected back to
/// view space for drawing. Keeping the arithmetic here — pure `Double` math, no
/// SwiftUI — is what lets the "editor maps between view and image space" contract
/// (spec 0001, Key contracts) be verified without a running view.
public struct CanvasProjection: Equatable, Sendable {
    /// Uniform scale from image pixels to view points (`< 1` when shrunk to fit).
    public let scale: Double
    /// View-space location of image pixel `(0, 0)` — the letter-box inset.
    public let imageOrigin: Point

    /// Builds the aspect-fit projection of `imageSize` inside `viewSize`, centering
    /// the drawn image so the unused axis is split into equal margins.
    public init(imageSize: Size, viewSize: Size) {
        let sx = imageSize.width > 0 ? viewSize.width / imageSize.width : 1
        let sy = imageSize.height > 0 ? viewSize.height / imageSize.height : 1
        let s = min(sx, sy)
        scale = s
        imageOrigin = Point(
            x: (viewSize.width - imageSize.width * s) / 2,
            y: (viewSize.height - imageSize.height * s) / 2
        )
    }

    /// Maps an image-space point to view space.
    public func toView(_ p: Point) -> Point {
        Point(x: imageOrigin.x + p.x * scale, y: imageOrigin.y + p.y * scale)
    }

    /// Maps a view-space point back to image space. A degenerate zero scale (an
    /// unlaid-out view) maps everything to the origin rather than dividing by zero.
    public func toImage(_ p: Point) -> Point {
        guard scale > 0 else { return Point(x: 0, y: 0) }
        return Point(x: (p.x - imageOrigin.x) / scale, y: (p.y - imageOrigin.y) / scale)
    }

    /// Maps an image-space rect to view space (origin projected, extent scaled).
    public func toView(_ r: Rect) -> Rect {
        let o = toView(r.origin)
        return Rect(x: o.x, y: o.y, width: r.size.width * scale, height: r.size.height * scale)
    }

    /// Scales an image-space length (e.g. a radius or stroke width) to view space.
    public func toView(length: Double) -> Double { length * scale }
}
