import AppKit

/// The one way Lightshot brings a standard window (settings, history, onboarding, editor) or a
/// modal to the front (LIG-23).
///
/// Lightshot is an `LSUIElement` app — no Dock icon except while the editor is open (spec 0004) —
/// so a window that opens behind the frontmost app is genuinely hard to find. Every call site goes
/// through here instead of repeating its own activation, so none of them can forget a step.
@MainActor
enum WindowPresenter {

    /// Bring `window` to the front, key and ready for input. Safe to call on a window that is
    /// already open — buried or minimized — to re-front it. The window's level is left alone: it
    /// fronts once, it does not float above other apps.
    static func present(_ window: NSWindow) {
        activateApp()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // An accessory app's activation can be declined by the system, in which case
        // `makeKeyAndOrderFront` orders the window only within our own (inactive) layer. Ordering
        // front regardless keeps the window at least visibly on top.
        window.orderFrontRegardless()
    }

    /// Activate the app ahead of a modal (`NSAlert`, `NSOpenPanel`, `NSSavePanel`) so it runs in
    /// front of whatever app the user was in.
    static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// How many editor-style windows are open. While any is, Lightshot is a regular app — Dock
    /// icon, ⌘-Tab entry, app menu — so the window can be found and switched to (spec 0004); the
    /// last one closing returns it to a menu-bar-only accessory. Counted, so closing one editor
    /// never hides another that is still open.
    private static var regularWindows = 0

    /// `present`, and while this window is open keep the app regular. Pair with
    /// `regularWindowClosed()` from the window's close hook.
    static func present(_ window: NSWindow, asRegularApp: Bool) {
        if asRegularApp {
            regularWindows += 1
            NSApp.setActivationPolicy(.regular)
        }
        present(window)
    }

    static func regularWindowClosed() {
        regularWindows = max(0, regularWindows - 1)
        if regularWindows == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}
