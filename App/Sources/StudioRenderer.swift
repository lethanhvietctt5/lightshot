import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import LightshotKit

/// Everything needed to draw any frame of a Studio edit (spec 0007, "One renderer"), built once
/// per edit and then read concurrently by the compositor: the pure engines (timeline, zoom camera,
/// cursor path) plus the pre-rendered background. Immutable, so preview and export can share it.
final class StudioRenderState: @unchecked Sendable {
    let edits: StudioEdits
    let timeline: StudioTimeline
    /// The canvas at the export resolution, in pixels. Preview renders the same frame scaled down.
    let layout: CanvasLayout
    /// The screen movie's pixel size.
    let sourceSize: Size
    /// The recorded region in points — what the input coordinates are relative to.
    let regionSize: Size
    let cursor: CursorPath?
    let zoom: ZoomCamera
    let keyEvents: [TimedKeyEvent]
    let background: CIImage
    let systemIsDark: Bool

    init(edits: StudioEdits, input: StudioInput?, sourceSize: Size, assetURL: (String) -> URL?, context: CIContext) {
        self.edits = edits
        timeline = StudioTimeline(clips: edits.clips)
        layout = CanvasLayout(sourceSize: sourceSize, style: edits.canvas, resolution: edits.output.resolution)
        self.sourceSize = sourceSize
        regionSize = input?.regionSize ?? sourceSize
        if let input, !input.samples.isEmpty {
            cursor = CursorPath(samples: input.samples, clicks: input.clicks, duration: edits.sourceDuration, smoothing: edits.cursor.smoothing)
        } else {
            cursor = nil
        }
        zoom = ZoomCamera(zooms: edits.zooms, transition: edits.zoomTransition, cursor: cursor, regionSize: regionSize)
        keyEvents = input?.keys ?? []
        background = StudioBackgroundRenderer.render(edits.background, blur: edits.canvas.backgroundBlur, canvas: layout.canvas, assetURL: assetURL, context: context)
        systemIsDark = KeystrokeOverlayAppearance.systemIsDark
    }

    /// The canvas rect in Core Image coordinates.
    var canvasRect: CGRect { CGRect(x: 0, y: 0, width: layout.canvas.width, height: layout.canvas.height) }
}

