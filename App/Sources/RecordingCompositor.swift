import AppKit
import Carbon.HIToolbox
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreText
import CoreVideo
import LightshotKit
import VideoToolbox

/// Draws the recording overlays into each frame before it is encoded (spec 0006, decision 4):
/// the camera bubble (stories 26–28), then the click highlight (story 29) and the keystroke pills
/// (stories 30–31) on top. The overlays therefore never appear on screen and land in the file at
/// exactly the frame's pixel scale, whatever the display's.
///
/// Runs on the recorder's serial queue: input events are forwarded onto it, frames are composited
/// on it. Each composited frame is a copy of the stream's buffer (which belongs to ScreenCaptureKit)
/// drawn into a buffer from a pool we own; a frame with nothing to draw is passed through untouched.
final class RecordingCompositor: @unchecked Sendable {
    private let mapping: FrameMapping
    private let width: Int
    private let height: Int
    private var pool: CVPixelBufferPool?

    private var highlight: ClickHighlightModel?
    private let highlightColor: CGColor

    private var keystrokes: KeystrokeOverlayModel?
    private let pillStyle: KeystrokePillStyle?
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])

    /// The camera feed plus the region's size in points — the bubble is laid out in points, like
    /// the on-screen preview, and scaled by the mapping, so the two agree.
    private let camera: (feed: CameraFeed, regionSize: Size)?

    /// - Parameter systemAppearanceIsDark: resolves the keystroke pill's `system` appearance, read
    ///   once at start (the file cannot follow a mid-recording theme switch anyway).
    init(
        mapping: FrameMapping, width: Int, height: Int,
        clickHighlight: ClickHighlightSettings?,
        keystrokes: KeystrokeOverlaySettings? = nil, systemAppearanceIsDark: Bool = false,
        camera: (feed: CameraFeed, regionSize: Size)? = nil
    ) {
        self.mapping = mapping
        self.width = width
        self.height = height
        self.camera = camera
        self.highlight = clickHighlight.map { ClickHighlightModel(settings: $0) }
        self.highlightColor = clickHighlight.map { $0.color.nsColor.cgColor } ?? .clear
        self.keystrokes = keystrokes.map { KeystrokeOverlayModel(settings: $0) }
        self.pillStyle = keystrokes.map {
            KeystrokePillStyle($0, pixelsPerPoint: mapping.pixelsPerPointX, systemIsDark: systemAppearanceIsDark)
        }
    }

    /// Whether any overlay is active; when not, frames pass through without a copy.
    var isActive: Bool { highlight != nil || keystrokes != nil || camera != nil }

    // MARK: - Events (on the recorder's queue)

    func handle(_ event: InputEvent, at time: TimeInterval) {
        switch event {
        case .pointer(.moved(let point)): highlight?.pointerMoved(to: point)
        case .pointer(.down(let point)): highlight?.clicked(at: point, time: time)
        case .key(let key): keystrokes?.handle(key, at: time)
        }
    }

    // MARK: - Frames (on the recorder's queue)

    /// The frame with the overlays drawn, or `source` itself when there is nothing to draw.
    func composite(_ source: CVPixelBuffer, at time: TimeInterval) -> CVPixelBuffer {
        highlight?.prune(at: time)
        keystrokes?.prune(at: time)
        // Story 31: re-check secure input on every rendered frame, not only on key events, so a
        // password field that takes focus between keys blacks the pill out at once.
        keystrokes?.setSecureInput(IsSecureEventInputEnabled())

        let circles = highlight?.circles(at: time) ?? []
        let pills = keystrokes?.items(at: time) ?? []
        let cameraFrame = camera?.feed.current?.latestFrame
        guard !circles.isEmpty || !pills.isEmpty || cameraFrame != nil, let target = copy(source) else { return source }

        CVPixelBufferLockBaseAddress(target, [])
        defer { CVPixelBufferUnlockBaseAddress(target, []) }
        guard let base = CVPixelBufferGetBaseAddress(target),
              let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(target), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return source }
        // Frame pixels are top-left origin like `CaptureRegion`; CoreGraphics is bottom-left.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        if let camera, let cameraFrame { draw(cameraFrame, feed: camera.feed, regionSize: camera.regionSize, into: context) }
        draw(circles.map(mapping.pixelCircle), into: context)
        if let pillStyle, !pills.isEmpty { draw(pills, style: pillStyle, over: source, into: context) }
        return target
    }

    // MARK: - Camera bubble

    /// The newest camera frame, aspect-filled into the bubble (or the whole frame when fullscreen,
    /// story 28), masked to the shape, mirrored if asked.
    private func draw(_ frame: CVPixelBuffer, feed: CameraFeed, regionSize: Size, into context: CGContext) {
        let (settings, fullscreen) = feed.snapshot()
        let scale = mapping.pixelsPerPointX
        let local = fullscreen
            ? Rect(x: 0, y: 0, width: regionSize.width, height: regionSize.height)
            : CameraBubbleLayout.frame(settings, in: regionSize)
        let rect = Rect(x: local.minX * scale, y: local.minY * scale, width: local.width * scale, height: local.height * scale)
        let radius = fullscreen ? 0 : CameraBubbleLayout.cornerRadius(for: settings.shape, side: local.width) * scale
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(frame, options: nil, imageOut: &image)
        guard let image else { return }
        let aspect = Double(image.width) / Double(max(image.height, 1))
        let cover = CameraBubbleLayout.coverRect(imageAspect: aspect, in: rect).cgRect
        let target = rect.cgRect

        context.saveGState()
        context.addPath(CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        // Images draw upright in a bottom-left context; undo the frame flip around the bubble.
        context.translateBy(x: 0, y: target.midY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -target.midY)
        if settings.mirror {
            context.translateBy(x: target.midX, y: 0)
            context.scaleBy(x: -1, y: 1)
            context.translateBy(x: -target.midX, y: 0)
        }
        context.interpolationQuality = .medium
        context.draw(image, in: cover)
        context.restoreGState()
    }

    // MARK: - Click highlight

    private func draw(_ circles: [HighlightCircle], into context: CGContext) {
        context.setFillColor(highlightColor)
        context.setStrokeColor(highlightColor)
        for circle in circles {
            let rect = circle.bounds.cgRect
            context.setAlpha(CGFloat(circle.opacity))
            if circle.filled { context.fillEllipse(in: rect) }
            if circle.strokeWidth > 0 {
                context.setLineWidth(CGFloat(circle.strokeWidth))
                context.strokeEllipse(in: rect)
            }
        }
        context.setAlpha(1)
    }

    // MARK: - Keystroke pills

    /// One pill per item, laid out left to right and anchored by the configured position; the
    /// backdrop is a blur of the frame under the pill (or a flat tint), the text on top.
    private func draw(_ items: [KeystrokeItem], style: KeystrokePillStyle, over source: CVPixelBuffer, into context: CGContext) {
        let lines = items.map { style.line(for: $0.text) }
        let widths = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) + 2 * style.paddingX }
        let pillHeight = style.ascent + style.descent + 2 * style.paddingY
        let groupWidth = widths.reduce(0, +) + style.gap * CGFloat(max(0, items.count - 1))
        let group = style.position.rect(
            for: Size(width: Double(groupWidth), height: Double(pillHeight)),
            in: Size(width: Double(width), height: Double(height)), margin: Double(style.margin)
        ).cgRect

        // One blur of the whole group per frame (a GPU render plus readback), shared by every pill.
        let backdrop = style.blur ? blurred(source, in: group, radius: style.blurRadius) : nil

        var x = group.minX
        for (index, item) in items.enumerated() {
            let rect = CGRect(x: x, y: group.minY, width: widths[index], height: pillHeight)
            x += widths[index] + style.gap
            context.saveGState()
            // The press bump scales about the pill's centre.
            let center = CGPoint(x: rect.midX, y: rect.midY)
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: CGFloat(item.scale), y: CGFloat(item.scale))
            context.translateBy(x: -center.x, y: -center.y)
            // The fade applies to the pill as a whole, not to backdrop, tint and text separately.
            context.setAlpha(CGFloat(item.opacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)

            let path = CGPath(roundedRect: rect, cornerWidth: pillHeight / 2, cornerHeight: pillHeight / 2, transform: nil)
            context.addPath(path)
            context.clip()
            if let backdrop, let groupRect = backdropRect {
                // Images draw upright in a bottom-left context; undo the frame flip around the rect.
                context.saveGState()
                context.translateBy(x: 0, y: groupRect.midY)
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: 0, y: -groupRect.midY)
                context.draw(backdrop, in: groupRect)
                context.restoreGState()
            }
            context.setFillColor(style.tint)
            context.fill(rect)

            // Glyphs draw upright too: flip around the baseline.
            let baseline = rect.minY + style.paddingY + style.ascent
            context.saveGState()
            context.translateBy(x: 0, y: baseline)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = CGPoint(x: rect.minX + style.paddingX, y: 0)
            CTLineDraw(lines[index], context)
            context.restoreGState()
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    /// Where the last `blurred(_:in:)` image belongs, in top-left pixel coordinates.
    private var backdropRect: CGRect?

    /// The frame under `rect` (top-left pixel coordinates), blurred; `backdropRect` says where it goes.
    private func blurred(_ source: CVPixelBuffer, in rect: CGRect, radius: CGFloat) -> CGImage? {
        backdropRect = nil
        // CoreImage is bottom-left; the frame's pixel rect flips vertically.
        let ciRect = CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !ciRect.isEmpty else { return nil }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = CIImage(cvPixelBuffer: source).clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage, let image = ciContext.createCGImage(output, from: ciRect) else { return nil }
        backdropRect = CGRect(x: ciRect.minX, y: CGFloat(height) - ciRect.maxY, width: ciRect.width, height: ciRect.height)
        return image
    }

    // MARK: - Buffers

    /// A pool buffer holding `source`'s pixels — our memory to draw into.
    private func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var target: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target) == kCVReturnSuccess, let target else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(target, [])
        defer {
            CVPixelBufferUnlockBaseAddress(target, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(target),
              CVPixelBufferGetWidth(source) == width, CVPixelBufferGetHeight(source) == height
        else { return nil }
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let targetStride = CVPixelBufferGetBytesPerRow(target)
        let rowBytes = min(sourceStride, targetStride, width * 4)
        for row in 0..<height {
            memcpy(to + row * targetStride, from + row * sourceStride, rowBytes)
        }
        return target
    }
}

