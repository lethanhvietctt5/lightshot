import CoreGraphics
import LightshotKit
import Vision

/// On-device recognition for auto redact (spec 0009): the text, faces and codes in a redaction
/// backdrop, handed to the pure `SensitiveDataScanner` as image-space value types. Vision runs
/// locally; nothing leaves the Mac. This holds no detection logic — which text is sensitive is
/// decided in the domain core.
enum SensitiveContentRecognizer {
    enum Failure: LocalizedError {
        case recognitionFailed(String)

        var errorDescription: String? {
            switch self {
            case let .recognitionFailed(reason): return "Auto Redact couldn't read this image: \(reason)"
            }
        }
    }

    /// Recognises the backdrop's text, and its faces and codes when asked for. Runs Vision off
    /// the main actor.
    static func recognize(_ backdrop: RedactionBackdrop, faces: Bool, codes: Bool) async throws -> ScanInput {
        try await Task.detached(priority: .userInitiated) {
            try recognizeSync(backdrop.image, frame: backdrop.frame, faces: faces, codes: codes)
        }.value
    }

    private static func recognizeSync(_ image: CGImage, frame: Rect, faces: Bool, codes: Bool) throws -> ScanInput {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        // Correction would "fix" keys and tokens into dictionary words.
        text.usesLanguageCorrection = false
        text.automaticallyDetectsLanguage = true
        let faceRequest = VNDetectFaceRectanglesRequest()
        let codeRequest = VNDetectBarcodesRequest()

        var requests: [VNRequest] = [text]
        if faces { requests.append(faceRequest) }
        if codes { requests.append(codeRequest) }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform(requests)
        } catch {
            throw Failure.recognitionFailed(error.localizedDescription)
        }

        let size = CGSize(width: image.width, height: image.height)
        /// Vision's normalised, bottom-left rect → image pixels, top-left, offset by the frame.
        func imageRect(_ normalized: CGRect) -> Rect {
            Rect(
                x: frame.minX + normalized.minX * size.width,
                y: frame.minY + (1 - normalized.maxY) * size.height,
                width: normalized.width * size.width,
                height: normalized.height * size.height
            )
        }

        let lines: [RecognizedLine] = (text.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let string = candidate.string
            var words: [RecognizedWord] = []
            var index = string.startIndex
            while index < string.endIndex {
                guard let start = string[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
                let end = string[start...].firstIndex(where: \.isWhitespace) ?? string.endIndex
                if let box = try? candidate.boundingBox(for: start..<end)?.boundingBox {
                    let lower = string.utf16.distance(from: string.startIndex, to: start)
                    let upper = string.utf16.distance(from: string.startIndex, to: end)
                    words.append(RecognizedWord(range: lower..<upper, box: imageRect(box)))
                }
                index = end
            }
            return words.isEmpty ? nil : RecognizedLine(text: string, words: words)
        }
        return ScanInput(
            lines: lines,
            faces: faces ? (faceRequest.results ?? []).map { imageRect($0.boundingBox) } : [],
            codes: codes ? (codeRequest.results ?? []).map { imageRect($0.boundingBox) } : []
        )
    }
}
