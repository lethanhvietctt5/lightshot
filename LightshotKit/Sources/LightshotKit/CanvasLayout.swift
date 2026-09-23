import Foundation

/// Where everything sits on the output canvas (spec 0007, stories 21–22 and 25), in output pixels
/// with a top-left origin. The renderer and the size estimate both use it, so what the preview
/// shows and what export writes agree.
public struct CanvasLayout: Equatable, Sendable {
    /// Share of the canvas' shorter side that a shadow strength of `1` blurs over.
    public static let shadowReach = 0.04

    /// The output frame, even edges.
    public let canvas: Size
    /// The screen, aspect-fit inside the padded canvas and centred.
    public let content: Rect
    public let cornerRadius: Double
    public let shadowRadius: Double

    public init(sourceSize: Size, style: CanvasStyle, resolution: OutputResolution) {
        let ratio = style.aspect.ratio(source: sourceSize)
        let sourceShorter = max(2, min(sourceSize.width, sourceSize.height))
        let shorter = min(resolution.shorterSide ?? sourceShorter, sourceShorter)
        func even(_ v: Double) -> Double { max(2, Double(Int(v.rounded()) & ~1)) }
        let width: Double
        let height: Double
        if ratio >= 1 {
            height = even(shorter)
            width = even(shorter * ratio)
        } else {
            width = even(shorter)
            height = even(shorter / ratio)
        }
        canvas = Size(width: width, height: height)

        let pad = min(max(style.padding, 0), CanvasStyle.maximumPadding) * min(width, height)
        let available = Size(width: width - 2 * pad, height: height - 2 * pad)
        let sourceRatio = sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 1
        var fitted = Size(width: available.width, height: available.width / sourceRatio)
        if fitted.height > available.height {
            fitted = Size(width: available.height * sourceRatio, height: available.height)
        }
        content = Rect(x: (width - fitted.width) / 2, y: (height - fitted.height) / 2, width: fitted.width, height: fitted.height)
        cornerRadius = min(max(style.cornerRadius, 0), CanvasStyle.maximumCornerRadius) * min(fitted.width, fitted.height)
        shadowRadius = min(max(style.shadow, 0), 1) * Self.shadowReach * min(width, height)
    }
}
