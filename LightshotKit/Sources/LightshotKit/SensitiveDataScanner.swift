import Foundation

// Auto redact (spec 0009): finding the sensitive parts of a capture and planning the
// redactions that cover them.
//
// Recognition is the OS's job — the app's Vision recogniser turns the backdrop into the
// value types below, the same split as captions (`SpeechTranscriber` → `StudioTranscript`).
// Everything after that is pure: which text counts as sensitive, which slice of a line it
// covers, the padding and merging, and how detections become redaction elements. Auto
// redact only chooses *where* redactions go; only `blackout` is secure redaction.

// MARK: - Scanner input

/// One recognised word: a range into its line's text and the image-space box it covers.
public struct RecognizedWord: Equatable, Sendable {
    /// UTF-16 offsets into the line's `text`.
    public var range: Range<Int>
    public var box: Rect

    public init(range: Range<Int>, box: Rect) {
        self.range = range
        self.box = box
    }
}

/// One recognised line of text, exactly as recognised, with a box per word.
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    public var words: [RecognizedWord]

    public init(text: String, words: [RecognizedWord]) {
        self.text = text
        self.words = words
    }

    /// The union of the line's word boxes.
    public var box: Rect? { union(words.map(\.box)) }
}

/// Everything the recogniser found in one backdrop, in image pixel coordinates.
public struct ScanInput: Equatable, Sendable {
    public var lines: [RecognizedLine]
    public var faces: [Rect]
    public var codes: [Rect]

    public init(lines: [RecognizedLine] = [], faces: [Rect] = [], codes: [Rect] = []) {
        self.lines = lines
        self.faces = faces
        self.codes = codes
    }
}

// MARK: - Output

/// A kind of thing auto redact looks for. The user chooses which are on.
public enum SensitiveCategory: String, CaseIterable, Codable, Sendable {
    case secret, paymentCard, bankAccount, email, phone, idNumber, ipAddress, postalAddress, link, face, code

    /// On until the user changes them: postal addresses (noisy), links (mostly harmless) and
    /// faces (avatars on every chat screenshot) are opt-in.
    public static let defaultEnabled: Set<SensitiveCategory> = [
        .secret, .paymentCard, .bankAccount, .email, .phone, .idNumber, .ipAddress, .code,
    ]

    /// The checklist title.
    public var title: String {
        switch self {
        case .secret: return "Passwords, keys & tokens"
        case .paymentCard: return "Payment cards"
        case .bankAccount: return "Bank accounts (IBAN)"
        case .email: return "Email addresses"
        case .phone: return "Phone numbers"
        case .idNumber: return "ID numbers (US SSN)"
        case .ipAddress: return "IP addresses"
        case .postalAddress: return "Postal addresses"
        case .link: return "Links"
        case .face: return "Faces"
        case .code: return "QR codes & barcodes"
        }
    }

    /// "1 email", "3 emails" — for the notice after a run.
    public func counted(_ count: Int) -> String {
        let (one, many): (String, String) = switch self {
        case .secret: ("secret", "secrets")
        case .paymentCard: ("card", "cards")
        case .bankAccount: ("bank account", "bank accounts")
        case .email: ("email", "emails")
        case .phone: ("phone number", "phone numbers")
        case .idNumber: ("ID number", "ID numbers")
        case .ipAddress: ("IP address", "IP addresses")
        case .postalAddress: ("address", "addresses")
        case .link: ("link", "links")
        case .face: ("face", "faces")
        case .code: ("code", "codes")
        }
        return "\(count) \(count == 1 ? one : many)"
    }
}

/// One found item: what it is and where. Not a redaction until applied.
public struct Detection: Equatable, Sendable {
    public var category: SensitiveCategory
    public var rect: Rect

    public init(category: SensitiveCategory, rect: Rect) {
        self.category = category
        self.rect = rect
    }
}

// MARK: - Scanner

