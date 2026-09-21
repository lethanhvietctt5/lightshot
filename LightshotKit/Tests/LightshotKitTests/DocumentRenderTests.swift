import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import LightshotKit

// Pixel-level behavior of `render(_ document:)` — the flatten seam (stories 15–20, 25,
// 33, 44). These decode the output PNG and assert coarse pixel facts (a mark appears,
// z-order wins, crop resizes) rather than snapshotting bytes. They use CoreGraphics /
// ImageIO to build fixtures and read pixels — never AppKit / ScreenCaptureKit — so the
// domain seam still holds.

// MARK: - Fixtures & pixel probing

/// A solid-color PNG `CapturedImage` to flatten annotations onto.
private func solidImage(width: Int, height: Int, rgb: (Double, Double, Double)) -> CapturedImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let cgImage = context.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cgImage, nil)
    CGImageDestinationFinalize(dest)
    return CapturedImage(pixelWidth: width, pixelHeight: height, data: data as Data)
}

private struct Pixels {
    let width: Int
    let height: Int
    private let buffer: [UInt8] // RGBA8, row-major, top-left origin

    /// Decodes a rendered PNG into a top-left-origin RGBA8 buffer for probing.
    init(_ rendered: RenderedImage) {
        let source = CGImageSourceCreateWithData(rendered.data as CFData, nil)!
        let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let w = cgImage.width
        let h = cgImage.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // A bitmap context's memory is already row-major from the *top* row (only its drawing
        // coordinates are bottom-left), so the bytes are a top-left buffer as they stand.
        width = w
        height = h
        buffer = bytes
    }

    /// RGB at an image-space pixel (top-left origin), each channel `0.0...1.0`.
    func rgb(x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
        let i = (y * width + x) * 4
        return (Double(buffer[i]) / 255, Double(buffer[i + 1]) / 255, Double(buffer[i + 2]) / 255)
    }
}

private func isRed(_ c: (r: Double, g: Double, b: Double)) -> Bool {
    c.r > 0.6 && c.g < 0.4 && c.b < 0.4
}
private func isWhite(_ c: (r: Double, g: Double, b: Double)) -> Bool {
    c.r > 0.9 && c.g > 0.9 && c.b > 0.9
}
private func isGreen(_ c: (r: Double, g: Double, b: Double)) -> Bool {
    c.g > 0.6 && c.r < 0.4 && c.b < 0.4
}
private func isBlack(_ c: (r: Double, g: Double, b: Double)) -> Bool {
    c.r < 0.1 && c.g < 0.1 && c.b < 0.1
}

/// Manhattan distance between two colors — used to assert a region *changed* (blur/pixelate)
/// without asserting anything about what it changed into.
private func channelDistance(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
    abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
}

/// A base image split left/right into two solid colors, so a filter that blends or shifts
/// pixels across the vertical seam is observable.
private func halvesImage(width: Int, height: Int, left: (Double, Double, Double), right: (Double, Double, Double)) -> CapturedImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: left.0, green: left.1, blue: left.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    context.setFillColor(CGColor(red: right.0, green: right.1, blue: right.2, alpha: 1))
    context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    let cgImage = context.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cgImage, nil)
    CGImageDestinationFinalize(dest)
    return CapturedImage(pixelWidth: width, pixelHeight: height, data: data as Data)
}

private func document(width: Int = 100, height: Int = 100, rgb: (Double, Double, Double) = (1, 1, 1)) -> AnnotationDocument {
    AnnotationDocument(baseImage: solidImage(width: width, height: height, rgb: rgb))
}

// MARK: - Dimensions & base pass-through

@Suite struct RenderDimensionTests {
    @Test func emptyDocumentKeepsBaseDimensions() {
        let doc = document(width: 128, height: 96)
        let out = render(doc)
        #expect(out.pixelWidth == 128)
        #expect(out.pixelHeight == 96)
    }

    @Test func emptyDocumentReproducesTheBasePixels() {
        let doc = document(width: 40, height: 40, rgb: (1, 1, 1))
        let pixels = Pixels(render(doc))
        #expect(isWhite(pixels.rgb(x: 20, y: 20)))
    }

    @Test func cropShrinksOutputToTheCropRect() {
        var doc = document(width: 200, height: 150)
        doc.applyCrop(Rect(x: 20, y: 10, width: 80, height: 60))
        let out = render(doc)
        #expect(out.pixelWidth == 80)
        #expect(out.pixelHeight == 60)
    }

