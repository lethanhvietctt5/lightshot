import AVFoundation
import OSLog
import LightshotKit

/// Crash recovery for takes that never finished (spec 0006, story 18).
///
/// The recorder writes each take as a fragmented `.mov` in the scratch directory and only deletes
/// or moves it when the take ends normally; a finished `.mp4` sits there briefly between the rewrap
/// and the move to the save location. Anything still there at launch belonged to a session that
/// died. A playable movie is rewrapped as MP4 beside it; a finished MP4 is taken as it is; an
/// unreadable stub is deleted so scratch never accumulates. The recovered MP4s are handed back in
/// the scratch directory for the caller to deliver through the same `MediaSink.save` every finished
/// take uses — so a recovered file can never overwrite one of the user's.
enum RecordingRecovery {
    private static let log = Logger(subsystem: "dev.lightshot.app", category: "recording")

    /// Recover every orphaned take under `scratchDirectory`, returning MP4s still in scratch.
    @MainActor
    static func recover(in scratchDirectory: URL) async -> [URL] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: scratchDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var recovered: [URL] = []
        for file in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            switch file.pathExtension {
            case "mp4":
                recovered.append(file)   // finished, never delivered
            case "mov":
                let asset = AVURLAsset(url: file)
                let playable = (try? await asset.load(.isPlayable)) ?? false
                let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
                guard playable, duration >= 0.5 else {
                    try? fileManager.removeItem(at: file)
                    continue
                }
                let mp4 = file.deletingPathExtension().appendingPathExtension("mp4")
                do {
                    try await MP4Remuxer.remux(file, to: mp4)
                    try? fileManager.removeItem(at: file)
                    recovered.append(mp4)
                    log.info("Recovered \(file.lastPathComponent, privacy: .public)")
                } catch {
                    log.error("Could not recover \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    // Keep the movie for a later attempt.
                }
            default:
                break
            }
        }
        return recovered
    }
}
