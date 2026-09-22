import AVFoundation
import CoreGraphics
import ImageIO
import LightshotKit
import UniformTypeIdentifiers

/// The in-process GIF encoder (spec 0006, stories 37–38): reads the finished MP4 with
/// `AVAssetReader`, keeps the frames a pure `GIFFramePlan` picks, scales them to the plan's size,
/// posterises per the quality setting, and writes them with ImageIO — which quantises each frame
/// to a palette. With "Optimise GIFs" on, pixels unchanged since the previous frame are written
/// transparent so the previous frame shows through and the frame compresses to almost nothing.
/// No third-party binaries.
///
/// Cancellation is checked per frame; a cancelled or failed conversion removes the partial file.
struct ImageIOGIFEncoder: GIFEncoding {
    func encode(video: URL, to output: URL, settings: GIFSettings, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingError.systemFailure("The recording has no video track.")
        }
        let (naturalSize, duration) = try await (track.load(.naturalSize), asset.load(.duration))
        let plan = GIFFramePlan(
            duration: CMTimeGetSeconds(duration),
            sourceSize: Size(width: Double(naturalSize.width), height: Double(naturalSize.height)),
            settings: settings
        )
        // Decoding and quantising are CPU work: off the caller's actor.
        try await Task.detached(priority: .userInitiated) {
            try Self.write(asset: asset, track: track, plan: plan, settings: settings, to: output, progress: progress)
        }.value
    }

    private static func write(
        asset: AVURLAsset, track: AVAssetTrack, plan: GIFFramePlan, settings: GIFSettings, to output: URL,
        progress: @Sendable (Double) -> Void
    ) throws {
        try? FileManager.default.removeItem(at: output)
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw reader.error ?? RecordingError.systemFailure("The recording could not be read.")
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, plan.frameCount, nil) else {
            throw RecordingError.systemFailure("The GIF could not be created.")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: plan.frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: plan.frameDelay,
            ],
        ] as CFDictionary

        var canvas = FrameCanvas(size: plan.outputSize, bitsPerChannel: GIFFramePlan.bitsPerChannel(quality: settings.quality))
        var lastFilled: Int?
        var lastImage: CGImage?
        func abandon() {
            reader.cancelReading()
            try? FileManager.default.removeItem(at: output)
        }
        while let sample = readerOutput.copyNextSampleBuffer() {
            if Task.isCancelled { abandon(); throw CancellationError() }
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard let index = plan.outputIndex(forSourceFrameAt: time, after: lastFilled),
                  let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            guard let image = canvas.frame(from: pixels, differencing: settings.optimize) else { continue }
            CGImageDestinationAddImage(destination, image, frameProperties)
            lastFilled = index
            lastImage = image
            progress(Double(index + 1) / Double(plan.frameCount))
        }
        if reader.status == .failed { abandon(); throw reader.error ?? RecordingError.systemFailure("The recording could not be read.") }
        if Task.isCancelled { abandon(); throw CancellationError() }
        // ImageIO wants exactly the promised count: a source that ran short holds its last frame.
        if let lastImage {
            for _ in ((lastFilled ?? -1) + 1)..<plan.frameCount { CGImageDestinationAddImage(destination, lastImage, frameProperties) }
        } else {
            abandon()
            throw RecordingError.systemFailure("The recording has no frames.")
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw RecordingError.systemFailure("The GIF could not be written.")
        }
        progress(1)
    }
}

/// One output-sized RGBA buffer reused per frame: draws the source scaled in, posterises, and —
/// when differencing — makes pixels equal to the previous frame transparent.
private struct FrameCanvas {
    private let width: Int
    private let height: Int
    private let mask: UInt8
    private var current: [UInt8]
    private var previous: [UInt8]?

    init(size: Size, bitsPerChannel: Int) {
        width = max(1, Int(size.width))
        height = max(1, Int(size.height))
        mask = bitsPerChannel >= 8 ? 0xFF : UInt8(truncatingIfNeeded: 0xFF << (8 - bitsPerChannel))
        current = [UInt8](repeating: 0, count: width * height * 4)
    }

    mutating func frame(from pixels: CVPixelBuffer, differencing: Bool) -> CGImage? {
        guard let source = Self.image(from: pixels) else { return nil }
        let rowBytes = width * 4
        let drawn: Bool = current.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // Posterise (quality).
        if mask != 0xFF {
            for i in stride(from: 0, to: current.count, by: 4) {
                current[i] &= mask; current[i + 1] &= mask; current[i + 2] &= mask
            }
        }
        var output = current
        if differencing, var shown = previous {
            // A pixel within `tolerance` of what the viewer is showing is written transparent, so
            // the shown pixel stays. The reference is what is *shown*, not what was decoded: the
            // decoder's own noise (H.264 wobbles a textured region a little every frame) must not
            // creep in as change, nor drift the picture over time.
            for i in stride(from: 0, to: output.count, by: 4) {
                if Self.close(shown[i], output[i]) && Self.close(shown[i + 1], output[i + 1]) && Self.close(shown[i + 2], output[i + 2]) {
                    output[i] = 0; output[i + 1] = 0; output[i + 2] = 0; output[i + 3] = 0
                } else {
                    shown[i] = output[i]; shown[i + 1] = output[i + 1]; shown[i + 2] = output[i + 2]
                }
            }
            previous = shown
        } else {
            previous = current
        }

        let data = Data(output)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Decoder noise, not content: channels this close count as the same pixel.
    private static let tolerance: Int = 8

    @inline(__always) private static func close(_ a: UInt8, _ b: UInt8) -> Bool {
        abs(Int(a) - Int(b)) <= tolerance
    }

    private static func image(from pixels: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels),
              let context = CGContext(
                data: base, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        return context.makeImage()
    }
}