public enum SensitiveDataScanner {
    /// The padded, merged detections in `input` for the enabled `categories`.
    public static func scan(_ input: ScanInput, categories: Set<SensitiveCategory>) -> [Detection] {
        var detections: [Detection] = []
        let keyBlockLines = privateKeyBlockLines(input.lines)

        for (index, line) in input.lines.enumerated() {
            guard let lineBox = line.box else { continue }
            let pad = lineBox.height * textPadding
            var found: [Detection] = []

            if keyBlockLines.contains(index) {
                found.append(Detection(category: .secret, rect: lineBox))
            } else {
                for match in matches(in: line.text) where categories.contains(match.category) {
                    if let rect = rect(for: match.range, in: line) {
                        found.append(Detection(category: match.category, rect: rect))
                    }
                }
                if categories.contains(.secret), let value = sameRowValue(forLabelLine: index, in: input.lines) {
                    found.append(Detection(category: .secret, rect: value))
                }
            }
            detections += merged(found.map { Detection(category: $0.category, rect: roundedOut($0.rect.insetBy(dx: -pad, dy: -pad))) })
        }

        if categories.contains(.face) {
            detections += input.faces.map {
                Detection(category: .face, rect: roundedOut($0.standardized.insetBy(dx: -$0.width * facePadding, dy: -$0.height * facePadding)))
            }
        }
        if categories.contains(.code) {
            detections += input.codes.map {
                Detection(category: .code, rect: roundedOut($0.standardized.insetBy(dx: -codePadding, dy: -codePadding)))
            }
        }
        return detections
    }

    /// Text detections grow by this share of their line's height on every side.
    static let textPadding = 0.2
    /// Faces grow by this share of their size on every side.
    static let facePadding = 0.1
    /// Codes grow by this many pixels on every side.
    static let codePadding = 4.0

    // MARK: Matching

    struct Match: Equatable {
        var category: SensitiveCategory
        /// UTF-16 offsets into the line.
        var range: Range<Int>
    }

    /// Every sensitive range in one line of text, before the category filter. Weaker readings
    /// of the same characters (a card number that also parses as a phone number, an email
    /// inside a link) are dropped here, so turning a category off never lets its text
    /// resurface as another.
    static func matches(in text: String) -> [Match] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var strong: [Match] = []

        func add(_ category: SensitiveCategory, _ range: NSRange, to list: inout [Match]) {
            guard range.length > 0 else { return }
            list.append(Match(category: category, range: range.location..<(range.location + range.length)))
        }

        for pattern in keyPatterns {
            for m in pattern.matches(in: text, range: whole) { add(.secret, m.range, to: &strong) }
        }
        for m in labelPattern.matches(in: text, range: whole) {
            let valueStart = m.range.location + m.range.length
            let rest = ns.substring(from: valueStart)
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let lead = (rest as NSString).range(of: trimmed).location
            add(.secret, NSRange(location: valueStart + lead, length: (trimmed as NSString).length), to: &strong)
        }
        for range in highEntropyRanges(in: ns) { add(.secret, range, to: &strong) }
        for m in cardPattern.matches(in: text, range: whole) where luhnValid(digits(ns.substring(with: m.range))) {
            add(.paymentCard, m.range, to: &strong)
        }
        for m in ibanPattern.matches(in: text, range: whole) {
            if let range = validIBANPrefix(of: m.range, in: ns) { add(.bankAccount, range, to: &strong) }
        }
        for m in emailPattern.matches(in: text, range: whole) { add(.email, m.range, to: &strong) }
        for m in ssnPattern.matches(in: text, range: whole) { add(.idNumber, m.range, to: &strong) }
        for m in ipv4Pattern.matches(in: text, range: whole) { add(.ipAddress, m.range, to: &strong) }
        for m in ipv6CandidatePattern.matches(in: text, range: whole) where isIPv6(ns.substring(with: m.range)) {
            add(.ipAddress, m.range, to: &strong)
        }

