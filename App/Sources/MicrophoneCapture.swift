import AVFoundation
import OSLog
import LightshotKit

private let log = Logger(subsystem: "dev.lightshot.app", category: "recording")

/// Narration capture for a take (spec 0006, stories 20, 23–25): an `AVCaptureSession` on the chosen
/// microphone delivering float PCM buffers on the recorder's queue, with the configured gain
/// applied in place, a running level for the meter, and a callback when the device disappears.
///
/// Mono is asked of the capture output itself (`AVNumberOfChannelsKey`), so the writer's AAC track
/// simply has one channel. Timing comes from the host clock like the screen frames, so the writer
/// can apply one pause offset to both.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let sampleRate = 48_000.0

    private let session = AVCaptureSession()
    private let device: AVCaptureDevice
    private let gain: Float
    private let onSample: @Sendable (CMSampleBuffer) -> Void
    private let onLevel: @Sendable (Float) -> Void
    private let onLost: @Sendable () -> Void
    private var disconnectObserver: (any NSObjectProtocol)?

    /// How many channels the capture delivers (and the writer's track carries).
    let channels: Int

    init(
        deviceID: String?, mono: Bool, volume: Double, queue: DispatchQueue,
        onSample: @escaping @Sendable (CMSampleBuffer) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onLost: @escaping @Sendable () -> Void
    ) throws {
        guard let device = deviceID.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .audio) else {
            throw RecordingError.systemFailure("No microphone is available.")
        }
        self.device = device
        self.gain = Float(volume)
        self.channels = mono ? 1 : 2
        self.onSample = onSample
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

        let lost = onLost
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil
        ) { _ in
            log.error("Microphone disconnected")
            lost()
        }
    }

    /// Blocking; call off the main thread.
    func start() {
        session.startRunning()
    }

    func stop() {
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        disconnectObserver = nil
        if session.isRunning { session.stopRunning() }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (on the recorder's queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onLevel(Self.applyGainAndMeasure(sampleBuffer, gain: gain))
        onSample(sampleBuffer)
    }

    /// Scale the float samples in place by `gain` (unity leaves them untouched) and return the
    /// buffer's level, `0...1`, from its RMS mapped over a 50 dB range.
    private static func applyGainAndMeasure(_ sampleBuffer: CMSampleBuffer, gain: Float) -> Float {
        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer
        )
        guard status == noErr, let data = list.mBuffers.mData else { return 0 }
        let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        let samples = data.assumingMemoryBound(to: Float.self)
        var sumOfSquares: Float = 0
        for i in 0..<count {
            if gain != 1 { samples[i] = max(-1, min(1, samples[i] * gain)) }
            sumOfSquares += samples[i] * samples[i]
        }
        _ = blockBuffer   // keep the block alive through the loop
        guard count > 0 else { return 0 }
        let rms = (sumOfSquares / Float(count)).squareRoot()
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return max(0, min(1, (decibels + 50) / 50))
    }
}
