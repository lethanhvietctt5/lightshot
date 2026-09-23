import AppKit
import SwiftUI
import LightshotKit

/// The Studio timeline (spec 0007, stories 5–13, 34–35), in **source time**: a header of edit
/// commands, the ruler, the recording's filmstrip (trimmed spans shaded), and the pill lanes —
/// zoom, trim, speed, text — with the playhead across them. Scrolls sideways when zoomed in.
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
                    StudioTracks(model: model, scale: TimelineScale(duration: max(model.edits.sourceDuration, 0.01), width: width))
                        .frame(width: width, height: geometry.size.height)
                        .padding(.horizontal, Self.inset)
                }
                .scrollIndicators(model.timelineZoom > 1 ? .automatic : .never)
            }
        }
        .disabled(model.sources == nil)
    }
}

/// Add zoom, auto zoom, trim, speed, text; delete; undo / redo.
private struct StudioTimelineHeader: View {
    @Bindable var model: StudioEditorModel

    var body: some View {
        HStack(spacing: 6) {
            tool("plus.magnifyingglass", "Add Zoom at Playhead") { model.addZoom() }
            tool("wand.and.stars", "Auto Zoom on Clicks") { model.autoZoom() }
                .disabled(!model.hasClicks)
            tool("scissors", "Trim at Playhead (T) — the trimmed part is skipped") { model.addTrim() }
            Menu {
                if let speed = model.selectedSpeed {
                    ForEach(studioSpeeds, id: \.self) { value in
                        Button(speedLabel(value)) { model.setSpeed(speed.id, value) }
                    }
                } else {
                    Button("Speed Up (2×)") { model.addSpeed(2) }
                    Button("Slow Down (0.5×)") { model.addSpeed(0.5) }
                }
            } label: {
                Label(model.selectedSpeed.map { speedLabel($0.speed) } ?? "Speed", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(model.selectedSpeed == nil ? "Speed up or slow down from the playhead" : "Speed of the selected part")
            tool("textformat", "Add Text at Playhead") { model.addAnnotation() }
            Divider().frame(height: 18).padding(.horizontal, 6)
            tool("trash", "Delete Selection (⌫)") { model.deleteSelection() }
                .disabled(model.selection == nil)
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

private let studioSpeeds: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]

/// `2×`, `0.5×`.
private func speedLabel(_ speed: Double) -> String {
    speed == speed.rounded() ? "\(Int(speed))×" : "\(speed)×"
}

private struct StudioTracks: View {
    @Bindable var model: StudioEditorModel
    let scale: TimelineScale

    static let rulerHeight: CGFloat = 28
    static let clipTop: CGFloat = 34
    static let clipHeight: CGFloat = 50
    static let laneHeight: CGFloat = 24
    static let zoomTop: CGFloat = 90
    static let trimTop: CGFloat = 120
    static let speedTop: CGFloat = 150
    static let textTop: CGFloat = 180

    var body: some View {
        ZStack(alignment: .topLeading) {
            ruler
            // Seek anywhere on the ruler / empty track.
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    model.selection = nil
                    model.seek(toSource: scale.time(at: value.location.x))
                })
            StudioFilmstrip(model: model, scale: scale)
                .offset(y: Self.clipTop)
                .allowsHitTesting(false)

            lane(top: Self.zoomTop, hint: model.edits.zooms.isEmpty ? "Zooms — add one at the playhead, or Auto Zoom on clicks" : nil)
            ForEach(model.edits.zooms) { zoom in
                StudioRegionPill(
                    model: model, id: zoom.id, start: zoom.start, end: zoom.end, scale: scale, color: StudioStyle.zoom,
                    selection: .zoom(zoom.id), panel: .zoom, deleteTitle: "Delete Zoom",
                    move: { model.moveZoom(zoom.id, toStart: $0) }, resize: { model.resizeZoom(zoom.id, start: $0, end: $1) }
                ) {
                    Label(String(format: "%.1f×", zoom.scale), systemImage: zoom.focus == .followCursor ? "cursorarrow.motionlines" : "scope")
                        .monospacedDigit()
                }
                .offset(x: scale.x(for: zoom.start), y: Self.zoomTop)
            }

            lane(top: Self.trimTop, hint: model.edits.trims.isEmpty ? "Trims — the parts you trim are skipped in playback and export" : nil)
            ForEach(model.edits.trims) { trim in
                StudioRegionPill(
                    model: model, id: trim.id, start: trim.start, end: trim.end, scale: scale, color: StudioStyle.trim,
                    selection: .trim(trim.id), deleteTitle: "Delete Trim",
                    move: { model.moveTrim(trim.id, toStart: $0) }, resize: { model.resizeTrim(trim.id, start: $0, end: $1) }
                ) {
                    Label("Trim", systemImage: "scissors")
                }
                .offset(x: scale.x(for: trim.start), y: Self.trimTop)
            }

            lane(top: Self.speedTop, hint: model.edits.speeds.isEmpty ? "Speed — speed up or slow down part of the recording" : nil)
            ForEach(model.edits.speeds) { speed in
                StudioRegionPill(
                    model: model, id: speed.id, start: speed.start, end: speed.end, scale: scale, color: StudioStyle.speed,
                    selection: .speed(speed.id), deleteTitle: "Delete Speed",
                    move: { model.moveSpeed(speed.id, toStart: $0) }, resize: { model.resizeSpeed(speed.id, start: $0, end: $1) },
                    menu: {
                        Menu("Speed") {
                            ForEach(studioSpeeds, id: \.self) { value in
                                Button(speedLabel(value)) { model.setSpeed(speed.id, value) }
                            }
                        }
                    }
                ) {
                    Label(speedLabel(speed.speed), systemImage: speed.speed > 1 ? "hare" : "tortoise")
                        .monospacedDigit()
                }
                .offset(x: scale.x(for: speed.start), y: Self.speedTop)
            }

            // The text lane (round 2, story 32).
            lane(top: Self.textTop, hint: nil)
            ForEach(model.edits.annotations) { annotation in
                StudioRegionPill(
                    model: model, id: annotation.id, start: annotation.start, end: annotation.end, scale: scale, color: StudioStyle.text,
                    selection: .annotation(annotation.id), panel: .text, deleteTitle: "Delete Text",
                    move: { model.moveAnnotation(annotation.id, toStart: $0) },
                    resize: { model.resizeAnnotation(annotation.id, start: $0, end: $1) }
                ) {
                    Label(annotation.text, systemImage: "textformat").lineLimit(1)
                }
                .offset(x: scale.x(for: annotation.start), y: Self.textTop)
            }
            playhead
                .offset(x: scale.x(for: model.sourceTime) - 6, y: Self.rulerHeight - 6)
                .allowsHitTesting(false)
        }
        .frame(width: scale.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: "tracks")
    }

    /// A lane's background, with a hint while it is empty.
    private func lane(top: CGFloat, hint: String?) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(StudioStyle.control.opacity(0.5))
            .frame(width: scale.width, height: Self.laneHeight)
            .overlay {
                if let hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).lineLimit(1)
                }
            }
            .offset(y: top)
            .allowsHitTesting(false)
    }

    private static let rulerOverhang: CGFloat = 40

    private var ruler: some View {
        Canvas { context, size in
            for tick in scale.ticks() {
                let x = scale.x(for: tick) + Self.rulerOverhang
                context.draw(
                    Text(TimelineScale.label(tick)).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Color.theme(.glyph)),
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
            Rectangle().fill(StudioStyle.playhead).frame(width: 2, height: Self.textTop + Self.laneHeight - Self.rulerHeight + 6)
        }
        .frame(width: 12)
    }
}

