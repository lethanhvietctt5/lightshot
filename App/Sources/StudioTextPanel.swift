import SwiftUI
import LightshotKit

/// Text annotations (spec 0007, round 2, story 32): add one at the playhead, then edit the selected
/// one's words, size, colours and fade; drag it on the preview to place it.
struct StudioTextPanel: View {
    @Bindable var model: StudioEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            button("Add Text at Playhead", prominent: model.edits.annotations.isEmpty) { model.addAnnotation() }
            if let annotation = model.selectedAnnotation {
                editor(annotation)
            } else if !model.edits.annotations.isEmpty {
                section("Texts") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.edits.annotations) { annotation in
                            Button {
                                model.selection = .annotation(annotation.id)
                                if let time = model.timeline.outputTime(atSource: annotation.start) { model.seek(to: time) }
                            } label: {
                                HStack {
                                    Text(annotation.text).lineLimit(1)
                                    Spacer()
                                    Text(TimelineScale.label(annotation.start)).foregroundStyle(StudioStyle.secondary).monospacedDigit()
                                }
                                .font(.system(size: 12))
                                .padding(.horizontal, 8).frame(height: 26)
                                .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.control))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Text("Add a title card or a callout; it gets its own lane on the timeline.")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            }
        }
    }

    @ViewBuilder
    private func editor(_ annotation: TextAnnotation) -> some View {
        section("Text") {
            StudioAnnotationTextField(model: model, annotation: annotation)
        }
        slider("Size", value: annotation.size, in: 0.03...0.2, format: "\(Int((annotation.size * 100).rounded()))%") { value in
            model.updateAnnotation(annotation.id) { $0.size = value }
        }
        ColorPicker("Text Colour", selection: Binding(
            get: { annotation.textColor.color },
            set: { color in model.updateAnnotation(annotation.id) { $0.textColor = RGBAColor(color) } }
        ), supportsOpacity: false)
        .font(.system(size: 13))
        ColorPicker("Background", selection: Binding(
            get: { annotation.background.color },
            set: { color in model.updateAnnotation(annotation.id) { $0.background = RGBAColor(color) } }
        ), supportsOpacity: true)
        .font(.system(size: 13))
        slider("Fade", value: annotation.fade, in: 0...1, format: String(format: "%.1f s", annotation.fade)) { value in
            model.updateAnnotation(annotation.id) { $0.fade = value }
        }
        Text("Drag the text on the preview to place it; drag its pill on the timeline to time it.")
            .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
        button("Delete Text") { model.deleteSelection() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(StudioStyle.secondary)
            content()
        }
    }

    private func slider(_ title: String, value: Double, in range: ClosedRange<Double>, format: String, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).foregroundStyle(StudioStyle.secondary)
                Spacer()
                Text(format).monospacedDigit()
            }
            .font(.system(size: 13))
            Slider(value: Binding(get: { value }, set: set), in: range) { editing in
                if editing { model.beginChange() } else { model.endChange() }
            }
        }
    }

    private func button(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(prominent ? StudioStyle.blue : StudioStyle.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The annotation's words, committed on Return (one undo step per edit).
private struct StudioAnnotationTextField: View {
    let model: StudioEditorModel
    let annotation: TextAnnotation
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Title", text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onChange(of: focused) { _, isFocused in
                model.isEditingText = isFocused
                if !isFocused { commit() }
            }
            .onSubmit { commit() }
            .onChange(of: annotation.id, initial: true) { _, _ in draft = annotation.text }
            .onDisappear { commit() }
    }

    private func commit() {
        guard draft != annotation.text else { return }
        let text = draft
        model.updateAnnotation(annotation.id) { $0.text = text }
    }
}
