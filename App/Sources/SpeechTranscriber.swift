import AVFoundation
import LightshotKit
import Speech

/// On-device transcription for Studio captions (spec 0007, round 2, story 29). The movie's first
/// audio track (the narration when tracks are separate) is exported to M4A and handed to
/// `SFSpeechRecognizer` with `requiresOnDeviceRecognition` — the local-only guardrail: when the
/// language has no on-device model the transcription is refused, never sent to a server.
enum SpeechTranscriber {
    enum Failure: LocalizedError {
        case noAudio
        case unsupportedLocale(String)
        case noOnDeviceModel(String)
        case nothingRecognised

        var errorDescription: String? {
            switch self {
            case .noAudio: return "This recording has no sound to transcribe."
            case let .unsupportedLocale(name): return "Speech recognition doesn't support \(name)."
            case let .noOnDeviceModel(name):
                return "There is no on-device speech model for \(name). Download it in System Settings → Keyboard → Dictation, then try again."
            case .nothingRecognised: return "No speech was recognised in this recording."
            }
        }
    }

    static func transcribe(movie url: URL, locale: Locale = .current) async throws -> StudioTranscript {
        let name = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw Failure.unsupportedLocale(name) }
        guard recognizer.supportsOnDeviceRecognition else { throw Failure.noOnDeviceModel(name) }

        let audio = try await exportAudio(from: url)
        defer { try? FileManager.default.removeItem(at: audio) }

        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation

        let box = RecognitionBox()
        let words: [TranscriptWord] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.start(continuation)
                box.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        box.finish(.success(result.bestTranscription.segments.map {
                            TranscriptWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                        }))
                    } else if let error {
                        // "No speech detected" arrives as an error; report it plainly.
                        let nsError = error as NSError
                        let noSpeech = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110
                        box.finish(.failure(noSpeech ? Failure.nothingRecognised : error))
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
        guard !words.isEmpty else { throw Failure.nothingRecognised }
        return StudioTranscript(locale: locale.identifier, words: words)
    }

    /// The first audio track as a temporary M4A (the recogniser reads audio files).
    static func exportAudio(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
        let composition = AVMutableComposition()
        guard let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.noAudio
        }
        try audio.insertTimeRange(try await track.load(.timeRange), of: track, at: .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecordingError.systemFailure("The audio could not be prepared for transcription.")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("lightshot-transcribe-\(UUID().uuidString).m4a")
        if #available(macOS 15.0, *) {
            try await session.export(to: output, as: .m4a)
        } else {
            session.outputURL = output
            session.outputFileType = .m4a
            await session.export()
            if let error = session.error { throw error }
        }
        return output
    }

    /// Resumes the continuation exactly once, from whichever thread the recogniser calls back on,
    /// and keeps the task so cancellation can stop it.
    private final class RecognitionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[TranscriptWord], Error>?
        var task: SFSpeechRecognitionTask? {
            get { lock.lock(); defer { lock.unlock() }; return storedTask }
            set { lock.lock(); storedTask = newValue; lock.unlock() }
        }
        private var storedTask: SFSpeechRecognitionTask?

        func start(_ continuation: CheckedContinuation<[TranscriptWord], Error>) {
            lock.lock(); self.continuation = continuation; lock.unlock()
        }

        func finish(_ result: Result<[TranscriptWord], Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }

        func cancel() {
            task?.cancel()
            finish(.failure(CancellationError()))
        }
    }
}