/// The whole recording's filmstrip with its waveform (story 33); trimmed spans are dimmed and
/// struck through, since playback skips them (story 34).
private struct StudioFilmstrip: View {
    @Bindable var model: StudioEditorModel
    let scale: TimelineScale

    private var width: CGFloat { max(2, scale.width) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            frames
                .frame(width: width, height: StudioTracks.clipHeight)
                .overlay(alignment: .bottom) { waveform }
            ForEach(model.edits.trims) { trim in
                let x = scale.x(for: trim.start), w = max(1, scale.x(for: trim.end) - x)
                ZStack {
                    Color.black.opacity(0.6)
                    Rectangle().fill(StudioStyle.trim).frame(height: 2)
                }
                .frame(width: w, height: StudioTracks.clipHeight)
                .offset(x: x)
            }
        }
        .frame(width: width, height: StudioTracks.clipHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.theme(.clipEdge), lineWidth: 1))
    }

    private var frames: some View {
        let aspect = model.sources.map { $0.pixelSize.width / max($0.pixelSize.height, 1) } ?? 16 / 9
        let slots = max(1, Int((width / (StudioTracks.clipHeight * aspect)).rounded(.up)))
        let slotWidth = width / CGFloat(slots)
        let duration = model.edits.sourceDuration
        return HStack(spacing: 0) {
            ForEach(0..<slots, id: \.self) { i in
                if let image = model.thumbnail(atSource: (Double(i) + 0.5) / Double(slots) * duration) {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: slotWidth, height: StudioTracks.clipHeight).clipped()
                } else {
                    StudioStyle.clip.frame(width: slotWidth, height: StudioTracks.clipHeight)
                }
            }
        }
    }

    @ViewBuilder
    private var waveform: some View {
        if !model.waveform.isEmpty {
            Canvas { context, size in
                let bars = max(1, Int(size.width / 3))
                let duration = model.edits.sourceDuration
                var path = Path()
                for i in 0..<bars {
                    let time = (Double(i) + 0.5) / Double(bars) * duration
                    let height = max(1, CGFloat(model.waveformPeak(atSource: time)) * size.height)
                    path.addRoundedRect(in: CGRect(x: CGFloat(i) * 3, y: size.height - height, width: 2, height: height), cornerSize: CGSize(width: 1, height: 1))
                }
                context.fill(path, with: .color(Color.white.opacity(0.85)))
            }
            .frame(height: 18)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
        }
    }
}

