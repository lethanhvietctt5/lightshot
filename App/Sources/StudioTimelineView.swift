import AppKit
import SwiftUI
import LightshotKit

/// The Studio timeline (spec 0007, stories 5–13), in **output time**: a header of edit commands,
/// the ruler, the clip track (filmstrip per clip, trim handles and speed on the selected clip) and
/// the zoom track (pills), with the playhead across both. Scrolls sideways when zoomed in.
struct StudioTimelineView: View {
    @Bindable var model: StudioEditorModel
    static let inset: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            StudioTimelineHeader(model: model)
                .padding(.horizontal, 16)
                .frame(height: 40)
            GeometryReader { geometry in
                let width = max(1, (geometry.size.width - Self.inset * 2) * model.timelineZoom)
                ScrollView(.horizontal) {
                    StudioTracks(model: model, scale: TimelineScale(duration: max(model.duration, 0.01), width: width))
                        .frame(width: width, height: geometry.size.height)
                        .padding(.horizontal, Self.inset)
                }
                .scrollIndicators(model.timelineZoom > 1 ? .automatic : .never)
            }
        }
        .disabled(model.sources == nil)
    }
}

/// Split, delete, speed, add zoom, auto zoom, undo / redo.
private struct StudioTimelineHeader: View {
    @Bindable var model: StudioEditorModel
    private static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    var body: some View {
        HStack(spacing: 6) {
            tool("scissors", "Split at Playhead (S)") { model.splitAtPlayhead() }
            tool("trash", "Delete Selection (⌫)") { model.deleteSelection() }
                .disabled(model.selection == nil)
            Menu {
                ForEach(Self.speeds, id: \.self) { speed in
                    Button(speedLabel(speed)) { if let clip = model.selectedClip { model.setSpeed(clip.id, speed) } }
                }
            } label: {
                Label(model.selectedClip.map { speedLabel($0.speed) } ?? "Speed", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.selectedClip == nil)
            .help("Playback speed of the selected clip")
            Divider().frame(height: 18).padding(.horizontal, 6)
            tool("plus.magnifyingglass", "Add Zoom at Playhead") { model.addZoom() }
            tool("wand.and.stars", "Auto Zoom on Clicks") { model.autoZoom() }
                .disabled(!model.hasClicks)
            Spacer()
            tool("arrow.uturn.backward", "Undo (⌘Z)") { model.undo() }.disabled(!model.canUndo)
            tool("arrow.uturn.forward", "Redo (⇧⌘Z)") { model.redo() }.disabled(!model.canRedo)
        }
    }

    private func tool(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct StudioTracks: View {
    @Bindable var model: StudioEditorModel
    let scale: TimelineScale

    static let rulerHeight: CGFloat = 28
    static let clipTop: CGFloat = 34
    static let clipHeight: CGFloat = 60
    static let zoomTop: CGFloat = 104
    static let zoomHeight: CGFloat = 30

    var body: some View {
        ZStack(alignment: .topLeading) {
            ruler
            // Seek anywhere on the ruler / empty track.
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    model.selection = nil
                    model.seek(to: scale.time(at: value.location.x))
                })
            ForEach(model.timeline.segments, id: \.clipID) { segment in
                StudioClipView(model: model, segment: segment, scale: scale)
                    .offset(x: scale.x(for: segment.outputStart), y: Self.clipTop)
            }
            // The zoom lane.
            RoundedRectangle(cornerRadius: 6).fill(StudioStyle.control.opacity(0.5))
                .frame(width: scale.width, height: Self.zoomHeight)
                .offset(y: Self.zoomTop)
                .allowsHitTesting(false)
            if model.edits.zooms.isEmpty {
                Text("Zooms appear here — add one at the playhead, or Auto Zoom on clicks")
                    .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    .frame(width: scale.width, height: Self.zoomHeight)
                    .offset(y: Self.zoomTop)
                    .allowsHitTesting(false)
            }
            ForEach(model.edits.zooms) { zoom in
                if let span = outputSpan(of: zoom) {
                    StudioZoomPill(model: model, zoom: zoom, span: span, scale: scale)
                        .offset(x: scale.x(for: span.lowerBound), y: Self.zoomTop)
                }
            }
            playhead
                .offset(x: scale.x(for: model.currentTime) - 6, y: Self.rulerHeight - 6)
                .allowsHitTesting(false)
        }
        .frame(width: scale.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: "tracks")
    }

    /// Where a zoom shows on the output timeline: its source span through the cuts, clamped to
    /// the kept parts; `nil` when it was cut away entirely.
    private func outputSpan(of zoom: ZoomRegion) -> ClosedRange<Double>? {
        let timeline = model.timeline
        let start = timeline.outputTime(atSource: zoom.start)
            ?? timeline.segments.first(where: { $0.sourceStart >= zoom.start && $0.sourceStart < zoom.end })?.outputStart
        let end = timeline.outputTime(atSource: zoom.end)
            ?? timeline.segments.last(where: { $0.sourceEnd <= zoom.end && $0.sourceEnd > zoom.start })?.outputEnd
        guard let start, let end, end > start else { return nil }
        return start...end
    }

    private static let rulerOverhang: CGFloat = 40

    private var ruler: some View {
        Canvas { context, size in
            for tick in scale.ticks() {
                let x = scale.x(for: tick) + Self.rulerOverhang
                context.draw(
                    Text(TimelineScale.label(tick)).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Color.white.opacity(0.75)),
                    at: CGPoint(x: x, y: 12)
                )
                var line = Path()
                line.move(to: CGPoint(x: x, y: Self.rulerHeight))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(StudioStyle.divider), lineWidth: 1)
            }
        }
        .frame(width: scale.width + Self.rulerOverhang * 2)
        .frame(maxHeight: .infinity)
        .offset(x: -Self.rulerOverhang)
        .allowsHitTesting(false)
    }

    private var playhead: some View {
        VStack(spacing: 0) {
            Circle().fill(StudioStyle.playhead).frame(width: 12, height: 12)
            Rectangle().fill(StudioStyle.playhead).frame(width: 2, height: Self.zoomTop + Self.zoomHeight - Self.rulerHeight + 6)
        }
        .frame(width: 12)
    }
}

