import Foundation

/// A pointer event the recorder's overlays react to (spec 0006, stories 29–30).
public enum PointerEvent: Equatable, Sendable {
    /// The pointer is at `position` (screen points, top-left origin).
    case moved(Point)
    /// A mouse button went down at `position`.
    case down(Point)
}

/// The OS input seam (spec 0006, story 29): streams pointer events while a take records. The
/// concrete source (app target) uses a global event monitor, which needs no permission for the
/// mouse; keystrokes (R11) arrive through the same seam behind Input Monitoring.
public protocol InputEventSource: Sendable {
    /// Start delivering events, from any thread, until `stop()`.
    func start(onEvent: @escaping @Sendable (PointerEvent) -> Void)
    func stop()
}
