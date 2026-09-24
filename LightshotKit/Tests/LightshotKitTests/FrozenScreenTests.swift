import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import LightshotKit

// The pure crop behind Freeze Screen (spec 0011): what the user selected on the frozen screen is
// exactly what they get. Stills are generated with CoreGraphics, so no screen is involved.

/// A still of a `points`-sized display at `scale`, one flat colour per quadrant:
/// red top-left, green top-right, blue bottom-left, white bottom-right.
private func quadrantStill(points: (width: Int, height: Int), scale: Int) -> CapturedImage {
    let width = points.width * scale
    let height = points.height * scale
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // CoreGraphics' origin is bottom-left, so the top half is the upper y range.
    let halfW = width / 2, halfH = height / 2
    let quads: [(CGRect, CGColor)] = [
        (CGRect(x: 0, y: halfH, width: halfW, height: height - halfH), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
        (CGRect(x: halfW, y: halfH, width: width - halfW, height: height - halfH), CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
        (CGRect(x: 0, y: 0, width: halfW, height: halfH), CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
        (CGRect(x: halfW, y: 0, width: width - halfW, height: halfH), CGColor(red: 1, green: 1, blue: 1, alpha: 1)),
    ]
    for (rect, color) in quads {
        context.setFillColor(color)
        context.fill(rect)
    }
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return CapturedImage(pixelWidth: width, pixelHeight: height, data: data as Data)
}

/// The set of distinct quadrant colours in a PNG. Each channel is snapped to 0 or 255, since
/// colour management shifts a flat colour by a few levels on the way through PNG.
private func colours(in image: CapturedImage) -> Set<[UInt8]> {
    let source = CGImageSourceCreateWithData(image.data as CFData, nil)!
    let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let width = cgImage.width, height = cgImage.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    var found = Set<[UInt8]>()
    for i in stride(from: 0, to: pixels.count, by: 4) {
        found.insert([pixels[i], pixels[i + 1], pixels[i + 2]].map { $0 > 127 ? 255 : 0 })
    }
    return found
}

private let red: [UInt8] = [255, 0, 0]
private let green: [UInt8] = [0, 255, 0]
private let blue: [UInt8] = [0, 0, 255]
private let white: [UInt8] = [255, 255, 255]

/// A 200 × 100 pt display at `scale` — 400 × 200 px at 2x — with its top-left at `origin`.
private func display(_ id: UInt32 = 1, origin: Point = Point(x: 0, y: 0), scale: Int = 2) -> FrozenDisplay {
    FrozenDisplay(
        displayID: id,
        frame: Rect(x: origin.x, y: origin.y, width: 200, height: 100),
        image: quadrantStill(points: (200, 100), scale: scale)
    )
}

/// One 2x display at `origin`, no windows.
private func frozen(origin: Point = Point(x: 0, y: 0)) -> FrozenScreen {
    FrozenScreen(displays: [display(origin: origin)], windows: [])
}

@Test func cropOfOneQuadrantIsThatQuadrantAtNativePixels() throws {
    let crop = try #require(frozen().image(of: .rect(Rect(x: 110, y: 10, width: 50, height: 30))))

    #expect(crop.pixelWidth == 100)
    #expect(crop.pixelHeight == 60)
    #expect(colours(in: crop) == [green])
}

@Test func aReversedDragIsStandardizedBeforeCropping() throws {
    // Dragged from bottom-right to top-left over the bottom-left quadrant.
    let crop = try #require(frozen().image(of: .rect(Rect(x: 90, y: 90, width: -80, height: -30))))

    #expect(crop.pixelWidth == 160)
    #expect(crop.pixelHeight == 60)
    #expect(colours(in: crop) == [blue])
}

@Test func aSelectionOvershootingTheEdgeIsClampedToTheScreen() throws {
    let crop = try #require(frozen().image(of: .rect(Rect(x: 150, y: 60, width: 100, height: 100))))

    #expect(crop.pixelWidth == 100)                 // 150…200 pt of the 200 pt display
    #expect(crop.pixelHeight == 80)                 // 60…100 pt of the 100 pt display
    #expect(colours(in: crop) == [white])
}

@Test func aSelectionEntirelyOffTheScreenCropsNothing() {
    #expect(frozen().image(of: .rect(Rect(x: 300, y: 10, width: 50, height: 50))) == nil)
    #expect(frozen().image(of: .rect(Rect(x: 10, y: 10, width: 0, height: 50))) == nil)
}

@Test func aDisplayAwayFromTheOriginIsOffsetBeforeCropping() throws {
    // A display whose top-left sits at (1000, 500) in global screen points.
    let screen = frozen(origin: Point(x: 1000, y: 500))
    let crop = try #require(screen.image(of: .rect(Rect(x: 1010, y: 510, width: 20, height: 20))))

    #expect(crop.pixelWidth == 40)
    #expect(colours(in: crop) == [red])
}

@Test func aDisplayRegionIsNeverCutFromTheStills() {
    #expect(frozen().image(of: .display(id: 1)) == nil)
}

// MARK: - Every display

/// Display 1 at 2x at the origin, display 2 at 1x to its right.
private func twoDisplays() -> FrozenScreen {
    FrozenScreen(
        displays: [display(1), display(2, origin: Point(x: 200, y: 0), scale: 1)],
        windows: []
    )
}

@Test func anAreaOnTheSecondDisplayIsCutFromItsStillAtItsOwnScale() throws {
    // 210…240 pt is 10…40 pt into display 2 — its top-left (red) quadrant, at 1x.
    let crop = try #require(twoDisplays().image(of: .rect(Rect(x: 210, y: 10, width: 30, height: 20))))

    #expect(crop.pixelWidth == 30)
    #expect(crop.pixelHeight == 20)
    #expect(colours(in: crop) == [red])
}

@Test func anAreaStraddlingTwoDisplaysIsClampedToTheOneItOverlapsMost() throws {
    // 180…260 pt: 20 pt on display 1, 60 pt on display 2 — so display 2, clamped to 200…260.
    let crop = try #require(twoDisplays().image(of: .rect(Rect(x: 180, y: 10, width: 80, height: 20))))

    #expect(crop.pixelWidth == 60)                  // 1x
    #expect(colours(in: crop) == [red])
}

// MARK: - Windows

@Test func aWindowIsItsFrozenImageAsAPNG() throws {
    let still = quadrantStill(points: (30, 20), scale: 2)
    let screen = FrozenScreen(
        displays: [display()],
        windows: [FrozenWindow(id: 7, frame: Rect(x: 10, y: 10, width: 30, height: 20), image: still)]
    )

    let image = try #require(screen.image(of: .window(id: 7, frame: Rect(x: 10, y: 10, width: 30, height: 20))))

    #expect(image.pixelWidth == 60)
    #expect(image.pixelHeight == 40)
    #expect(CGImageSourceGetType(CGImageSourceCreateWithData(image.data as CFData, nil)!) == "public.png" as CFString)
    #expect(colours(in: image) == [red, green, blue, white])
}

@Test func aWindowWithNoFrozenImageGivesNothing() {
    let screen = FrozenScreen(
        displays: [display()],
        windows: [FrozenWindow(id: 7, frame: Rect(x: 10, y: 10, width: 30, height: 20), image: nil)]
    )

    #expect(screen.image(of: .window(id: 7, frame: Rect(x: 10, y: 10, width: 30, height: 20))) == nil)
    #expect(screen.image(of: .window(id: 8, frame: Rect(x: 10, y: 10, width: 30, height: 20))) == nil)
}

@Test func fractionalSelectionsRoundLikeTheLiveRectCapture() throws {
    // Live rect capture floors the pixel origin and rounds the pixel size: 10.3 pt → 20 px origin,
    // 20.4 pt × 2 = 40.8 → 41 px wide, 15.2 pt × 2 = 30.4 → 30 px tall.
    let crop = try #require(frozen().image(of: .rect(Rect(x: 10.3, y: 10.3, width: 20.4, height: 15.2))))

    #expect(crop.pixelWidth == 41)
    #expect(crop.pixelHeight == 30)
}

@Test func aStillInAnyImageIOFormatCropsToAPNG() throws {
    // The app freezes to uncompressed TIFF for speed; what comes out must still be a PNG capture.
    let png = quadrantStill(points: (200, 100), scale: 2)
    let source = CGImageSourceCreateWithData(png.data as CFData, nil)!
    let tiff = NSMutableData()
    let destination = CGImageDestinationCreateWithData(tiff, "public.tiff" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, CGImageSourceCreateImageAtIndex(source, 0, nil)!, nil)
    CGImageDestinationFinalize(destination)
    let screen = FrozenScreen(
        displays: [FrozenDisplay(
            displayID: 1,
            frame: Rect(x: 0, y: 0, width: 200, height: 100),
            image: CapturedImage(pixelWidth: 400, pixelHeight: 200, data: tiff as Data)
        )],
        windows: []
    )

    let crop = try #require(screen.image(of: .rect(Rect(x: 10, y: 60, width: 40, height: 20))))

    let type = CGImageSourceGetType(CGImageSourceCreateWithData(crop.data as CFData, nil)!)
    #expect(type == "public.png" as CFString)
    #expect(colours(in: crop) == [blue])
}
