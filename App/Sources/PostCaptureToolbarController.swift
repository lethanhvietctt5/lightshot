import AppKit
import SwiftUI
import LightshotKit

/// Presents the post-capture toolbar (story 14) as a small floating panel at the selection: quick
/// actions over the freshly captured image. Shown *after* the image exists — a separate surface
/// from the pre-capture selection overlay.
///
/// A thin OS wrapper (no unit tests). It owns only placement and lifetime; the actions themselves
/// are closures the `AppController` supplies (annotate → editor, copy → clipboard, pin → floating
/// window, discard → dismiss). Save lights up once its ticket lands.
@MainActor
final class PostCaptureToolbarController {
    private var panel: NSPanel?

    func present(
        at region: CaptureRegion,
        annotate: @escaping () -> Void,
        copy: @escaping () -> Void,
        pin: @escaping () -> Void
    ) {
        dismiss()
        // Both selection modes place the toolbar the same way — at the captured region's bounds.
        // A rect carries its own bounds; a window carries its on-screen frame for exactly this.
        let rect: Rect
        switch region {
        case let .rect(r): rect = r
        case let .window(_, frame): rect = frame
        }

        let view = PostCaptureToolbarView(
            annotate: { [weak self] in self?.dismiss(); annotate() },
            copy: { [weak self] in self?.dismiss(); copy() },
            pin: { [weak self] in self?.dismiss(); pin() },
            discard: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        panel.setFrame(NSRect(origin: frameOrigin(for: rect, size: size), size: size), display: true)
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Places the toolbar centered just below the selection, converting the overlay's top-left
    /// screen points into AppKit's bottom-left global coordinates. Falls back above the selection
    /// when there's no room below, and clamps horizontally to the screen.
    private func frameOrigin(for rect: Rect, size: NSSize) -> NSPoint {
        let selection = rect.standardized
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 8

        // Selection bottom edge in bottom-left global space.
        let selectionBottomY = screenFrame.maxY - selection.maxY
        var originY = selectionBottomY - gap - size.height
        if originY < screenFrame.minY {
            // No room below — sit above the selection's top edge instead.
            originY = screenFrame.maxY - selection.minY + gap
        }

        var originX = screenFrame.minX + selection.midX - size.width / 2
        originX = min(max(originX, screenFrame.minX + gap), screenFrame.maxX - size.width - gap)
        return NSPoint(x: originX, y: originY)
    }
}

/// The toolbar's buttons. Save is intentionally absent until its ticket lands.
private struct PostCaptureToolbarView: View {
    let annotate: () -> Void
    let copy: () -> Void
    let pin: () -> Void
    let discard: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            button("Annotate", systemImage: "pencil.tip.crop.circle", action: annotate)
            button("Copy", systemImage: "doc.on.doc", action: copy)
            button("Pin", systemImage: "pin", action: pin)
            button("Discard", systemImage: "trash", action: discard)
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .fixedSize()
    }

    private func button(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
