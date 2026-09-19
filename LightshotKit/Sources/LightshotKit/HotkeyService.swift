import Foundation

/// The global-hotkey seam (story 56), fronted as a protocol so the domain core never imports the
/// Carbon/AppKit key-registration APIs.
///
/// The concrete implementation (app target) wraps Carbon's `RegisterEventHotKey`; it is a thin OS
/// wrapper and not unit-tested. Registration reports which actions it could **not** claim (the OS or
/// another app already owns the chord) so the app surfaces them rather than silently dropping a
/// binding — the same "never silent" contract the capture seam holds.
@MainActor
public protocol HotkeyService: AnyObject {
    /// Replace any prior registration with `bindings`, invoking `handler` on the main actor when a
    /// registered chord fires. Returns the actions whose hotkey could not be registered (an empty
    /// array on full success).
    @discardableResult
    func register(_ bindings: HotkeyBindings, handler: @escaping (CaptureAction) -> Void) -> [CaptureAction]

    /// Unregister every hotkey this service currently owns.
    func unregisterAll()
}
