import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// The flattened output of `render` — base image plus all annotations, rasterized.
///
/// Kept distinct from `CapturedImage` because a render is an *output* (what gets copied/saved),
/// whereas `CapturedImage` is the *input* that flows in from a capture or an opened file. Like the
/// input it carries native pixel dimensions and opaque encoded bytes, so the core avoids image
/// frameworks in its public surface.
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

/// Flatten an annotated document into a `RenderedImage` — the deterministic export
/// path (story 44): base image plus every element, drawn in z-order, cropped to the
/// visible frame. This is the single render seam the spec places in the domain core.
///
/// It uses **CoreGraphics / CoreText / ImageIO** — pure, screen-free, permission-free C
/// frameworks — and imports **no AppKit or ScreenCaptureKit**, so the pixel-level
/// assertions in the test suite run without a display. Element geometry arrives in image
/// pixel coordinates (top-left origin, y down); the context is set up bottom-left/y-up, so
/// every coordinate is mapped through `contextPoint` / `contextRect` rather than flipping
/// the whole context (which would mirror the base image and the text).
///
/// An empty document with no crop flattens to the base image at its native size — the
/// behavior the LIG-7 tracer bullet proved — but the bytes are re-encoded PNG, not the
/// original capture data verbatim.
public func render(_ document: AnnotationDocument) -> RenderedImage {
    let frame = document.visibleFrame
    let width = max(1, Int(frame.width.rounded()))
    let height = max(1, Int(frame.height.rounded()))

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        // A context this small should never fail to allocate; fall back to the raw
        // base bytes rather than crash, so `render` is total.
        return RenderedImage(pixelWidth: width, pixelHeight: height, data: document.baseImage.data)
    }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let flattener = Flattener(context: context, frame: frame, height: height)
    flattener.drawBase(document.baseImage)
    for element in document.elements {
        flattener.draw(element)
    }

    guard let image = context.makeImage() else {
        return RenderedImage(pixelWidth: width, pixelHeight: height, data: document.baseImage.data)
    }
    return RenderedImage(pixelWidth: width, pixelHeight: height, data: encodePNG(image))
}

/// Draws base + elements into a bottom-left/y-up CGContext, converting each
/// image-space coordinate into context space on the way in.
private struct Flattener {
    let context: CGContext
    /// The visible frame in image coordinates — the crop rect, or the whole image.
    let frame: Rect
    /// Output height in pixels, used to flip image-y (down) into context-y (up).
    let height: Int

    /// Maps an image-space point (top-left origin, y down) to context space
    /// (bottom-left origin, y up), offsetting by the crop frame.
    func contextPoint(_ p: Point) -> CGPoint {
        CGPoint(x: p.x - frame.minX, y: Double(height) - (p.y - frame.minY))
    }

    /// Maps an image-space rect to a context-space `CGRect` (origin at its
    /// bottom-left corner, as CoreGraphics expects).
    func contextRect(_ r: Rect) -> CGRect {
        let s = r.standardized
        return CGRect(
            x: s.minX - frame.minX,
            y: Double(height) - (s.minY - frame.minY) - s.height,
            width: s.width,
            height: s.height
        )
    }

    func drawBase(_ base: CapturedImage) {
        guard let cgImage = decodeImage(base.data) else { return }
        let imageRect = Rect(x: 0, y: 0, width: Double(base.pixelWidth), height: Double(base.pixelHeight))
        context.draw(cgImage, in: contextRect(imageRect))
    }

    func draw(_ element: AnnotationElement) {
        let style = element.style
        context.saveGState()
        context.setStrokeColor(cgColor(style.color))
        context.setFillColor(cgColor(style.color))
        context.setLineWidth(style.strokeWidth)

        switch element.kind {
        case let .line(from, to):
            strokePolyline([from, to])

        case let .arrow(from, to):
            strokePolyline([from, to])
            drawArrowhead(from: from, to: to, style: style)

        case let .rectangle(rect):
            fillThenStroke(CGPath(rect: contextRect(rect), transform: nil), style: style)

        case let .ellipse(rect):
            fillThenStroke(CGPath(ellipseIn: contextRect(rect), transform: nil), style: style)

        case let .freehand(points):
            strokePolyline(points)

        case let .text(string, box):
            drawText(string, box: box, style: style)

        case let .stepMarker(number, center, radius):
            drawStepMarker(number: number, center: center, radius: radius, style: style)

        case .highlight, .redaction:
            // Highlighter (story 22) and blur/pixelate/blackout redaction (stories 23–24)
            // are their own tickets, including the secure-erase semantics render must get
            // exactly right. LIG-9 covers only the vector tools, so these are left for
            // those tickets to draw and pixel-test.
            break
        }

        context.restoreGState()
    }

