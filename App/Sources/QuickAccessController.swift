import AppKit
import SwiftUI
import LightshotKit

/// The Quick Access Overlay for screenshots (spec 0014; CleanShot's Quick Access Overlay): each
/// screenshot waits as a card in a bottom corner of the screen, newest at the bottom, until the user
/// copies, saves, annotates, pins, drags or closes it. The stack and its placement are the core's
/// (`QuickAccessStack`, `QuickAccessLayout.arrange`); this owns the panels, hover, auto-close and
/// drag-out.
///
/// A thin OS wrapper (no unit tests). Cards never take focus, and sit above the floating level so
/// every display grab leaves them out of the next screenshot.
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
        /// The image written as a file into `folder`, named and encoded like a default save.
        let dragFile: (CapturedImage, _ folder: URL) -> URL?
    }

    private let actions: Actions
    private let settings: () -> QuickAccessSettings
    private var stack = QuickAccessStack()
    private var cards: [UUID: Card] = [:]
    /// The screen the stack lives on while it's up: the one under the pointer when it started.
    private var screen: NSScreen?
    /// The side the cards were last laid out on, so a Settings change moves them.
    private var side: QuickAccessSide?
    private var observers: [NSObjectProtocol] = []
    /// Where drag-out files are written, one folder per card; emptied at launch (see `remove`).
    private static let dragFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Lightshot Drag", isDirectory: true)

    /// One card on screen.
    private struct Card {
        let panel: NSPanel
        let model: QuickAccessCardModel
        var autoClose: Task<Void, Never>?
        /// When auto-close fires, while it's counting.
        var deadline: Date?
        /// How much of the auto-close interval is left while the pointer holds it.
        var remaining: TimeInterval?
        /// The card's drag-out file, written on the first drag.
        var dragFile: URL?
    }

    init(actions: Actions, settings: @escaping () -> QuickAccessSettings) {
        self.actions = actions
        self.settings = settings
        try? FileManager.default.removeItem(at: Self.dragFolder)
        let center = NotificationCenter.default
        // A display unplugged or rearranged: keep the stack on a screen that exists.
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        // Position changed in Settings: move the cards that are up.
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stack.cards.isEmpty, self.settings().side != self.side else { return }
                self.layout()
            }
        })
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
        startAutoClose(id, after: settings().autoClose.seconds)
    }

    func closeAll() {
        for id in stack.cards.map(\.id) { remove(id, animated: false, relayout: false) }
    }

    // MARK: - Layout

    /// Place every card where the core's arrangement says, closing the ones that no longer fit. A
    /// card just added slides in from its side.
    private func layout(entering newID: UUID? = nil) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let side = settings().side
        self.side = side
        let arrangement = QuickAccessLayout.arrange(stack, in: Rect(visible), side: side)
        for id in arrangement.closing { remove(id, animated: false, relayout: false) }
        for (id, frame) in arrangement.frames {
            guard let panel = cards[id]?.panel else { continue }
            let target = frame.cgRect
            if id == newID {
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

    private func screensChanged() {
        guard !stack.cards.isEmpty else { return }
        if let screen, !NSScreen.screens.contains(screen) { self.screen = NSScreen.main }
        layout()
    }

    // MARK: - Cards

    private func makePanel(for id: UUID, image: CapturedImage, model: QuickAccessCardModel) -> NSPanel {
        let view = QuickAccessCardView(
            model: model,
            copy: { [weak self] in self?.act(id) { self?.confirm(id) { self?.actions.copy(image); return true } } },
            save: { [weak self] in self?.act(id) { self?.confirm(id) { self?.actions.save(image) ?? false } } },
            saveAs: { [weak self] in self?.act(id) { if self?.actions.saveAs(image) == true { self?.remove(id) } } },
            annotate: { [weak self] in self?.act(id) { self?.remove(id); self?.actions.annotate(image) } },
            pin: { [weak self] in self?.act(id) { self?.remove(id); self?.actions.pin(image) } },
            close: { [weak self] in self?.remove(id) },
            closeAll: { [weak self] in self?.closeAll() },
            hovering: { [weak self] inside in self?.hover(id, inside: inside) }
        )
        let host = QuickAccessCardHostingView(rootView: view)
        host.dragFile = { [weak self] in self?.dragFile(for: id, image: image) }
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

    /// Run a card's action, unless the card is already done (showing its tick) or gone.
    private func act(_ id: UUID, _ action: () -> Void) {
        guard let card = cards[id], !card.model.confirmed else { return }
        action()
    }

    /// Copy and Save: a tick on the card, then it goes. A failed action keeps the card.
    private func confirm(_ id: UUID, _ action: () -> Bool) {
        guard action(), let model = cards[id]?.model else { return }
        stopAutoClose(id)
        model.confirmed = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.remove(id)
        }
    }

    /// The card's drag-out file, written once into the card's own folder.
    private func dragFile(for id: UUID, image: CapturedImage) -> URL? {
        guard cards[id] != nil, !(cards[id]?.model.confirmed ?? true) else { return nil }
        if let url = cards[id]?.dragFile { return url }
        let url = actions.dragFile(image, Self.dragFolder.appendingPathComponent(id.uuidString, isDirectory: true))
        cards[id]?.dragFile = url
        return url
    }

    private func dragEnded(_ id: UUID, dropped: Bool) {
        // ⌥ at the drop inverts Close after dragging, as in CleanShot: it keeps a card that would
        // close, and closes one that would stay.
        let keep = !settings().closeAfterDragging != NSEvent.modifierFlags.contains(.option)
        if dropped, !keep { remove(id) }
    }

    private func remove(_ id: UUID, animated: Bool = true, relayout: Bool = true) {
        guard let card = cards.removeValue(forKey: id) else { return }
        card.autoClose?.cancel()
        stack.remove(id)
        // A dropped file stays: receivers such as Finder copy it after the drag session ends, so
        // deleting it here loses the drop. The drag folder is emptied at the next launch instead.
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

    /// The pointer holds a card's countdown while it's over the card, and the countdown resumes
    /// with what was left when it leaves.
    private func hover(_ id: UUID, inside: Bool) {
        guard let card = cards[id] else { return }
        card.model.hovering = inside
        guard !card.model.confirmed else { return }
        if inside {
            let left = card.deadline.map { max(0, $0.timeIntervalSinceNow) }
            stopAutoClose(id)
            cards[id]?.remaining = left
        } else if let left = card.remaining {
            startAutoClose(id, after: left)
        }
    }

    private func startAutoClose(_ id: UUID, after seconds: TimeInterval?) {
        stopAutoClose(id)
        guard let seconds, cards[id] != nil else { return }
        cards[id]?.deadline = Date().addingTimeInterval(seconds)
        cards[id]?.remaining = nil
        cards[id]?.autoClose = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.remove(id)
        }
    }

    private func stopAutoClose(_ id: UUID) {
        cards[id]?.autoClose?.cancel()
        cards[id]?.autoClose = nil
        cards[id]?.deadline = nil
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
