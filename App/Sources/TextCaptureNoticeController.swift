import AppKit
import SwiftUI
import LightshotKit

/// The notice for an OCR Text run (spec 0010): "Reading text…" while recognition runs, then "Text
/// copied" with the first line, "No text found", or the recognition error, in a small dark HUD near
/// the bottom of the screen under the pointer (where the selection was just made). It never takes
/// focus or the mouse, so the user can paste straight away, and a result fades on its own. Each
/// status replaces the one before.
@MainActor
final class TextCaptureNoticeController {
    private var panel: NSPanel?
    private var pending: Task<Void, Never>?

    func show(_ status: TextCaptureStatus) {
        dismiss()
        let notice = Notice(status)
        guard status == .reading else { return present(notice) }
        // A warm recognition finishes in a blink; only say "reading" when it is actually slow, so
        // the common case doesn't flash two notices.
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.present(notice)
        }
    }

    private func present(_ notice: Notice) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let host = NSHostingView(rootView: NoticeView(notice: notice))
        let size = host.fittingSize
        let frame = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.12,
            width: size.width,
            height: size.height
        )
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel

        guard let duration = notice.duration else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
            panel.orderOut(nil)
        }
    }

    private func dismiss() {
        pending?.cancel()
        pending = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// What the HUD says for each status.
private struct Notice {
    var symbol: String
    var title: String
    var detail: String?
    /// Seconds on screen; an error stays a little longer so it can be read. `nil` stays until the
    /// next status replaces it.
    var duration: Double?

    init(_ status: TextCaptureStatus) {
        switch status {
        case .reading:
            symbol = "text.viewfinder"
            title = "Reading text…"
            detail = nil
            duration = nil
        case let .copied(text):
            symbol = "doc.on.clipboard"
            title = "Text copied"
            detail = Self.preview(of: text)
            duration = 2
        case .noText:
            symbol = "text.viewfinder"
            title = "No text found"
            detail = nil
            duration = 2
        case let .failed(message):
            symbol = "exclamationmark.triangle"
            title = "Couldn’t read the text"
            detail = message
            duration = 4
        }
    }

    /// The first line, cut to about 60 characters, so the user can spot a misread at a glance.
    static func preview(of text: String) -> String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return first.count > 60 ? String(first.prefix(60)) + "…" : first
    }
}

/// Dark in either appearance (spec 0008), like the countdown: it is read against the screen.
private struct NoticeView: View {
    let notice: Notice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.symbol)
                .font(.system(size: 18, weight: .medium))
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: 13, weight: .semibold))
                if let detail = notice.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                        .frame(maxWidth: 360, alignment: .leading)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .fixedSize()
    }
}
