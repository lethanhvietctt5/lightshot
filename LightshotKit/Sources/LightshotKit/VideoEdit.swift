import Foundation

/// The in/out points of a trim (spec 0006, story 35), clamped to the clip and never shorter than
/// `minimumLength` — a handle dragged past the other stops short of it.
public struct TrimRange: Equatable, Sendable {
    public static let minimumLength: TimeInterval = 0.5

    public private(set) var start: TimeInterval
    public private(set) var end: TimeInterval
    public let duration: TimeInterval

    /// The whole clip.
    public init(duration: TimeInterval) {
        self.duration = max(0, duration)
        start = 0
        end = self.duration
    }

    public init(start: TimeInterval, end: TimeInterval, duration: TimeInterval) {
        self.init(duration: duration)
        setStart(start)
        setEnd(end)
    }

    public var length: TimeInterval { end - start }
    public var isWholeClip: Bool { start == 0 && end == duration }

    /// Move the in point: clamped to the clip, and never closer than `minimumLength` to the out
    /// point (unless the clip itself is shorter than that).
    public mutating func setStart(_ value: TimeInterval) {
        let latest = max(0, end - min(Self.minimumLength, duration))
        start = min(max(value, 0), latest)
    }

    public mutating func setEnd(_ value: TimeInterval) {
        let earliest = min(duration, start + min(Self.minimumLength, duration))
        end = max(min(value, duration), earliest)
    }
}

/// The output size presets (story 35): the longest edge capped, aspect kept, never scaled up.
public enum DimensionPreset: String, CaseIterable, Sendable {
    case original, p1080, p720, p480

    public var maxLongestEdge: Double? {
        switch self {
        case .original: return nil
        case .p1080: return 1920
        case .p720: return 1280
        case .p480: return 854
        }
    }

    public var title: String {
        switch self {
        case .original: return "Original"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        }
    }
}

/// Output-size arithmetic for the editor (story 35). Every result has even edges, which H.264
/// encoders want, and at least 2 px a side.
public enum VideoDimensions {
    public static func size(for preset: DimensionPreset, source: Size) -> Size {
        guard let cap = preset.maxLongestEdge, max(source.width, source.height) > cap else { return even(source) }
        let scale = cap / max(source.width, source.height)
        return even(Size(width: source.width * scale, height: source.height * scale))
    }

    /// A typed width (or height) keeps the source aspect; both typed fit the source inside that
    /// box, still keeping its aspect — the picture is never stretched. Clamped to the source so
    /// nothing is scaled up.
    public static func size(width: Double?, height: Double?, source: Size) -> Size {
        let aspect = source.height > 0 ? source.width / source.height : 1
        var result: Size
        switch (width, height) {
        case let (w?, h?):
            let scale = min(w / max(source.width, 1), h / max(source.height, 1))
            result = Size(width: source.width * scale, height: source.height * scale)
        case let (w?, nil): result = Size(width: w, height: w / aspect)
        case let (nil, h?): result = Size(width: h * aspect, height: h)
        case (nil, nil): result = source
        }
        result.width = min(max(result.width, 2), max(source.width, 2))
        result.height = min(max(result.height, 2), max(source.height, 2))
        return even(result)
    }

    /// Down to the even number, so nothing is ever scaled up by rounding.
    private static func even(_ size: Size) -> Size {
        Size(width: max(2, (size.width / 2).rounded(.down) * 2), height: max(2, (size.height / 2).rounded(.down) * 2))
    }
}

/// What to do with the sound (story 35).
public enum AudioEdit: Equatable, Sendable {
    case unchanged
    case mute
    case volume(Double)
    case mono
    case remove
}

/// One export's settings (story 35): the cut plus, for a re-encode, the size, the quality and the
/// audio treatment.
public struct VideoEditSettings: Equatable, Sendable {
    public var trim: TrimRange
    public var dimensions: Size
    /// `0...1`; drives the encoder's bit rate through `VideoBitRate`.
    public var quality: Double
    public var audio: AudioEdit

    public init(trim: TrimRange, dimensions: Size, quality: Double = VideoBitRate.defaultQuality, audio: AudioEdit = .unchanged) {
        self.trim = trim
        self.dimensions = dimensions
        self.quality = min(max(quality, 0), 1)
        self.audio = audio
    }
}

/// The one place the encoder's bit rate comes from, so the estimate and the export agree (story
/// 35's estimated file size). The recorder writes at 0.1 bits per pixel per frame; that is the
/// default quality here, and the slider runs from a quarter of it to double.
public enum VideoBitRate {
    public static let defaultQuality: Double = 0.5
    public static let minimumBitsPerSecond: Double = 500_000
    /// AAC narration or computer audio, per channel.
    public static let audioBitsPerSecondPerChannel: Double = 64_000

    /// Bits per pixel per frame for a quality: 0.025 at 0, 0.1 at the default, 0.2 at 1.
    public static func bitsPerPixel(quality: Double) -> Double {
        let q = min(max(quality, 0), 1)
        return q <= defaultQuality
            ? 0.025 + (0.1 - 0.025) * (q / defaultQuality)
            : 0.1 + (0.2 - 0.1) * ((q - defaultQuality) / (1 - defaultQuality))
    }

    public static func videoBitsPerSecond(size: Size, fps: Double, quality: Double) -> Double {
        max(minimumBitsPerSecond, size.width * size.height * max(1, fps) * bitsPerPixel(quality: quality))
    }
}

/// The editor's "Estimated file size" (story 35): bit rates × the trimmed length, plus a little
/// container overhead. Within the ±25 % the ticket asks of an H.264 export at the default quality,
/// because the export sets the very same average bit rate.
public enum SizeEstimator {
    public static let containerOverheadBytes: Double = 4_096

    /// - Parameter audioChannels: channels in the source, `0` for none.
    public static func estimatedBytes(settings: VideoEditSettings, fps: Double, audioChannels: Int) -> Double {
        let seconds = settings.trim.length
        let video = VideoBitRate.videoBitsPerSecond(size: settings.dimensions, fps: fps, quality: settings.quality)
        let channels: Int
        switch settings.audio {
        case .remove: channels = 0
        case .mono: channels = min(audioChannels, 1)
        case .unchanged, .mute, .volume: channels = audioChannels
        }
        let audio = Double(channels) * VideoBitRate.audioBitsPerSecondPerChannel
        return (video + audio) * seconds / 8 + containerOverheadBytes
    }

    /// A pass-through cut keeps the source's own bit rate: the source size scaled by the cut.
    public static func estimatedTrimOnlyBytes(sourceBytes: Double, trim: TrimRange) -> Double {
        guard trim.duration > 0 else { return sourceBytes }
        return sourceBytes * (trim.length / trim.duration)
    }
}
