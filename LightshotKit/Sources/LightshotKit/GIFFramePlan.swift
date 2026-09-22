import Foundation

/// How a recorded video becomes a GIF (spec 0006, story 37): which source frames are kept, at
/// what size, with what delay — and how "quality" maps onto the palette. Pure, so the sampling is
/// tested without decoding a movie; the app's `GIFEncoder` walks the frames and asks.
public struct GIFFramePlan: Equatable, Sendable {
    /// The GIF's pixel size: the source, or the source scaled down to `maxWidth` keeping its aspect.
    public let outputSize: Size
    /// Seconds between frames, in whole centiseconds because that is all a GIF can store.
    public let frameDelay: TimeInterval
    /// How many frames the GIF holds — the duration at `frameDelay`, at least one.
    public let frameCount: Int

    public init(duration: TimeInterval, sourceSize: Size, settings: GIFSettings) {
        frameDelay = Self.delay(forFPS: settings.fps)
        frameCount = max(1, Int((max(duration, 0) / frameDelay).rounded(.up)))
        if let maxWidth = settings.maxWidth, sourceSize.width > Double(maxWidth), sourceSize.width > 0 {
            let scale = Double(maxWidth) / sourceSize.width
            outputSize = Size(width: Double(maxWidth), height: max(1, (sourceSize.height * scale).rounded()))
        } else {
            outputSize = Size(width: max(1, sourceSize.width.rounded()), height: max(1, sourceSize.height.rounded()))
        }
    }

    /// A GIF delay is stored in 1/100 s; the nearest one to `1/fps`, never under 2 (browsers treat
    /// shorter as 10).
    public static func delay(forFPS fps: Int) -> TimeInterval {
        max(2, (100.0 / Double(max(fps, 1))).rounded()) / 100
    }

    /// When output frame `index` should be sampled from the source.
    public func sampleTime(ofFrame index: Int) -> TimeInterval {
        Double(index) * frameDelay
    }

    /// The output frame a source frame shown at `time` fills — the next one after `lastFilled`
    /// once the source has reached (or passed) its sample time — or `nil` to skip it. One source
    /// frame fills at most one output frame; the encoder repeats the last frame if the source
    /// runs out early.
    public func outputIndex(forSourceFrameAt time: TimeInterval, after lastFilled: Int?) -> Int? {
        let next = (lastFilled ?? -1) + 1
        guard next < frameCount else { return nil }
        // A hair of tolerance so 0.0700000001 vs 0.07 never drops a frame.
        return time + 1e-6 >= sampleTime(ofFrame: next) ? next : nil
    }

    /// Story 37's quality as colour depth before palette quantisation: 1 keeps all 8 bits per
    /// channel; lower values posterise (down to 4 bits at 0), which shrinks the file at the cost of
    /// banding.
    public static func bitsPerChannel(quality: Double) -> Int {
        4 + Int((min(max(quality, 0), 1) * 4).rounded())
    }
}

/// The OS GIF seam (spec 0006, stories 37–38): turns a finished video into a GIF. The app's
/// encoder reads the movie with AVFoundation and writes with ImageIO; the domain only knows the
/// contract — progress `0...1`, `CancellationError` on cancel, and **no partial output left behind**
/// on any failure.
public protocol GIFEncoding: Sendable {
    func encode(video: URL, to output: URL, settings: GIFSettings, progress: @escaping @Sendable (Double) -> Void) async throws
}
