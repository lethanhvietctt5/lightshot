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

    // A context this small should never fail to allocate; fall back to the raw base
    // bytes rather than crash, so `render` is total.
    guard let image = flatten(document, elements: document.elements[...]) else {
        return RenderedImage(pixelWidth: width, pixelHeight: height, data: document.baseImage.data)
    }
    return RenderedImage(pixelWidth: width, pixelHeight: height, data: encodePNG(image))
}

/// Base image plus `elements`, drawn in order into the document's visible frame. Shared by
/// `render` (every element) and `redactionBackdrop` (only those beneath a redaction).
func flatten(_ document: AnnotationDocument, elements: ArraySlice<AnnotationElement>) -> CGImage? {
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
    ) else { return nil }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let flattener = Flattener(context: context, frame: frame, height: height)
    flattener.drawBase(document.baseImage)
    for element in elements {
        flattener.draw(element)
    }
    return context.makeImage()
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

        case let .arrow(from, to, bend, arrowStyle):
            drawArrow(from: from, to: to, bend: bend, arrowStyle: arrowStyle, style: style)

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

        case let .highlight(rect):
            drawHighlight(rect, style: style)

        case let .redaction(rect, redaction, strength, seed):
            drawRedaction(rect, redaction, strength: strength, seed: seed)
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

    private func drawArrow(from: Point, to: Point, bend: Point?, arrowStyle: ArrowStyle, style: Style) {
        // Build the outline in context space via the shared geometry (`arrowShape`), so the
        // on-screen preview (`EditorView`) and this flatten path never drift apart.
        func point(_ p: Point) -> Point { let c = contextPoint(p); return Point(x: c.x, y: c.y) }
        let shape = arrowShape(
            from: point(from), to: point(to), bend: bend.map(point),
            style: arrowStyle, lineWidth: style.strokeWidth
        )
        guard !shape.path.isEmpty else { return }

        context.beginPath()
        for element in shape.path {
            switch element {
            case let .move(p): context.move(to: CGPoint(x: p.x, y: p.y))
            case let .line(p): context.addLine(to: CGPoint(x: p.x, y: p.y))
            case let .quadCurve(to, control):
                context.addQuadCurve(to: CGPoint(x: to.x, y: to.y), control: CGPoint(x: control.x, y: control.y))
            case .close: context.closePath()
            }
        }
        switch shape.paint {
        case let .fill(rounding) where rounding > 0:
            context.setLineWidth(rounding)
            context.drawPath(using: .fillStroke)
        case .fill:
            context.fillPath()
        case let .stroke(width):
            context.setLineWidth(width)
            context.strokePath()
        }
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

    // MARK: - Highlight & redaction (stories 22–24)

    /// A translucent colored wash: the fill alpha is capped so the content beneath stays
    /// visible (story 22). A highlighter draws attention — it is never a redaction, so it
    /// must not fully cover what it sits on.
    private func drawHighlight(_ rect: Rect, style: Style) {
        var wash = style.color
        wash.alpha = min(style.color.alpha, Self.highlightAlpha)
        context.setFillColor(cgColor(wash))
        context.fill(contextRect(rect))
    }

    private func drawRedaction(_ rect: Rect, _ redaction: RedactionStyle, strength: Double, seed: UInt64) {
        if redaction == .blackout {
            // Secure erase (story 24): an opaque solid replaces the covered pixels, so
            // nothing beneath survives in the exported bytes. Black and fully opaque — the
            // only redaction the app treats as secret-safe.
            context.setFillColor(cgColor(RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)))
            context.fill(contextRect(rect))
            return
        }

        // Blur / pixelate obscure everything drawn so far — the same backdrop-and-patch
        // path the editor canvas previews with, so what you see is what exports.
        guard let snapshot = context.makeImage(),
              let patch = RedactionBackdrop(image: snapshot, frame: frame)
                .patch(rect, style: redaction, strength: strength, seed: seed) else { return }
        context.saveGState()
        context.interpolationQuality = .none
        context.setBlendMode(.copy)  // replace the region outright; don't blend patch edges
        context.draw(patch.image, in: contextRect(patch.rect))
        context.restoreGState()
    }

    /// Alpha cap for the highlighter wash — low enough that the content beneath reads through.
    private static let highlightAlpha: Double = 0.35

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
