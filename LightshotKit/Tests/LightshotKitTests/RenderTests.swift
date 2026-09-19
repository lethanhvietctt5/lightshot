import Testing
import Foundation
@testable import LightshotKit

// Base-only `render` for the tracer bullet: with no annotations or crop yet, the flattened
// output is the base image at its native size. When `AnnotationDocument` lands these assertions
// grow into z-order / crop / redaction facts (see spec Testing Decisions).

@Test func baseOnlyRenderPreservesNativeDimensions() {
    let base = CapturedImage(pixelWidth: 2560, pixelHeight: 1440, data: Data([0x1, 0x2, 0x3]))

    let output = render(base)

    #expect(output.pixelWidth == 2560)
    #expect(output.pixelHeight == 1440)
}

@Test func baseOnlyRenderPassesTheImageThroughUnchanged() {
    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
    let base = CapturedImage(pixelWidth: 100, pixelHeight: 200, data: bytes)

    let output = render(base)

    #expect(output.data == bytes)
}
