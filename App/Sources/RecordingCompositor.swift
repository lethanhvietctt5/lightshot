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
        self.highlightColor = clickHighlight.map { $0.color.nsColor.cgColor } ?? .clear
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

}

extension CursorHighlightColor {
    /// The highlight colour as AppKit sees it; `.accent` is the system accent. Shared by the
    /// compositor and the Settings preview so the two never disagree.
    var nsColor: NSColor {
        guard let rgb else { return .controlAccentColor }
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}
