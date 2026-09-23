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
        // Trimming everything away is refused: something must always play.
        guard next != edits, next.clips.reduce(0, { $0 + $1.sourceLength }) >= StudioClip.minimumLength - 1e-9 else { return }
        if gestureStart == nil { record(edits) }
        edits = next
    }

    // MARK: - Look settings

    /// Set any setting (background, canvas, cursor, camera, keystrokes, audio, output, zoom
    /// transition / blur); the value is clamped to its range.
    public mutating func set<Value>(_ keyPath: WritableKeyPath<StudioEdits, Value>, _ value: Value) {
        perform { $0[keyPath: keyPath] = value }
    }

    // MARK: - Region lanes (zooms, trims, speeds)

    /// Add a region starting at a source time, in the free gap there; `nil` when no gap of the
    /// lane's minimum length is free at or after that time, or the change was refused.
    private mutating func addRegion<R: TimelineRegion>(
        _ lane: WritableKeyPath<StudioEdits, [R]>, atSource time: Double, length: Double, make: (Double, Double) -> R
    ) -> UUID? {
        guard let slot = freeSlot(in: lane, from: time, length: length) else { return nil }
        let region = make(slot.lowerBound, slot.upperBound)
        perform { $0[keyPath: lane].append(region) }
        return edits[keyPath: lane].contains { $0.id == region.id } ? region.id : nil
    }

    /// The first span of up to `length` seconds that overlaps no region of the lane, starting as
    /// close to `time` as possible (pulled back from the source's end when needed).
    private func freeSlot<R: TimelineRegion>(in lane: KeyPath<StudioEdits, [R]>, from time: Double, length: Double) -> ClosedRange<Double>? {
        let duration = edits.sourceDuration
        let wanted = min(length, duration)
        var gaps: [ClosedRange<Double>] = []
        var cursor = 0.0
        for region in edits[keyPath: lane].sorted(by: { $0.start < $1.start }) {
            if region.start > cursor { gaps.append(cursor...region.start) }
            cursor = max(cursor, region.end)
        }
        if cursor < duration { gaps.append(cursor...duration) }
        for gap in gaps where gap.upperBound > time || gap == gaps.last {
            let size = gap.upperBound - gap.lowerBound
            guard size >= R.minimumLength else { continue }
            let span = min(wanted, size)
            let start = min(max(time, gap.lowerBound), gap.upperBound - span)
            return start...(start + span)
        }
        return nil
    }

    /// The span a region may occupy: between its neighbours and inside the source.
    private func bounds<R: TimelineRegion>(of id: UUID, in lane: KeyPath<StudioEdits, [R]>) -> ClosedRange<Double>? {
        let sorted = edits[keyPath: lane].sorted { $0.start < $1.start }
        guard let index = sorted.firstIndex(where: { $0.id == id }) else { return nil }
        let lower = index > 0 ? sorted[index - 1].end : 0
        let upper = index + 1 < sorted.count ? sorted[index + 1].start : edits.sourceDuration
        return lower...upper
    }

    /// Drag a pill: keeps its length, stops at its neighbours.
    private mutating func moveRegion<R: TimelineRegion>(_ lane: WritableKeyPath<StudioEdits, [R]>, _ id: UUID, toStart start: Double) {
        guard let region = edits[keyPath: lane].first(where: { $0.id == id }), let limit = bounds(of: id, in: lane) else { return }
        let length = region.end - region.start
        let newStart = min(max(start, limit.lowerBound), limit.upperBound - length)
        updateRegion(lane, id) { $0.start = newStart; $0.end = newStart + length }
    }

    /// Drag a pill's edge(s): stops at its neighbours, never below the lane's minimum length.
    private mutating func resizeRegion<R: TimelineRegion>(_ lane: WritableKeyPath<StudioEdits, [R]>, _ id: UUID, start: Double, end: Double) {
        guard let region = edits[keyPath: lane].first(where: { $0.id == id }), let limit = bounds(of: id, in: lane) else { return }
        var newStart = min(max(start, limit.lowerBound), limit.upperBound - R.minimumLength)
        var newEnd = max(min(end, limit.upperBound), limit.lowerBound + R.minimumLength)
        if newEnd - newStart < R.minimumLength {
            if newStart != region.start { newStart = newEnd - R.minimumLength } else { newEnd = newStart + R.minimumLength }
        }
        updateRegion(lane, id) { $0.start = newStart; $0.end = newEnd }
    }

    private mutating func updateRegion<R: TimelineRegion>(_ lane: WritableKeyPath<StudioEdits, [R]>, _ id: UUID, _ change: (inout R) -> Void) {
        perform { edits in
            if let index = edits[keyPath: lane].firstIndex(where: { $0.id == id }) { change(&edits[keyPath: lane][index]) }
        }
    }

    private mutating func removeRegion<R: TimelineRegion>(_ lane: WritableKeyPath<StudioEdits, [R]>, _ id: UUID) {
        perform { $0[keyPath: lane].removeAll { $0.id == id } }
    }

    // MARK: - Trims (round 3, story 34)

    /// Skip a span starting at a source time; `nil` when there is no room or nothing would be left.
    @discardableResult
    public mutating func addTrim(atSource time: Double, length: Double = TrimRegion.defaultLength) -> TrimRegion.ID? {
        addRegion(\.trims, atSource: time, length: length) { TrimRegion(start: $0, end: $1) }
    }

    public mutating func moveTrim(_ id: TrimRegion.ID, toStart start: Double) { moveRegion(\.trims, id, toStart: start) }
    public mutating func resizeTrim(_ id: TrimRegion.ID, start: Double, end: Double) { resizeRegion(\.trims, id, start: start, end: end) }
    public mutating func removeTrim(_ id: TrimRegion.ID) { removeRegion(\.trims, id) }

    // MARK: - Speed (round 3, story 35)

    /// Play a span starting at a source time at `speed`; `nil` when there is no room.
    @discardableResult
    public mutating func addSpeed(atSource time: Double, length: Double = SpeedRegion.defaultLength, speed: Double) -> SpeedRegion.ID? {
        addRegion(\.speeds, atSource: time, length: length) { SpeedRegion(start: $0, end: $1, speed: speed) }
    }

    public mutating func moveSpeed(_ id: SpeedRegion.ID, toStart start: Double) { moveRegion(\.speeds, id, toStart: start) }
    public mutating func resizeSpeed(_ id: SpeedRegion.ID, start: Double, end: Double) { resizeRegion(\.speeds, id, start: start, end: end) }
    public mutating func setSpeed(_ id: SpeedRegion.ID, _ speed: Double) { updateRegion(\.speeds, id) { $0.speed = speed } }
    public mutating func removeSpeed(_ id: SpeedRegion.ID) { removeRegion(\.speeds, id) }

    // MARK: - Zooms (stories 10–13)

    /// Add a zoom starting at a source time, in the free gap there; returns its id, or `nil` when
    /// no gap of `ZoomRegion.minimumLength` is free at or after that time.
    @discardableResult
    public mutating func addZoom(atSource time: Double, length: Double = ZoomRegion.defaultLength) -> ZoomRegion.ID? {
        addRegion(\.zooms, atSource: time, length: length) { ZoomRegion(start: $0, end: $1) }
    }

    public mutating func moveZoom(_ id: ZoomRegion.ID, toStart start: Double) { moveRegion(\.zooms, id, toStart: start) }
    public mutating func resizeZoom(_ id: ZoomRegion.ID, start: Double, end: Double) { resizeRegion(\.zooms, id, start: start, end: end) }

    public mutating func setZoomScale(_ id: ZoomRegion.ID, _ scale: Double) {
        updateRegion(\.zooms, id) { $0.scale = scale }
    }

    public mutating func setZoomFocus(_ id: ZoomRegion.ID, _ focus: ZoomFocus) {
        updateRegion(\.zooms, id) { $0.focus = focus }
    }

    public mutating func removeZoom(_ id: ZoomRegion.ID) { removeRegion(\.zooms, id) }

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

    // MARK: - Text annotations (round 2, story 32)

    /// Add a text annotation at a source time, pulled inside the source; returns its id.
    @discardableResult
    public mutating func addAnnotation(atSource time: Double) -> TextAnnotation.ID {
        let length = min(TextAnnotation.defaultLength, edits.sourceDuration)
        let start = min(max(time, 0), edits.sourceDuration - length)
        let annotation = TextAnnotation(start: start, end: start + length)
        perform { $0.annotations.append(annotation) }
        return annotation.id
    }

    /// Drag a pill: keeps its length, stays inside the source.
    public mutating func moveAnnotation(_ id: TextAnnotation.ID, toStart start: Double) {
        guard let a = edits.annotations.first(where: { $0.id == id }) else { return }
        let length = a.end - a.start
        let newStart = min(max(start, 0), edits.sourceDuration - length)
        updateAnnotation(id) { $0.start = newStart; $0.end = newStart + length }
    }

    /// Drag a pill's edge(s), never below the minimum length.
    public mutating func resizeAnnotation(_ id: TextAnnotation.ID, start: Double, end: Double) {
        guard let a = edits.annotations.first(where: { $0.id == id }) else { return }
        var newStart = max(0, start), newEnd = min(edits.sourceDuration, end)
        if newEnd - newStart < TextAnnotation.minimumLength {
            if newStart != a.start { newStart = newEnd - TextAnnotation.minimumLength } else { newEnd = newStart + TextAnnotation.minimumLength }
        }
        updateAnnotation(id) { $0.start = newStart; $0.end = newEnd }
    }

    /// Change an annotation's text, place or look; clamped like every edit.
    public mutating func updateAnnotation(_ id: TextAnnotation.ID, _ change: (inout TextAnnotation) -> Void) {
        perform { edits in
            if let index = edits.annotations.firstIndex(where: { $0.id == id }) { change(&edits.annotations[index]) }
        }
    }

    public mutating func removeAnnotation(_ id: TextAnnotation.ID) {
        perform { $0.annotations.removeAll { $0.id == id } }
    }

    // MARK: - Transcript editing (round 2, stories 30–31)

    /// Remove a source range from the output by trimming it (merged with the trims it touches).
    /// Refused when nothing would be left.
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

    /// Merge the ranges into the trims: overlapping or nearly touching spans (closer than a clip's
    /// minimum length, so no sliver is left playing) become one trim.
    private mutating func cut(sourceRanges ranges: [ClosedRange<Double>]) {
        let spans = (edits.trims.map { $0.start...$0.end } + ranges.filter { $0.upperBound > $0.lowerBound })
            .map { max(0, $0.lowerBound)...min(edits.sourceDuration, $0.upperBound) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for span in spans {
            if let last = merged.last, span.lowerBound - last.upperBound < StudioClip.minimumLength {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        let trims = merged.map { span in
            edits.trims.first { $0.start == span.lowerBound && $0.end == span.upperBound } ?? TrimRegion(start: span.lowerBound, end: span.upperBound)
        }
        perform { $0.trims = trims }
    }

    /// Correct a caption's text (story 30).
    public mutating func editCaption(_ id: CaptionLine.ID, text: String) {
        perform { edits in
            if let index = edits.captions.lines.firstIndex(where: { $0.id == id }) { edits.captions.lines[index].text = text }
        }
    }
}
