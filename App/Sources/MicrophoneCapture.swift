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
/// microphone delivering float PCM buffers on the recorder's queue, with the level measured on the
/// raw input (so a muted mic reads silent whatever the gain), the configured gain applied into a
/// buffer of our own, and a callback when the device disappears.
///
/// Mono is asked of the capture output itself (`AVNumberOfChannelsKey`), so the writer's AAC track
/// simply has one channel. Timing comes from the host clock like the screen frames, so the writer
/// can apply one pause offset to both.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let sampleRate = 48_000.0

    private let session = AVCaptureSession()
    private let queue: DispatchQueue
    private let gain: Float
    private let onSample: @Sendable (CMSampleBuffer) -> Void
    private let onLevel: @Sendable (Float) -> Void
    private let onLost: @Sendable () -> Void
    private var disconnectObserver: (any NSObjectProtocol)?
    private let lock = NSLock()
    private var isActive = true

    /// How many channels the capture delivers (and the writer's track carries).
    let channels: Int

    init(
        deviceID: String?, mono: Bool, volume: Double, queue: DispatchQueue,
        onSample: @escaping @Sendable (CMSampleBuffer) -> Void,
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
        guard active, let samples = PCMSamples(sampleBuffer) else { return }
        onLevel(samples.level)
        if gain == 1 {
            onSample(sampleBuffer)
        } else if let scaled = samples.copy(scaledBy: gain, timingFrom: sampleBuffer) {
            onSample(scaled)
        }
    }
}

/// A read-only view over an interleaved float PCM sample buffer, and a way to produce a scaled
/// copy in memory we own — the capture output's memory is never written to.
private struct PCMSamples {
    private let block: CMBlockBuffer
    private let base: UnsafeMutablePointer<Float>
    private let count: Int

    init?(_ sampleBuffer: CMSampleBuffer) {
        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer
        )
        // Interleaved float: exactly one AudioBuffer, so the single-entry list is the right size.
        guard status == noErr, let blockBuffer, let data = list.mBuffers.mData else { return nil }
        self.block = blockBuffer
        self.base = data.assumingMemoryBound(to: Float.self)
        self.count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
    }

    /// RMS mapped over a 50 dB range to `0...1`.
    var level: Float {
        guard count > 0 else { return 0 }
        var sumOfSquares: Float = 0
        for i in 0..<count { sumOfSquares += base[i] * base[i] }
        let rms = (sumOfSquares / Float(count)).squareRoot()
        guard rms > 0 else { return 0 }
        return max(0, min(1, (20 * log10(rms) + 50) / 50))
    }

    /// A new sample buffer whose samples are ours, scaled and clipped, carrying the original timing
    /// and format.
    func copy(scaledBy gain: Float, timingFrom original: CMSampleBuffer) -> CMSampleBuffer? {
        let byteCount = count * MemoryLayout<Float>.size
        var newBlock: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &newBlock
        ) == noErr, let newBlock, CMBlockBufferAssureBlockMemory(newBlock) == noErr else { return nil }

        var scaled = [Float](repeating: 0, count: count)
        for i in 0..<count { scaled[i] = max(-1, min(1, base[i] * gain)) }
        let copied = scaled.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: newBlock, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr, let format = CMSampleBufferGetFormatDescription(original) else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(MicrophoneCapture.sampleRate)),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(original),
            decodeTimeStamp: .invalid
        )
        var result: CMSampleBuffer?
        let frames = CMSampleBufferGetNumSamples(original)
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: newBlock, formatDescription: format,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result
        ) == noErr else { return nil }
        _ = block   // the source memory stays alive until we are done reading it
        return result
    }
}
