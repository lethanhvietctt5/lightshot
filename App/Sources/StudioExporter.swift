import AVFoundation
import LightshotKit

/// Exports a Studio edit (spec 0007, stories 25–28): the composition read through
/// `StudioCompositor` at the canvas size and chosen frame rate, encoded as H.264 or HEVC at the
/// `VideoBitRate` for the quality; audio mixed per the audio edit. GIF output encodes the MP4 first
/// and converts it with spec 0006's `GIFEncoder`.
enum StudioExporter {
    static func export(
        _ sources: StudioComposition.Sources, state: StudioRenderState, to output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let edits = state.edits
        switch edits.output.format {
        case .mp4:
            try await exportMovie(sources, state: state, to: output, progress: progress)
        case .gif:
            let movie = output.deletingPathExtension().appendingPathExtension("studio-export.mp4")
            defer { try? FileManager.default.removeItem(at: movie) }
            try await exportMovie(sources, state: state, to: movie) { progress($0 * 0.5) }
            var settings = GIFSettings.standard
            settings.maxWidth = min(settings.maxWidth ?? 800, Int(state.layout.canvas.width))
            try await ImageIOGIFEncoder().encode(video: movie, to: output, settings: settings) { progress(0.5 + $0 * 0.5) }
        }
    }

    /// The export's encoded size estimate (story 25), from the same bit rates the encoder uses.
    static func estimatedBytes(state: StudioRenderState, hasAudio: Bool, audioChannels: Int) -> Double {
        let size = state.layout.canvas
        let video = VideoBitRate.videoBitsPerSecond(size: size, fps: Double(state.edits.output.fps), quality: state.edits.output.quality)
        let channels = state.edits.audio == .mono ? 1 : max(1, min(audioChannels, 2))
        let audio = hasAudio && state.edits.audio != .remove ? VideoBitRate.audioBitsPerSecondPerChannel * Double(channels) : 0
        return (video + audio) / 8 * state.timeline.outputDuration + SizeEstimator.containerOverheadBytes
    }

    private static func exportMovie(
        _ sources: StudioComposition.Sources, state: StudioRenderState, to output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: output)
        let edits = state.edits
        let canvas = state.layout.canvas
        let renderSize = CGSize(width: canvas.width, height: canvas.height)
        let built = try StudioComposition.make(sources, state: state, renderSize: renderSize, fps: edits.output.fps)
        let composition = built.asset

        let reader = try AVAssetReader(asset: composition)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)

        let videoTracks = composition.tracks(withMediaType: .video)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOut.videoComposition = built.videoComposition
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        let codec: AVVideoCodecType = edits.output.codec == .hevc ? .hevc : .h264
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(VideoBitRate.videoBitsPerSecond(size: canvas, fps: Double(edits.output.fps), quality: edits.output.quality)),
            AVVideoExpectedSourceFrameRateKey: edits.output.fps,
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(canvas.width),
            AVVideoHeightKey: Int(canvas.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)

        var audioPair: (AVAssetReaderOutput, AVAssetWriterInput)?
        let audioTracks = composition.tracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let channels = edits.audio == .mono ? 1 : 2
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ])
            out.audioMix = built.audioMix
            out.audioTimePitchAlgorithm = .spectral
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

        guard reader.startReading() else { throw reader.error ?? RecordingError.systemFailure("The edit could not be read.") }
        guard writer.startWriting() else { throw writer.error ?? RecordingError.systemFailure("The export could not be started.") }
        writer.startSession(atSourceTime: .zero)

        let pump = VideoExporter.Pump(reader: reader, writer: writer, output: output)
        let duration = max(CMTimeGetSeconds(composition.duration), 0.001)
        let videoJob = VideoExporter.Pump.Job(input: videoIn, output: videoOut)
        let audioJob = audioPair.map { VideoExporter.Pump.Job(input: $0.1, output: $0.0) }
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await pump.drive(videoJob) { time in progress(min(1, max(0, CMTimeGetSeconds(time) / duration))) }
                }
                if let audioJob { group.addTask { await pump.drive(audioJob, onSample: nil) } }
            }
        } onCancel: {
            pump.cancel()
        }
        try await pump.finish()
        progress(1)
    }
}
