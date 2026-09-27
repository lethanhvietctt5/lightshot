import Foundation

// Quick Access Overlay (spec 0014): after a screenshot, a card waits in a bottom corner of the
// screen for an action. The cards, their placement and their settings are pure and live here; the
// app's `QuickAccessController` draws them and runs their actions.

/// The Quick Access cards on screen, oldest first. Each card is one screenshot, known by its id.
public struct QuickAccessStack: Equatable, Sendable {
    public struct Card: Equatable, Sendable {
        public let id: UUID
        public let image: CapturedImage
    }

    public private(set) var cards: [Card] = []

    public init() {}

    /// Add a card for `image` at the bottom of the stack (the newest), and return its id.
    @discardableResult
    public mutating func push(_ image: CapturedImage) -> UUID {
        let id = UUID()
        cards.append(Card(id: id, image: image))
        return id
    }

    public mutating func remove(_ id: UUID) {
        cards.removeAll { $0.id == id }
    }

    /// The cards that don't fit in `available` points and must close, given each card's height
    /// (oldest first, like `cards`) and the gap between cards: the oldest go first, and the newest
    /// is always kept, even if it alone is taller.
    public func overflow(cardHeights: [Double], available: Double, spacing: Double) -> [UUID] {
        var used = 0.0
        var kept = 0
        for height in cardHeights.reversed() {
            let needed = used + (kept == 0 ? 0 : spacing) + height
            guard kept == 0 || needed <= available else { break }
            used = needed
            kept += 1
        }
        return cards.prefix(max(0, cards.count - kept)).map(\.id)
    }
}

/// Where the cards go (spec 0014). Rects are in the screen's visible frame space with a bottom-left
/// origin, as AppKit places windows.
public enum QuickAccessLayout {
    public static let cardWidth = 220.0
    public static let minCardHeight = 90.0
    public static let maxCardHeight = 220.0
    /// From the screen's edges.
    public static let margin = 16.0
    /// Between cards.
    public static let spacing = 12.0

    /// A card is `cardWidth` wide and as tall as the image's aspect ratio makes it, clamped so very
    /// tall or very wide screenshots don't make unusable cards (the image is fitted inside).
    public static func cardSize(pixelWidth: Int, pixelHeight: Int) -> Size {
        guard pixelWidth > 0, pixelHeight > 0 else { return Size(width: cardWidth, height: maxCardHeight) }
        let height = cardWidth * Double(pixelHeight) / Double(pixelWidth)
        return Size(width: cardWidth, height: min(max(height, minCardHeight), maxCardHeight))
    }

    /// The cards' frames, given their sizes oldest first: stacked up from the chosen bottom corner,
    /// the newest at the bottom.
    public static func frames(for sizes: [Size], in visible: Rect, side: QuickAccessSide) -> [Rect] {
        var y = visible.minY + margin
        var frames: [Rect] = []
        for size in sizes.reversed() {
            let x = side == .left ? visible.minX + margin : visible.maxX - margin - size.width
            frames.append(Rect(x: x, y: y, width: size.width, height: size.height))
            y += size.height + spacing
        }
        return frames.reversed()
    }

    /// How tall the stack may grow on a screen: its visible height less a margin top and bottom.
    public static func availableHeight(in visible: Rect) -> Double {
        visible.height - 2 * margin
    }

    /// Where every card of `stack` goes on a screen, and which cards must close because the stack
    /// no longer fits: the whole placement in one call.
    public struct Arrangement: Equatable, Sendable {
        public var frames: [UUID: Rect]
        public var closing: [UUID]
    }

    public static func arrange(_ stack: QuickAccessStack, in visible: Rect, side: QuickAccessSide) -> Arrangement {
        let sizes = stack.cards.map { cardSize(pixelWidth: $0.image.pixelWidth, pixelHeight: $0.image.pixelHeight) }
        let closing = stack.overflow(cardHeights: sizes.map(\.height), available: availableHeight(in: visible), spacing: spacing)
        let kept = zip(stack.cards, sizes).filter { !closing.contains($0.0.id) }
        let placed = frames(for: kept.map(\.1), in: visible, side: side)
        return Arrangement(
            frames: Dictionary(uniqueKeysWithValues: zip(kept.map(\.0.id), placed)),
            closing: closing
        )
    }
}

/// Which bottom corner the cards stack in.
public enum QuickAccessSide: String, Codable, CaseIterable, Sendable {
    case left
    case right
}

/// When a card nobody touches closes by itself.
public enum QuickAccessAutoClose: String, Codable, CaseIterable, Sendable {
    case never
    case after10s
    case after30s
    case after1min

    /// The Settings picker's label.
    public var title: String {
        switch self {
        case .never: return "Never"
        case .after10s: return "After 10 seconds"
        case .after30s: return "After 30 seconds"
        case .after1min: return "After 1 minute"
        }
    }

    /// `nil` for never.
    public var seconds: TimeInterval? {
        switch self {
        case .never: return nil
        case .after10s: return 10
        case .after30s: return 30
        case .after1min: return 60
        }
    }
}

/// The Quick Access section of Settings (spec 0014).
public struct QuickAccessSettings: Equatable, Codable, Sendable {
    public var side: QuickAccessSide
    public var autoClose: QuickAccessAutoClose
    /// Close a card once it has been dropped somewhere; ⌥ at the drop inverts this.
    public var closeAfterDragging: Bool

    public init(side: QuickAccessSide = .left, autoClose: QuickAccessAutoClose = .never, closeAfterDragging: Bool = true) {
        self.side = side
        self.autoClose = autoClose
        self.closeAfterDragging = closeAfterDragging
    }

    /// Fields missing from a stored blob take their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            side: try c.decodeIfPresent(QuickAccessSide.self, forKey: .side) ?? .left,
            autoClose: try c.decodeIfPresent(QuickAccessAutoClose.self, forKey: .autoClose) ?? .never,
            closeAfterDragging: try c.decodeIfPresent(Bool.self, forKey: .closeAfterDragging) ?? true
        )
    }
}
