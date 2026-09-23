import Foundation

// The Studio editor's edits (spec 0007): everything the user can change about a take before
// export, as one Codable value. `StudioDocument` mutates it through commands; the renderer reads
// it. Ranges are clamped by `normalized()`, which every command runs, so a stored or decoded
// value is always renderable.

/// A kept range of the source movie, played at `speed` (spec 0007, stories 6–8). Times are
/// **source seconds**.
public struct StudioClip: Equatable, Codable, Sendable, Identifiable {
    public static let minimumLength = 0.1
    public static let speedRange = 0.25...4.0

    public var id: UUID
    public var start: Double
    public var end: Double
    public var speed: Double

    public init(id: UUID = UUID(), start: Double, end: Double, speed: Double = 1) {
        self.id = id
        self.start = start
        self.end = end
        self.speed = speed
    }

    public var sourceLength: Double { end - start }
    public var outputLength: Double { sourceLength / speed }
}

/// Where a zoom looks (story 11): a fixed point of the frame (normalised, top-left origin), or the
/// smoothed cursor.
public enum ZoomFocus: Equatable, Codable, Sendable {
    case followCursor
    case point(Point)
}

/// A zoom pill on the timeline (stories 10–13). Times are **source seconds**, so a cut hides the
/// part of a zoom it removes rather than shifting it.
public struct ZoomRegion: Equatable, Codable, Sendable, Identifiable {
    public static let defaultLength = 2.0
    public static let minimumLength = 0.5
    public static let defaultScale = 2.0
    public static let minimumScale = 1.1
    public static let maximumScale = 5.0

    public var id: UUID
    public var start: Double
    public var end: Double
    public var scale: Double
    public var focus: ZoomFocus

    public init(id: UUID = UUID(), start: Double, end: Double, scale: Double = defaultScale, focus: ZoomFocus = .followCursor) {
        self.id = id
        self.start = start
        self.end = end
        self.scale = scale
        self.focus = focus
    }

    public var length: Double { end - start }
}

/// A named two-or-more-stop linear gradient (story 20).
public enum GradientPreset: String, CaseIterable, Codable, Sendable {
    case sunset, ocean, forest, candy, dusk, slate, peach, mint

    public var title: String { rawValue.capitalized }

