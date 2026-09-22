import AppKit
import CoreMedia
import CoreVideo
import LightshotKit

/// Draws the recording overlays into each frame before it is encoded (spec 0006, decision 4):
/// today the click highlight (story 29); the keystroke pill (R11) and the camera bubble (R9) join
/// it. The overlays therefore never appear on screen and land in the file at exactly the frame's
/// pixel scale, whatever the display's.
///
/// Runs on the recorder's serial queue: pointer events are forwarded onto it, frames are composited
/// on it. Each composited frame is a copy of the stream's buffer (which belongs to ScreenCaptureKit)
/// drawn into a buffer from a pool we own; a frame with nothing to draw is passed through untouched.
final class RecordingCompositor: @unchecked Sendable {
    private let mapping: FrameMapping
    private var highlight: ClickHighlightModel?
    private let highlightColor: CGColor
    private var pool: CVPixelBufferPool?
    private let width: Int
    private let height: Int

    init(mapping: FrameMapping, width: Int, height: Int, clickHighlight: ClickHighlightSettings?) {
        self.mapping = mapping
        self.width = width
        self.height = height
        self.highlight = clickHighlight.map { ClickHighlightModel(settings: $0) }
        self.highlightColor = Self.cgColor(for: clickHighlight?.color ?? .yellow)
    }

    /// Whether any overlay is active; when not, frames pass through without a copy.
    var isActive: Bool { highlight != nil }

    // MARK: - Events (on the recorder's queue)

    func handle(_ event: PointerEvent, at time: TimeInterval) {
        switch event {
        case let .moved(point): highlight?.pointerMoved(to: point)
        case let .down(point): highlight?.clicked(at: point, time: time)
        }
    }

    // MARK: - Frames (on the recorder's queue)

    /// The frame with the overlays drawn, or `source` itself when there is nothing to draw.
    func composite(_ source: CVPixelBuffer, at time: TimeInterval) -> CVPixelBuffer {
        highlight?.prune(at: time)
        let circles = highlight?.circles(at: time) ?? []
        guard !circles.isEmpty, let target = copy(source) else { return source }

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
        draw(circles.map(mapping.pixelCircle), into: context)
        return target
    }

    private func draw(_ circles: [HighlightCircle], into context: CGContext) {
        for circle in circles {
            let rect = CGRect(
                x: circle.center.x - circle.radius, y: circle.center.y - circle.radius,
                width: circle.radius * 2, height: circle.radius * 2
            )
            context.setAlpha(CGFloat(circle.opacity))
            if circle.filled {
                context.setFillColor(highlightColor)
                context.fillEllipse(in: rect)
            } else {
                context.setStrokeColor(highlightColor)
                context.setLineWidth(max(2, circle.radius * 0.18))
                context.strokeEllipse(in: rect)
            }
        }
    }

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

    private static func cgColor(for color: CursorHighlightColor) -> CGColor {
        if let rgb = color.rgb {
            return CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
        return NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor ?? CGColor(srgbRed: 0.2, green: 0.5, blue: 1, alpha: 1)
    }
}
