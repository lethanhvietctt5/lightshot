import CoreGraphics
import ImageIO
import LightshotKit
import Vision

/// On-device recognition for OCR Text (spec 0010): the lines of text in a captured area, handed to
/// the core as `RecognizedLine`s in image pixels, plus its QR codes and barcodes (spec 0012) from the
/// same pass. Vision runs locally; nothing leaves the Mac. The reading order, and whether a code wins
/// over the text, is decided in the core (`TextCapture`), not here.
///
/// Unlike auto redact's recogniser, language correction is **on**: OCR Text wants readable prose,
/// while auto redact must not "correct" keys and tokens into words.
struct VisionTextRecognizer: TextRecognizer {
    func recognizeText(in image: CapturedImage) async -> Result<TextRecognition, TextRecognitionError> {
        let data = image.data
        return await Task.detached(priority: .userInitiated) {
            Self.recognizeSync(data)
        }.value
    }

    nonisolated private static func recognizeSync(_ data: Data) -> Result<TextRecognition, TextRecognitionError> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return .failure(TextRecognitionError("The captured image couldn’t be read."))
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        // Every symbology Vision knows (its default). Performed separately so a barcode failure
        // can't cost the text.
        let codes = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .failure(TextRecognitionError("Text recognition failed: \(error.localizedDescription)"))
        }
        try? handler.perform([codes])

        let width = Double(image.width), height = Double(image.height)
        // Vision's normalised, bottom-left box → image pixels, top-left.
        func pixels(_ box: CGRect) -> Rect {
            Rect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
        }
        let lines: [RecognizedLine] = (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            // One word spanning the whole line is enough: only the line's box matters for reading order.
            return RecognizedLine(text: text, words: [RecognizedWord(range: 0..<text.utf16.count, box: pixels(observation.boundingBox))])
        }
        let found: [RecognizedCode] = (codes.results ?? []).compactMap { observation in
            // A code whose content isn't text (binary data) is skipped.
            guard let payload = observation.payloadStringValue else { return nil }
            let isQR = observation.symbology == .qr || observation.symbology == .microQR
            return RecognizedCode(payload: payload, kind: isQR ? .qrCode : .barcode, box: pixels(observation.boundingBox))
        }
        return .success(TextRecognition(lines: lines, codes: found))
    }
}
