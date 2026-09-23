import Foundation

/// What part of the source frame is on screen at a moment (spec 0007, stories 10–13).
public struct ZoomViewport: Equatable, Sendable {
    /// `1` shows the whole frame; `2` shows half of it on each axis.
    public let scale: Double
    /// The visible rect, normalised to the frame (top-left origin), always inside `0…1`.
    public let rect: Rect

    public static let identity = ZoomViewport(scale: 1, rect: Rect(x: 0, y: 0, width: 1, height: 1))

    /// A viewport of `scale` centred as close to `center` as the frame allows.
    public init(scale: Double, center: Point) {
        let side = 1 / max(scale, 1)
        let half = side / 2
        let x = min(max(center.x, half), 1 - half)
        let y = min(max(center.y, half), 1 - half)
        self.init(scale: max(scale, 1), rect: Rect(x: x - half, y: y - half, width: side, height: side))
    }

    private init(scale: Double, rect: Rect) {
        self.scale = scale
        self.rect = rect
    }
}

/// The zoom camera (spec 0007): eases into each zoom region over `transition`, holds, and eases
/// back out — or straight into the next zoom when the gap is shorter than a transition, so
/// back-to-back zooms pan instead of bouncing out and in. A follow-cursor zoom tracks a
/// dead-zoned, spring-smoothed camera path so small movements don't pan and big ones glide.
public struct ZoomCamera: Sendable {
    /// Share of the viewport the cursor may roam before a follow-cursor zoom pans.
    public static let deadZone = 0.6
    /// How quickly the follow camera catches up once it pans (per second).
    static let followRate = 6.0

    private let zooms: [ZoomRegion]
    private let transition: Double
    /// Per follow-cursor zoom: its camera centre at `start - transition + i / CursorPath.rate`.
    private let followPaths: [ZoomRegion.ID: [Point]]

    public init(zooms: [ZoomRegion], transition: Double, cursor: CursorPath?, regionSize: Size) {
        self.zooms = zooms.sorted { $0.start < $1.start }
        self.transition = max(transition, 0.01)
        var paths: [ZoomRegion.ID: [Point]] = [:]
        if let cursor, !cursor.isEmpty, regionSize.width > 0, regionSize.height > 0 {
            for zoom in self.zooms where zoom.focus == .followCursor {
                paths[zoom.id] = Self.followPath(zoom, transition: self.transition, cursor: cursor, regionSize: regionSize)
            }
        }
        followPaths = paths
    }

    /// The dead-zoned camera centre over a follow zoom's whole span (easing in and out included).
    private static func followPath(_ zoom: ZoomRegion, transition: Double, cursor: CursorPath, regionSize: Size) -> [Point] {
        let start = zoom.start - transition
        let count = Int(((zoom.end + transition - start) * CursorPath.rate).rounded(.up)) + 1
        let half = 0.5 / zoom.scale
        let box = half * deadZone
        let dt = 1 / CursorPath.rate
        let catchUp = 1 - exp(-followRate * dt)
        func normalized(_ t: Double) -> Point {
            let p = cursor.position(at: max(t, 0)) ?? Point(x: regionSize.width / 2, y: regionSize.height / 2)
            return Point(x: p.x / regionSize.width, y: p.y / regionSize.height)
        }
        func clamp(_ p: Point) -> Point {
            Point(x: min(max(p.x, half), 1 - half), y: min(max(p.y, half), 1 - half))
        }
        var camera = clamp(normalized(zoom.start))
        var path: [Point] = []
        path.reserveCapacity(count)
        for i in 0..<count {
            let c = normalized(start + Double(i) * dt)
            var target = camera
            if c.x > camera.x + box { target.x = c.x - box } else if c.x < camera.x - box { target.x = c.x + box }
            if c.y > camera.y + box { target.y = c.y - box } else if c.y < camera.y - box { target.y = c.y + box }
            target = clamp(target)
            camera = Point(x: camera.x + (target.x - camera.x) * catchUp, y: camera.y + (target.y - camera.y) * catchUp)
            path.append(camera)
        }
        return path
    }

    /// Ease-in-out cubic.
    static func ease(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private func focus(of zoom: ZoomRegion, at time: Double) -> Point {
        switch zoom.focus {
        case let .point(p):
            return p
        case .followCursor:
            guard let path = followPaths[zoom.id], !path.isEmpty else { return Point(x: 0.5, y: 0.5) }
            let i = Int(((time - (zoom.start - transition)) * CursorPath.rate).rounded())
            return path[min(max(i, 0), path.count - 1)]
        }
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private static func lerp(_ a: Point, _ b: Point, _ t: Double) -> Point { Point(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t)) }

    /// The viewport at a source time.
    public func viewport(at time: Double) -> ZoomViewport {
        guard let index = zooms.lastIndex(where: { $0.start <= time }) else { return .identity }
        let zoom = zooms[index]
        let center = Point(x: 0.5, y: 0.5)

        // Where the camera comes from: the previous zoom when it hands over directly.
        var fromScale = 1.0
        var fromFocus = center
        if index > 0 {
            let previous = zooms[index - 1]
            if zoom.start - previous.end < transition {
                fromScale = previous.scale
                fromFocus = focus(of: previous, at: time)
            }
        }
        let entering = Self.ease((time - zoom.start) / transition)
        var scale = Self.lerp(fromScale, zoom.scale, entering)
        var focus = Self.lerp(fromFocus, focus(of: zoom, at: time), entering)

        // Leaving: back to the whole frame, unless the next zoom takes over within a transition
        // (it then becomes `zoom` once its start passes, and hands over from here).
        let handsOver = index + 1 < zooms.count && zooms[index + 1].start - zoom.end < transition
        if time > zoom.end && !handsOver {
            let leaving = Self.ease((time - zoom.end) / transition)
            if leaving >= 1 { return .identity }
            scale = Self.lerp(scale, 1, leaving)
            focus = Self.lerp(focus, center, leaving)
        }
        return ZoomViewport(scale: scale, center: focus)
    }
}

/// Auto zoom (spec 0007, story 12): one follow-cursor zoom per cluster of clicks.
public enum AutoZoom {
    /// Clicks closer than this belong to one cluster.
    public static let clusterGap = 3.0
    /// The zoom starts this long before a cluster's first click…
    public static let leadIn = 0.8
    /// …and ends this long after its last.
    public static let tail = 1.5
    public static let scale = 2.0

    public static func suggest(clicks: [TimedPoint], duration: Double) -> [ZoomRegion] {
        let times = clicks.map(\.time).filter { $0 >= 0 && $0 <= duration }.sorted()
        guard let first = times.first else { return [] }
        var clusters: [(Double, Double)] = [(first, first)]
        for t in times.dropFirst() {
            if t - clusters[clusters.count - 1].1 < clusterGap {
                clusters[clusters.count - 1].1 = t
            } else {
                clusters.append((t, t))
            }
        }
        var spans: [(Double, Double)] = []
        for (a, b) in clusters {
            let span = (max(0, a - leadIn), min(duration, b + tail))
            if let last = spans.last, span.0 <= last.1 {
                spans[spans.count - 1].1 = max(last.1, span.1)
            } else {
                spans.append(span)
            }
        }
        return spans
            .filter { $0.1 - $0.0 >= ZoomRegion.minimumLength }
            .map { ZoomRegion(start: $0.0, end: $0.1, scale: scale, focus: .followCursor) }
    }
}