    /// Colour stops from the start to the end of the gradient line.
    public var stops: [RGBAColor] {
        func c(_ hex: UInt32) -> RGBAColor {
            RGBAColor(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
        switch self {
        case .sunset: return [c(0xFF7E5F), c(0xFEB47B)]
        case .ocean: return [c(0x2E3192), c(0x1BFFFF)]
        case .forest: return [c(0x134E5E), c(0x71B280)]
        case .candy: return [c(0xD53369), c(0xDAAE51)]
        case .dusk: return [c(0x2C3E50), c(0xFD746C)]
        case .slate: return [c(0x232526), c(0x414345)]
        case .peach: return [c(0xFFDDE1), c(0xEE9CA7)]
        case .mint: return [c(0xA8E063), c(0x56AB2F)]
        }
    }

    /// The gradient line's angle in degrees (0 = left → right, 90 = top → bottom).
    public var angle: Double { 135 }
}

/// A generated wallpaper (story 20): a base gradient with soft colour blobs, drawn by the renderer
/// at any size — the app ships no wallpaper images (spec 0007, decision 4).
public enum WallpaperPreset: String, CaseIterable, Codable, Sendable {
    case aurora, lagoon, ember, orchid, midnight, meadow

    public var title: String { rawValue.capitalized }

    public struct Blob: Equatable, Sendable {
        /// Centre, normalised to the canvas (top-left origin).
        public let center: Point
        /// Radius as a fraction of the canvas' longer side.
        public let radius: Double
        public let color: RGBAColor
    }

    public var base: GradientPreset {
        switch self {
        case .aurora: return .ocean
        case .lagoon: return .forest
        case .ember: return .sunset
        case .orchid: return .candy
        case .midnight: return .slate
        case .meadow: return .mint
        }
    }

    public var blobs: [Blob] {
        let tints: [RGBAColor]
        switch self {
        case .aurora: tints = [RGBAColor(red: 0.55, green: 0.3, blue: 1, alpha: 0.8), RGBAColor(red: 0.1, green: 1, blue: 0.7, alpha: 0.7)]
        case .lagoon: tints = [RGBAColor(red: 0.1, green: 0.8, blue: 0.9, alpha: 0.7), RGBAColor(red: 0.9, green: 1, blue: 0.6, alpha: 0.5)]
        case .ember: tints = [RGBAColor(red: 1, green: 0.25, blue: 0.3, alpha: 0.7), RGBAColor(red: 1, green: 0.9, blue: 0.4, alpha: 0.6)]
        case .orchid: tints = [RGBAColor(red: 0.6, green: 0.2, blue: 0.9, alpha: 0.7), RGBAColor(red: 1, green: 0.6, blue: 0.8, alpha: 0.6)]
        case .midnight: tints = [RGBAColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 0.6), RGBAColor(red: 0.6, green: 0.2, blue: 0.6, alpha: 0.5)]
        case .meadow: tints = [RGBAColor(red: 1, green: 0.95, blue: 0.5, alpha: 0.6), RGBAColor(red: 0.2, green: 0.7, blue: 0.9, alpha: 0.5)]
        }
        return [
            Blob(center: Point(x: 0.2, y: 0.25), radius: 0.55, color: tints[0]),
            Blob(center: Point(x: 0.85, y: 0.8), radius: 0.6, color: tints[1]),
        ]
    }
}

/// What sits behind the screen on the canvas (story 20).
public enum StudioBackground: Equatable, Codable, Sendable {
    /// Black behind any padding; with no padding, nothing shows.
    case none
    case color(RGBAColor)
    case gradient(GradientPreset)
    case wallpaper(WallpaperPreset)
    /// The user's image, copied into the project folder under this file name.
    case image(fileName: String)
}

/// The output frame's shape (story 22).
public enum StudioAspect: String, CaseIterable, Codable, Sendable {
    case auto, wide, standard, square, portrait, vertical

    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .wide: return "16:9"
        case .standard: return "4:3"
        case .square: return "1:1"
        case .portrait: return "4:5"
        case .vertical: return "9:16"
        }
    }

    /// Width over height; `auto` is the source's own.
    public func ratio(source: Size) -> Double {
        switch self {
        case .auto: return source.height > 0 ? source.width / source.height : 16.0 / 9
        case .wide: return 16.0 / 9
        case .standard: return 4.0 / 3
        case .square: return 1
        case .portrait: return 4.0 / 5
        case .vertical: return 9.0 / 16
        }
    }
}

/// The canvas around the screen (stories 21–22).
public struct CanvasStyle: Equatable, Codable, Sendable {
    public static let maximumPadding = 0.3
    public static let maximumCornerRadius = 0.25

    /// Space around the screen, as a fraction of the canvas' shorter side.
    public var padding: Double
    /// Screen corner radius, as a fraction of the screen's shorter side.
    public var cornerRadius: Double
    /// Shadow strength `0…1`.
    public var shadow: Double
    public var aspect: StudioAspect
    /// Background blur `0…1` (wallpapers and images).
    public var backgroundBlur: Double

    public init(padding: Double = 0, cornerRadius: Double = 0, shadow: Double = 0, aspect: StudioAspect = .auto, backgroundBlur: Double = 0) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.aspect = aspect
        self.backgroundBlur = backgroundBlur
    }
}

/// How clicks read on video (story 16).
public enum ClickEffect: String, CaseIterable, Codable, Sendable {
    case none, ripple, pulse

    public var title: String { rawValue.capitalized }
}

/// The cursor, re-drawn from recorded data (stories 14–19).
public struct CursorStyle: Equatable, Codable, Sendable {
    public static let minimumSize = 0.5
    public static let maximumSize = 3.0

