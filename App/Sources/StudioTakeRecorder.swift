import AVFoundation
import CoreVideo
import LightshotKit
import os

private let log = Logger(subsystem: "dev.lightshot.app", category: "studio-take")

/// A studio take's side recordings (spec 0007, stories 1–2), kept on the take's own clock: the
/// pointer / click / key events through the pure `StudioInputRecorder`, and — when the camera is
/// on — the camera as its own movie, sampled at a steady rate so it keeps running while the screen
/// is still (SCK only sends frames when the screen changes). Every method runs on the recording
/// queue, like `RecordingWriter`.
final class StudioTakeRecorder: @unchecked Sendable {
    static let cameraFPS = 30

    private let queue: DispatchQueue
    private var input: StudioInputRecorder
    private var cameraFeed: CameraFeed?
    private var cameraWriter: CameraMovieWriter?
    private var timer: DispatchSourceTimer?
    private let cameraScratchURL: URL

    init(regionOrigin: Point, regionSize: Size, queue: DispatchQueue, cameraScratchURL: URL) {
        self.queue = queue
        input = StudioInputRecorder(regionOrigin: regionOrigin, regionSize: regionSize)
        self.cameraScratchURL = cameraScratchURL
    }

    static func hostNow() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

    /// Record the camera from `feed` into its own movie (story 2).
    func attachCamera(_ feed: CameraFeed) {
        cameraFeed = feed
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / Self.cameraFPS))
        timer.setEventHandler { [weak self] in self?.sampleCamera() }
        timer.resume()
        self.timer = timer
    }

    private func sampleCamera() {
        guard let cameraFeed, let time = input.sourceTime(at: Self.hostNow()),
              let frame = cameraFeed.frameSnapshot().frame else { return }
        if cameraWriter == nil {
            do {
                cameraWriter = try CameraMovieWriter(
                    url: cameraScratchURL, width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame), fps: Self.cameraFPS
                )
            } catch {
                // A camera that cannot be written costs the camera track, not the take.
                log.error("Camera movie unavailable: \(error.localizedDescription, privacy: .public)")
                self.cameraFeed = nil
                return
            }
        }
        cameraWriter?.append(frame, at: time)
    }

    /// A complete screen frame arrived at a host time: the first one is source time zero.
    func frameArrived(at hostTime: Double) { input.start(at: hostTime) }

    func record(_ event: InputEvent, at hostTime: Double) { input.record(event, at: hostTime) }
    func pause(at hostTime: Double) { input.pause(at: hostTime) }
    func resume(at hostTime: Double) { input.resume(at: hostTime) }

    /// Write the side files next to the delivered screen movie: `input.json` and the camera movie,
    /// ended at the stop time so both run as long as the screen.
    func finish(at stopHostTime: Double, screen: URL) async {
        let (data, writer, end): (Data?, CameraMovieWriter?, Double) = await withCheckedContinuation { continuation in
            queue.async { [self] in
                timer?.cancel()
                timer = nil
                let end = input.sourceTime(at: stopHostTime) ?? 0
                continuation.resume(returning: (try? JSONEncoder().encode(input.finish()), cameraWriter, end))
            }
        }
        if let data {
            do { try data.write(to: StudioTake.inputURL(forScreen: screen), options: .atomic) } catch {
                log.error("Studio input not written: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let writer else { return }
        do {
            let movie = try await writer.finish(at: end)
            let destination = StudioTake.cameraURL(forScreen: screen)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: movie, to: destination)
        } catch {
            log.error("Camera movie not finished: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Abandon the side recordings (the take was discarded or failed).
    func cancel() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            cameraWriter?.cancel()
            cameraWriter = nil
        }
    }
}

/// Writes camera frames to a QuickTime movie (H.264) at the source times it is given.
final class CameraMovieWriter: @unchecked Sendable {
    private let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var lastTime: Double?

    init(url: URL, width: Int, height: Int, fps: Int) throws {
        try? FileManager.default.removeItem(at: url)
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_000_000, Int(Double(width * height * fps) * 0.1)),
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw RecordingError.systemFailure("The camera movie could not be set up.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? RecordingError.systemFailure("The camera movie could not start.")
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ frame: CVPixelBuffer, at time: Double) {
        if let lastTime, time <= lastTime { return }
        guard input.isReadyForMoreMediaData else { return }
        if adaptor.append(frame, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)) { lastTime = time }
    }

    func finish(at end: Double) async throws -> URL {
        guard lastTime != nil else {
            cancel()
            throw RecordingError.systemFailure("No camera frames were captured.")
        }
        if end > (lastTime ?? 0) { writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 600)) }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? RecordingError.systemFailure("The camera movie could not be finished.") }
        return url
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}
