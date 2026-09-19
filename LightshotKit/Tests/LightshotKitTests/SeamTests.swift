import Testing
import Foundation
@testable import LightshotKit

// Placeholder suite that proves the domain-core test harness runs (LIG-6).
// The substantive behavioral suites (AnnotationDocument, render, HistoryStore) arrive
// with their own tickets. The invariant this file quietly guards: this target compiles
// and passes with **no AppKit / ScreenCaptureKit imports**.

@Test func packageVersionIsExposed() {
    #expect(LightshotKit.version == "0.0.1")
}

@Test func capturedImageCarriesPixelDimensionsAndBytes() {
    let image = CapturedImage(pixelWidth: 2560, pixelHeight: 1440, data: Data([0x89, 0x50]))
    #expect(image.pixelWidth == 2560)
    #expect(image.pixelHeight == 1440)
    #expect(image.data.count == 2)
    #expect(image == image)
}
