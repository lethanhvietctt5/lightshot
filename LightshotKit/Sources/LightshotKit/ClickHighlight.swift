import Foundation

/// How the pointer halo is drawn (spec 0006, story 29): a stroked ring, a filled disc, or a filled
/// disc with a solid outline. Click rings are always stroked.
public enum CursorHighlightStyle: String, CaseIterable, Codable, Sendable {
    case ring
    case filled
    case outline

    public var title: String {
        switch self {
        case .ring: return "Ring"
        case .filled: return "Filled"
        case .outline: return "Outline"
        }
    }
}

public enum CursorHighlightSize: String, CaseIterable, Codable, Sendable {
    case small
    case medium
    case large

    /// The highlight's radius in screen points.
    public var radius: Double {
        switch self {
        case .small: return 14
        case .medium: return 22
        case .large: return 32
        }
    }

    public var title: String { rawValue.capitalized }
}

/// The highlight colours CleanShot offers, plus the system accent (resolved by the app).
public enum CursorHighlightColor: String, CaseIterable, Codable, Sendable {
    case blue, red, green, yellow, orange, purple, pink, gray, accent

    public var title: String { self == .accent ? "System Accent" : rawValue.capitalized }

    /// sRGB components, or `nil` for the accent colour the app looks up.
    public var rgb: RGBColor? {
        switch self {
        case .blue: return RGBColor(red: 0.20, green: 0.50, blue: 1.00)
        case .red: return RGBColor(red: 1.00, green: 0.25, blue: 0.25)
        case .green: return RGBColor(red: 0.25, green: 0.80, blue: 0.40)
        case .yellow: return RGBColor(red: 1.00, green: 0.85, blue: 0.20)
        case .orange: return RGBColor(red: 1.00, green: 0.55, blue: 0.15)
        case .purple: return RGBColor(red: 0.65, green: 0.40, blue: 1.00)
        case .pink: return RGBColor(red: 1.00, green: 0.45, blue: 0.75)
        case .gray: return RGBColor(red: 0.60, green: 0.60, blue: 0.60)
        case .accent: return nil
        }
    }
}

/// sRGB components in `0...1`.
public struct RGBColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// The user's highlight preferences (story 29), carried into `RecordingOptions`.
public struct ClickHighlightSettings: Equatable, Codable, Sendable {
    public var style: CursorHighlightStyle
    public var size: CursorHighlightSize
    public var color: CursorHighlightColor
    /// Play an expanding ring on every mouse-down.
    public var animateClicks: Bool

    public init(
        style: CursorHighlightStyle = .ring, size: CursorHighlightSize = .medium,
        color: CursorHighlightColor = .yellow, animateClicks: Bool = true
    ) {
        self.style = style
        self.size = size
        self.color = color
        self.animateClicks = animateClicks
    }

    public static let standard = ClickHighlightSettings()
}

/// One circle to draw over a frame, in screen points: the steady pointer halo, or a click ring.
/// Filled and stroked are independent so the `outline` style can be both.
public struct HighlightCircle: Equatable, Sendable {
    public let center: Point
    public let radius: Double
    /// `0...1`; click rings fade as they expand.
    public let opacity: Double
    public let filled: Bool
    /// The stroke's width, `0` for no stroke.
    public let strokeWidth: Double

    public init(center: Point, radius: Double, opacity: Double, filled: Bool, strokeWidth: Double) {
        self.center = center
        self.radius = radius
        self.opacity = opacity
        self.filled = filled
        self.strokeWidth = strokeWidth
    }

    /// The stroke width for a circle of `radius`: thin, but never under two points.
    public static func strokeWidth(for radius: Double) -> Double { max(2, radius * 0.18) }

    /// The circle's bounding box, for drawing.
    public var bounds: Rect {
        Rect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

/// The click-highlight geometry per frame (story 29): where the pointer halo sits and which click
/// rings are still animating. Pure, so the halo/ring rules are tested without a screen; the app's
/// compositor draws what `circles(at:)` returns.
///
/// The halo follows the pointer; a mouse-down spawns a ring that grows from the halo's radius to
/// `ringGrowth` times it over `ringDuration` seconds while fading out. Rings older than that are
/// forgotten.
public struct ClickHighlightModel: Equatable, Sendable {
    public static let ringDuration: TimeInterval = 0.4
    public static let ringGrowth: Double = 2.4
    public static let haloOpacity: Double = 0.45

    public let settings: ClickHighlightSettings
    public private(set) var pointer: Point?
    private var clicks: [Click] = []

    private struct Click: Equatable, Sendable {
        let position: Point
        let time: TimeInterval
    }

    public init(settings: ClickHighlightSettings) {
        self.settings = settings
    }

    public mutating func pointerMoved(to point: Point) {
        pointer = point
    }

    /// A mouse-down at `point`; with animation off it only moves the halo.
    public mutating func clicked(at point: Point, time: TimeInterval) {
        pointer = point
        guard settings.animateClicks else { return }
        clicks.append(Click(position: point, time: time))
    }

    /// Drop rings that have finished animating by `time`.
    public mutating func prune(at time: TimeInterval) {
        clicks.removeAll { time - $0.time >= Self.ringDuration }
    }

    /// What to draw at `time`: the halo (if the pointer is known) then any live click rings,
    /// oldest first.
    public func circles(at time: TimeInterval) -> [HighlightCircle] {
        var result: [HighlightCircle] = []
        let radius = settings.size.radius
        if let pointer {
            result.append(HighlightCircle(
                center: pointer, radius: radius, opacity: Self.haloOpacity,
                filled: settings.style != .ring,
                strokeWidth: settings.style == .filled ? 0 : HighlightCircle.strokeWidth(for: radius)
            ))
        }
        for click in clicks {
            let progress = (time - click.time) / Self.ringDuration
            guard progress >= 0, progress < 1 else { continue }
            let ringRadius = radius * (1 + (Self.ringGrowth - 1) * progress)
            result.append(HighlightCircle(
                center: click.position, radius: ringRadius, opacity: 1 - progress,
                filled: false, strokeWidth: HighlightCircle.strokeWidth(for: ringRadius)
            ))
        }
        return result
    }
}

/// Maps screen points onto the recorded frame's pixels (story 29): the region's top-left in
/// screen space, and the frame's pixels per point on each axis (which differ from the display's
/// backing scale when the output is capped or scaled to 1x).
public struct FrameMapping: Equatable, Sendable {
    public let regionOrigin: Point
    public let pixelsPerPointX: Double
    public let pixelsPerPointY: Double

    public init(regionOrigin: Point, pixelsPerPointX: Double, pixelsPerPointY: Double) {
        self.regionOrigin = regionOrigin
        self.pixelsPerPointX = pixelsPerPointX
        self.pixelsPerPointY = pixelsPerPointY
    }

    /// The frame pixel for a screen point (top-left origin, like `CaptureRegion`).
    public func pixelPoint(for screenPoint: Point) -> Point {
        Point(x: (screenPoint.x - regionOrigin.x) * pixelsPerPointX, y: (screenPoint.y - regionOrigin.y) * pixelsPerPointY)
    }

    /// A circle in screen points as a circle in frame pixels (radius and stroke follow the x scale).
    public func pixelCircle(for circle: HighlightCircle) -> HighlightCircle {
        HighlightCircle(
            center: pixelPoint(for: circle.center), radius: circle.radius * pixelsPerPointX, opacity: circle.opacity,
            filled: circle.filled, strokeWidth: circle.strokeWidth * pixelsPerPointX
        )
    }
}
