import AVFoundation
import Foundation
import LightshotKit

/// The video editor's exports (spec 0006, stories 35–36): a lossless cut, or a re-encode with the
/// chosen size, quality and audio treatment. Everything writes to `output`, which must not exist;
/// the caller decides whether that becomes a new file or replaces the original.
enum VideoExporter {
    /// What the editor needs to know about a clip before it can plan an export.
    struct Source: Sendable {
        let url: URL
        let duration: TimeInterval
        let size: Size
        let fps: Double
        let audioChannels: Int
        let bytes: Double
    }

    static func inspect(_ url: URL) async throws -> Source {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingError.systemFailure("The file has no video track.")
        }
        let (natural, fps, duration) = try await (video.load(.naturalSize), video.load(.nominalFrameRate), asset.load(.duration))
        var channels = 0
        if let audio = try await asset.loadTracks(withMediaType: .audio).first,
           let format = try await audio.load(.formatDescriptions).first,
           let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
            channels = Int(description.pointee.mChannelsPerFrame)
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 0
        return Source(
            url: url, duration: CMTimeGetSeconds(duration),
            size: Size(width: Double(natural.width), height: Double(natural.height)),
            fps: Double(fps > 0 ? fps : 30), audioChannels: channels, bytes: bytes
        )
    }

    /// Trim only: a container-level cut through the pass-through preset — no re-encode, so it
    /// keeps the codec and costs about a copy of the kept part.
    static func trimOnly(_ url: URL, range: TrimRange, to output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingError.systemFailure("The recording could not be prepared for export.")
        }
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 600),
            end: CMTime(seconds: range.end, preferredTimescale: 600)
        )
        try await Self.run(session, to: output, progress: progress)
    }

    /// Runs an export session with progress and cancellation: the session's own progress is polled
    /// while it runs, and cancelling the calling task cancels the export and removes the file.
    /// `AVAssetExportSession` is thread-safe for progress and cancel but not marked `Sendable`.
    private struct SessionBox: @unchecked Sendable { let session: AVAssetExportSession }

    private static func run(_ session: AVAssetExportSession, to output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try? FileManager.default.removeItem(at: output)
        let box = SessionBox(session: session)
        let poll = Task {
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { poll.cancel() }
        do {
            try await withTaskCancellationHandler {
                if #available(macOS 15.0, *) {
                    try await session.export(to: output, as: .mp4)
                } else {
                    session.outputURL = output
                    session.outputFileType = .mp4
                    await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
                    if session.status == .cancelled { throw CancellationError() }
                    if session.status != .completed { throw session.error ?? RecordingError.systemFailure("The cut could not be written.") }
                }
            } onCancel: {
                box.session.cancelExport()
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        progress(1)
    }

    /// Trim & Convert: re-encode the cut as H.264 at `settings.dimensions` and the bit rate the
    /// quality maps to (`VideoBitRate`, shared with the size estimate), with the audio treated as
    /// asked. Unchanged audio is passed through as-is; mute / volume / mono are decoded, mixed and
    /// re-encoded as AAC; remove drops it.
    static func convert(_ source: Source, settings: VideoEditSettings, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: output)
        let asset = AVURLAsset(url: source.url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first else { throw RecordingError.systemFailure("The file has no video track.") }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let range = CMTimeRange(
            start: CMTime(seconds: settings.trim.start, preferredTimescale: 600),
            end: CMTime(seconds: settings.trim.end, preferredTimescale: 600)
        )
        reader.timeRange = range

        // Video: decode to BGRA, let the writer scale to the target size, encode at our bit rate.
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        let width = Int(settings.dimensions.width), height = Int(settings.dimensions.height)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResize,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(VideoBitRate.videoBitsPerSecond(size: settings.dimensions, fps: source.fps, quality: settings.quality)),
                AVVideoExpectedSourceFrameRateKey: Int(source.fps.rounded()),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)

        // Audio, per the treatment.
        var audioPair: (AVAssetReaderOutput, AVAssetWriterInput)?
        if let audioTrack = audioTracks.first, settings.audio != .remove {
            switch settings.audio {
            case .unchanged:
                let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                reader.add(out)
                let hint = try await audioTrack.load(.formatDescriptions).first
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
                input.expectsMediaDataInRealTime = false
                writer.add(input)
                audioPair = (out, input)
            case .remove:
                break   // excluded above; listed so the switch stays exhaustive
            case .mute, .volume, .mono:
                let channels = settings.audio == .mono ? 1 : max(1, min(source.audioChannels, 2))
                let out = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                ])
                let volume: Float
                switch settings.audio {
                case .mute: volume = 0
                case let .volume(v): volume = Float(min(max(v, 0), 2))
                default: volume = 1
                }
                let mix = AVMutableAudioMix()
                let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
                parameters.setVolume(volume, at: .zero)
                mix.inputParameters = [parameters]
                out.audioMix = mix
                reader.add(out)
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: Int(VideoBitRate.audioBitsPerSecondPerChannel) * channels,
                ])
                input.expectsMediaDataInRealTime = false
                writer.add(input)
                audioPair = (out, input)
            }
        }

        guard reader.startReading() else { throw reader.error ?? RecordingError.systemFailure("The recording could not be read.") }
        guard writer.startWriting() else { throw writer.error ?? RecordingError.systemFailure("The export could not be started.") }
        writer.startSession(atSourceTime: range.start)

        let pump = Pump(reader: reader, writer: writer, output: output)
        let trimLength = settings.trim.length
        let trimStart = settings.trim.start
        // Both inputs are pumped at once: the writer interleaves audio and video and stops asking
        // for more of one until the other has caught up, so pumping them in turn would deadlock.
        // The pump runs on a GCD queue with no task context, so cancellation reaches it by flag.
        let videoJob = Pump.Job(input: videoIn, output: videoOut)
        let audioJob = audioPair.map { Pump.Job(input: $0.1, output: $0.0) }
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await pump.drive(videoJob) { time in
                        progress(trimLength > 0 ? min(1, max(0, (CMTimeGetSeconds(time) - trimStart) / trimLength)) : 1)
                    }
                }
                if let audioJob {
                    group.addTask { await pump.drive(audioJob, onSample: nil) }
                }
            }
        } onCancel: {
            pump.cancel()
        }
        try await pump.finish()
        progress(1)
    }

    /// Feeds writer inputs from reader outputs on their own queue, and finishes or cancels the
    /// writer once. Cancellation of the calling task abandons the export and removes the file.
    final class Pump: @unchecked Sendable {
        private let reader: AVAssetReader
        private let writer: AVAssetWriter
        private let output: URL
        private let queue = DispatchQueue(label: "dev.lightshot.export")
        private var failed: Error?
        private let lock = NSLock()
        private var cancelled = false

        /// Stop pumping: the reader is cancelled so `copyNextSampleBuffer` returns at once.
        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
            reader.cancelReading()
        }

        private var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        init(reader: AVAssetReader, writer: AVAssetWriter, output: URL) {
            self.reader = reader
            self.writer = writer
            self.output = output
        }

        /// One input/output pair being pumped; AVFoundation's objects are used only on `queue`.
        final class Job: @unchecked Sendable {
            let input: AVAssetWriterInput
            let output: AVAssetReaderOutput
            var done = false
            init(input: AVAssetWriterInput, output: AVAssetReaderOutput) {
                self.input = input
                self.output = output
            }
        }

        func drive(_ job: Job, onSample: (@Sendable (CMTime) -> Void)?) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                job.input.requestMediaDataWhenReady(on: queue) { [self] in
                    guard !job.done else { return }
                    while job.input.isReadyForMoreMediaData {
                        if isCancelled || failed != nil { break }
                        guard let sample = job.output.copyNextSampleBuffer() else {
                            job.input.markAsFinished()
                            job.done = true
                            continuation.resume()
                            return
                        }
                        if !job.input.append(sample) {
                            failed = writer.error ?? RecordingError.systemFailure("The export could not be written.")
                            break
                        }
                        onSample?(CMSampleBufferGetPresentationTimeStamp(sample))
                    }
                    if isCancelled || failed != nil {
                        job.input.markAsFinished()
                        job.done = true
                        continuation.resume()
                    }
                }
            }
        }

        func finish() async throws {
            if isCancelled || failed != nil || reader.status == .failed {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: output)
                if isCancelled { throw CancellationError() }
                throw failed ?? reader.error ?? RecordingError.systemFailure("The recording could not be read.")
            }
            await writer.finishWriting()
            guard writer.status == .completed else {
                try? FileManager.default.removeItem(at: output)
                throw writer.error ?? RecordingError.systemFailure("The export could not be finished.")
            }
        }
    }
}