/// One clip: its filmstrip, a speed badge, and — when selected — a yellow frame with trim handles.
private struct StudioClipView: View {
    @Bindable var model: StudioEditorModel
    let segment: StudioTimeline.Segment
    let scale: TimelineScale
    @State private var dragOrigin: StudioClip?
    private static let handleWidth: CGFloat = 10

    private var isSelected: Bool { model.selection == .clip(segment.clipID) }
    private var width: CGFloat { max(2, scale.x(for: segment.outputEnd) - scale.x(for: segment.outputStart) - 2) }
    private var pointsPerSecond: CGFloat { scale.width / max(model.duration, 0.01) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            filmstrip
                .frame(width: width, height: StudioTracks.clipHeight)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isSelected ? StudioStyle.selection : Color.white.opacity(0.15), lineWidth: isSelected ? 3 : 1))
            if segment.speed != 1 {
                Text(speedLabel(segment.speed))
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .padding(6)
            }
            if isSelected, width > Self.handleWidth * 3 {
                handle(leading: true)
                handle(leading: false).offset(x: width - Self.handleWidth)
            }
        }
        .frame(width: width, height: StudioTracks.clipHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = .clip(segment.clipID)
        }
        .contextMenu {
            Button("Split at Playhead") { model.splitAtPlayhead() }
            Menu("Speed") {
                ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4], id: \.self) { speed in
                    Button(speedLabel(speed)) { model.setSpeed(segment.clipID, speed) }
                }
            }
            Button("Delete Clip") { model.selection = .clip(segment.clipID); model.deleteSelection() }
        }
    }

    private var filmstrip: some View {
        let aspect = model.sources.map { $0.pixelSize.width / max($0.pixelSize.height, 1) } ?? 16 / 9
        let slots = max(1, Int((width / (StudioTracks.clipHeight * aspect)).rounded(.up)))
        let slotWidth = width / CGFloat(slots)
        return HStack(spacing: 0) {
            ForEach(0..<slots, id: \.self) { i in
                let time = segment.sourceStart + (Double(i) + 0.5) / Double(slots) * (segment.sourceEnd - segment.sourceStart)
                if let image = model.thumbnail(atSource: time) {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: slotWidth, height: StudioTracks.clipHeight).clipped()
                } else {
                    StudioStyle.clip.frame(width: slotWidth, height: StudioTracks.clipHeight)
                }
            }
        }
    }

    /// A trim handle: drags that edge in source time (story 7), one undo step per drag.
    private func handle(leading: Bool) -> some View {
        Image(systemName: leading ? "chevron.compact.left" : "chevron.compact.right")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(Color.black.opacity(0.7))
            .frame(width: Self.handleWidth, height: StudioTracks.clipHeight)
            .background(RoundedRectangle(cornerRadius: 4).fill(StudioStyle.selection))
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("tracks"))
                    .onChanged { value in
                        if dragOrigin == nil {
                            dragOrigin = model.edits.clips.first { $0.id == segment.clipID }
                            model.beginChange()
                        }
                        guard let origin = dragOrigin else { return }
                        let delta = Double(value.translation.width / pointsPerSecond) * origin.speed
                        if leading {
                            model.trimClip(origin.id, start: origin.start + delta, end: origin.end)
                        } else {
                            model.trimClip(origin.id, start: origin.start, end: origin.end + delta)
                        }
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                        model.endChange()
                    }
            )
    }
}

