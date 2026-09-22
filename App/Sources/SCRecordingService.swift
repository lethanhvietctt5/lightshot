import AppKit
import AVFoundation
import IOKit.pwr_mgt
import OSLog
import ScreenCaptureKit
import LightshotKit

private let log = Logger(subsystem: "dev.lightshot.app", category: "recording")

/// ScreenCaptureKit-backed `RecordingService` (the OS side of the recording seam, spec 0006).
///
/// A thin wrapper with no unit tests — it needs a real display + TCC state; the coordinator routing
/// it feeds is tested against a fake. One `SCStream` delivers frames of the `RecordingOptions.region`
/// (a display, a window, or a rect of the primary display) on a private queue, and a
/// `RecordingWriter` encodes them through `AVAssetWriter` into H.264 / HEVC MP4 at the options'
/// frame rate and resolution. Lightshot's own windows are excluded from the stream by process, so
/// the recording controls and overlays never appear in the output (story 15). A display-sleep
/// assertion is held for the life of the take (story 17).
///
/// Only Screen Recording permission is involved here; the microphone, camera and keystroke
/// features (R7–R11) add their own sources and permissions.
final class SCRecordingService: NSObject, RecordingService, @unchecked Sendable {
    /// The same advisory Screen Recording view `SCCaptureService` has — including the shared
    /// "have we asked yet?" flag — so first-run onboarding and both services agree on the grant.
    private let permissions = SCCaptureService()

    /// Serialises every touch of the stream and writer: SCK delivers frames on it, and
    /// pause / resume / stop / cancel hop onto it, so the writer is never used from two threads.
    private let queue = DispatchQueue(label: "dev.lightshot.recording")

    private var stream: SCStream?
    private var output: StreamOutput?
    private var writer: RecordingWriter?
    private var sleepAssertion: IOPMAssertionID = 0

    func authorizationStatus() async -> CaptureAuthorizationStatus {
        await permissions.authorizationStatus()
    }

    @discardableResult
    func requestAuthorization() async -> CaptureAuthorizationStatus {
        await permissions.requestAuthorization()
    }

    func start(_ options: RecordingOptions, writingTo url: URL) async -> Result<Void, RecordingError> {
        guard case let .video(video) = options.output else {
            // GIF takes are recorded as video first (R13 converts afterwards); the settings for the
            // stream are the video ones.
            return await start(videoSettings: .standard, options: options, writingTo: url)
        }
        return await start(videoSettings: video, options: options, writingTo: url)
    }