    public var visible: Bool
    /// Scale over the system arrow's natural size.
    public var size: Double
    /// `0` follows the samples exactly; `1` is the heaviest glide.
    public var smoothing: Double
    public var hideWhenIdle: Bool
    /// Seconds without movement before the cursor fades.
    public var idleDelay: Double
    public var clickEffect: ClickEffect
    public var clickColor: RGBAColor
    /// Directional blur along the cursor's velocity, `0…1`.
    public var motionBlur: Double

    public init(
        visible: Bool = true, size: Double = 1.5, smoothing: Double = 0.5, hideWhenIdle: Bool = false,
        idleDelay: Double = 2, clickEffect: ClickEffect = .ripple,
        clickColor: RGBAColor = RGBAColor(red: 0.2, green: 0.5, blue: 1), motionBlur: Double = 0.4
    ) {
        self.visible = visible
        self.size = size
        self.smoothing = smoothing
        self.hideWhenIdle = hideWhenIdle
        self.idleDelay = idleDelay
        self.clickEffect = clickEffect
        self.clickColor = clickColor
        self.motionBlur = motionBlur
    }
}

/// The camera track's placement after the take (story 23); reuses spec 0006's bubble settings.
public struct StudioCameraStyle: Equatable, Codable, Sendable {
    public var visible: Bool
    public var bubble: CameraBubbleSettings

    public init(visible: Bool = true, bubble: CameraBubbleSettings = .standard) {
        self.visible = visible
        self.bubble = bubble
    }
}

/// The keystroke overlay after the take (story 24); reuses spec 0006's overlay settings.
public struct StudioKeystrokeStyle: Equatable, Codable, Sendable {
    public var visible: Bool
    public var overlay: KeystrokeOverlaySettings

    public init(visible: Bool = true, overlay: KeystrokeOverlaySettings = .standard) {
        self.visible = visible
        self.overlay = overlay
    }
}

/// The export's resolution preset (story 25): the canvas' shorter side, never above the source's.
public enum OutputResolution: String, CaseIterable, Codable, Sendable {
    case source, p2160, p1440, p1080, p720

    public var title: String {
        switch self {
        case .source: return "Source"
        case .p2160: return "4K"
        case .p1440: return "1440p"
        case .p1080: return "1080p"
        case .p720: return "720p"
        }
    }

    public var shorterSide: Double? {
        switch self {
        case .source: return nil
        case .p2160: return 2160
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        }
    }
}

public enum StudioCodec: String, CaseIterable, Codable, Sendable {
    case h264, hevc

    public var title: String { self == .h264 ? "H.264" : "HEVC" }
}

public enum StudioOutputFormat: String, CaseIterable, Codable, Sendable {
    case mp4, gif

    public var title: String { rawValue.uppercased() }
}

/// Export settings (stories 25–26).
public struct StudioOutput: Equatable, Codable, Sendable {
    public static let frameRates = [24, 30, 60]

    public var resolution: OutputResolution
    public var fps: Int
    public var codec: StudioCodec
    /// `0…1`, the same curve as spec 0006's `VideoBitRate`.
    public var quality: Double
    public var format: StudioOutputFormat

    public init(resolution: OutputResolution = .source, fps: Int = 60, codec: StudioCodec = .h264, quality: Double = VideoBitRate.defaultQuality, format: StudioOutputFormat = .mp4) {
        self.resolution = resolution
        self.fps = fps
        self.codec = codec
        self.quality = quality
        self.format = format
    }
}

/// All of a Studio session's edits (spec 0007). Codable and versioned: it is `project.json`.
public struct StudioEdits: Equatable, Codable, Sendable {
    public static let currentVersion = 1
    public static let transitionRange = 0.2...1.5

    /// Where the defaults come from: a studio take gets the designed look; a plain MP4 starts
    /// untouched, so exporting it unchanged changes nothing but the encode.
    public enum Look: Sendable { case studio, plain }

