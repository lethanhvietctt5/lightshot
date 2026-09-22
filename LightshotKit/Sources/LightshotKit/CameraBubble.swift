import Foundation

/// A camera the recorder can composite (spec 0006, story 27).
public struct CameraDevice: Equatable, Identifiable, Sendable {
    /// The OS's stable identifier for the device (`AVCaptureDevice.uniqueID`).
    public let id: String
    public let name: String
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// The OS camera seam (spec 0006, stories 26–27): what the recorder toolbar's camera menu lists.
/// Frames are pixel buffers — an OS type — so they stay in the app target's capture, exactly as
/// microphone audio does behind `AudioInputService`.
public protocol CameraService: Sendable {
    func availableCameras() async -> [CameraDevice]
}

/// How big the bubble is, as a share of the recording region's shorter side.
public enum CameraBubbleSize: String, CaseIterable, Codable, Sendable {
    case tiny, small, medium, large, huge

    public var fraction: Double {
        switch self {
        case .tiny: return 0.12
        case .small: return 0.18
        case .medium: return 0.25
        case .large: return 0.33
        case .huge: return 0.45
        }
    }

    public var title: String { rawValue.capitalized }
}

public enum CameraBubbleShape: String, CaseIterable, Codable, Sendable {
    case circle, rounded, square

    public var title: String { rawValue.capitalized }
}

/// The user's camera-bubble preferences (story 27), carried into `RecordingOptions`. The position
/// is the bubble's centre as a fraction of the region on each axis, so it survives a different
/// region size; `nil` is the default corner.
public struct CameraBubbleSettings: Equatable, Codable, Sendable {
    public var size: CameraBubbleSize
    public var shape: CameraBubbleShape
    /// Flip horizontally, so the bubble reads like a mirror (the natural way to see oneself).
    public var mirror: Bool
    public var anchor: Point?

    public init(size: CameraBubbleSize = .medium, shape: CameraBubbleShape = .circle, mirror: Bool = true, anchor: Point? = nil) {
        self.size = size
        self.shape = shape
        self.mirror = mirror
        self.anchor = anchor
    }

    public static let standard = CameraBubbleSettings()
}

/// Where and how big the bubble is (stories 26–28), pure so the on-screen preview and the
/// composited output agree to the pixel: both call this with the same region size and scale the
/// result by their own pixels-per-point.
public enum CameraBubbleLayout {
    /// Points between the bubble and the region's edges in the default corner.
    public static let margin: Double = 16
    /// The bubble never shrinks below this (unless the region itself is smaller).
    public static let minimumSide: Double = 80

    /// The bubble's side in region points.
    public static func side(for size: CameraBubbleSize, in region: Size) -> Double {
        let shorter = min(region.width, region.height)
        let wanted = max(shorter * size.fraction, minimumSide)
        return min(wanted, shorter)
    }

    /// The bubble's frame in region points (top-left origin), kept inside the region — or the whole
    /// region when the camera is fullscreen (story 28).
    public static func frame(_ settings: CameraBubbleSettings, in region: Size, fullscreen: Bool = false) -> Rect {
        if fullscreen { return Rect(x: 0, y: 0, width: region.width, height: region.height) }
        let side = side(for: settings.size, in: region)
        let center = settings.anchor.map { Point(x: $0.x * region.width, y: $0.y * region.height) }
            ?? Point(x: region.width - margin - side / 2, y: region.height - margin - side / 2)
        let x = min(max(center.x - side / 2, 0), max(region.width - side, 0))
        let y = min(max(center.y - side / 2, 0), max(region.height - side, 0))
        return Rect(x: x, y: y, width: side, height: side)
    }

    /// The anchor to store for a bubble whose centre was dragged to `center` (region points).
    public static func anchor(forCenter center: Point, in region: Size) -> Point {
        Point(
            x: region.width > 0 ? min(max(center.x / region.width, 0), 1) : 0.5,
            y: region.height > 0 ? min(max(center.y / region.height, 0), 1) : 0.5
        )
    }

    /// Fullscreen has no rounding: the camera fills the frame edge to edge.
    public static func cornerRadius(for shape: CameraBubbleShape, side: Double, fullscreen: Bool = false) -> Double {
        if fullscreen { return 0 }
        switch shape {
        case .circle: return side / 2
        case .rounded: return side * 0.18
        case .square: return 0
        }
    }

    /// Aspect-fill: the rect a camera image of `imageAspect` (width ÷ height) is drawn into so it
    /// covers `target`, centred — the parts outside `target` are clipped by the bubble's shape.
    public static func coverRect(imageAspect: Double, in target: Rect) -> Rect {
        guard imageAspect > 0, target.width > 0, target.height > 0 else { return target }
        let targetAspect = target.width / target.height
        if imageAspect > targetAspect {
            let width = target.height * imageAspect
            return Rect(x: target.minX - (width - target.width) / 2, y: target.minY, width: width, height: target.height)
        } else {
            let height = target.width / imageAspect
            return Rect(x: target.minX, y: target.minY - (height - target.height) / 2, width: target.width, height: height)
        }
    }
}
