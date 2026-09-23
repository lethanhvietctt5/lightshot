import Foundation

/// The Studio editor's document (spec 0007): `StudioEdits` changed only through commands, each
/// one undoable. The editor's primary seam, as `AnnotationDocument` is the screenshot editor's —
/// views call commands and render `edits`; they never mutate edits themselves.
///
/// Undo snapshots the whole `StudioEdits` (a few hundred bytes), which keeps every command trivially
/// reversible. A command that changes nothing leaves no undo step. Continuous controls (sliders,
/// pill drags) bracket their changes with `beginChange()` / `endChange()` so one gesture is one step.
public struct StudioDocument: Equatable, Sendable {
    public static let undoLimit = 200

    public private(set) var edits: StudioEdits
    private var past: [StudioEdits] = []
    private var future: [StudioEdits] = []
    /// The edits when a gesture began; while set, commands don't push undo steps.
    private var gestureStart: StudioEdits?

    public init(edits: StudioEdits) {
        self.edits = edits.normalized()
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public var timeline: StudioTimeline { StudioTimeline(clips: edits.clips) }

    // MARK: - Undo

    public mutating func undo() {
        endChange()
        guard let previous = past.popLast() else { return }
        future.append(edits)
        edits = previous
    }

    public mutating func redo() {
        endChange()
        guard let next = future.popLast() else { return }
        past.append(edits)
        edits = next
    }

    /// Start a gesture: the changes until `endChange()` become one undo step.
    public mutating func beginChange() {
        if gestureStart == nil { gestureStart = edits }
    }

    public mutating func endChange() {
        guard let start = gestureStart else { return }
        gestureStart = nil
        if start != edits { record(start) }
    }

    private mutating func record(_ previous: StudioEdits) {
        past.append(previous)
        if past.count > Self.undoLimit { past.removeFirst(past.count - Self.undoLimit) }
        future.removeAll()
    }

    /// Apply `change` to a copy, normalise, and keep it (with an undo step) only if it differs.
    private mutating func perform(_ change: (inout StudioEdits) -> Void) {
        var next = edits
        change(&next)
        next = next.normalized()
        guard next != edits else { return }
        if gestureStart == nil { record(edits) }
        edits = next
    }

    // MARK: - Look settings

    /// Set any setting (background, canvas, cursor, camera, keystrokes, audio, output, zoom
    /// transition / blur); the value is clamped to its range.
    public mutating func set<Value>(_ keyPath: WritableKeyPath<StudioEdits, Value>, _ value: Value) {
        perform { $0[keyPath: keyPath] = value }
    }

    // MARK: - Clips (stories 6–8)

    /// Split the clip under an output time in two; returns the second clip's id, or `nil` when
    /// the time is within `StudioClip.minimumLength` of the clip's edges.
    @discardableResult
    public mutating func split(atOutput outputTime: Double) -> StudioClip.ID? {
        guard let segment = timeline.segment(atOutput: outputTime),
              let index = edits.clips.firstIndex(where: { $0.id == segment.clipID }) else { return nil }
        let clip = edits.clips[index]
        let at = timeline.sourceTime(atOutput: outputTime)
        guard at - clip.start >= StudioClip.minimumLength, clip.end - at >= StudioClip.minimumLength else { return nil }
        let second = StudioClip(start: at, end: clip.end, speed: clip.speed)
        perform {
            $0.clips[index].end = at
            $0.clips.insert(second, at: index + 1)
        }
        return second.id
    }

    /// Cut a clip out; the last remaining clip stays.
    public mutating func deleteClip(_ id: StudioClip.ID) {
        guard edits.clips.count > 1 else { return }
        perform { $0.clips.removeAll { $0.id == id } }
    }

    /// Move a clip's edges, never past its neighbours or the source, never below the minimum length.
    public mutating func trimClip(_ id: StudioClip.ID, start: Double, end: Double) {
        guard let index = edits.clips.firstIndex(where: { $0.id == id }) else { return }
        let lower = index > 0 ? edits.clips[index - 1].end : 0
        let upper = index + 1 < edits.clips.count ? edits.clips[index + 1].start : edits.sourceDuration
        let clip = edits.clips[index]
        var newStart = min(max(start, lower), upper - StudioClip.minimumLength)
        var newEnd = max(min(end, upper), lower + StudioClip.minimumLength)
        // A one-sided drag keeps the other edge fixed; respect the minimum against it.
        if newStart != clip.start && newEnd == clip.end { newStart = min(newStart, newEnd - StudioClip.minimumLength) }
        if newEnd != clip.end && newStart == clip.start { newEnd = max(newEnd, newStart + StudioClip.minimumLength) }
        if newEnd - newStart < StudioClip.minimumLength { newEnd = newStart + StudioClip.minimumLength }
        perform {
            $0.clips[index].start = newStart
            $0.clips[index].end = min(newEnd, upper)
        }
    }

    public mutating func setSpeed(_ id: StudioClip.ID, _ speed: Double) {
        perform { edits in
            if let index = edits.clips.firstIndex(where: { $0.id == id }) { edits.clips[index].speed = speed }
        }
    }

    // MARK: - Zooms (stories 10–13)

    /// Add a zoom starting at a source time, in the free gap there; returns its id, or `nil` when
    /// no gap of `ZoomRegion.minimumLength` is free at or after that time.
    @discardableResult
    public mutating func addZoom(atSource time: Double, length: Double = ZoomRegion.defaultLength) -> ZoomRegion.ID? {
        guard let slot = freeSlot(from: time, length: length) else { return nil }
        let zoom = ZoomRegion(start: slot.lowerBound, end: slot.upperBound)
        perform { $0.zooms.append(zoom) }
        return zoom.id
    }

    /// The first span of up to `length` seconds that overlaps no zoom, starting as close to `time`
    /// as possible (pulled back from the source's end when needed).
    private func freeSlot(from time: Double, length: Double) -> ClosedRange<Double>? {
        let duration = edits.sourceDuration
        let wanted = min(length, duration)
        var gaps: [ClosedRange<Double>] = []
        var cursor = 0.0
        for zoom in edits.zooms.sorted(by: { $0.start < $1.start }) {
            if zoom.start > cursor { gaps.append(cursor...zoom.start) }
            cursor = max(cursor, zoom.end)
        }
        if cursor < duration { gaps.append(cursor...duration) }
        for gap in gaps where gap.upperBound > time || gap == gaps.last {
            let size = gap.upperBound - gap.lowerBound
            guard size >= ZoomRegion.minimumLength else { continue }
            let span = min(wanted, size)
            let start = min(max(time, gap.lowerBound), gap.upperBound - span)
            return start...(start + span)
        }
        return nil
    }

    /// The span a zoom may occupy: between its neighbours and inside the source.
    private func bounds(ofZoom id: ZoomRegion.ID) -> ClosedRange<Double>? {
        let sorted = edits.zooms.sorted { $0.start < $1.start }
        guard let index = sorted.firstIndex(where: { $0.id == id }) else { return nil }
        let lower = index > 0 ? sorted[index - 1].end : 0
        let upper = index + 1 < sorted.count ? sorted[index + 1].start : edits.sourceDuration
        return lower...upper
    }

    /// Drag a pill: keeps its length, stops at its neighbours.
    public mutating func moveZoom(_ id: ZoomRegion.ID, toStart start: Double) {
        guard let zoom = edits.zooms.first(where: { $0.id == id }), let limit = bounds(ofZoom: id) else { return }
        let newStart = min(max(start, limit.lowerBound), limit.upperBound - zoom.length)
        updateZoom(id) { $0.start = newStart; $0.end = newStart + zoom.length }
    }

    /// Drag a pill's edge(s): stops at its neighbours, never below the minimum length.
    public mutating func resizeZoom(_ id: ZoomRegion.ID, start: Double, end: Double) {
        guard let zoom = edits.zooms.first(where: { $0.id == id }), let limit = bounds(ofZoom: id) else { return }
        var newStart = min(max(start, limit.lowerBound), limit.upperBound - ZoomRegion.minimumLength)
        var newEnd = max(min(end, limit.upperBound), limit.lowerBound + ZoomRegion.minimumLength)
        if newEnd - newStart < ZoomRegion.minimumLength {
            if newStart != zoom.start { newStart = newEnd - ZoomRegion.minimumLength } else { newEnd = newStart + ZoomRegion.minimumLength }
        }
        updateZoom(id) { $0.start = newStart; $0.end = newEnd }
    }

    public mutating func setZoomScale(_ id: ZoomRegion.ID, _ scale: Double) {
        updateZoom(id) { $0.scale = scale }
    }

    public mutating func setZoomFocus(_ id: ZoomRegion.ID, _ focus: ZoomFocus) {
        updateZoom(id) { $0.focus = focus }
    }

    public mutating func removeZoom(_ id: ZoomRegion.ID) {
        perform { $0.zooms.removeAll { $0.id == id } }
    }

    /// Add auto-zoom suggestions (story 12) where they don't overlap an existing zoom; returns the
    /// ids added.
    @discardableResult
    public mutating func autoZoom(clicks: [TimedPoint]) -> [ZoomRegion.ID] {
        let existing = edits.zooms
        let added = AutoZoom.suggest(clicks: clicks, duration: edits.sourceDuration).filter { suggestion in
            !existing.contains { $0.start < suggestion.end && suggestion.start < $0.end }
        }
        guard !added.isEmpty else { return [] }
        perform { $0.zooms += added }
        return added.map(\.id)
    }

    // MARK: - Transcript editing (round 2, stories 30–31)

    /// Remove a source range from the output: a clip it falls inside is split, clips it overlaps
    /// are trimmed, clips it covers go. Refused when nothing would be left.
    public mutating func cut(sourceRange range: ClosedRange<Double>) {
        cut(sourceRanges: [range])
    }

    /// Cut the span of a run of words (story 30): from the first word's start to the last's end.
    public mutating func cut(words: [TranscriptWord]) {
        guard let start = words.map(\.start).min(), let end = words.map(\.end).max(), end > start else { return }
        cut(sourceRange: start...end)
    }

    /// Cut every pause longer than `minimumGap` (story 31) — before the first word, between words,
    /// after the last — keeping `padding` of it next to the speech. One undo step; returns how many
    /// pauses were cut.
    @discardableResult
    public mutating func removeSilences(words: [TranscriptWord], minimumGap: Double = 1, padding: Double = 0.15) -> Int {
        let sorted = words.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return 0 }
        var ranges: [ClosedRange<Double>] = []
        if sorted[0].start >= minimumGap { ranges.append(0...(sorted[0].start - padding)) }
        var speechEnd = sorted[0].end
        for word in sorted.dropFirst() {
            if word.start - speechEnd >= minimumGap { ranges.append((speechEnd + padding)...(word.start - padding)) }
            speechEnd = max(speechEnd, word.end)
        }
        if edits.sourceDuration - speechEnd >= minimumGap { ranges.append((speechEnd + padding)...edits.sourceDuration) }
        let before = edits
        cut(sourceRanges: ranges)
        return edits == before ? 0 : ranges.count
    }

