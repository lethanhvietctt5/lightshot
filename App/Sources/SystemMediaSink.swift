import AppKit
import LightshotKit

/// System `MediaSink` (the OS side of the recording output seam): file references on the pasteboard,
/// and moving a finished recording to its destination.
///
/// Recordings are files from the moment the writer finalises them, so unlike `SystemImageSink` there
/// is nothing to encode: `copyFile` puts the URL on the general pasteboard (it pastes into Finder,
/// Slack, Mail as the file), and `save` moves the scratch file to the chosen destination, creating
/// the directory if needed and refusing to overwrite — a collision is an error the coordinator
/// surfaces, never a silent replacement.
final class SystemMediaSink: MediaSink {
    func copyFile(at url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    func save(_ url: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: url, to: destination)
    }

    func removeFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
