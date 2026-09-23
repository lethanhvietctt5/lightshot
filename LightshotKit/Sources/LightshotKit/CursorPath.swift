import Foundation

/// The studio cursor's motion (spec 0007, stories 14–18): the recorded samples resampled at a
/// fixed rate and smoothed by a critically-damped spring, so any frame time has a position, a
/// velocity (for motion blur), an idle fade and the clicks in flight. Pure and deterministic:
/// the preview and the export ask the same questions and get the same answers.
public struct CursorPath: Sendable {
    public static let rate = 120.0
    /// How long a click's effect plays.
    public static let clickDuration = 0.5
    /// How long the idle fade takes once the delay has passed.
    public static let fadeDuration = 0.25
    /// Movement below this (points) between samples doesn't count as moving.
    static let stillThreshold = 0.5

    public struct Click: Equatable, Sendable {
        public let point: Point
        /// `0…1` through the click's effect.
        public let progress: Double
    }

    /// Smoothed positions at `i / rate` seconds.
    private let positions: [Point]
    /// For each resampled index, the source time the pointer last moved.
    private let lastMove: [Double]
    private let clickEvents: [TimedPoint]

    /// `smoothing` `0` follows the samples exactly; `1` is the heaviest glide.
    public init(samples: [TimedPoint], clicks: [TimedPoint], duration: Double, smoothing: Double) {
        clickEvents = clicks.sorted { $0.time < $1.time }
        let sorted = samples.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else {
            positions = []
            lastMove = []
            return
        }
        let count = max(1, Int((max(duration, sorted.last!.time) * Self.rate).rounded(.up)) + 1)
        var raw: [Point] = []
        var moved: [Double] = []
        raw.reserveCapacity(count)
        moved.reserveCapacity(count)
        var j = 0
        var lastMoveTime = sorted[0].time
        for i in 0..<count {
            let t = Double(i) / Self.rate
            while j + 1 < sorted.count && sorted[j + 1].time <= t {
                if Self.distance(sorted[j + 1].point, sorted[j].point) > Self.stillThreshold { lastMoveTime = sorted[j + 1].time }
                j += 1
            }
            if t <= sorted[0].time {
                raw.append(sorted[0].point)
            } else if j + 1 < sorted.count {
                let a = sorted[j], b = sorted[j + 1]
                let f = (t - a.time) / max(b.time - a.time, 1e-9)
                raw.append(Point(x: a.point.x + (b.point.x - a.point.x) * f, y: a.point.y + (b.point.y - a.point.y) * f))
                // Mid-segment of a real move counts as moving.
                if Self.distance(a.point, b.point) > Self.stillThreshold { lastMoveTime = t }
            } else {
                raw.append(sorted[j].point)
            }
            moved.append(lastMoveTime)
        }
        positions = Self.smooth(raw, smoothing: min(max(smoothing, 0), 1))
        lastMove = moved
    }

    private static func distance(_ a: Point, _ b: Point) -> Double { hypot(a.x - b.x, a.y - b.y) }

    /// A critically-damped spring chasing the raw path; its natural frequency falls as smoothing
    /// rises (40 rad/s ≈ no lag … 5 rad/s ≈ a slow glide).
    private static func smooth(_ raw: [Point], smoothing: Double) -> [Point] {
        guard smoothing > 0, let first = raw.first else { return raw }
        let omega = 40 - 35 * smoothing
        let substeps = 4
        let dt = 1 / rate / Double(substeps)
        var position = first
        var velocity = Point(x: 0, y: 0)
        var out: [Point] = []
        out.reserveCapacity(raw.count)
        for target in raw {
            for _ in 0..<substeps {
                let ax = omega * omega * (target.x - position.x) - 2 * omega * velocity.x
                let ay = omega * omega * (target.y - position.y) - 2 * omega * velocity.y
                velocity = Point(x: velocity.x + ax * dt, y: velocity.y + ay * dt)
                position = Point(x: position.x + velocity.x * dt, y: position.y + velocity.y * dt)
            }
            out.append(position)
        }
        return out
    }

    public var isEmpty: Bool { positions.isEmpty }

    /// The cursor at a source time (region points), or `nil` for a take with no pointer data.
    public func position(at time: Double) -> Point? {
        guard !positions.isEmpty else { return nil }
        let x = max(0, time) * Self.rate
        let i = min(Int(x), positions.count - 1)
        let j = min(i + 1, positions.count - 1)
        let f = min(max(x - Double(i), 0), 1)
        let a = positions[i], b = positions[j]
        return Point(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    /// Points per second at a source time.
    public func velocity(at time: Double) -> Point {
        guard positions.count > 1 else { return Point(x: 0, y: 0) }
        let h = 1 / Self.rate
        guard let a = position(at: time - h / 2), let b = position(at: time + h / 2) else { return Point(x: 0, y: 0) }
        return Point(x: (b.x - a.x) / h, y: (b.y - a.y) / h)
    }

    /// `1` while the cursor moves or has been still for less than `delay`; fades to `0` over
    /// `fadeDuration` after that (story 17).
    public func idleOpacity(at time: Double, delay: Double) -> Double {
        guard !lastMove.isEmpty else { return 1 }
        let i = min(max(Int((time * Self.rate).rounded(.down)), 0), lastMove.count - 1)
        let idle = time - lastMove[i]
        if idle <= delay { return 1 }
        return max(0, 1 - (idle - delay) / Self.fadeDuration)
    }

    /// The clicks whose effect is playing at a source time (story 16).
    public func clicks(at time: Double) -> [Click] {
        clickEvents.compactMap { click in
            let elapsed = time - click.time
            guard elapsed >= 0, elapsed < Self.clickDuration else { return nil }
            return Click(point: click.point, progress: elapsed / Self.clickDuration)
        }
    }
}
