import AVFoundation
import LightshotKit

/// Conversions between `CMSampleBuffer` and plain interleaved float frames, so the microphone,
/// ScreenCaptureKit's system audio (which arrives deinterleaved) and the mixer all speak one
/// format, and nothing ever writes into memory a capture API owns.
enum PCMBuffer {
    struct Frames {
        var samples: [Float]      // interleaved, `channels` per frame
        let channels: Int
        let sampleRate: Double
        var presentation: CMTime

        var frameCount: Int { channels > 0 ? samples.count / channels : 0 }

        /// RMS mapped over a 50 dB range to `0...1`.
        var level: Float {
            guard !samples.isEmpty else { return 0 }
            var sumOfSquares: Float = 0
            for s in samples { sumOfSquares += s * s }
            let rms = (sumOfSquares / Float(samples.count)).squareRoot()
            guard rms > 0 else { return 0 }
            return max(0, min(1, (20 * log10(rms) + 50) / 50))
        }

        /// Scale and clip every sample (the kit's tested rule).
        mutating func apply(gain: Float) {
            AudioMixer.applyGain(gain, to: &samples)
        }
    }

    /// Read a float32 LPCM buffer, interleaved or not, into interleaved frames. `nil` for any
    /// other format.
    static func frames(from sampleBuffer: CMSampleBuffer) -> Frames? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32
        else { return nil }
        let channels = Int(asbd.mChannelsPerFrame)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let deinterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bufferCount = deinterleaved ? channels : 1

        let list = AudioBufferList.allocate(maximumBuffers: bufferCount)
        defer { free(list.unsafeMutablePointer) }
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: bufferCount),
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block
        )
        guard status == noErr, block != nil else { return nil }

        var samples = [Float](repeating: 0, count: frameCount * channels)
        if deinterleaved {
            for channel in 0..<min(channels, list.count) {
                guard let data = list[channel].mData else { continue }
                let source = data.assumingMemoryBound(to: Float.self)
                let available = Int(list[channel].mDataByteSize) / MemoryLayout<Float>.size
                for frame in 0..<min(frameCount, available) { samples[frame * channels + channel] = source[frame] }
            }
        } else if let data = list[0].mData {
            let source = data.assumingMemoryBound(to: Float.self)
            let available = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<min(samples.count, available) { samples[i] = source[i] }
        }
        withExtendedLifetime(block) {}   // the source memory stays alive until the copy is done
        return Frames(samples: samples, channels: channels, sampleRate: asbd.mSampleRate, presentation: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// Build an interleaved float32 sample buffer we own from `frames`, stamped at `presentation`
    /// with a per-sample duration of one frame.
    static func sampleBuffer(_ frames: Frames, at presentation: CMTime) -> CMSampleBuffer? {
        let channels = frames.channels
        var asbd = AudioStreamBasicDescription(
            mSampleRate: frames.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        let byteCount = frames.samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block
        ) == noErr, let block, CMBlockBufferAssureBlockMemory(block) == noErr else { return nil }
        let copied = frames.samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(frames.sampleRate)),
            presentationTimeStamp: presentation, decodeTimeStamp: .invalid
        )
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frames.frameCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result
        ) == noErr else { return nil }
        return result
    }
}
