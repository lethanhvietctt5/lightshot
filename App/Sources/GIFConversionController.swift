import AppKit
import SwiftUI

/// The "making your GIF" popup (spec 0006, stories 37–38): a progress bar and Cancel. Cancelling
/// asks whether to keep the video instead or delete the take.
@MainActor
final class GIFConversionController {
    private var panel: NSPanel?
    private var model: ConversionModel?

    func show(cancel: @escaping () -> Void) {
        hide()
        let model = ConversionModel()
        self.model = model
        let hosting = NSHostingView(rootView: GIFConversionView(model: model, cancel: cancel))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: screen.maxX - size.width - 16, y: screen.minY + 16, width: size.width, height: size.height), display: true)
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func update(progress: Double) {
        model?.progress = min(max(progress, 0), 1)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    /// Story 38: after Cancel, keep the video instead (`true`) or delete the take.
    func resolveCancelled() -> Bool {
        let alert = NSAlert()
        alert.messageText = "GIF conversion cancelled"
        alert.informativeText = "Keep the recording as a video instead, or delete it?"
        alert.addButton(withTitle: "Keep the Video")
        alert.addButton(withTitle: "Delete")
        WindowPresenter.activateApp()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
@Observable
private final class ConversionModel {
    var progress: Double = 0
}

private struct GIFConversionView: View {
    let model: ConversionModel
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Making your GIF…", systemImage: "photo.stack")
                .font(.system(size: 13, weight: .medium))
            ProgressView(value: model.progress)
                .frame(width: 240)
            HStack {
                Text("\(Int((model.progress * 100).rounded()))%")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .fixedSize()
    }
}
