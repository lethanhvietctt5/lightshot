import AVFoundation
import CoreGraphics
import LightshotKit

/// `MediaMetadataSource` over AVFoundation (spec 0006, story 39): the frame size from the video
/// track (its `naturalSize` under `preferredTransform`, never inferred from a thumbnail), the
/// duration, and a first-frame PNG thumbnail from `AVAssetImageGenerator`.
struct AVMediaMetadata: MediaMetadataSource {
    static let thumbnailMaxPixelSize = 320

    func videoMetadata(for url: URL) async -> VideoMetadata? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform, duration) = try? await (track.load(.naturalSize), track.load(.preferredTransform), asset.load(.duration))
        else { return nil }
        let oriented = natural.applying(transform)
        let width = Int(abs(oriented.width).rounded()), height = Int(abs(oriented.height).rounded())
        guard width > 0, height > 0 else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: Self.thumbnailMaxPixelSize, height: Self.thumbnailMaxPixelSize)
        guard let frame = try? await generator.image(at: .zero).image, let png = PNGEncoder.data(from: frame) else { return nil }
        return VideoMetadata(pixelWidth: width, pixelHeight: height, duration: CMTimeGetSeconds(duration), thumbnailPNG: png)
    }
}
