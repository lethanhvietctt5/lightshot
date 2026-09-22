import AVFoundation
import CoreVideo
import LightshotKit

/// One camera, running (spec 0006, stories 26–28): an `AVCaptureSession` whose frames feed two
/// consumers — the on-screen preview bubble through `previewLayer`, and the compositor through
/// `latestFrame`, the most recent BGRA buffer, read on the recorder's queue. Frames are kept, not
/// queued: the compositor draws whatever is newest when a screen frame arrives.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// The device asked for (`nil` = system default), so a re-show with the same choice reuses us.
    let requestedDeviceID: String?
    let previewLayer: AVCaptureVideoPreviewLayer
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.lightshot.camera")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    init(deviceID: String?) throws {
        // The toggle gate asks for the grant (story 41); by here it must already exist, or the
        // device input would raise the system prompt from inside a take.
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw RecordingError.permissionDenied(.camera)
        }
        // A remembered camera that is unplugged falls back to the system default.
        guard let device = deviceID.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .video) else {
            throw RecordingError.systemFailure("No camera is available.")
        }
        requestedDeviceID = deviceID
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecordingError.systemFailure("The camera could not be opened.")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// `startRunning` blocks while the device opens, so it runs off the caller's thread.
    func start() {
        queue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    func stop() {
        // Clear the frame after the session stops, so an in-flight frame cannot re-set it.
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.lock.lock(); self.latest = nil; self.lock.unlock()
        }
    }

    var latestFrame: CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); latest = frame; lock.unlock()
    }
}

/// The camera state the preview bubble and the recorder share (stories 27–28): the running
/// capture, the bubble's settings (the anchor moves as the user drags) and the fullscreen flag
/// (a click toggles it). Both sides read it on their own threads, hence the lock.
final class CameraFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var capture: CameraCapture?
    /// Told (on any thread) when a new capture replaces the running one — a restart tears the
    /// take down and starts afresh — so the on-screen preview can re-attach its layer.
    var onCaptureReplaced: (@Sendable (CameraCapture) -> Void)?
    private var settings = CameraBubbleSettings.standard
    private var fullscreen = false

    /// The running capture for `deviceID`, starting one (with `settings`) if none is running for
    /// that device yet. A capture already running for the same device is kept — with whatever
    /// position the user dragged it to meanwhile.
    @discardableResult
    func start(deviceID: String?, settings: CameraBubbleSettings) throws -> CameraCapture {
        // Held across the swap so two starts (preview on the main actor, take on the recorder's)
        // cannot both create a capture and orphan one running.
        lock.lock()
        defer { lock.unlock() }
        if let capture, capture.requestedDeviceID == deviceID { return capture }
        let previous = capture
        let fresh = try CameraCapture(deviceID: deviceID)
        previous?.stop()
        capture = fresh
        self.settings = settings
        fullscreen = false
        let replaced = previous != nil ? onCaptureReplaced : nil
        fresh.start()
        replaced?(fresh)
        return fresh
    }

    func stop() {
        lock.lock()
        let running = capture
        capture = nil
        fullscreen = false
        lock.unlock()
        running?.stop()
    }

    var current: CameraCapture? {
        lock.lock(); defer { lock.unlock() }
        return capture
    }

    var isRunning: Bool { current != nil }

    /// Settings, fullscreen flag and the newest frame together.
    func frameSnapshot() -> (settings: CameraBubbleSettings, isFullscreen: Bool, frame: CVPixelBuffer?) {
        lock.lock(); defer { lock.unlock() }
        return (settings, fullscreen, capture?.latestFrame)
    }

    /// Settings and fullscreen flag together, consistent.
    func snapshot() -> (settings: CameraBubbleSettings, isFullscreen: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (settings, fullscreen)
    }

    func update(_ change: (inout CameraBubbleSettings) -> Void) {
        lock.lock(); change(&settings); lock.unlock()
    }

    /// Story 28: click toggles fullscreen camera and back; returns the new state.
    @discardableResult
    func toggleFullscreen() -> Bool {
        lock.lock(); defer { lock.unlock() }
        fullscreen.toggle()
        return fullscreen
    }
}

/// What the compositor needs to draw the bubble (stories 26–28): the feed, and the region's size
/// in points so the layout matches the on-screen preview's.
struct CameraOverlay: @unchecked Sendable {
    let feed: CameraFeed
    let regionSize: Size
}