    @Test func cropOffsetsAnnotationsIntoTheCroppedFrame() {
        var doc = document(width: 200, height: 150) // white base
        var mark = AnnotationElement(kind: .rectangle(Rect(x: 100, y: 80, width: 40, height: 30)))
        mark.style = Style(color: .red, strokeWidth: 3, fill: .red)
        _ = doc.add(mark)
        doc.applyCrop(Rect(x: 80, y: 60, width: 100, height: 80))
        let pixels = Pixels(render(doc))
        #expect(pixels.width == 100 && pixels.height == 80)
        // The mark centered at image (120, 95) lands at output (40, 35): anchored, not drifted.
        #expect(isRed(pixels.rgb(x: 40, y: 35)))
        // A spot inside the crop but outside the mark stays base white.
        #expect(isWhite(pixels.rgb(x: 5, y: 5)))
    }

    @Test func reversingACropRestoresTheFullFrameWithElementsIntact() {
        var doc = document(width: 200, height: 150) // white base
        // A mark at the image centre, so its read point is invariant under the probe's flip.
        var mark = AnnotationElement(kind: .rectangle(Rect(x: 80, y: 60, width: 40, height: 30)))
        mark.style = Style(color: .red, strokeWidth: 3, fill: .red)
        _ = doc.add(mark)

        doc.applyCrop(Rect(x: 0, y: 0, width: 60, height: 60)) // crops the mark out of the frame
        #expect(render(doc).pixelWidth == 60) // cropped output no longer spans the mark

        doc.undo() // reverse the crop
        let out = render(doc)
        #expect(out.pixelWidth == 200 && out.pixelHeight == 150) // full frame restored
        #expect(isRed(Pixels(out).rgb(x: 100, y: 75))) // mark intact at the image centre
    }
}

// MARK: - Vector tools appear

@Suite struct RenderVectorTests {
    @Test func filledRectanglePaintsItsInterior() {
        var doc = document() // white base
        var element = AnnotationElement(kind: .rectangle(Rect(x: 20, y: 20, width: 60, height: 60)))
        element.style = Style(color: .red, strokeWidth: 3, fill: .red)
        _ = doc.add(element)
        let pixels = Pixels(render(doc))
        #expect(isRed(pixels.rgb(x: 50, y: 50)))  // inside the box
        #expect(isWhite(pixels.rgb(x: 5, y: 5)))   // outside stays base
    }

    @Test func strokedLineMarksThePixelsAlongIt() {
        var doc = document()
        _ = doc.add(AnnotationElement(
            kind: .line(from: Point(x: 10, y: 50), to: Point(x: 90, y: 50)),
            style: Style(color: .red, strokeWidth: 6)
        ))
        let pixels = Pixels(render(doc))
        #expect(isRed(pixels.rgb(x: 50, y: 50)))   // on the line
        #expect(isWhite(pixels.rgb(x: 50, y: 20)))  // above it
    }

    @Test func filledEllipsePaintsCenterButNotBoundingBoxCorner() {
        var doc = document()
        var element = AnnotationElement(kind: .ellipse(Rect(x: 10, y: 10, width: 80, height: 80)))
        element.style = Style(color: .red, fill: .red)
        _ = doc.add(element)
        let pixels = Pixels(render(doc))
        #expect(isRed(pixels.rgb(x: 50, y: 50)))   // center
        #expect(isWhite(pixels.rgb(x: 12, y: 12)))  // corner outside the ellipse
    }
}

// MARK: - Highlight & redaction (stories 22–24)

@Suite struct RenderRedactionTests {
    @Test func highlighterWashesTheRegionButLetsContentShowThrough() {
        var doc = document() // white base
        _ = doc.add(AnnotationElement(
            kind: .highlight(Rect(x: 20, y: 20, width: 60, height: 60)),
            style: Style(color: .red)
        ))
        let c = Pixels(render(doc)).rgb(x: 50, y: 50)
        // Translucent red over white reads as pink: the red channel stays high, but green and
        // blue are only partly knocked down — the white beneath still shows. A solid fill
        // would drive green/blue to ~0, which would mean the highlighter hid the content.
        #expect(c.r > 0.9)
        #expect(c.g > 0.4 && c.g < 0.95)
        #expect(c.b > 0.4 && c.b < 0.95)
    }