        // The data detector's readings are the weakest: a phone number, link or address that
        // overlaps anything above is the same characters read another way.
        var weak: [Match] = []
        for m in dataDetector?.matches(in: text, range: whole) ?? [] {
            switch m.resultType {
            // E.164 caps a phone number at 15 digits; the detector also claims longer runs
            // (a 16-digit order number), which are not phone numbers.
            case .phoneNumber where (7...15).contains(digits(ns.substring(with: m.range)).count):
                add(.phone, m.range, to: &weak)
            case .address: add(.postalAddress, m.range, to: &weak)
            case .link where m.url?.scheme != "mailto": add(.link, m.range, to: &weak)
            default: break
            }
        }
        weak.removeAll { w in strong.contains { $0.range.overlaps(w.range) } }
        return strong + weak
    }

    /// Known credential formats. Case-sensitive: the prefixes are.
    static let keyPatterns: [NSRegularExpression] = [
        #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,                               // AWS access key id
        #"\b(?:ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{36,}\b"#,                // GitHub tokens
        #"\bgithub_pat_[A-Za-z0-9_]{22,}\b"#,                            // GitHub fine-grained
        #"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{10,}\b"#,                // Stripe
        #"\bxox[abpors]-[A-Za-z0-9-]{10,}\b"#,                           // Slack
        #"\bAIza[0-9A-Za-z_\-]{35}"#,                                    // Google API key
        #"\bsk-[A-Za-z0-9_\-]{20,}"#,                                    // sk-style LLM keys
        #"\beyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}"#, // JWT
    ].map { try! NSRegularExpression(pattern: $0) }

    /// A label and its `:`/`=` separator; the value is whatever follows on the line.
    static let labelPattern = try! NSRegularExpression(
        pattern: #"\b(?:password|passwd|pwd|passcode|client[ _-]?secret|secret|token|api[ _-]?key|apikey|access[ _-]?key|private[ _-]?key)\s*[:=]"#,
        options: .caseInsensitive
    )

    /// A line that is only a label (optionally with its colon) — a form's left column.
    static let bareLabelPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:password|passwd|pwd|passcode|client[ _-]?secret|secret|token|api[ _-]?key|apikey|access[ _-]?key|private[ _-]?key)\s*:?\s*$"#,
        options: .caseInsensitive
    )

    static let cardPattern = try! NSRegularExpression(pattern: #"(?<![\d-])\d(?:[ -]?\d){12,18}(?![\d-])"#)
    static let ibanPattern = try! NSRegularExpression(pattern: #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}\b"#)
    static let emailPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}"#
    )
    static let ssnPattern = try! NSRegularExpression(pattern: #"(?<![\d-])(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}(?![\d-])"#)
    static let ipv4Pattern = try! NSRegularExpression(
        pattern: #"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?!\.?\d)"#
    )
    static let ipv6CandidatePattern = try! NSRegularExpression(pattern: #"(?<![0-9A-Fa-f:])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?![0-9A-Fa-f:])"#)

    static let dataDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.address.rawValue
    )

    // MARK: Checksums and validators

    static func digits(_ string: String) -> [Int] { string.compactMap(\.wholeNumberValue) }

    static func luhnValid(_ digits: [Int]) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// The longest prefix of the matched run (dropping whole space-separated groups off the
    /// end) that is a valid IBAN — the pattern greedily runs into a following capitalised word.
    static func validIBANPrefix(of range: NSRange, in text: NSString) -> NSRange? {
        var candidate = text.substring(with: range)
        while true {
            if ibanValid(candidate) {
                return NSRange(location: range.location, length: (candidate as NSString).length)
            }
            guard let space = candidate.lastIndex(of: " ") else { return nil }
            candidate = String(candidate[..<space])
        }
    }

    static func ibanValid(_ string: String) -> Bool {
        let compact = string.replacingOccurrences(of: " ", with: "")
        guard (15...34).contains(compact.count) else { return false }
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for character in rearranged {
            let value: Int
            if let digit = character.wholeNumberValue {
                value = digit
            } else if let ascii = character.asciiValue, character.isUppercase {
                value = Int(ascii) - 55   // A = 10 … Z = 35
            } else {
                return false
            }
            remainder = (remainder * (value > 9 ? 100 : 10) + value) % 97
        }
        return remainder == 1
    }

    static func isIPv6(_ string: String) -> Bool {
        guard string.contains(where: \.isHexDigit) else { return false }
        var address = in6_addr()
        return inet_pton(AF_INET6, string, &address) == 1
    }

    /// Long, random-looking runs: at least 20 characters mixing upper case, lower case and
    /// digits, with at least 3.5 bits of entropy per character. A URL or path is split at its
    /// punctuation and each segment judged alone. Pure hex (commit hashes) never qualifies.
    static func highEntropyRanges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/?&=:#@,;()[]{}<>\"'`|"))
        var start: Int?
        func flush(_ end: Int) {
            defer { start = nil }
            guard let s = start, end - s >= 20 else { return }
            let range = NSRange(location: s, length: end - s)
            if looksRandom(text.substring(with: range)) { ranges.append(range) }
        }
        for i in 0..<text.length {
            let unit = text.character(at: i)
            let isSeparator = UnicodeScalar(unit).map { separators.contains($0) } ?? false
            if isSeparator { flush(i) } else if start == nil { start = i }
        }
        flush(text.length)
        return ranges
    }

    static func looksRandom(_ token: String) -> Bool {
        guard token.contains(where: \.isUppercase),
              token.contains(where: \.isLowercase),
              token.contains(where: \.isNumber) else { return false }
        if token.allSatisfy(\.isHexDigit) { return false }
        var counts: [Character: Int] = [:]
        for character in token { counts[character, default: 0] += 1 }
        let length = Double(token.count)
        let entropy = counts.values.reduce(0.0) { sum, n in
            let p = Double(n) / length
            return sum - p * log2(p)
        }
        return entropy >= 3.5
    }

    // MARK: Geometry

    /// The image-space rect covering `range` of the line: the words it overlaps, each sliced
    /// horizontally in proportion to the characters covered.
    static func rect(for range: Range<Int>, in line: RecognizedLine) -> Rect? {
        let slices: [Rect] = line.words.compactMap { word in
            let lower = max(range.lowerBound, word.range.lowerBound)
            let upper = min(range.upperBound, word.range.upperBound)
            guard upper > lower, !word.range.isEmpty else { return nil }
            let box = word.box.standardized
            let perUnit = box.width / Double(word.range.count)
            return Rect(
                x: box.minX + Double(lower - word.range.lowerBound) * perUnit,
                y: box.minY,
                width: Double(upper - lower) * perUnit,
                height: box.height
            )
        }
        return union(slices)
    }

    /// The indices of lines inside `-----BEGIN … PRIVATE KEY-----` … `-----END … PRIVATE KEY-----`,
    /// both markers included. An unterminated block runs to the last line.
    static func privateKeyBlockLines(_ lines: [RecognizedLine]) -> Set<Int> {
        var indices = Set<Int>()
        var inside = false
        for (index, line) in lines.enumerated() {
            let text = line.text.uppercased()
            if !inside, text.contains("BEGIN"), text.contains("PRIVATE KEY") { inside = true }
            if inside { indices.insert(index) }
            if inside, text.contains("END"), text.contains("PRIVATE KEY"), !text.contains("BEGIN") { inside = false }
        }
        return indices
    }

    /// For a line that is only a label ("Password", "API key:"), the box of the nearest line to
    /// its right on the same row — a two-column form's value.
    static func sameRowValue(forLabelLine index: Int, in lines: [RecognizedLine]) -> Rect? {
        let label = lines[index]
        let ns = label.text as NSString
        guard bareLabelPattern.firstMatch(in: label.text, range: NSRange(location: 0, length: ns.length)) != nil,
              let labelBox = label.box else { return nil }
        let candidates: [Rect] = lines.enumerated().compactMap { offset, other in
            guard offset != index, let box = other.box, box.minX >= labelBox.maxX else { return nil }
            let overlap = min(box.maxY, labelBox.maxY) - max(box.minY, labelBox.minY)
            return overlap >= min(box.height, labelBox.height) / 2 ? box : nil
        }
        return candidates.min { $0.minX < $1.minX }
    }

    /// Detections on one line, merged wherever their padded rects touch or overlap. A merged
    /// detection keeps the category of its leftmost part.
    static func merged(_ detections: [Detection]) -> [Detection] {
        var result: [Detection] = []
        for detection in detections.sorted(by: { $0.rect.minX < $1.rect.minX }) {
            if let last = result.last, touches(last.rect, detection.rect), let joined = union([last.rect, detection.rect]) {
                result[result.count - 1].rect = joined
            } else {
                result.append(detection)
            }
        }
        return result
    }

    static func touches(_ a: Rect, _ b: Rect) -> Bool {
        a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY
    }

    static func roundedOut(_ rect: Rect) -> Rect {
        let x0 = rect.minX.rounded(.down), y0 = rect.minY.rounded(.down)
        return Rect(x: x0, y: y0, width: rect.maxX.rounded(.up) - x0, height: rect.maxY.rounded(.up) - y0)
    }
}

