import AppKit
import SwiftUI
import LightshotKit

/// The Quick Access Overlay for screenshots (spec 0014; CleanShot's Quick Access Overlay): each
/// screenshot waits as a card in a bottom corner of the screen, newest at the bottom, until the user
/// copies, saves, annotates, pins, drags or closes it. The stack and its placement are the core's
/// (`QuickAccessStack`, `QuickAccessLayout`); this owns the panels, hover, auto-close and drag-out.
///
/// A thin OS wrapper (no unit tests). Cards never take focus, and sit above the floating level so
/// a freeze leaves them out of the next screenshot.
@MainActor
final class QuickAccessController {
    /// What a card's buttons do. `save` and `saveAs` report whether the image was written, so a
    /// failed save keeps its card.
    struct Actions {
        let copy: (CapturedImage) -> Void
        let save: (CapturedImage) -> Bool
        let saveAs: (CapturedImage) -> Bool
        let annotate: (CapturedImage) -> Void
        let pin: (CapturedImage) -> Void
        /// The image as a file to drag out, named and encoded like a default save.
        let dragFile: (CapturedImage) -> URL?
    }

    private let actions: Actions
    private let settings: () -> QuickAccessSettings
    private var stack = QuickAccessStack()
    private var cards: [UUID: Card] = [:]
    /// The screen the stack lives on while it's up: the one under the pointer when it started.
    private var screen: NSScreen?

    /// One card on screen.
    private struct Card {
        let panel: NSPanel
        let model: QuickAccessCardModel
        var autoClose: Task<Void, Never>?
    }

    init(actions: Actions, settings: @escaping () -> QuickAccessSettings) {
        self.actions = actions
        self.settings = settings
    }

    func present(_ image: CapturedImage) {
        if stack.cards.isEmpty {
            screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        }
        let id = stack.push(image)
        let size = QuickAccessLayout.cardSize(pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight)
        let model = QuickAccessCardModel(image: NSImage(data: image.data) ?? NSImage(), size: size)
        let panel = makePanel(for: id, image: image, model: model)
        cards[id] = Card(panel: panel, model: model)
        layout(entering: id)
        scheduleAutoClose(id)
    }

    func closeAll() {
        for id in stack.cards.map(\.id) { remove(id, animated: false) }
    }

    // MARK: - Layout

    /// Place every card from the core's layout, closing the oldest that no longer fit. A card just
    /// added slides in from its side.
    private func layout(entering newID: UUID? = nil) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let area = Rect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height)
        let sizes = stack.cards.map { cards[$0.id]?.model.size ?? Size(width: 0, height: 0) }
        let overflow = stack.fitting(
            cardHeights: sizes.map(\.height),
            available: QuickAccessLayout.availableHeight(in: area),
            spacing: QuickAccessLayout.spacing
        )
        for id in overflow { remove(id, animated: false, relayout: false) }

        let side = settings().side
        let frames = QuickAccessLayout.frames(
            for: stack.cards.map { cards[$0.id]?.model.size ?? Size(width: 0, height: 0) },
            in: area, side: side
        )
        for (card, frame) in zip(stack.cards, frames) {
            guard let panel = cards[card.id]?.panel else { continue }
            let target = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
            if card.id == newID {
                let offset = (target.width + QuickAccessLayout.margin) * (side == .left ? -1 : 1)
                panel.setFrame(target.offsetBy(dx: offset, dy: 0), display: false)
                panel.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    // MARK: - Cards

    private func makePanel(for id: UUID, image: CapturedImage, model: QuickAccessCardModel) -> NSPanel {
        let view = QuickAccessCardView(
            model: model,
            copy: { [weak self] in self?.confirm(id) { self?.actions.copy(image); return true } },
            save: { [weak self] in self?.confirm(id) { self?.actions.save(image) ?? false } },
            saveAs: { [weak self] in if self?.actions.saveAs(image) == true { self?.remove(id) } },
            annotate: { [weak self] in self?.remove(id); self?.actions.annotate(image) },
            pin: { [weak self] in self?.remove(id); self?.actions.pin(image) },
            close: { [weak self] in self?.remove(id) },
            closeAll: { [weak self] in self?.closeAll() },
            hovering: { [weak self] inside in self?.hover(id, inside: inside) }
        )
        let host = QuickAccessCardHostingView(rootView: view)
        host.dragFile = { [weak self] in self?.actions.dragFile(image) }
        host.dragImage = model.image
        host.onDragEnded = { [weak self] dropped in self?.dragEnded(id, dropped: dropped) }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: model.size.width, height: model.size.height),
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
        panel.contentView = host
        return panel
    }

    /// Copy and Save: a tick on the card, then it goes. A failed action keeps the card.
    private func confirm(_ id: UUID, _ action: () -> Bool) {
        guard action(), let model = cards[id]?.model else { return }
        cards[id]?.autoClose?.cancel()
        model.confirmed = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.remove(id)
        }
    }

    private func dragEnded(_ id: UUID, dropped: Bool) {
        // ⌥ at the drop keeps the card when it would close, and closes it when it would stay.
        let keep = !settings().closeAfterDragging != NSEvent.modifierFlags.contains(.option)
        if dropped, !keep { remove(id) }
    }

    private func remove(_ id: UUID, animated: Bool = true, relayout: Bool = true) {
        guard let card = cards.removeValue(forKey: id) else { return }
        card.autoClose?.cancel()
        stack.remove(id)
        if animated {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; card.panel.animator().alphaValue = 0 }) {
                card.panel.orderOut(nil)
            }
        } else {
            card.panel.orderOut(nil)
        }
        if relayout { layout() }
        if stack.cards.isEmpty { screen = nil }
    }

    // MARK: - Auto-close

    private func hover(_ id: UUID, inside: Bool) {
        cards[id]?.model.hovering = inside
        if inside {
            cards[id]?.autoClose?.cancel()
            cards[id]?.autoClose = nil
        } else {
            scheduleAutoClose(id)
        }
    }

    private func scheduleAutoClose(_ id: UUID) {
        cards[id]?.autoClose?.cancel()
        guard let seconds = settings().autoClose.seconds, cards[id] != nil else { return }
        cards[id]?.autoClose = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.remove(id)
        }
    }
}