/// Draws one output frame (spec 0007): background → shadow → zoomed, rounded screen → cursor with
/// motion blur → click effects → camera → keystroke pills. Core Image, in canvas pixels with a
/// bottom-left origin; `StudioRenderState` supplies the geometry.
enum StudioFrameRenderer {
    /// The arrow the studio cursor is drawn with (spec 0007, decision 3): the macOS arrow as a
    /// vector path — black body, white rim — rasterised once at 8× so it stays sharp when zoomed.
    /// Drawn here rather than taken from `NSCursor`, whose image depends on AppKit state.
    /// `size` is in cursor points; the hot spot is the tip, top-left based.
    static let arrow: (image: CIImage, hotSpot: CGPoint, size: CGSize) = {
        let size = CGSize(width: 14, height: 22)
        let scale: CGFloat = 8
        let path = CGMutablePath()
        // Top-left based points, tip at (1, 1).
        let points: [CGPoint] = [
            CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 17), CGPoint(x: 5, y: 13.2), CGPoint(x: 8, y: 20),
            CGPoint(x: 10.6, y: 18.9), CGPoint(x: 7.7, y: 12.3), CGPoint(x: 12.8, y: 12.3),
        ]
        path.addLines(between: points.map { CGPoint(x: $0.x * scale, y: (size.height - $0.y) * scale) })
        path.closeSubpath()
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (CIImage.empty(), CGPoint(x: 1, y: 1), size) }
        context.setLineJoin(.round)
        context.addPath(path)
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(2.2 * scale)
        context.strokePath()
        context.addPath(path)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fillPath()
        let image = context.makeImage().map { CIImage(cgImage: $0) } ?? CIImage.empty()
        return (image, CGPoint(x: 1, y: 1), size)
    }()

    static func render(_ state: StudioRenderState, screen: CIImage?, camera: CIImage?, outputTime: Double, frameDuration: Double) -> CIImage {
        let edits = state.edits
        let layout = state.layout
        let canvasHeight = layout.canvas.height
        let content = layout.content
        let contentCI = CGRect(x: content.minX, y: canvasHeight - content.maxY, width: content.width, height: content.height)
        let t = state.timeline.sourceTime(atOutput: outputTime)
        let viewport = state.zoom.viewport(at: t)

        var image = state.background

        // Shadow under the screen card.
        if layout.shadowRadius > 0 {
            let shadow = roundedRect(contentCI.offsetBy(dx: 0, dy: -layout.shadowRadius * 0.35), radius: layout.cornerRadius,
                                     color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35 + 0.35 * edits.canvas.shadow))
                .applyingGaussianBlur(sigma: layout.shadowRadius / 2)
            image = shadow.composited(over: image)
        }

        // The screen through the zoom viewport, with motion blur while the camera moves.
        if let screen {
            var layer = screenLayer(screen, viewport: viewport, state: state, contentCI: contentCI)
            if edits.zoomMotionBlur > 0 {
                let previous = state.zoom.viewport(at: t - frameDuration)
                let moved = abs(previous.scale - viewport.scale) > 0.002 || abs(previous.rect.midX - viewport.rect.midX) > 0.001
                    || abs(previous.rect.midY - viewport.rect.midY) > 0.001
                if moved {
                    // A running average of viewports spread back over the frame: the k-th sample is
                    // dissolved in at 1/k, which blends premultiplied pixels correctly (a colour
                    // matrix works unpremultiplied and washes the picture out).
                    let samples = 4
                    for i in 1..<samples {
                        let back = frameDuration * edits.zoomMotionBlur * Double(i) / Double(samples - 1)
                        let sample = screenLayer(screen, viewport: state.zoom.viewport(at: t - back), state: state, contentCI: contentCI)
                        layer = layer.applyingFilter("CIDissolveTransition", parameters: [
                            kCIInputTargetImageKey: sample, kCIInputTimeKey: 1.0 / Double(i + 1),
                        ]).cropped(to: contentCI)
                    }
                }
            }
            let mask = roundedRect(contentCI, radius: layout.cornerRadius, color: .white)
            layer = layer.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
            ])
            image = layer.composited(over: image)
        }

        // The cursor and its clicks, drawn from data (stories 14–19).
        if edits.cursor.visible, let cursor = state.cursor, let position = cursor.position(at: t) {
            let opacity = edits.cursor.hideWhenIdle ? cursor.idleOpacity(at: t, delay: edits.cursor.idleDelay) : 1
            let pointsToCanvas = content.width / viewport.rect.width / max(state.regionSize.width, 1)
            if opacity > 0 {
                let clickLayer = clicks(cursor.clicks(at: t), state: state, viewport: viewport, contentCI: contentCI, scale: pointsToCanvas)
                if let clickLayer { image = clickLayer.cropped(to: contentCI).composited(over: image) }
                var arrow = cursorLayer(at: position, velocity: cursor.velocity(at: t), state: state, viewport: viewport,
                                        contentCI: contentCI, scale: pointsToCanvas, frameDuration: frameDuration)
                if opacity < 1 { arrow = arrow.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)]) }
                image = arrow.cropped(to: contentCI).composited(over: image)
            }
        }

        // The camera, laid out on the screen card (story 23).
        if edits.camera.visible, let camera {
            image = cameraLayer(camera, settings: edits.camera.bubble, contentCI: contentCI).composited(over: image)
        }

        // Text annotations (round 2, story 32), above the camera.
        for annotation in edits.annotations {
            let opacity = annotation.opacity(at: t)
            if opacity > 0, let layer = annotationLayer(annotation, opacity: opacity, contentCI: contentCI) {
                image = layer.composited(over: image)
            }
        }

        // Keystrokes replayed from the recorded events (story 24).
        if edits.keystrokes.visible, !state.keyEvents.isEmpty {
            if let pills = keystrokeLayer(state: state, at: t, over: image, contentCI: contentCI) { image = pills.composited(over: image) }
        }

        // Captions from the transcript (round 2, story 29).
        if edits.captions.visible, let line = edits.captions.line(at: t),
           let caption = captionLayer(line.text, style: edits.captions.style, contentCI: contentCI) {
            image = caption.composited(over: image)
        }

        return image.cropped(to: state.canvasRect)
    }

    /// A title card / callout: the text on its rounded background, centred at its point of the card,
    /// shrunk to fit the card's width, faded by `opacity`.
    private static func annotationLayer(_ annotation: TextAnnotation, opacity: Double, contentCI: CGRect) -> CIImage? {
        guard !annotation.text.isEmpty else { return nil }
        var fontSize = CGFloat(annotation.size) * contentCI.height
        let c = annotation.textColor
        func line(_ size: CGFloat) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: annotation.text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .bold),
                .foregroundColor: NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha),
            ]))
        }
        var ctLine = line(fontSize)
        var width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        if width > contentCI.width * 0.92 {
            fontSize *= contentCI.width * 0.92 / width
            ctLine = line(fontSize)
            width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil)
        let padX = fontSize * 0.55, padY = fontSize * 0.32
        let box = CGSize(width: ceil(width + 2 * padX), height: ceil(ascent + descent + 2 * padY))
        guard let context = CGContext(
            data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setAlpha(CGFloat(opacity))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let b = annotation.background
        if b.alpha > 0 {
            context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: box), cornerWidth: box.height * 0.28, cornerHeight: box.height * 0.28, transform: nil))
            context.setFillColor(CGColor(srgbRed: b.red, green: b.green, blue: b.blue, alpha: b.alpha))
            context.fillPath()
        }
        context.textPosition = CGPoint(x: padX, y: padY + descent)
        CTLineDraw(ctLine, context)
        context.endTransparencyLayer()
        guard let cg = context.makeImage() else { return nil }
        let cx = contentCI.minX + annotation.center.x * contentCI.width
        let cy = contentCI.maxY - annotation.center.y * contentCI.height
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: (cx - box.width / 2).rounded(), y: (cy - box.height / 2).rounded()))
    }

    /// One caption line, centred at the bottom (or top) of the screen card, shrunk to fit its width.
    private static func captionLayer(_ text: String, style: CaptionStyle, contentCI: CGRect) -> CIImage? {
        guard !text.isEmpty else { return nil }
        var fontSize = CGFloat(style.size.fraction) * contentCI.height
        func line(_ size: CGFloat) -> CTLine {
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            let c = style.textColor
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha),
            ]))
        }
        var ctLine = line(fontSize)
        var width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        let maxWidth = contentCI.width * 0.88
        if width > maxWidth {
            fontSize *= maxWidth / width
            ctLine = line(fontSize)
            width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil)
        let padX = fontSize * 0.6, padY = fontSize * 0.3
        let box = CGSize(width: ceil(width + 2 * padX), height: ceil(ascent + descent + 2 * padY))
        guard let context = CGContext(
            data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let rect = CGRect(origin: .zero, size: box)
        if style.backdrop {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: box.height * 0.3, cornerHeight: box.height * 0.3, transform: nil))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.7))
            context.fillPath()
        } else {
            context.setShadow(offset: .zero, blur: fontSize * 0.25, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.9))
        }
        context.textPosition = CGPoint(x: padX, y: padY + descent)
        CTLineDraw(ctLine, context)
        guard let cg = context.makeImage() else { return nil }
        let margin = contentCI.height * 0.06
        let x = contentCI.midX - box.width / 2
        let y = style.position == .bottom ? contentCI.minY + margin : contentCI.maxY - margin - box.height
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
    }

    // MARK: - Layers

    /// Map a normalised frame point (top-left origin) to canvas CI coordinates through a viewport.
    private static func canvasPoint(_ n: Point, viewport: ZoomViewport, contentCI: CGRect) -> CGPoint {
        let x = contentCI.minX + (n.x - viewport.rect.minX) / viewport.rect.width * contentCI.width
        let yTop = (n.y - viewport.rect.minY) / viewport.rect.height * contentCI.height
        return CGPoint(x: x, y: contentCI.maxY - yTop)
    }

    private static func screenLayer(_ screen: CIImage, viewport: ZoomViewport, state: StudioRenderState, contentCI: CGRect) -> CIImage {
        let w = screen.extent.width, h = screen.extent.height
        let v = viewport.rect
        let crop = CGRect(x: v.minX * w, y: (1 - v.maxY) * h, width: v.width * w, height: v.height * h)
        let transform = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
            .concatenating(CGAffineTransform(scaleX: contentCI.width / crop.width, y: contentCI.height / crop.height))
            .concatenating(CGAffineTransform(translationX: contentCI.minX, y: contentCI.minY))
        return screen.clampedToExtent().transformed(by: transform).cropped(to: contentCI)
    }

    private static func cursorLayer(
        at position: Point, velocity: Point, state: StudioRenderState, viewport: ZoomViewport,
        contentCI: CGRect, scale: Double, frameDuration: Double
    ) -> CIImage {
        let normalized = Point(x: position.x / state.regionSize.width, y: position.y / state.regionSize.height)
        let tip = canvasPoint(normalized, viewport: viewport, contentCI: contentCI)
        let points = state.edits.cursor.size * scale                // canvas pixels per cursor point
        let image = arrow.image
        let sx = arrow.size.width * points / max(image.extent.width, 1)
        let sy = arrow.size.height * points / max(image.extent.height, 1)
        // The hot spot is top-left based; CI is bottom-left.
        let hot = CGPoint(x: arrow.hotSpot.x * points, y: (arrow.size.height - arrow.hotSpot.y) * points)
        var layer = image
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: tip.x - hot.x, y: tip.y - hot.y))
        let blur = state.edits.cursor.motionBlur
        if blur > 0 {
            let speed = hypot(velocity.x, velocity.y) * scale * frameDuration      // canvas px per frame
            let radius = min(speed * blur * 0.6, 40)
            if radius > 1 {
                let angle = atan2(-velocity.y, velocity.x)                        // CI's y points up
                layer = layer.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                    kCIInputRadiusKey: radius, kCIInputAngleKey: angle,
                ]).cropped(to: layer.extent.insetBy(dx: -radius, dy: -radius))
            }
        }
        return layer
    }

    private static func clicks(_ clicks: [CursorPath.Click], state: StudioRenderState, viewport: ZoomViewport, contentCI: CGRect, scale: Double) -> CIImage? {
        let effect = state.edits.cursor.clickEffect
        guard effect != .none, !clicks.isEmpty else { return nil }
        let c = state.edits.cursor.clickColor
        var layer: CIImage?
        for click in clicks {
            let n = Point(x: click.point.x / state.regionSize.width, y: click.point.y / state.regionSize.height)
            let center = canvasPoint(n, viewport: viewport, contentCI: contentCI)
            let p = click.progress
            let fade = 1 - p
            let ring: CIImage
            switch effect {
            case .ripple:
                let radius = (6 + 26 * p) * scale
                let width = max(2, 3 * scale)
                ring = ringImage(center: center, radius: radius, width: width, color: CIColor(red: c.red, green: c.green, blue: c.blue, alpha: 0.9 * fade))
            case .pulse:
                let radius = (10 + 8 * sin(.pi * p)) * scale
                ring = discImage(center: center, radius: radius, color: CIColor(red: c.red, green: c.green, blue: c.blue, alpha: 0.45 * fade))
            case .none:
                continue
            }
            layer = layer.map { ring.composited(over: $0) } ?? ring
        }
        return layer
    }

    private static func cameraLayer(_ camera: CIImage, settings: CameraBubbleSettings, contentCI: CGRect) -> CIImage {
        let local = CameraBubbleLayout.frame(settings, in: Size(width: contentCI.width, height: contentCI.height))
        let bubble = CGRect(x: contentCI.minX + local.minX, y: contentCI.maxY - local.maxY, width: local.width, height: local.height)
        let aspect = camera.extent.width / max(camera.extent.height, 1)
        let cover = CameraBubbleLayout.coverRect(imageAspect: aspect, in: Rect(x: bubble.minX, y: bubble.minY, width: bubble.width, height: bubble.height))
        var transform = CGAffineTransform(translationX: -camera.extent.minX, y: -camera.extent.minY)
            .concatenating(CGAffineTransform(scaleX: cover.width / camera.extent.width, y: cover.height / camera.extent.height))
        if settings.mirror {
            transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1)).concatenating(CGAffineTransform(translationX: cover.width, y: 0))
        }
        transform = transform.concatenating(CGAffineTransform(translationX: cover.minX, y: cover.minY))
        let radius = CameraBubbleLayout.cornerRadius(for: settings.shape, side: local.width)
        let mask = roundedRect(bubble, radius: radius, color: .white)
        let face = camera.transformed(by: transform).cropped(to: bubble)
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        let shadow = roundedRect(bubble.offsetBy(dx: 0, dy: -4), radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
            .applyingGaussianBlur(sigma: 8)
        return face.composited(over: shadow)
    }

    private static func keystrokeLayer(state: StudioRenderState, at t: Double, over image: CIImage, contentCI: CGRect) -> CIImage? {
        var model = KeystrokeOverlayModel(settings: state.edits.keystrokes.overlay)
        for event in state.keyEvents where event.time <= t { model.handle(event.event, at: event.time) }
        let items = model.items(at: t)
        guard !items.isEmpty else { return nil }
        // Pills are sized like the recorder's, relative to a 1080-pixel-tall frame.
        let pixelsPerPoint = min(contentCI.width, contentCI.height) / 1080 * 2
        let style = KeystrokePillStyle(state.edits.keystrokes.overlay, pixelsPerPoint: pixelsPerPoint, systemIsDark: state.systemIsDark)
        let lines = items.map { style.line(for: $0.text) }
        let widths = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) + 2 * style.paddingX }
        let pillHeight = style.ascent + style.descent + 2 * style.paddingY
        let groupWidth = widths.reduce(0, +) + style.gap * CGFloat(max(0, items.count - 1))
        let local = style.position.rect(
            for: Size(width: Double(groupWidth), height: Double(pillHeight)),
            in: Size(width: contentCI.width, height: contentCI.height), margin: Double(style.margin)
        )
        let group = CGRect(x: contentCI.minX + local.minX, y: contentCI.maxY - local.maxY, width: local.width, height: local.height).integral
        let scaleMargin = style.cornerRadius * 0.2
        let canvas = group.insetBy(dx: -scaleMargin - 8, dy: -scaleMargin - 8)
        guard let context = CGContext(
            data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var masks: CIImage?
        var x = group.minX - canvas.minX
        let y = group.minY - canvas.minY
        for (index, item) in items.enumerated() {
            let rect = CGRect(x: x, y: y, width: widths[index], height: pillHeight)
            x += widths[index] + style.gap
            context.saveGState()
            context.translateBy(x: rect.midX, y: rect.midY)
            context.scaleBy(x: CGFloat(item.scale), y: CGFloat(item.scale))
            context.translateBy(x: -rect.midX, y: -rect.midY)
            context.setAlpha(CGFloat(item.opacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: style.cornerRadius, cornerHeight: style.cornerRadius, transform: nil))
            context.clip()
            context.setFillColor(style.tint)
            context.fill(rect)
            context.textPosition = CGPoint(x: rect.minX + style.paddingX, y: rect.minY + style.paddingY + style.descent)
            CTLineDraw(lines[index], context)
            context.endTransparencyLayer()
            context.restoreGState()
            let maskRect = rect.offsetBy(dx: canvas.minX, dy: canvas.minY)
            let mask = roundedRect(maskRect, radius: style.cornerRadius, color: CIColor(red: 1, green: 1, blue: 1, alpha: item.opacity))
            masks = masks.map { mask.composited(over: $0) } ?? mask
        }
        guard let cg = context.makeImage() else { return nil }
        let pills = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: canvas.minX, y: canvas.minY))
        guard style.blur, let masks else { return pills }
        let backdrop = image.clampedToExtent().applyingGaussianBlur(sigma: Double(style.blurRadius)).cropped(to: canvas)
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: masks])
        return pills.composited(over: backdrop)
    }

    // MARK: - Shapes

    static func roundedRect(_ rect: CGRect, radius: Double, color: CIColor) -> CIImage {
        let filter = CIFilter.roundedRectangleGenerator()
        filter.extent = rect
        filter.radius = Float(max(0, min(radius, min(rect.width, rect.height) / 2)))
        filter.color = color
        return filter.outputImage ?? CIImage.empty()
    }

    private static func discImage(center: CGPoint, radius: Double, color: CIColor) -> CIImage {
        roundedRect(CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius), radius: radius, color: color)
    }

    private static func ringImage(center: CGPoint, radius: Double, width: Double, color: CIColor) -> CIImage {
        let outer = discImage(center: center, radius: radius, color: color)
        let inner = discImage(center: center, radius: max(0, radius - width), color: .white)
        return outer.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner])
    }
}

