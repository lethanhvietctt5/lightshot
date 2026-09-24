import CoreGraphics
import ImageIO
import LightshotKit
import Vision

/// On-device recognition for OCR Text (spec 0010): the lines of text in a captured area, handed to
/// the core as `RecognizedLine`s in image pixels. Vision runs locally; nothing leaves the Mac. The
/// reading order is decided in the core (`TextCapture.plainText`), not here.
///
/// Unlike auto redact's recogniser, language correction is **on**: OCR Text wants readable prose,
/// while auto redact must not "correct" keys and tokens into words.
struct VisionTextRecognizer: TextRecognizer {
    func recognizeText(in image: CapturedImage) async -> Result<[RecognizedLine], TextRecognitionError> {
        let data = image.data
        return await Task.detached(priority: .userInitiated) {
            Self.recognizeSync(data)
        }.value
    }

    nonisolated private static func recognizeSync(_ data: Data) -> Result<[RecognizedLine], TextRecognitionError> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return .failure(TextRecognitionError("The captured image couldn’t be read."))
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return .failure(TextRecognitionError("Text recognition failed: \(error.localizedDescription)"))
        }

        let width = Double(image.width), height = Double(image.height)
        let lines: [RecognizedLine] = (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            // Vision's normalised, bottom-left box → image pixels, top-left. One word spanning the
            // whole line is enough: only the line's box matters for reading order.
            let box = observation.boundingBox
            let rect = Rect(
                x: box.minX * width,
                y: (1 - box.maxY) * height,
                width: box.width * width,
                height: box.height * height
            )
            return RecognizedLine(text: text, words: [RecognizedWord(range: 0..<text.utf16.count, box: rect)])
        }
        return .success(lines)
    }
}