    private func start(
        videoSettings video: VideoSettings, options: RecordingOptions, writingTo url: URL
    ) async -> Result<Void, RecordingError> {
        do {
            // The shareable-content query is the first thing that fails when Screen Recording
            // permission is missing — it surfaces as SCStreamError.userDeclined.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let target = try Self.target(for: options.region, in: content)

            let size = Self.outputSize(
                points: target.pointSize, scale: target.scale, settings: video
            )
            let configuration = SCStreamConfiguration()
            configuration.width = size.width
            configuration.height = size.height
            if let sourceRect = target.sourceRect { configuration.sourceRect = sourceRect }
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, video.fps)))
            configuration.showsCursor = options.showCursor
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.queueDepth = 6

            let writer = try RecordingWriter(
                url: url, width: size.width, height: size.height, codec: video.codec, fps: video.fps
            )
            let output = StreamOutput(writer: writer)
            let stream = SCStream(filter: target.filter, configuration: configuration, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            log.info("Recording started: \(size.width)×\(size.height) @ \(video.fps) fps → \(url.lastPathComponent, privacy: .public)")

            self.stream = stream
            self.output = output
            self.writer = writer
            holdDisplayAwake()
            return .success(())
        } catch let error as RecordingError {
            log.error("Recording failed to start: \(String(describing: error), privacy: .public)")
            return .failure(error)
        } catch {
            log.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            return .failure(Self.mapError(error))
        }
    }

    func pause() async {
        let writer = self.writer
        queue.async { writer?.pause() }
    }

    func resume() async {
        let writer = self.writer
        queue.async { writer?.resume() }
    }

    func stop() async -> Result<URL, RecordingError> {
        guard let stream, let writer else {
            return .failure(.systemFailure("No recording is in progress."))
        }
        defer { tearDown() }
        do {
            try await stream.stopCapture()
        } catch {
            // The stream may already have stopped (e.g. the display went away); the writer still
            // holds whatever was captured, so finalise it and report the stream's error only if the
            // file itself is unusable.
            if let streamError = output?.failure { return .failure(streamError) }
        }
        do {
            let url = try await writer.finish(on: queue)
            if let streamError = output?.failure { return .failure(streamError) }
            log.info("Recording finished: \(url.lastPathComponent, privacy: .public), \(writer.frameCount) frames")
            return .success(url)
        } catch let error as RecordingError {
            log.error("Recording failed to finish: \(String(describing: error), privacy: .public)")
            return .failure(error)
        } catch {
            log.error("Recording failed to finish: \(error.localizedDescription, privacy: .public)")
            return .failure(Self.mapError(error))
        }
    }

    func cancel() async {
        defer { tearDown() }
        try? await stream?.stopCapture()
        let writer = self.writer
        queue.sync { writer?.cancel() }
    }

    private func tearDown() {
        stream = nil
        output = nil
        writer = nil
        releaseDisplayAwake()
    }

    // MARK: - Target resolution

    /// What the stream captures, resolved from the domain's `CaptureRegion`.
    private struct Target {
        let filter: SCContentFilter
        /// The captured area in points.
        let pointSize: CGSize
        /// Backing scale of the display it comes from.
        let scale: CGFloat
        /// For a rect: the sub-rect of the display to stream, in display points.
        let sourceRect: CGRect?
    }

    private static func target(for region: CaptureRegion, in content: SCShareableContent) throws -> Target {
        // Exclude Lightshot's own windows by process, so the toolbar, controls pill, countdown and
        // dimming never reach the file even when they overlap the region (story 15).
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }

        switch region {
        case let .display(id):
            guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
                throw RecordingError.noDisplayAvailable
            }
            return Target(
                filter: SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: []),
                pointSize: CGSize(width: display.width, height: display.height),
                scale: Self.backingScale(for: display.displayID),
                sourceRect: nil
            )
        case let .rect(rect):
            // The overlay runs on the main screen, so a rect is a sub-rect of the primary display.
            guard let display = content.displays.first else { throw RecordingError.noDisplayAvailable }
            let standardized = rect.standardized
            let sourceRect = CGRect(
                x: standardized.minX, y: standardized.minY, width: standardized.width, height: standardized.height
            )
            return Target(
                filter: SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: []),
                pointSize: sourceRect.size,
                scale: Self.backingScale(for: display.displayID),
                sourceRect: sourceRect
            )
        case let .window(id, _):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw RecordingError.systemFailure("The selected window is no longer available.")
            }
            let scale = (NSScreen.main ?? NSScreen.screens.first)?.backingScaleFactor ?? 2
            return Target(
                filter: SCContentFilter(desktopIndependentWindow: window),
                pointSize: window.frame.size,
                scale: scale,
                sourceRect: nil
            )
        }
    }

    /// The encoded frame size: native pixels by default, halved for "scale Retina to 1x", then
    /// capped by the longest-edge limit — and always even, which H.264 / HEVC require.
    static func outputSize(points: CGSize, scale: CGFloat, settings: VideoSettings) -> (width: Int, height: Int) {
        var width = points.width * (settings.scaleRetinaTo1x ? 1 : scale)
        var height = points.height * (settings.scaleRetinaTo1x ? 1 : scale)
        if let cap = settings.maxResolution.maxLongestEdge {
            let longest = max(width, height)
            if longest > CGFloat(cap) {
                let factor = CGFloat(cap) / longest
                width *= factor
                height *= factor
            }
        }
        func even(_ value: CGFloat) -> Int { max(2, Int(value.rounded(.down)) & ~1) }
        return (even(width), even(height))
    }

    private static func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? CGDirectDisplayID) == displayID }
        return screen?.backingScaleFactor ?? 2
    }

    /// The status check is advisory; the stream is authoritative — a permission revoked after any
    /// preflight lands here as `userDeclined`. A full disk surfaces as its own case so the message
    /// can say so.
    private static func mapError(_ error: Error) -> RecordingError {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return .permissionDenied(.screenRecording)
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return .diskFull
        }
        return .systemFailure(nsError.localizedDescription)
    }

    // MARK: - Display sleep (story 17)

    private func holdDisplayAwake() {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Lightshot is recording the screen" as CFString,
            &id
        )
        sleepAssertion = result == kIOReturnSuccess ? id : 0
    }

    private func releaseDisplayAwake() {
        guard sleepAssertion != 0 else { return }
        IOPMAssertionRelease(sleepAssertion)
        sleepAssertion = 0
    }
}

