import SwiftUI
import AppKit
import LightshotKit

/// The capture-history window (stories 50–54): a grid of recent captures with per-item actions and
/// a footer for retention + clear-all.
///
/// A thin projection of `HistoryModel` — it renders `model.records` and routes button taps back to
/// the model, which owns the store and the reopen/copy/reveal/delete behavior.
struct HistoryView: View {
    @State private var model: HistoryModel

    init(model: HistoryModel) {
        _model = State(initialValue: model)
    }

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 360)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.records.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No captures yet")
                    .font(.headline)
                Text("Screenshots you take appear here.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.records) { record in
                        HistoryItemCard(record: record, model: model)
                    }
                }
                .padding(16)
            }
        }
    }

    private var footer: some View {
        HStack {
            Stepper(value: $model.retention, in: 1...500) {
                Text("Keep last \(model.retention) captures")
            }
            .help("Older captures beyond this limit are removed to control disk use and privacy.")
            Spacer()
            Button("Clear All…", role: .destructive) {
                confirmClearAll()
            }
            .disabled(model.records.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func confirmClearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear all captures?"
        alert.informativeText = "This permanently deletes every capture in your history. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.clearAll()
        }
    }
}

/// One capture in the grid: its thumbnail, when/how it was captured, and the row of actions.
private struct HistoryItemCard: View {
    let record: CaptureRecord
    let model: HistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.source.label)
                        .font(.caption).bold()
                    Text(record.timestamp, format: .dateTime.month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            actions
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .contextMenu {
            Button("Open in Editor") { model.reopen(record) }
            Button("Copy") { model.copy(record) }
            Button("Reveal in Finder") { model.reveal(record) }
            Divider()
            Button("Delete", role: .destructive) { model.delete(record) }
        }
        .onTapGesture(count: 2) { model.reopen(record) }
    }

    private var thumbnail: some View {
        Group {
            if let image = NSImage(contentsOf: record.thumbnailURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 120)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var actions: some View {
        HStack(spacing: 4) {
            actionButton("square.and.pencil", "Open in Editor") { model.reopen(record) }
            actionButton("doc.on.doc", "Copy") { model.copy(record) }
            actionButton("folder", "Reveal in Finder") { model.reveal(record) }
            Spacer()
            actionButton("trash", "Delete") { model.delete(record) }
        }
        .buttonStyle(.borderless)
    }

    private func actionButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .help(help)
    }
}

private extension CaptureSource {
    /// Human-readable label for the history list.
    var label: String {
        switch self {
        case .fullscreen: return "Fullscreen"
        case .area: return "Area"
        case .window: return "Window"
        case .file: return "Opened file"
        }
    }
}