    public var version: Int
    public var sourceDuration: Double
    public var clips: [StudioClip]
    public var zooms: [ZoomRegion]
    /// Seconds a zoom takes to ease in or out (story 13).
    public var zoomTransition: Double
    /// Blur on the screen while the zoom camera moves, `0…1` (story 18).
    public var zoomMotionBlur: Double
    public var background: StudioBackground
    public var canvas: CanvasStyle
    public var cursor: CursorStyle
    public var camera: StudioCameraStyle
    public var keystrokes: StudioKeystrokeStyle
    public var audio: AudioEdit
    public var output: StudioOutput
    /// Burned-in captions (round 2, stories 29–30).
    public var captions: StudioCaptions
    /// Text annotations (round 2, story 32).
    public var annotations: [TextAnnotation]

    public init(sourceDuration: Double, look: Look) {
        version = Self.currentVersion
        self.sourceDuration = max(sourceDuration, StudioClip.minimumLength)
        clips = [StudioClip(start: 0, end: self.sourceDuration)]
        zooms = []
        zoomTransition = 0.6
        zoomMotionBlur = 0.3
        switch look {
        case .studio:
            background = .wallpaper(.aurora)
            canvas = CanvasStyle(padding: 0.08, cornerRadius: 0.02, shadow: 0.6, aspect: .auto, backgroundBlur: 0)
        case .plain:
            background = .none
            canvas = CanvasStyle()
        }
        cursor = CursorStyle()
        camera = StudioCameraStyle()
        keystrokes = StudioKeystrokeStyle()
        audio = .unchanged
        output = StudioOutput()
        captions = StudioCaptions()
        annotations = []
    }

    private enum CodingKeys: String, CodingKey {
        case version, sourceDuration, clips, zooms, zoomTransition, zoomMotionBlur, background, canvas, cursor, camera
        case keystrokes, audio, output, captions, annotations
    }

