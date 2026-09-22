import AVFoundation
import OSLog
import LightshotKit

/// Crash recovery for takes that never finished (spec 0006, story 18).
///
/// The recorder writes each take as a fragmented `.mov` in the scratch directory and only deletes
/// or moves it when the take ends normally. Anything still there at launch belonged to a session
/// that died: if the fragments make a playable movie it is rewrapped as MP4 into the save location
/// and surfaced; an unreadable stub is deleted so scratch never accumulates.
enum RecordingRecovery {
    private static let log = Logger(subsystem: "dev.lightshot.app", category: "recording")

    /// Recover every orphaned take under `scratchDirectory`, returning the files it produced.
    /// `destination` names where each recovered take should land (a fresh default destination).
    @MainActor
    static func recover(in scratchDirectory: URL, destination: () -> URL) async -> [URL] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: scratchDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var recovered: [URL] = []
        for movie in entries where movie.pathExtension == "mov" {
            let asset = AVURLAsset(url: movie)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            if playable, duration >= 0.5 {
                let target = destination()
                do {
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try await MP4Remuxer.remux(movie, to: target)
                    recovered.append(target)
                    log.info("Recovered \(movie.lastPathComponent, privacy: .public) → \(target.lastPathComponent, privacy: .public)")
                } catch {
                    log.error("Could not recover \(movie.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue   // keep the movie for a later attempt
                }
            }
            try? fileManager.removeItem(at: movie)
        }
        return recovered
    }
}
