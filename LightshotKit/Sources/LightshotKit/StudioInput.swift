import Foundation

/// A point at a time: a pointer sample or a click, in **region points** (top-left origin of the
/// recorded region) at **source seconds**.
public struct TimedPoint: Equatable, Codable, Sendable {
    public var time: Double
    public var point: Point

    public init(time: Double, point: Point) {
        self.time = time
        self.point = point
    }
}

/// A keyboard event at a source time, replayed through `KeystrokeOverlayModel` when rendering.
public struct TimedKeyEvent: Equatable, Codable, Sendable {
    public var time: Double
    public var event: KeyEvent

    public init(time: Double, event: KeyEvent) {
        self.time = time
        self.event = event
    }
}

/// A studio take's input data (spec 0007, story 1): what the pointer and keyboard did, recorded
/// beside the clean screen movie as `input.json` so the cursor, clicks and keys can be restyled
/// after the take.
public struct StudioInput: Equatable, Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// The recorded region's size in points — what the sample coordinates are relative to.
    public var regionSize: Size
    public var samples: [TimedPoint]
    public var clicks: [TimedPoint]
    public var keys: [TimedKeyEvent]
    /// The cursor is already drawn into the screen movie (an ordinary take): the editor then uses
    /// the pointer data only to steer zooms and never draws a second cursor. `false` for a studio
    /// take's clean screen.
    public var cursorInVideo: Bool

    public init(regionSize: Size, samples: [TimedPoint] = [], clicks: [TimedPoint] = [], keys: [TimedKeyEvent] = [], cursorInVideo: Bool = false) {
        version = Self.currentVersion
        self.regionSize = regionSize
        self.samples = samples
        self.clicks = clicks
        self.keys = keys
        self.cursorInVideo = cursorInVideo
    }

    private enum CodingKeys: String, CodingKey { case version, regionSize, samples, clicks, keys, cursorInVideo }

    /// `cursorInVideo` is newer than the format; older files are studio takes, so it defaults to `false`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        regionSize = try c.decode(Size.self, forKey: .regionSize)
        samples = try c.decode([TimedPoint].self, forKey: .samples)
        clicks = try c.decode([TimedPoint].self, forKey: .clicks)
        keys = try c.decode([TimedKeyEvent].self, forKey: .keys)
        cursorInVideo = try c.decodeIfPresent(Bool.self, forKey: .cursorInVideo) ?? false
    }
}
