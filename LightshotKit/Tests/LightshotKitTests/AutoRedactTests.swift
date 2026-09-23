import Testing
import Foundation
@testable import LightshotKit

// Auto redact (spec 0009). Recognised text is built by hand — a monospaced line, 10 px per
// UTF-16 unit and 20 px tall — so these tests assert which rectangles get covered without
// Vision, a screen or a permission. Credential-shaped strings are assembled from pieces so
// the repository never holds anything a secret scanner would flag.

private let charWidth = 10.0
private let lineHeight = 20.0
/// 20% of the line height, on every side.
private let pad = 4.0

/// A line of monospaced text at (`x`, `y`), one word per space-separated run.
private func line(_ text: String, x: Double = 0, y: Double = 0) -> RecognizedLine {
    var words: [RecognizedWord] = []
    var start: Int?
    let units = Array(text.utf16)
    for i in 0...units.count {
        let isSpace = i == units.count || units[i] == 32
        if isSpace, let s = start {
            words.append(RecognizedWord(
                range: s..<i,
                box: Rect(x: x + Double(s) * charWidth, y: y, width: Double(i - s) * charWidth, height: lineHeight)
            ))
            start = nil
        } else if !isSpace, start == nil {
            start = i
        }
    }
    return RecognizedLine(text: text, words: words)
}

/// The padded rect the scanner reports for characters `from..<to` of a line at (`x`, `y`).
private func expected(_ from: Int, _ to: Int, x: Double = 0, y: Double = 0) -> Rect {
    Rect(x: x + Double(from) * charWidth - pad, y: y - pad, width: Double(to - from) * charWidth + 2 * pad, height: lineHeight + 2 * pad)
}

private func scan(_ lines: [RecognizedLine], _ categories: Set<SensitiveCategory> = Set(SensitiveCategory.allCases)) -> [Detection] {
    SensitiveDataScanner.scan(ScanInput(lines: lines), categories: categories)
}

private func scan(_ text: String, _ categories: Set<SensitiveCategory> = Set(SensitiveCategory.allCases)) -> [Detection] {
    scan([line(text)], categories)
}

/// The detection covering exactly `needle` in `text`, for readable expectations.
private func covering(_ needle: String, in text: String, _ category: SensitiveCategory) -> Detection {
    let range = (text as NSString).range(of: needle)
    return Detection(category: category, rect: expected(range.location, range.location + range.length))
}

// MARK: - Categories

@Suite struct SensitiveCategoryDetectionTests {
    @Test func findsLuhnValidCardsAndIgnoresNearMisses() {
        let text = "Card 4111 1111 1111 1111 on file"
        #expect(scan(text) == [covering("4111 1111 1111 1111", in: text, .paymentCard)])
        #expect(scan("Card 4111 1111 1111 1112 on file", [.paymentCard]).isEmpty)
    }

    @Test func findsValidIBANsAndIgnoresABadCheckDigit() {
        let text = "IBAN GB82 WEST 1234 5698 7654 32 BIC NWBKGB2L"
        #expect(scan(text, [.bankAccount]) == [covering("GB82 WEST 1234 5698 7654 32", in: text, .bankAccount)])
        #expect(scan("IBAN GB83 WEST 1234 5698 7654 32", [.bankAccount]).isEmpty)
    }

    @Test func findsEmails() {
        let text = "From: ada.lovelace+work@example.co.uk today"
        #expect(scan(text) == [covering("ada.lovelace+work@example.co.uk", in: text, .email)])
    }

    @Test func findsPhoneNumbers() {
        let text = "Call (415) 555-0132 now"
        #expect(scan(text, [.phone]) == [covering("(415) 555-0132", in: text, .phone)])
    }

    @Test func longDigitRunsAreNotPhoneNumbers() {
        // A 16-digit order number that fails the card checksum is not a phone number either.
        #expect(scan("Order 1000 2000 3000 4001", [.phone, .paymentCard]).isEmpty)
    }

    @Test func findsSSNsButNotImpossibleOnes() {
        let text = "SSN 123-45-6789"
        #expect(scan(text) == [covering("123-45-6789", in: text, .idNumber)])
        #expect(scan("SSN 000-12-3456", [.idNumber]).isEmpty)
        #expect(scan("SSN 666-12-3456", [.idNumber]).isEmpty)
    }

    @Test func findsIPv4AndIPv6ButNotOutOfRangeOctets() {
        let v4 = "host 192.168.10.254 up"
        #expect(scan(v4, [.ipAddress]) == [covering("192.168.10.254", in: v4, .ipAddress)])
        let v6 = "addr fe80::1ff:fe23:4567:890a up"
        #expect(scan(v6, [.ipAddress]) == [covering("fe80::1ff:fe23:4567:890a", in: v6, .ipAddress)])
        #expect(scan("host 999.1.1.1 up", [.ipAddress]).isEmpty)
        #expect(scan("at 12:30:45 today", [.ipAddress]).isEmpty)
    }