// MARK: - Card view

@MainActor
@Observable
final class QuickAccessCardModel {
    let image: NSImage
    let size: Size
    var hovering = false
    /// Copied or saved: the tick shows until the card goes.
    var confirmed = false

    init(image: NSImage, size: Size) {
        self.image = image
        self.size = size
    }
}

/// One card: the screenshot fitted into the card, and on hover Copy / Save in the middle with
/// Close, Pin and Annotate in the corners. Dark in either appearance (spec 0008): it is read against
/// whatever is on screen.
private struct QuickAccessCardView: View {
    let model: QuickAccessCardModel
    let copy: () -> Void
    let save: () -> Void
    let saveAs: () -> Void
    let annotate: () -> Void
    let pin: () -> Void
    let close: () -> Void
    let closeAll: () -> Void
    let hovering: (Bool) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            Image(nsImage: model.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
            if model.confirmed {
                Color.black.opacity(0.5)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            } else if model.hovering {
                Color.black.opacity(0.45)
                VStack(spacing: 8) {
                    pill("Copy", action: copy)
                    pill("Save", action: save)
                }
                VStack {
                    HStack {
                        corner("xmark", help: "Close", action: close)
                        Spacer()
                        corner("pin", help: "Pin", action: pin)
                    }
                    Spacer()
                    HStack {
                        corner("pencil.tip.crop.circle", help: "Annotate", action: annotate)
                        Spacer()
                    }
                }
                .padding(6)
            }
        }
        .frame(width: model.size.width, height: model.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(count: 2, perform: annotate)
        .onHover(perform: hovering)
        .contextMenu {
            Button("Copy", action: copy)
            Button("Save", action: save)
            Button("Save As…", action: saveAs)
            Divider()
            Button("Annotate", action: annotate)
            Button("Pin", action: pin)
            Divider()
            Button("Close", action: close)
            Button("Close All", action: closeAll)
        }
        .help("Drag into another app · Double-click to annotate")
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 84, height: 26)
                .background(.white, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func corner(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.6), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Drag out

/// The card's host: a drag that starts on it (past a few points) becomes an AppKit dragging session
/// carrying the screenshot as a file, so the end of the drag — and whether anything accepted the
/// drop — is known, which SwiftUI's `onDrag` doesn't say.
private final class QuickAccessCardHostingView<Content: View>: NSHostingView<Content> {
    var dragFile: (() -> URL?)?
    var dragImage: NSImage?
    /// `true` when a destination accepted the drop.
    var onDragEnded: ((Bool) -> Void)? {
        get { source.ended }
        set { source.ended = newValue }
    }
    private var mouseDownPoint: NSPoint?
    private let source = CardDragSource()

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return super.mouseDragged(with: event) }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 4, let url = dragFile?() else {
            return super.mouseDragged(with: event)
        }
        // One session per press.
        mouseDownPoint = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: dragImage)
        beginDraggingSession(with: [item], event: event, source: source)
    }
}

/// The card's dragging source: copies out of the app only, and reports whether the drop landed.
private final class CardDragSource: NSObject, NSDraggingSource {
    var ended: ((Bool) -> Void)?

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        ended?(operation != [])
    }
}