    @Test func blackoutErasesTheSentinelBeneathIt() {
        // The whole base is a green sentinel; a blackout covers the middle.
        var doc = AnnotationDocument(baseImage: solidImage(width: 100, height: 100, rgb: (0, 1, 0)))
        _ = doc.add(AnnotationElement(kind: .redaction(Rect(x: 20, y: 20, width: 60, height: 60), style: .blackout)))
        let pixels = Pixels(render(doc))
        // Inside the box: opaque black, with no trace of the sentinel — secure erase.
        for (x, y) in [(30, 30), (50, 50), (70, 70)] {
            let c = pixels.rgb(x: x, y: y)
            #expect(isBlack(c))
            #expect(!isGreen(c))
        }
        // Outside the box the sentinel survives, so the fill is scoped to its region.
        #expect(isGreen(pixels.rgb(x: 5, y: 5)))
    }

    @Test func blurChangesTheRegionWithoutErasingIt() {
        // Red | blue halves; a blur straddling the seam must blend the two, not replace them.
        let base = halvesImage(width: 100, height: 100, left: (1, 0, 0), right: (0, 0, 1))
        var doc = AnnotationDocument(baseImage: base)
        _ = doc.add(AnnotationElement(kind: .redaction(Rect(x: 30, y: 30, width: 40, height: 40), style: .blur)))
        let plain = Pixels(render(AnnotationDocument(baseImage: base)))
        let blurred = Pixels(render(doc))
        // The sharp seam pixel changed (obscuring), but the assertion says nothing about
        // recoverability — blur is explicitly not a secure erase.
        #expect(channelDistance(plain.rgb(x: 50, y: 50), blurred.rgb(x: 50, y: 50)) > 0.05)
    }

    @Test func pixelateChangesTheRegion() {
        let base = halvesImage(width: 100, height: 100, left: (1, 0, 0), right: (0, 0, 1))
        var doc = AnnotationDocument(baseImage: base)
        _ = doc.add(AnnotationElement(kind: .redaction(Rect(x: 30, y: 30, width: 40, height: 40), style: .pixelate)))
        let plain = Pixels(render(AnnotationDocument(baseImage: base)))
        let pixelated = Pixels(render(doc))
        // Blocking shifts the seam, so at least one pixel around it differs from the base.
        let changed = (44...56).contains { x in
            channelDistance(plain.rgb(x: x, y: 50), pixelated.rgb(x: x, y: 50)) > 0.05
        }
        #expect(changed)
    }
}

// MARK: - Z-order

@Suite struct RenderZOrderTests {
    @Test func laterElementDrawsOnTopAtOverlap() {
        var doc = document()
        var bottom = AnnotationElement(kind: .rectangle(Rect(x: 10, y: 10, width: 60, height: 60)))
        bottom.style = Style(color: .black, fill: .black)
        var top = AnnotationElement(kind: .rectangle(Rect(x: 30, y: 30, width: 60, height: 60)))
        top.style = Style(color: .red, fill: .red)
        _ = doc.add(bottom)
        _ = doc.add(top)
        let pixels = Pixels(render(doc))
        // The overlap region (40,40) belongs to the top (red) element.
        #expect(isRed(pixels.rgb(x: 45, y: 45)))
    }
}

// MARK: - Arrow styles & redaction effect (spec 0003)

/// Wraps a `CGImage` as a `RenderedImage` so `Pixels` can probe a preview patch the same
/// way it probes an export.
private func rendered(_ image: CGImage) -> RenderedImage {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return RenderedImage(pixelWidth: image.width, pixelHeight: image.height, data: data as Data)
}

@Suite struct RenderArrowStyleTests {
    @Test func standardArrowIsThinAtTheTailAndWideAtTheHead() {
        var doc = document(width: 200, height: 100)
        _ = doc.add(AnnotationElement(
            kind: .arrow(from: Point(x: 10, y: 50), to: Point(x: 190, y: 50)),
            style: Style(color: .red, strokeWidth: 8)
        ))
        let pixels = Pixels(render(doc))
        // 4px off the axis: bare near the tail, painted where the shaft meets the head.
        #expect(isRed(pixels.rgb(x: 30, y: 50)))
        #expect(isWhite(pixels.rgb(x: 30, y: 55)))
        #expect(isRed(pixels.rgb(x: 145, y: 55)))
        // …and the head flares well past the shaft.
        #expect(isRed(pixels.rgb(x: 155, y: 64)))
    }

    @Test func curvedArrowIsDrawnThroughItsBendNotAlongItsChord() {
        var doc = document(width: 200, height: 120)
        _ = doc.add(AnnotationElement(
            kind: .arrow(from: Point(x: 20, y: 100), to: Point(x: 180, y: 100), bend: Point(x: 100, y: 30), style: .curved),
            style: Style(color: .red, strokeWidth: 6)
        ))
        let pixels = Pixels(render(doc))
        #expect(isRed(pixels.rgb(x: 100, y: 30)))
        #expect(isWhite(pixels.rgb(x: 100, y: 100)))
    }
}