    @Test func findsKnownKeyFormats() {
        let keys = [
            "AKIA" + "IOSFODNN7EXAMPLE",
            "ghp" + "_" + String(repeating: "aB3", count: 12),
            "sk" + "_live_" + "4eC39HqLyjWDarjtT1zdp7dc",
            "xox" + "b-" + "1234567890-abcdefABCDEF",
            "AI" + "za" + "SyA1234567890abcdefghijklmnopqrstu",
            "eyJ" + "hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.dozjgNryP4J3jVmNHl0w5N",
        ]
        for key in keys {
            let text = "key " + key
            #expect(scan(text, [.secret]) == [covering(key, in: text, .secret)], "\(key)")
        }
    }

    @Test func coversOnlyTheValueAfterALabel() {
        let text = "Password: hunter2"
        #expect(scan(text) == [covering("hunter2", in: text, .secret)])
        let assignment = "API_KEY=abc"
        #expect(scan(assignment) == [covering("abc", in: assignment, .secret)])
    }

    @Test func slicesAWordWhenTheValueIsPartOfIt() {
        // "password:hunter2" is one recognised word; the value is its last seven characters.
        let text = "password:hunter2"
        #expect(scan(text) == [covering("hunter2", in: text, .secret)])
    }

    @Test func coversTheValueInTheNextColumnOfALabel() {
        let label = line("Password", x: 0, y: 100)
        let value = line("correct horse", x: 200, y: 102)
        let elsewhere = line("Username", x: 0, y: 140)
        #expect(scan([label, value, elsewhere], [.secret]) == [
            Detection(category: .secret, rect: expected(0, 13, x: 200, y: 102)),
        ])
    }

    @Test func leavesCommitHashesAloneUnlessLabelled() {
        let sha = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b"
        #expect(scan("commit " + sha, [.secret]).isEmpty)
        let labelled = "token: " + sha
        #expect(scan(labelled, [.secret]) == [covering(sha, in: labelled, .secret)])
    }

    @Test func findsLongRandomLookingStrings() {
        let token = "Qm9vX2xpZ2h0c2hvdF9zZWNyZXQ7Rk"
        let text = "export X=" + token
        #expect(scan(text, [.secret]) == [covering(token, in: text, .secret)])
        #expect(scan("see Documentation/GettingStartedWithLightshot for help", [.secret]).isEmpty)
    }

    @Test func coversEveryLineOfAPrivateKeyBlock() {
        let lines = [
            line("-----BEGIN RSA PRIVATE KEY-----", y: 0),
            line("MIIEowIBAAKCAQEA0m59l2u9iDnMbrXH", y: 20),
            line("-----END RSA PRIVATE KEY-----", y: 40),
            line("after the key", y: 60),
        ]
        #expect(scan(lines, [.secret]) == [
            Detection(category: .secret, rect: expected(0, 31, y: 0)),
            Detection(category: .secret, rect: expected(0, 32, y: 20)),
            Detection(category: .secret, rect: expected(0, 29, y: 40)),
        ])
    }

    @Test func linksAndAddressesAreFoundOnlyWhenEnabled() {
        let text = "See https://example.com/docs for more"
        #expect(scan(text, SensitiveCategory.defaultEnabled).isEmpty)
        #expect(scan(text, [.link]) == [covering("https://example.com/docs", in: text, .link)])
    }

    @Test func aCardNumberNeverResurfacesAsAPhoneNumber() {
        #expect(scan("Card 4111 1111 1111 1111", [.phone]).isEmpty)
    }

    @Test func disablingACategoryRemovesExactlyItsDetections() {
        let text = "ada@example.com 123-45-6789"
        #expect(scan(text).map(\.category) == [.email, .idNumber])
        #expect(scan(text, [.idNumber]) == [covering("123-45-6789", in: text, .idNumber)])
    }

    @Test func facesAndCodesPassThroughPadded() {
        let input = ScanInput(faces: [Rect(x: 100, y: 100, width: 50, height: 60)], codes: [Rect(x: 10, y: 10, width: 40, height: 40)])
        #expect(SensitiveDataScanner.scan(input, categories: [.face, .code]) == [
            Detection(category: .face, rect: Rect(x: 95, y: 94, width: 60, height: 72)),
            Detection(category: .code, rect: Rect(x: 6, y: 6, width: 48, height: 48)),
        ])
        #expect(SensitiveDataScanner.scan(input, categories: [.code]).map(\.category) == [.code])
    }
}

// MARK: - Merging

@Suite struct DetectionMergingTests {
    @Test func adjacentMatchesOnALineMergeIntoOne() {
        // An email and an SSN with no gap between them: their padded rects overlap, so they
        // become one redaction that keeps the leftmost part's category.
        let text = "ada@example.com123-45-6789"
        #expect(scan(text) == [Detection(category: .email, rect: expected(0, 26))])
    }

    @Test func matchesOnDifferentLinesStaySeparate() {
        let detections = scan([line("ada@example.com", y: 0), line("bob@example.com", y: 22)], [.email])
        #expect(detections.count == 2)
    }

    @Test func distantMatchesOnALineStaySeparate() {
        let text = "ada@example.com and some other words bob@example.com"
        #expect(scan(text, [.email]).count == 2)
    }
}