/// The canvas background (story 20), rendered once per edit into a bitmap so frames only
/// composite it.
enum StudioBackgroundRenderer {
    static func render(_ background: StudioBackground, blur: Double, canvas: Size, assetURL: (String) -> URL?, context: CIContext) -> CIImage {
        let rect = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        var image: CIImage
        var blurs = false
        switch background {
        case .none:
            image = CIImage(color: .black)
        case let .color(c):
            image = CIImage(color: CIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha))
        case let .gradient(preset):
            image = gradient(preset, in: rect)
        case let .wallpaper(preset):
            image = gradient(preset.base, in: rect)
            for blob in preset.blobs {
                let filter = CIFilter.radialGradient()
                filter.center = CGPoint(x: blob.center.x * rect.width, y: (1 - blob.center.y) * rect.height)
                filter.radius0 = 0
                filter.radius1 = Float(blob.radius * max(rect.width, rect.height))
                filter.color0 = CIColor(red: blob.color.red, green: blob.color.green, blue: blob.color.blue, alpha: blob.color.alpha)
                filter.color1 = CIColor(red: blob.color.red, green: blob.color.green, blue: blob.color.blue, alpha: 0)
                if let blob = filter.outputImage { image = blob.composited(over: image) }
            }
            blurs = true
        case let .image(fileName):
            if let url = assetURL(fileName), let loaded = CIImage(contentsOf: url) {
                let scale = max(rect.width / loaded.extent.width, rect.height / loaded.extent.height)
                let scaled = loaded.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                image = scaled.transformed(by: CGAffineTransform(
                    translationX: (rect.width - scaled.extent.width) / 2 - scaled.extent.minX,
                    y: (rect.height - scaled.extent.height) / 2 - scaled.extent.minY
                ))
                blurs = true
            } else {
                image = CIImage(color: .black)
            }
        }
        if blurs, blur > 0 {
            image = image.clampedToExtent().applyingGaussianBlur(sigma: blur * 0.03 * min(rect.width, rect.height))
        }
        image = image.cropped(to: rect)
        // Rendered once: every frame then composites a plain bitmap.
        guard let cg = context.createCGImage(image, from: rect) else { return image }
        return CIImage(cgImage: cg)
    }

    static func gradient(_ preset: GradientPreset, in rect: CGRect) -> CIImage {
        let stops = preset.stops
        let radians = preset.angle * .pi / 180
        let dx = cos(radians), dy = sin(radians)          // top-left based: y grows downwards
        let length = abs(rect.width * dx) + abs(rect.height * dy)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let filter = CIFilter.linearGradient()
        filter.point0 = CGPoint(x: center.x - dx * length / 2, y: center.y + dy * length / 2)
        filter.point1 = CGPoint(x: center.x + dx * length / 2, y: center.y - dy * length / 2)
        let a = stops.first ?? .black, b = stops.last ?? .black
        filter.color0 = CIColor(red: a.red, green: a.green, blue: a.blue, alpha: a.alpha)
        filter.color1 = CIColor(red: b.red, green: b.green, blue: b.blue, alpha: b.alpha)
        return filter.outputImage ?? CIImage(color: .black)
    }
}
