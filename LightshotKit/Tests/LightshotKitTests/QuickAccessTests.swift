import Testing
import Foundation
@testable import LightshotKit

// Quick Access Overlay (spec 0014): the card stack, its layout, and its settings — pure, so the
// corner cards can be reasoned about without a screen.

private func image(_ width: Int = 200, _ height: Int = 100) -> CapturedImage {
    CapturedImage(pixelWidth: width, pixelHeight: height, data: Data([UInt8(width % 256), UInt8(height % 256)]))
}

// MARK: - Stack

@Test func cardsStackOldestFirstWithDistinctIDs() {
    var stack = QuickAccessStack()
    let first = stack.push(image(10, 10))
    let second = stack.push(image(20, 20))

    #expect(stack.cards.map(\.id) == [first, second])
    #expect(stack.cards.map(\.image) == [image(10, 10), image(20, 20)])
    #expect(first != second)
}

@Test func removingACardKeepsTheOthersInOrder() {
    var stack = QuickAccessStack()
    let a = stack.push(image())
    let b = stack.push(image())
    let c = stack.push(image())

    stack.remove(b)
    #expect(stack.cards.map(\.id) == [a, c])
    stack.remove(UUID())                        // unknown id: nothing happens
    #expect(stack.cards.map(\.id) == [a, c])
    stack.removeAll()
    #expect(stack.cards.isEmpty)
}

@Test func theOldestCardsCloseFirstWhenTheStackDoesNotFit() {
    var stack = QuickAccessStack()
    let ids = (0..<4).map { _ in stack.push(image()) }

    // Four 100 pt cards with 12 pt gaps need 436 pt; 300 pt fits the newest two (212 pt).
    let closing = stack.fitting(cardHeights: [100, 100, 100, 100], available: 300, spacing: 12)
    #expect(closing == [ids[0], ids[1]])
    #expect(stack.fitting(cardHeights: [100, 100, 100, 100], available: 436, spacing: 12).isEmpty)
}

@Test func theNewestCardIsKeptEvenWhenItAloneIsTooTall() {
    var stack = QuickAccessStack()
    let old = stack.push(image())
    _ = stack.push(image())

    #expect(stack.fitting(cardHeights: [100, 500], available: 300, spacing: 12) == [old])
    #expect(QuickAccessStack().fitting(cardHeights: [], available: 300, spacing: 12).isEmpty)
}

// MARK: - Layout

@Test func cardsAre220WideWithTheImagesAspectClampedTo90Through220() {
    #expect(QuickAccessLayout.cardSize(pixelWidth: 2560, pixelHeight: 1440) == Size(width: 220, height: 123.75))
    #expect(QuickAccessLayout.cardSize(pixelWidth: 800, pixelHeight: 800) == Size(width: 220, height: 220))
    #expect(QuickAccessLayout.cardSize(pixelWidth: 400, pixelHeight: 1600) == Size(width: 220, height: 220))  // tall: capped
    #expect(QuickAccessLayout.cardSize(pixelWidth: 4000, pixelHeight: 100) == Size(width: 220, height: 90))   // wide: floored
    #expect(QuickAccessLayout.cardSize(pixelWidth: 0, pixelHeight: 0) == Size(width: 220, height: 220))       // degenerate
}

@Test func cardsStackUpFromTheBottomLeftNewestAtTheBottom() {
    let visible = Rect(x: 0, y: 0, width: 1440, height: 900)
    let frames = QuickAccessLayout.frames(
        for: [Size(width: 220, height: 100), Size(width: 220, height: 150)],   // oldest, newest
        in: visible, side: .left
    )
    #expect(frames == [
        Rect(x: 16, y: 16 + 150 + 12, width: 220, height: 100),   // the older card sits above
        Rect(x: 16, y: 16, width: 220, height: 150),              // the newest at the bottom
    ])
}

@Test func onTheRightCardsHugTheRightEdge() {
    let visible = Rect(x: 0, y: 0, width: 1440, height: 900)
    let frames = QuickAccessLayout.frames(for: [Size(width: 220, height: 100)], in: visible, side: .right)
    #expect(frames == [Rect(x: 1440 - 16 - 220, y: 16, width: 220, height: 100)])
}

@Test func framesFollowAnOffsetVisibleFrame() {
    // A second display to the right, with the Dock taking 70 pt at the bottom.
    let visible = Rect(x: 1440, y: 70, width: 1920, height: 1010)
    #expect(QuickAccessLayout.frames(for: [Size(width: 220, height: 100)], in: visible, side: .left)
        == [Rect(x: 1440 + 16, y: 70 + 16, width: 220, height: 100)])
    #expect(QuickAccessLayout.frames(for: [Size(width: 220, height: 100)], in: visible, side: .right)
        == [Rect(x: 1440 + 1920 - 16 - 220, y: 70 + 16, width: 220, height: 100)])
    #expect(QuickAccessLayout.frames(for: [], in: visible, side: .left).isEmpty)
}

@Test func theHeightTheStackMayFillLeavesAMarginTopAndBottom() {
    #expect(QuickAccessLayout.availableHeight(in: Rect(x: 0, y: 70, width: 1440, height: 800)) == 800 - 32)
}

// MARK: - Settings

@Test func quickAccessDefaultsToBottomLeftNeverAutoClosingAndClosingAfterADrag() {
    let settings = QuickAccessSettings()
    #expect(settings.side == .left)
    #expect(settings.autoClose == .never)
    #expect(settings.autoClose.seconds == nil)
    #expect(settings.closeAfterDragging)
    #expect(QuickAccessAutoClose.after30s.seconds == 30)
}

@Test func quickAccessSettingsRoundTripAndFillMissingFields() throws {
    let custom = QuickAccessSettings(side: .right, autoClose: .after1min, closeAfterDragging: false)
    let data = try JSONEncoder().encode(custom)
    #expect(try JSONDecoder().decode(QuickAccessSettings.self, from: data) == custom)

    let partial = Data(#"{"side":"right"}"#.utf8)
    #expect(try JSONDecoder().decode(QuickAccessSettings.self, from: partial)
        == QuickAccessSettings(side: .right, autoClose: .never, closeAfterDragging: true))
}