// MARK: - Planning

private func makeDocument(width: Int = 400, height: Int = 300) -> AnnotationDocument {
    AnnotationDocument(baseImage: CapturedImage(pixelWidth: width, pixelHeight: height, data: Data()))
}

@Suite struct AutoRedactPlanTests {
    private let inside = Detection(category: .email, rect: Rect(x: 10, y: 10, width: 50, height: 20))

    @Test func elementsCarryTheStyleStrengthAndDistinctSeeds() {
        var seeds: [UInt64] = [7, 8]
        let plan = AutoRedactPlan(
            detections: [inside, Detection(category: .phone, rect: Rect(x: 10, y: 50, width: 50, height: 20))],
            in: makeDocument(), style: .blur, strength: 0.8, seed: { seeds.removeFirst() }
        )
        #expect(plan.elements.map(\.kind) == [
            .redaction(inside.rect, style: .blur, strength: 0.8, seed: 7),
            .redaction(Rect(x: 10, y: 50, width: 50, height: 20), style: .blur, strength: 0.8, seed: 8),
        ])
    }

    @Test func clipsToTheCropAndDropsWhatIsOutsideIt() {
        var document = makeDocument()
        document.applyCrop(Rect(x: 0, y: 0, width: 40, height: 100))
        let outside = Detection(category: .email, rect: Rect(x: 200, y: 10, width: 50, height: 20))
        let plan = AutoRedactPlan(detections: [inside, outside], in: document, style: .blackout, strength: 0.5)
        #expect(plan.detections == [Detection(category: .email, rect: Rect(x: 10, y: 10, width: 30, height: 20))])
    }

    @Test func skipsWhatAnExistingRedactionAlreadyCovers() {
        var document = makeDocument()
        document.add(AnnotationElement(kind: .redaction(Rect(x: 0, y: 0, width: 50, height: 40), style: .pixelate)))
        // 40 of 50 px wide (80%) is covered: skipped. Shifted right it is only 60%: kept.
        let shifted = Detection(category: .email, rect: Rect(x: 20, y: 10, width: 50, height: 20))
        let plan = AutoRedactPlan(detections: [inside, shifted], in: document, style: .blackout, strength: 0.5)
        #expect(plan.detections == [shifted])
    }

    @Test func countsByCategoryMostFirst() {
        let d = { (c: SensitiveCategory, y: Double) in Detection(category: c, rect: Rect(x: 0, y: y, width: 10, height: 10)) }
        let plan = AutoRedactPlan(
            detections: [d(.secret, 0), d(.email, 20), d(.email, 40), d(.paymentCard, 60)],
            in: makeDocument(), style: .blackout, strength: 0.5
        )
        #expect(plan.counts.map(\.category) == [.email, .secret, .paymentCard])
        #expect(plan.counts.map(\.count) == [2, 1, 1])
    }
}

// MARK: - Document batch add

@Suite struct AddContentsOfTests {
    private func redaction(_ x: Double) -> AnnotationElement {
        AnnotationElement(kind: .redaction(Rect(x: x, y: 0, width: 10, height: 10), style: .blackout))
    }

    @Test func addsEveryElementOnTopInOrder() {
        var doc = makeDocument()
        let first = doc.add(AnnotationElement(kind: .rectangle(Rect(x: 0, y: 0, width: 5, height: 5))))
        let batch = [redaction(10), redaction(20)]
        let ids = doc.add(contentsOf: batch)
        #expect(doc.elements.map(\.id) == [first] + batch.map(\.id))
        #expect(ids == batch.map(\.id))
    }

    @Test func theBatchIsOneUndoStep() {
        var doc = makeDocument()
        doc.add(contentsOf: [redaction(10), redaction(20), redaction(30)])
        doc.undo()
        #expect(doc.elements.isEmpty)
        #expect(!doc.canUndo)
        doc.redo()
        #expect(doc.elements.count == 3)
    }

    @Test func anEmptyBatchRecordsNothing() {
        var doc = makeDocument()
        doc.add(contentsOf: [])
        #expect(!doc.canUndo)
    }

    @Test func aLaterEditUndoesSeparately() {
        var doc = makeDocument()
        doc.add(contentsOf: [redaction(10), redaction(20)])
        doc.add(redaction(30))
        doc.undo()
        #expect(doc.elements.count == 2)
    }

    @Test func stepMarkersInABatchAreNumberedInOrder() {
        var doc = makeDocument()
        doc.add(AnnotationElement(kind: .stepMarker(number: 0, center: Point(x: 0, y: 0), radius: 10)))
        doc.add(contentsOf: [
            AnnotationElement(kind: .stepMarker(number: 0, center: Point(x: 20, y: 0), radius: 10)),
            AnnotationElement(kind: .stepMarker(number: 0, center: Point(x: 40, y: 0), radius: 10)),
        ])
        let numbers = doc.elements.compactMap { element -> Int? in
            if case let .stepMarker(number, _, _) = element.kind { return number }
            return nil
        }
        #expect(numbers == [1, 2, 3])
    }
}
