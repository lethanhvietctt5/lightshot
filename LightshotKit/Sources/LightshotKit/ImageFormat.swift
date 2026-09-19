import Foundation

/// The encoding a `RenderedImage` is written out as (stories 42/44).
///
/// A single value the encoder consumes end to end: the editor passes the chosen setting straight
/// through to `ImageSink.write` and the drag payload, so there is no separate "quality" channel.
/// Formats that ignore quality (PNG) simply carry no quality field; story 42's selectable quality
/// lives on the `jpeg` case, normalized to `0.0...1.0`. The same value type carries the **default**
/// (from `SettingsStore`) and any **per-save override**.
public enum ImageFormat: Equatable, Sendable {
    /// Lossless PNG. Ignores quality.
    case png
    /// Lossy JPEG at `quality`, normalized `0.0...1.0` (higher is better).
    case jpeg(quality: Double)

    /// JPEG at a quality clamped into the valid `0.0...1.0` range, so an out-of-range setting or
    /// slider value can never reach the encoder.
    public static func jpeg(clamping quality: Double) -> ImageFormat {
        .jpeg(quality: min(max(quality, 0), 1))
    }

    /// File extension for this format, no leading dot: `png` or `jpg`.
    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }

    /// Uniform Type Identifier the encoder and the drag pasteboard use to name the type.
    public var utiIdentifier: String {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        }
    }
}