/// Receives the stream's frames on the service's queue and hands complete ones to the writer;
/// remembers a stream-level failure so `stop()` can report it.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: RecordingWriter
    private(set) var failure: RecordingError?

    init(writer: RecordingWriter) {
        self.writer = writer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer) else { return }
        writer.append(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        log.error("Stream stopped with error: \(nsError.localizedDescription, privacy: .public)")
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            failure = .permissionDenied(.screenRecording)
        } else {
            failure = .systemFailure(nsError.localizedDescription)
        }
    }

    /// SCK also delivers "idle" and "blank" frames; only complete ones carry new pixels.
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}

/// Encodes screen frames into an MP4 through `AVAssetWriter`. Every method runs on the service's
/// serial queue; the class only guards its own state with that convention.
///
/// Pause/resume (story 13) is a presentation-time offset: frames delivered while paused are dropped,
/// and the first frame after resume is re-stamped to follow the last written one, so the file has
/// no gap and no frozen stretch.
private final class RecordingWriter: @unchecked Sendable {
    private let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let frameDuration: CMTime

    private var started = false
    private var paused = false
    private var resumePending = false
    private var offset = CMTime.zero
    private var lastWritten: CMTime?
    private(set) var failure: RecordingError?
    private(set) var frameCount = 0

    init(url: URL, width: Int, height: Int, codec: VideoCodec, fps: Int) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))

        // Bit rate scales with pixel throughput: ~0.1 bit per pixel per frame reads as high quality
        // for screen content (≈11 Mb/s for 2560×1440 at 30 fps).
        let bitRate = max(1_000_000, Int(Double(width * height * max(1, fps)) * 0.1))
        let settings: [String: Any] = [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else {
            throw RecordingError.systemFailure("The video encoder rejected the recording settings.")
        }
        writer.add(input)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard failure == nil, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !started {
            guard writer.startWriting() else {
                failure = .systemFailure(writer.error?.localizedDescription ?? "The video writer could not start.")
                log.error("AVAssetWriter.startWriting failed: \(self.writer.error?.localizedDescription ?? "unknown", privacy: .public)")
                return
            }
            writer.startSession(atSourceTime: presentation)
            started = true
        }
        guard !paused else { return }
        if resumePending, let lastWritten {
            // Close the gap: the next frame lands one frame after the last one written before the pause.
            offset = CMTimeSubtract(CMTimeSubtract(presentation, lastWritten), frameDuration)
            resumePending = false
        }

        let stamped = CMTimeSubtract(presentation, offset)
        if let lastWritten, CMTimeCompare(stamped, lastWritten) <= 0 { return }   // keep timestamps monotonic
        guard input.isReadyForMoreMediaData else { return }                       // drop rather than block
        if adaptor.append(pixelBuffer, withPresentationTime: stamped) {
            self.lastWritten = stamped
            frameCount += 1
        } else if writer.status == .failed {
            failure = Self.map(writer.error)
            log.error("AVAssetWriter append failed: \(self.writer.error?.localizedDescription ?? "unknown", privacy: .public)")
        }
    }

    func pause() { paused = true }

    func resume() {
        guard paused else { return }
        paused = false
        resumePending = true
    }

    func cancel() {
        if started { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }

    /// Finalise on `queue` and return the file. A take that never received a frame is an error, not
    /// an empty file.
    func finish(on queue: DispatchQueue) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let failure { continuation.resume(throwing: failure); return }
                guard started else {
                    continuation.resume(throwing: RecordingError.systemFailure("No frames were captured."))
                    return
                }
                input.markAsFinished()
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: Self.map(writer.error))
                    }
                }
            }
        }
    }

    private static func map(_ error: Error?) -> RecordingError {
        guard let nsError = error as NSError? else { return .systemFailure("The video writer failed.") }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError { return .diskFull }
        return .systemFailure(nsError.localizedDescription)
    }
}