@Suite struct RenderRedactionEffectTests {
    private let base = halvesImage(width: 200, height: 120, left: (1, 0, 0), right: (0, 0, 1))
    private let region = Rect(x: 60, y: 30, width: 80, height: 60)

    private func doc(_ style: RedactionStyle, strength: Double = 0.5, seed: UInt64 = 7) -> AnnotationDocument {
        var doc = AnnotationDocument(baseImage: base)
        _ = doc.add(AnnotationElement(kind: .redaction(region, style: style, strength: strength, seed: seed)))
        return doc
    }

    @Test(arguments: [RedactionStyle.blur, .pixelate])
    func theSameElementAlwaysFlattensToTheSamePixels(style: RedactionStyle) {
        #expect(render(doc(style)).data == render(doc(style)).data)
    }

    @Test(arguments: [RedactionStyle.blur, .pixelate])
    func aDifferentSeedScramblesDifferently(style: RedactionStyle) {
        #expect(render(doc(style, seed: 1)).data != render(doc(style, seed: 2)).data)
    }

    @Test(arguments: [RedactionStyle.blur, .pixelate])
    func strengthChangesTheResult(style: RedactionStyle) {
        #expect(render(doc(style, strength: 0.1)).data != render(doc(style, strength: 0.9)).data)
    }

    @Test func blurSmearsTheSeamWidelyAndStaysInsideItsRegion() {
        let plain = Pixels(render(AnnotationDocument(baseImage: base)))
        let blurred = Pixels(render(doc(.blur, strength: 1)))
        // 20px from the red/blue seam is still solid on the base; a strong blur reaches it.
        #expect(channelDistance(plain.rgb(x: 80, y: 60), blurred.rgb(x: 80, y: 60)) > 0.05)
        // Just outside the region nothing moved.
        #expect(channelDistance(plain.rgb(x: 55, y: 60), blurred.rgb(x: 55, y: 60)) < 0.001)
        #expect(channelDistance(plain.rgb(x: 100, y: 25), blurred.rgb(x: 100, y: 25)) < 0.001)
    }

    @Test func blurObscuresAnnotationsBeneathItButNotThoseAbove() {
        var doc = AnnotationDocument(baseImage: solidImage(width: 200, height: 120, rgb: (1, 1, 1)))
        let mark = Rect(x: 90, y: 50, width: 20, height: 20)
        _ = doc.add(AnnotationElement(kind: .rectangle(mark), style: Style(color: .red, fill: .red)))
        _ = doc.add(AnnotationElement(kind: .redaction(region, style: .blur, strength: 0.3, seed: 7)))
        // Beneath the blur the red square bleeds into its white surroundings: no longer
        // solid red at its center, no longer pure white just outside it.
        let blurred = Pixels(render(doc))
        #expect(!isRed(blurred.rgb(x: 100, y: 60)))
        #expect(channelDistance(blurred.rgb(x: 82, y: 60), (1, 1, 1)) > 0.02)

        _ = doc.add(AnnotationElement(kind: .rectangle(mark), style: Style(color: .red, fill: .red)))
        #expect(isRed(Pixels(render(doc)).rgb(x: 100, y: 60)))
    }

    @Test(arguments: [RedactionStyle.blur, .pixelate])
    func theCanvasPreviewPatchIsExactlyWhatExports(style: RedactionStyle) throws {
        let document = doc(style)
        let patch = try #require(redactionBackdrop(document, below: 0)?.patch(region, style: style, strength: 0.5, seed: 7))
        #expect(patch.rect == region)
        let preview = Pixels(rendered(patch.image))
        let export = Pixels(render(document))
        for (x, y) in [(0, 0), (40, 30), (39, 10), (79, 59), (12, 47)] {
            let a = preview.rgb(x: x, y: y), b = export.rgb(x: 60 + x, y: 30 + y)
            #expect(channelDistance(a, b) < 0.001)
        }
    }

    @Test func blackoutNeedsNoPatch() {
        #expect(redactionBackdrop(doc(.blackout), below: 0)?.patch(region, style: .blackout, strength: 0.5, seed: 7) == nil)
    }

    @Test func aRegionPokingOutsideTheCropIsClippedToTheVisibleFrame() throws {
        var document = doc(.pixelate)
        document.applyCrop(Rect(x: 100, y: 0, width: 100, height: 120))
        let patch = try #require(redactionBackdrop(document, below: 0)?.patch(region, style: .pixelate, strength: 0.5, seed: 7))
        #expect(patch.rect == Rect(x: 100, y: 30, width: 40, height: 60))
    }
}
