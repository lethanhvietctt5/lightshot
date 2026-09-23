import AVFoundation
import CoreImage
import LightshotKit

/// The one instruction a Studio composition carries: the render state for the whole timeline and
/// which composition tracks hold the screen and the camera.
final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let state: StudioRenderState
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let frameDuration: Double

    init(timeRange: CMTimeRange, state: StudioRenderState, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?, frameDuration: Double) {
        self.timeRange = timeRange
        self.state = state
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.frameDuration = frameDuration
        requiredSourceTrackIDs = ([screenTrackID] + (cameraTrackID.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

/// The Studio editor's `AVVideoCompositing` (spec 0007, "One renderer"): every preview frame and
/// every exported frame is drawn here by `StudioFrameRenderer`, so the two cannot disagree.
final class StudioCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let context: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    private static let bgra: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]
    let sourcePixelBufferAttributes: [String: any Sendable]? = StudioCompositor.bgra
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = StudioCompositor.bgra
    private let queue = DispatchQueue(label: "dev.lightshot.studio.compositor")
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            guard let instruction = request.videoCompositionInstruction as? StudioInstruction,
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "dev.lightshot.studio", code: 1))
                return
            }
            let screen = request.sourceFrame(byTrackID: instruction.screenTrackID).map { CIImage(cvPixelBuffer: $0) }
            let camera = instruction.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
            let state = instruction.state
            let frame = StudioFrameRenderer.render(
                state, screen: screen, camera: camera,
                outputTime: CMTimeGetSeconds(request.compositionTime), frameDuration: instruction.frameDuration
            )
            let size = request.renderContext.size
            let scale = size.width / state.layout.canvas.width
            let scaled = scale == 1 ? frame : frame.transformed(by: CGAffineTransform(scaleX: scale, y: size.height / state.layout.canvas.height))
            Self.context.render(scaled, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: output)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

/// A Studio edit as AVFoundation objects (spec 0007): the clips laid end to end in an
/// `AVMutableComposition` (speed through `scaleTimeRange`), a video composition that renders through
/// `StudioCompositor`, and the audio mix for the audio edit.
struct StudioComposition: @unchecked Sendable {
    let asset: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix?
    let hasAudio: Bool

    /// The source movies, loaded once per editor session.
    struct Sources: @unchecked Sendable {
        let screen: AVAsset
        let screenVideo: AVAssetTrack
        let screenAudio: [AVAssetTrack]
        /// Kept alive with its track: an `AVAssetTrack` is unusable once its asset is released.
        let cameraAsset: AVAsset?
        let camera: AVAssetTrack?
        let pixelSize: Size
        let duration: Double
        let fps: Double

        static func load(screen url: URL, camera cameraURL: URL?) async throws -> Sources {
            let asset = AVURLAsset(url: url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw RecordingError.systemFailure("The recording has no video track.")
            }
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let size = try await video.load(.naturalSize)
            let fps = try await video.load(.nominalFrameRate)
            let duration = try await asset.load(.duration)
            let cameraAsset = cameraURL.map { AVURLAsset(url: $0) }
            let camera = try? await cameraAsset?.loadTracks(withMediaType: .video).first
            return Sources(
                screen: asset, screenVideo: video, screenAudio: audio, cameraAsset: camera == nil ? nil : cameraAsset, camera: camera,
                pixelSize: Size(width: Double(abs(size.width)), height: Double(abs(size.height))),
                duration: CMTimeGetSeconds(duration), fps: Double(fps > 0 ? fps : 30)
            )
        }
    }

    /// Build the composition for `state`, rendering at `renderSize` (the canvas for export, smaller
    /// for preview) and `fps`.
    static func make(_ sources: Sources, state: StudioRenderState, renderSize: CGSize, fps: Int) throws -> StudioComposition {
        let composition = AVMutableComposition()
        guard let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecordingError.systemFailure("The edit could not be built.")
        }
        let includeAudio = state.edits.audio != .remove
        let audioTracks: [(AVMutableCompositionTrack, AVAssetTrack)] = includeAudio ? sources.screenAudio.compactMap { source in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid).map { ($0, source) }
        } : []
        let cameraTrack = sources.camera.flatMap { _ in composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) }
        let cameraDuration = sources.camera.map { CMTimeGetSeconds($0.timeRange.end) } ?? 0

        var cursor = CMTime.zero
        for segment in state.timeline.segments {
            let range = CMTimeRange(
                start: CMTime(seconds: segment.sourceStart, preferredTimescale: 6000),
                end: CMTime(seconds: min(segment.sourceEnd, sources.duration), preferredTimescale: 6000)
            )
            guard range.duration > .zero else { continue }
            try screenTrack.insertTimeRange(range, of: sources.screenVideo, at: cursor)
            for (track, source) in audioTracks {
                let audioRange = CMTimeRangeGetIntersection(range, otherRange: source.timeRange)
                if audioRange.duration > .zero {
                    try track.insertTimeRange(audioRange, of: source, at: CMTimeAdd(cursor, CMTimeSubtract(audioRange.start, range.start)))
                }
            }
            if let cameraTrack, let source = sources.camera {
                let cameraRange = CMTimeRangeGetIntersection(range, otherRange: CMTimeRange(start: .zero, end: CMTime(seconds: cameraDuration, preferredTimescale: 6000)))
                if cameraRange.duration > .zero {
                    try cameraTrack.insertTimeRange(cameraRange, of: source, at: CMTimeAdd(cursor, CMTimeSubtract(cameraRange.start, range.start)))
                }
            }
            let inserted = CMTimeRange(start: cursor, duration: range.duration)
            let scaled = CMTime(seconds: CMTimeGetSeconds(range.duration) / segment.speed, preferredTimescale: 6000)
            if segment.speed != 1 {
                for track in composition.tracks { track.scaleTimeRange(inserted, toDuration: scaled) }
            }
            cursor = CMTimeAdd(cursor, scaled)
        }

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = StudioCompositor.self
        video.renderSize = renderSize
        video.frameDuration = frameDuration
        video.instructions = [StudioInstruction(
            timeRange: CMTimeRange(start: .zero, duration: composition.duration),
            state: state, screenTrackID: screenTrack.trackID, cameraTrackID: cameraTrack?.trackID,
            frameDuration: 1 / Double(max(fps, 1))
        )]

        var audioMix: AVAudioMix?
        let volume: Float?
        switch state.edits.audio {
        case .mute: volume = 0
        case let .volume(v): volume = Float(v)
        default: volume = nil
        }
        if let volume, !audioTracks.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioTracks.map { track, _ in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(volume, at: .zero)
                parameters.audioTimePitchAlgorithm = .spectral
                return parameters
            }
            audioMix = mix
        }
        return StudioComposition(asset: composition, videoComposition: video, audioMix: audioMix, hasAudio: !audioTracks.isEmpty)
    }
}