/// How the keystroke pill is drawn (story 30), resolved once per recording in frame pixels.
struct KeystrokePillStyle {
    let position: KeystrokeOverlayPosition
    let blur: Bool
    let font: CTFont
    let ascent: CGFloat
    let descent: CGFloat
    let paddingX: CGFloat
    let paddingY: CGFloat
    let gap: CGFloat
    let margin: CGFloat
    let blurRadius: CGFloat
    let tint: CGColor
    let text: CGColor

    init(_ settings: KeystrokeOverlaySettings, pixelsPerPoint: Double, systemIsDark: Bool) {
        let scale = CGFloat(pixelsPerPoint)
        let fontSize = CGFloat(settings.size.fontSize) * scale
        position = settings.position
        blur = settings.blurBackground
        font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        paddingX = fontSize * 0.6
        paddingY = fontSize * 0.35
        gap = fontSize * 0.4
        margin = 24 * scale
        blurRadius = 10 * scale
        let dark: Bool
        switch settings.appearance {
        case .light: dark = false
        case .dark: dark = true
        case .system: dark = systemIsDark
        }
        // Over a blur the tint is a wash; flat, it has to carry the contrast itself.
        tint = dark
            ? CGColor(gray: 0.05, alpha: settings.blurBackground ? 0.5 : 0.8)
            : CGColor(gray: 1, alpha: settings.blurBackground ? 0.55 : 0.92)
        text = dark ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0.05, alpha: 1)
    }

    func line(for string: String) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: text,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }
}

extension KeystrokeOverlayAppearance {
    /// Whether the system appearance is dark right now, readable off the main actor (the
    /// compositor is built on the recorder's actor, where `NSApp.effectiveAppearance` is not).
    static var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
}

extension CursorHighlightColor {
    /// The highlight colour as AppKit sees it; `.accent` is the system accent. Shared by the
    /// compositor and the Settings preview so the two never disagree.
    var nsColor: NSColor {
        guard let rgb else { return .controlAccentColor }
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}
