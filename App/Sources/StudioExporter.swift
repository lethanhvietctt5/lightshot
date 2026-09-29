import AVFoundation
import LightshotKit
import VideoToolbox

/// Exports a Studio edit (spec 0007, stories 25–28): the composition read through
/// `StudioCompositor` at the canvas size and chosen frame rate, encoded as H.264 or HEVC at
/// `StudioOutput.videoBitsPerSecond` with a key frame at least every
/// `StudioOutput.maxKeyFrameInterval`; audio mixed per the audio edit. GIF output reads the same
/// composition at the GIF's size and frame delay straight into spec 0006's `GIFEncoder`.
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
            try await exportGIF(sources, state: state, to: output, progress: progress)
        }
    }

    /// The GIF renders only the frames and pixels it keeps: a full-size movie at the export's frame
    /// rate first cost 40 times the render work, and its decoder noise leaked into the frame
    /// differencing (LIG-75).
    private static func exportGIF(
        _ sources: StudioComposition.Sources, state: StudioRenderState, to output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var settings = GIFSettings.standard
        settings.maxWidth = min(settings.maxWidth ?? 800, Int(state.layout.canvas.width))
        let plan = GIFFramePlan(duration: state.timeline.outputDuration, sourceSize: state.layout.canvas, settings: settings)
        let built = try StudioComposition.make(
            sources, state: state, renderSize: CGSize(width: plan.outputSize.width, height: plan.outputSize.height),
            frameDuration: CMTime(value: CMTimeValue((plan.frameDelay * 100).rounded()), timescale: 100),   // whole centiseconds
            blurDuration: StudioComposition.frameDuration(fps: state.edits.output.fps)
        )
        try await ImageIOGIFEncoder().encode(plan: plan, settings: settings, to: output, progress: progress) {
            let reader = try AVAssetReader(asset: built.asset)
            let frames = AVAssetReaderVideoCompositionOutput(
                videoTracks: built.asset.tracks(withMediaType: .video), videoSettings: ImageIOGIFEncoder.frameFormat
            )
            frames.videoComposition = built.videoComposition
            frames.alwaysCopiesSampleData = false
            reader.add(frames)
            return (reader, frames)
        }
    }

    /// The export's encoded size estimate (story 25), from the same bit rates the encoder uses.
    static func estimatedBytes(state: StudioRenderState, hasAudio: Bool, audioChannels: Int) -> Double {
        let size = state.layout.canvas
        let video = state.edits.output.videoBitsPerSecond(canvas: size)
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
        let built = try StudioComposition.make(
            sources, state: state, renderSize: renderSize, frameDuration: StudioComposition.frameDuration(fps: edits.output.fps)
        )
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
            AVVideoAverageBitRateKey: Int(edits.output.videoBitsPerSecond(canvas: canvas)),
            AVVideoExpectedSourceFrameRateKey: edits.output.fps,
            AVVideoMaxKeyFrameIntervalDurationKey: StudioOutput.maxKeyFrameInterval,
            // The media engine is the export's ceiling: HEVC encodes in ~60 % of the time at the
            // same rate, and looks the same (SSIM 0.998 against the take). H.264 ignores it.
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: true,
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
