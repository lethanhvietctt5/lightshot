import AppKit
import LightshotKit

/// The OS side of `InputEventSource` for the mouse (spec 0006, story 29): `NSEvent` monitors for
/// pointer moves, drags and button presses. Mouse monitors need no grant — only keyboard monitors
/// are gated by Input Monitoring (R11). A global monitor never sees events sent to Lightshot's own
/// windows (the controls pill, later the camera preview), so a local monitor covers those and the
/// halo keeps following the pointer across them. Positions are converted from AppKit's bottom-left
/// global coordinates to the top-left screen points every `CaptureRegion` uses.
final class MouseEventMonitor: InputEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var monitors: [Any] = []

    func start(onEvent: @escaping @Sendable (PointerEvent) -> Void) {
        stop()
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let down: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let installed: [Any?] = [
            NSEvent.addGlobalMonitorForEvents(matching: moved) { _ in onEvent(.moved(Self.pointer())) },
            NSEvent.addGlobalMonitorForEvents(matching: down) { _ in onEvent(.down(Self.pointer())) },
            NSEvent.addLocalMonitorForEvents(matching: moved) { event in onEvent(.moved(Self.pointer())); return event },
            NSEvent.addLocalMonitorForEvents(matching: down) { event in onEvent(.down(Self.pointer())); return event },
        ]
        lock.lock()
        monitors = installed.compactMap { $0 }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let installed = monitors
        monitors = []
        lock.unlock()
        for monitor in installed { NSEvent.removeMonitor(monitor) }
    }

    /// The pointer in top-left screen points: AppKit's global location flipped against the primary
    /// display's height (the primary display is the one whose origin is (0, 0) in both spaces).
    static func pointer() -> Point {
        let location = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return Point(x: location.x, y: primaryHeight - location.y)
    }
}