    // MARK: - Primitives

    private func strokePolyline(_ points: [Point]) {
        guard points.count > 1 else { return }
        context.beginPath()
        context.move(to: contextPoint(points[0]))
        for p in points.dropFirst() { context.addLine(to: contextPoint(p)) }
        context.strokePath()
    }

    private func fillThenStroke(_ path: CGPath, style: Style) {
        context.addPath(path)
        if let fill = style.fill {
            context.setFillColor(cgColor(fill))
            context.drawPath(using: .fillStroke)
        } else {
            context.drawPath(using: .stroke)
        }
    }

    private func drawArrowhead(from: Point, to: Point, style: Style) {
        // Compute the triangle in context space via the shared geometry helper, so the
        // on-screen preview (`EditorView`) and this flatten path never drift apart.
        let tail = contextPoint(from)
        let tip = contextPoint(to)
        let corners = arrowheadPoints(
            from: Point(x: tail.x, y: tail.y),
            to: Point(x: tip.x, y: tip.y),
            lineWidth: style.strokeWidth
        )
        guard corners.count == 3 else { return }
        context.beginPath()
        context.move(to: CGPoint(x: corners[0].x, y: corners[0].y))
        context.addLine(to: CGPoint(x: corners[1].x, y: corners[1].y))
        context.addLine(to: CGPoint(x: corners[2].x, y: corners[2].y))
        context.closePath()
        context.fillPath()
    }

    private func drawText(_ string: String, box: Rect, style: Style) {
        guard !string.isEmpty else { return }
        let line = makeLine(string, fontSize: style.fontSize, color: style.color)
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)
        // Baseline sits `ascent` below the box's top edge (image-down → context-down).
        let topLeft = contextPoint(box.standardized.origin)
        context.textPosition = CGPoint(x: topLeft.x, y: topLeft.y - ascent)
        CTLineDraw(line, context)
    }

    private func drawStepMarker(number: Int, center: Point, radius: Double, style: Style) {
        let box = Rect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.addPath(CGPath(ellipseIn: contextRect(box), transform: nil))
        context.fillPath()

        // The number is drawn in white for contrast, centered in the disc, sized to fit.
        let line = makeLine(String(number), fontSize: radius * 1.2, color: RGBAColor(red: 1, green: 1, blue: 1))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let c = contextPoint(center)
        context.textPosition = CGPoint(x: c.x - textWidth / 2, y: c.y - (ascent - descent) / 2)
        CTLineDraw(line, context)
    }

    private func makeLine(_ string: String, fontSize: Double, color: RGBAColor) -> CTLine {
        let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(fontSize), nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: cgColor(color),
        ]
        let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)!
        return CTLineCreateWithAttributedString(attributed)
    }
}

/// Encode a rendered image into `format`'s bytes — the single pixels-to-file step shared by disk
/// save (`ImageSink.write`) and drag-out (`AppCoordinator.dragItem`). PNG returns the already-PNG
/// render bytes unchanged; JPEG re-encodes the decoded image at the requested (clamped) quality via
/// ImageIO. Pure and screen-free (no AppKit), so both output paths run through one tested encoder,
/// and it is total: any failure falls back to the original render bytes rather than throwing.
public func encode(_ image: RenderedImage, as format: ImageFormat) -> Data {
    switch format {
    case .png:
        return image.data
    case let .jpeg(quality):
        guard let cgImage = decodeImage(image.data) else { return image.data }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, ImageFormat.jpeg(quality: quality).utiIdentifier as CFString, 1, nil) else {
            return image.data
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1)
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return image.data }
        return out as Data
    }
}

// MARK: - CoreGraphics helpers

private func cgColor(_ c: RGBAColor) -> CGColor {
    CGColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
}

private func decodeImage(_ data: Data) -> CGImage? {
    guard !data.isEmpty,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return image
}

private func encodePNG(_ image: CGImage) -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        return Data()
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}
