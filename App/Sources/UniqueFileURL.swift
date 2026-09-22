import Foundation

extension URL {
    /// This URL, or `name 2.ext`, `name 3.ext`… when a file already exists there — the one rule
    /// every "never overwrite" path shares (recovered takes, edited copies, backups).
    func uniqueForFileSystem(_ fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: path) else { return self }
        let directory = deletingLastPathComponent()
        let stem = deletingPathExtension().lastPathComponent
        for n in 2... {
            let candidate = directory.appendingPathComponent("\(stem) \(n)").appendingPathExtension(pathExtension)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return self
    }
}