    /// Round-2 fields are optional in the file, so a project saved before them still opens.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        sourceDuration = try c.decode(Double.self, forKey: .sourceDuration)
        clips = try c.decode([StudioClip].self, forKey: .clips)
        zooms = try c.decode([ZoomRegion].self, forKey: .zooms)
        zoomTransition = try c.decode(Double.self, forKey: .zoomTransition)
        zoomMotionBlur = try c.decode(Double.self, forKey: .zoomMotionBlur)
        background = try c.decode(StudioBackground.self, forKey: .background)
        canvas = try c.decode(CanvasStyle.self, forKey: .canvas)
        cursor = try c.decode(CursorStyle.self, forKey: .cursor)
        camera = try c.decode(StudioCameraStyle.self, forKey: .camera)
        keystrokes = try c.decode(StudioKeystrokeStyle.self, forKey: .keystrokes)
        audio = try c.decode(AudioEdit.self, forKey: .audio)
        output = try c.decode(StudioOutput.self, forKey: .output)
        captions = try c.decodeIfPresent(StudioCaptions.self, forKey: .captions) ?? StudioCaptions()
        annotations = try c.decodeIfPresent([TextAnnotation].self, forKey: .annotations) ?? []
    }

    /// How a take looks when it is shared without the editor (S8 / LIG-57): exactly as the
    /// recording was set up — the cursor if "Show cursor" was on, a click ripple if clicks were
    /// highlighted, the keystroke pill and camera bubble if they were on — and nothing a studio
    /// would add (no background, padding, zoom or smoothing). Rendered at the source's size, frame
    /// rate and codec; a GIF take is rendered as a movie first, then converted.
    public static func flattenLook(options: RecordingOptions, sourceDuration: Double) -> StudioEdits {
        var edits = StudioEdits(sourceDuration: sourceDuration, look: .plain)
        edits.zoomMotionBlur = 0
        edits.cursor = CursorStyle(
            visible: options.showCursor, size: 1, smoothing: 0, hideWhenIdle: false,
            clickEffect: options.highlightClicks ? .ripple : .none,
            clickColor: options.clickHighlight.color.rgb.map { RGBAColor(red: $0.red, green: $0.green, blue: $0.blue) }
                ?? RGBAColor(red: 0.2, green: 0.5, blue: 1),
            motionBlur: 0
        )
        edits.keystrokes = StudioKeystrokeStyle(visible: options.showKeystrokes, overlay: options.keystrokeOverlay)
        edits.camera = StudioCameraStyle(visible: options.camera.isOn, bubble: options.cameraBubble)
        var output = StudioOutput(resolution: .source, format: .mp4)
        if case let .video(video) = options.output {
            output.fps = video.fps
            output.codec = video.codec == .hevc ? .hevc : .h264
        }
        edits.output = output
        return edits.normalized()
    }

    /// Every range clamped, clips and zooms in source order and inside the source.
    public func normalized() -> StudioEdits {
        var e = self
        func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
        e.clips = e.clips
            .map { var c = $0; c.start = clamp(c.start, 0...e.sourceDuration); c.end = clamp(c.end, 0...e.sourceDuration); c.speed = clamp(c.speed, StudioClip.speedRange); return c }
            .filter { $0.sourceLength > 0 }
            .sorted { $0.start < $1.start }
        e.zooms = e.zooms
            .map { var z = $0; z.start = clamp(z.start, 0...e.sourceDuration); z.end = clamp(z.end, 0...e.sourceDuration); z.scale = clamp(z.scale, ZoomRegion.minimumScale...ZoomRegion.maximumScale)
                if case let .point(p) = z.focus { z.focus = .point(Point(x: clamp(p.x, 0...1), y: clamp(p.y, 0...1))) }
                return z }
            .filter { $0.length > 0 }
            .sorted { $0.start < $1.start }
        e.zoomTransition = clamp(e.zoomTransition, Self.transitionRange)
        e.zoomMotionBlur = clamp(e.zoomMotionBlur, 0...1)
        e.canvas.padding = clamp(e.canvas.padding, 0...CanvasStyle.maximumPadding)
        e.canvas.cornerRadius = clamp(e.canvas.cornerRadius, 0...CanvasStyle.maximumCornerRadius)
        e.canvas.shadow = clamp(e.canvas.shadow, 0...1)
        e.canvas.backgroundBlur = clamp(e.canvas.backgroundBlur, 0...1)
        e.cursor.size = clamp(e.cursor.size, CursorStyle.minimumSize...CursorStyle.maximumSize)
        e.cursor.smoothing = clamp(e.cursor.smoothing, 0...1)
        e.cursor.idleDelay = clamp(e.cursor.idleDelay, 0.5...10)
        e.cursor.motionBlur = clamp(e.cursor.motionBlur, 0...1)
        if case let .volume(v) = e.audio { e.audio = .volume(clamp(v, 0...1)) }
        e.output.quality = clamp(e.output.quality, 0...1)
        e.captions.lines = e.captions.lines
            .map { var l = $0; l.start = clamp(l.start, 0...e.sourceDuration); l.end = clamp(l.end, 0...e.sourceDuration); return l }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        e.annotations = e.annotations.map { a in
            var a = a
            a.start = clamp(a.start, 0...e.sourceDuration)
            a.end = clamp(a.end, 0...e.sourceDuration)
            if a.end - a.start < TextAnnotation.minimumLength {
                a.end = min(e.sourceDuration, a.start + TextAnnotation.minimumLength)
                a.start = max(0, min(a.start, a.end - TextAnnotation.minimumLength))
            }
            a.center = Point(x: clamp(a.center.x, 0...1), y: clamp(a.center.y, 0...1))
            a.size = clamp(a.size, 0.02...0.25)
            a.fade = clamp(a.fade, 0...2)
            return a
        }.sorted { $0.start < $1.start }
        if !StudioOutput.frameRates.contains(e.output.fps) {
            e.output.fps = StudioOutput.frameRates.min { abs($0 - e.output.fps) < abs($1 - e.output.fps) } ?? 30
        }
        return e
    }
}
