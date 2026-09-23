import SwiftUI
import LightshotKit

/// Captions and transcript editing (spec 0007, round 2, stories 29–31): transcribe on this Mac,
/// style the burned-in captions, fix a line's text, and cut speech by selecting words — or every
/// long pause at once.
struct StudioCaptionsPanel: View {
    @Bindable var model: StudioEditorModel
    @State private var silenceGap = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.hasAudio {
                transcribeRow
            } else {
                note("This recording has no sound to transcribe. Record with the microphone on to make captions.", symbol: "speaker.slash")
            }
            if let error = model.transcriptionError {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if model.transcript != nil {
                style
                silences
                transcript
                lines
            }
        }
    }

    private var transcribeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.transcribe()
            } label: {
                HStack {
                    if model.isTranscribing { ProgressView().controlSize(.small) }
                    Text(model.isTranscribing ? "Transcribing…" : model.transcript == nil ? "Transcribe Narration" : "Transcribe Again")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(model.transcript == nil ? StudioStyle.blue : StudioStyle.control))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isTranscribing)
            Text("Speech is recognised on this Mac — nothing is sent to a server.")
                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
        }
    }

    // MARK: - Style (story 29)

    @ViewBuilder
    private var style: some View {
        Toggle("Show Captions", isOn: Binding(get: { model.edits.captions.visible }, set: { model.set(\.captions.visible, $0) }))
            .toggleStyle(.switch).font(.system(size: 13))
        if model.edits.captions.visible {
            labelled("Size") {
                Picker("Size", selection: Binding(get: { model.edits.captions.style.size }, set: { model.set(\.captions.style.size, $0) })) {
                    ForEach(CaptionSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            labelled("Position") {
                Picker("Position", selection: Binding(get: { model.edits.captions.style.position }, set: { model.set(\.captions.style.position, $0) })) {
                    ForEach(CaptionPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            ColorPicker("Text Colour", selection: Binding(
                get: { model.edits.captions.style.textColor.color }, set: { model.set(\.captions.style.textColor, RGBAColor($0)) }
            ), supportsOpacity: false)
            .font(.system(size: 13))
            Toggle("Backdrop", isOn: Binding(get: { model.edits.captions.style.backdrop }, set: { model.set(\.captions.style.backdrop, $0) }))
                .toggleStyle(.switch).font(.system(size: 13))
        }
    }

    // MARK: - Silences (story 31)

    private var silences: some View {
        labelled("Remove Silences", value: String(format: "pauses over %.1f s", silenceGap)) {
            VStack(spacing: 8) {
                Slider(value: $silenceGap, in: 0.5...3)
                button("Remove Silences") { model.removeSilences(minimumGap: silenceGap) }
            }
        }
    }

    // MARK: - Transcript (story 30)

    private var transcript: some View {
        labelled("Transcript", value: model.selectedWords.isEmpty ? nil : "\(model.selectedWords.count) selected") {
            VStack(alignment: .leading, spacing: 10) {
                let words = model.transcript?.words ?? []
                StudioFlowLayout(spacing: 4) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        wordChip(word, index: index)
                    }
                }
                HStack(spacing: 8) {
                    button("Cut Selected Words") { model.cutSelectedWords() }
                        .disabled(model.selectedWords.isEmpty)
                    button("Clear") { model.selectedWords = [] }
                        .disabled(model.selectedWords.isEmpty)
                }
                Text("Click words to select them, then cut. Cut words are struck through; Undo brings them back.")
                    .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
            }
        }
    }

    private func wordChip(_ word: TranscriptWord, index: Int) -> some View {
        let selected = model.selectedWords.contains(index)
        let cut = model.isCut(word)
        return Text(word.text)
            .font(.system(size: 12))
            .strikethrough(cut)
            .foregroundStyle(cut ? StudioStyle.secondary : Color.white)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(selected ? StudioStyle.blue.opacity(0.7) : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture {
                if selected { model.selectedWords.remove(index) } else { model.selectedWords.insert(index) }
                model.seek(toWord: word)
            }
    }

    // MARK: - Lines (story 30)

    private var lines: some View {
        labelled("Caption Lines", value: "\(model.edits.captions.lines.count)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.edits.captions.lines) { line in
                    StudioCaptionLineRow(model: model, line: line)
                }
                button("Rebuild Lines from Transcript") { model.regenerateCaptions() }
            }
        }
    }

    // MARK: - Building blocks

    private func labelled<Content: View>(_ title: String, value: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(StudioStyle.secondary)
                Spacer()
                if let value { Text(value).font(.system(size: 12).monospacedDigit()).foregroundStyle(StudioStyle.secondary) }
            }
            content()
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(StudioStyle.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String, symbol: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol) }
            .font(.system(size: 13))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(StudioStyle.control))
    }
}

/// One caption line: its time and an editable text committed on Return (one undo step per edit).
private struct StudioCaptionLineRow: View {
    let model: StudioEditorModel
    let line: CaptionLine
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(TimelineScale.label(line.start))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(StudioStyle.secondary)
                .frame(width: 38, alignment: .leading)
            TextField("Caption", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { commit() }
                .onChange(of: line.text, initial: true) { _, text in draft = text }
        }
        .padding(.vertical, 2)
        .onDisappear { commit() }
    }

    private func commit() {
        if draft != line.text { model.editCaption(line.id, text: draft) }
    }
}

/// Lays children out left to right, wrapping onto new rows — the transcript's words.
struct StudioFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