/// The smallest rect enclosing every rect, or `nil` for none.
func union(_ rects: [Rect]) -> Rect? {
    guard let first = rects.first else { return nil }
    return rects.dropFirst().reduce(first.standardized) { acc, r in
        let x0 = min(acc.minX, r.minX), y0 = min(acc.minY, r.minY)
        return Rect(x: x0, y: y0, width: max(acc.maxX, r.maxX) - x0, height: max(acc.maxY, r.maxY) - y0)
    }
}

// MARK: - Planning

/// The redactions an auto-redact run adds to a document: its detections clipped to the
/// visible frame, minus any already covered by a redaction, each as a `.redaction` element in
/// the given style and strength with its own seed.
public struct AutoRedactPlan: Sendable {
    /// The detections that became elements, in the same order as `elements`.
    public let detections: [Detection]
    public let elements: [AnnotationElement]

    /// A detection at least this much covered by one existing redaction is skipped.
    static let coveredShare = 0.8

    public init(
        detections: [Detection],
        in document: AnnotationDocument,
        style: RedactionStyle,
        strength: Double,
        seed: () -> UInt64 = { UInt64.random(in: .min ... .max) }
    ) {
        let frame = document.visibleFrame.standardized
        let existing: [Rect] = document.elements.compactMap {
            if case let .redaction(rect, _, _, _) = $0.kind { return rect.standardized }
            return nil
        }
        var kept: [Detection] = []
        for detection in detections {
            guard let clipped = detection.rect.standardized.intersection(frame),
                  clipped.width >= 1, clipped.height >= 1 else { continue }
            let area = clipped.width * clipped.height
            let covered = existing.contains { rect in
                guard let overlap = rect.intersection(clipped) else { return false }
                return overlap.width * overlap.height >= area * Self.coveredShare
            }
            if !covered { kept.append(Detection(category: detection.category, rect: clipped)) }
        }
        self.detections = kept
        self.elements = kept.map {
            AnnotationElement(kind: .redaction($0.rect, style: style, strength: strength, seed: seed()))
        }
    }

    /// How many of each category, most first (ties in `SensitiveCategory` order).
    public var counts: [(category: SensitiveCategory, count: Int)] {
        SensitiveCategory.allCases
            .map { category in (category, detections.filter { $0.category == category }.count) }
            .filter { $0.1 > 0 }
            .enumerated()
            .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
            .map { (category: $0.element.0, count: $0.element.1) }
    }
}
