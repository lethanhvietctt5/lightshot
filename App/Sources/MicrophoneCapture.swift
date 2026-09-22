import AVFoundation
import OSLog
import LightshotKit

private let log = Logger(subsystem: "dev.lightshot.app", category: "recording")

/// The latest microphone level, `0...1`, written from the capture queue and read by the pill's
/// meter on the main thread — hence the lock.
final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Float = 0

    var level: Float {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Narration capture for a take (spec 0006, stories 20, 23–25): an `AVCaptureSession` on the chosen
/// microphone delivering float PCM on the recorder's queue as `PCMBuffer.Frames` we own, with the
/// level measured on the raw input (so a muted mic reads silent whatever the gain), the configured
/// gain applied, and a callback when the device disappears.
///
/// Mono is asked of the capture output itself (`AVNumberOfChannelsKey`), so the writer's AAC track
/// simply has one channel. Timing comes from the host clock like the screen frames, so the writer
/// can apply one pause offset to both.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let sampleRate = 48_000.0

    private let session = AVCaptureSession()
    private let queue: DispatchQueue
    private let gain: Float
    private let onFrames: @Sendable (PCMBuffer.Frames) -> Void
    private let onLevel: @Sendable (Float) -> Void
    private let onLost: @Sendable () -> Void
    private var disconnectObserver: (any NSObjectProtocol)?
    private let lock = NSLock()
    private var isActive = true

    /// How many channels the capture delivers (and the writer's track carries).
    let channels: Int

    init(
        deviceID: String?, mono: Bool, volume: Double, queue: DispatchQueue,
        onFrames: @escaping @Sendable (PCMBuffer.Frames) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onLost: @escaping @Sendable () -> Void
    ) throws {
        // A remembered device that is no longer attached falls back to the system default.
        guard let device = deviceID.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .audio) else {
            throw RecordingError.systemFailure("No microphone is available.")
        }
        self.queue = queue
        self.gain = Float(volume)
        self.channels = mono ? 1 : 2
        self.onFrames = onFrames
        self.onLevel = onLevel
        self.onLost = onLost
        super.init()

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecordingError.systemFailure("The microphone could not be opened.")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        output.setSampleBufferDelegate(self, queue: queue)

        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil
        ) { [weak self] _ in
            self?.deviceLost()
        }
    }

    /// Starts the session on the recorder's queue (`startRunning` blocks for a moment).
    func start() {
        queue.async { [session] in session.startRunning() }
    }

    /// Stops delivering and ignores anything already in flight. Safe to call more than once.
    func stop() {
        lock.lock()
        let wasActive = isActive
        isActive = false
        lock.unlock()
        guard wasActive else { return }
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        disconnectObserver = nil
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private var active: Bool {
        lock.lock(); defer { lock.unlock() }
        return isActive
    }

    private func deviceLost() {
        guard active else { return }
        log.error("Microphone disconnected")
        onLost()
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (on the recorder's queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard active, var frames = PCMBuffer.frames(from: sampleBuffer) else { return }
        onLevel(frames.level)
        frames.apply(gain: gain)
        onFrames(frames)
    }
}