/// `2×`, `0.5×`.
private func speedLabel(_ speed: Double) -> String {
    speed == speed.rounded() ? "\(Int(speed))×" : "\(speed)×"
}

/// A zoom pill (story 10): select, drag to move, drag an edge to resize — in source time.
private struct StudioZoomPill: View {
    @Bindable var model: StudioEditorModel
    let zoom: ZoomRegion
    let span: ClosedRange<Double>
    let scale: TimelineScale
    @State private var dragOrigin: (zoom: ZoomRegion, outputStart: Double, outputEnd: Double)?
    private static let edge: CGFloat = 8

    private var isSelected: Bool { model.selection == .zoom(zoom.id) }
    private var width: CGFloat { max(14, scale.x(for: span.upperBound) - scale.x(for: span.lowerBound)) }
    private var pointsPerSecond: CGFloat { scale.width / max(model.duration, 0.01) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(StudioStyle.zoom.opacity(isSelected ? 1 : 0.75))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Color.white : .clear, lineWidth: 2))
            HStack(spacing: 4) {
                Image(systemName: zoom.focus == .followCursor ? "cursorarrow.motionlines" : "scope")
                Text(String(format: "%.1f×", zoom.scale)).monospacedDigit()
            }
            .font(.system(size: 11, weight: .semibold))
            .opacity(width > 60 ? 1 : 0)
            HStack {
                edgeHandle(leading: true)
                Spacer(minLength: 0)
                edgeHandle(leading: false)
            }
        }
        .frame(width: width, height: StudioTracks.zoomHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = .zoom(zoom.id)
            model.panel = .zoom
        }
        .gesture(drag(.move))
        .contextMenu {
            Button("Delete Zoom") { model.selection = .zoom(zoom.id); model.deleteSelection() }
        }
    }

    private enum DragKind { case move, leading, trailing }

    private func edgeHandle(leading: Bool) -> some View {
        Color.white.opacity(isSelected ? 0.35 : 0.001)
            .frame(width: Self.edge)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(drag(leading ? .leading : .trailing))
    }

    private func drag(_ kind: DragKind) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("tracks"))
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = (zoom, span.lowerBound, span.upperBound)
                    model.selection = .zoom(zoom.id)
                    model.beginChange()
                }
                guard let origin = dragOrigin else { return }
                let dt = Double(value.translation.width / pointsPerSecond)
                let timeline = model.timeline
                switch kind {
                case .move:
                    let newStart = timeline.sourceTime(atOutput: origin.outputStart + dt)
                    model.moveZoom(origin.zoom.id, toStart: newStart)
                case .leading:
                    model.resizeZoom(origin.zoom.id, start: timeline.sourceTime(atOutput: origin.outputStart + dt), end: origin.zoom.end)
                case .trailing:
                    model.resizeZoom(origin.zoom.id, start: origin.zoom.start, end: timeline.sourceTime(atOutput: origin.outputEnd + dt))
                }
            }
            .onEnded { _ in
                dragOrigin = nil
                model.endChange()
            }
    }
}