    private mutating func cut(sourceRanges ranges: [ClosedRange<Double>]) {
        var clips = edits.clips
        for range in ranges where range.upperBound > range.lowerBound {
            var next: [StudioClip] = []
            for clip in clips {
                if range.upperBound <= clip.start || range.lowerBound >= clip.end {
                    next.append(clip)                                            // untouched
                } else if range.lowerBound > clip.start && range.upperBound < clip.end {
                    var left = clip, right = StudioClip(start: range.upperBound, end: clip.end, speed: clip.speed)
                    left.end = range.lowerBound
                    next += [left, right]                                        // split around it
                } else if range.lowerBound > clip.start {
                    var left = clip; left.end = range.lowerBound; next.append(left)
                } else if range.upperBound < clip.end {
                    var right = clip; right.start = range.upperBound; next.append(right)
                }                                                                // else covered: dropped
            }
            clips = next.filter { $0.sourceLength >= StudioClip.minimumLength }
        }
        guard !clips.isEmpty else { return }
        perform { $0.clips = clips }
    }

    /// Correct a caption's text (story 30).
    public mutating func editCaption(_ id: CaptionLine.ID, text: String) {
        perform { edits in
            if let index = edits.captions.lines.firstIndex(where: { $0.id == id }) { edits.captions.lines[index].text = text }
        }
    }

    private mutating func updateZoom(_ id: ZoomRegion.ID, _ change: @escaping (inout ZoomRegion) -> Void) {
        perform { edits in
            if let index = edits.zooms.firstIndex(where: { $0.id == id }) { change(&edits.zooms[index]) }
        }
    }
}
