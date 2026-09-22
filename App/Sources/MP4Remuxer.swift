import AVFoundation
import LightshotKit

/// Rewraps a QuickTime movie as MP4 without re-encoding (spec 0006, story 18).
///
/// The recorder writes a *fragmented* `.mov` so a crash mid-take leaves a playable file; the
/// deliverable is still MP4, so a finished (or recovered) take is passed through here — a container
/// change only, taking a fraction of a second.
enum MP4Remuxer {
    static func remux(_ source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingError.systemFailure("The recording could not be prepared for export.")
        }
        try? FileManager.default.removeItem(at: destination)
        if #available(macOS 15.0, *) {
            try await session.export(to: destination, as: .mp4)
        } else {
            session.outputURL = destination
            session.outputFileType = .mp4
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
            if session.status != .completed {
                throw session.error ?? RecordingError.systemFailure("The recording could not be written as MP4.")
            }
        }
    }
}