/// A pill on a region lane (zoom, trim, speed, text): select, drag to move, drag an edge to resize —
/// in source time, snapping to the playhead and nearby edges within 8 points (story 33).
private struct StudioRegionPill<Content: View, Actions: View>: View {
    @Bindable var model: StudioEditorModel
    let id: UUID
    let start: Double
    let end: Double
    let scale: TimelineScale
    let color: Color
    let selection: StudioEditorModel.Selection
    var panel: StudioEditorModel.Panel?
    let deleteTitle: String
    let move: (Double) -> Void
    let resize: (Double, Double) -> Void
    @ViewBuilder var menu: () -> Actions
    @ViewBuilder var content: () -> Content

    @State private var dragOrigin: (start: Double, end: Double)?
    private static var edge: CGFloat { 8 }

    init(
        model: StudioEditorModel, id: UUID, start: Double, end: Double, scale: TimelineScale, color: Color,
        selection: StudioEditorModel.Selection, panel: StudioEditorModel.Panel? = nil, deleteTitle: String,
        move: @escaping (Double) -> Void, resize: @escaping (Double, Double) -> Void,
        @ViewBuilder menu: @escaping () -> Actions = { EmptyView() }, @ViewBuilder content: @escaping () -> Content
    ) {
        self.model = model
        self.id = id
        self.start = start
        self.end = end
        self.scale = scale
        self.color = color
        self.selection = selection
        self.panel = panel
        self.deleteTitle = deleteTitle
        self.move = move
        self.resize = resize
        self.menu = menu
        self.content = content
    }

    private var isSelected: Bool { model.selection == selection }
    private var width: CGFloat { max(14, scale.x(for: end) - scale.x(for: start)) }
    private var pointsPerSecond: CGFloat { scale.width / max(scale.duration, 0.01) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(isSelected ? 1 : 0.75))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Color.white : .clear, lineWidth: 2))
            content()
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioStyle.onAccent)
                .padding(.horizontal, 10)
                .opacity(width > 56 ? 1 : 0)
            HStack {
                edgeHandle(leading: true)
                Spacer(minLength: 0)
                edgeHandle(leading: false)
            }
        }
        .frame(width: width, height: StudioTracks.laneHeight)
        .contentShape(Rectangle())
        .onTapGesture { select() }
        .gesture(drag(.move))
        .contextMenu {
            menu()
            Button(deleteTitle) { model.selection = selection; model.deleteSelection() }
        }
    }

    private func select() {
        model.selection = selection
        if let panel { model.panel = panel }
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
                    dragOrigin = (start, end)
                    select()
                    model.beginChange()
                }
                guard let origin = dragOrigin else { return }
                let dt = Double(value.translation.width / pointsPerSecond)
                let targets = model.snapTargets(excluding: id)
                let tolerance = Double(8 / pointsPerSecond)
                switch kind {
                case .move:
                    move(TimelineSnap.snapSpan(start: origin.start + dt, length: origin.end - origin.start, to: targets, tolerance: tolerance))
                case .leading:
                    resize(TimelineSnap.snap(origin.start + dt, to: targets, tolerance: tolerance), origin.end)
                case .trailing:
                    resize(origin.start, TimelineSnap.snap(origin.end + dt, to: targets, tolerance: tolerance))
                }
            }
            .onEnded { _ in
                dragOrigin = nil
                model.endChange()
            }
    }
}
