import SwiftUI
import LightshotKit

/// The menu-bar app shell (the OS side of the seam).
///
/// It depends on `LightshotKit`; the package never depends back. Concrete
/// ScreenCaptureKit / AppKit implementations of the domain protocols land here as their
/// tickets are picked up. For LIG-6 this is a stub menu that only proves the app launches
/// as a menu-bar (accessory) app and that the domain package is linked.
@main
struct LightshotApp: App {
    var body: some Scene {
        MenuBarExtra("Lightshot", systemImage: "camera.viewfinder") {
            LightshotMenu()
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct LightshotMenu: View {
    var body: some View {
        // Capture actions are wired in later tickets (fullscreen LIG-7, area LIG-13,
        // window LIG-14). These are inert stubs so the menu is demoable today.
        Button("Capture Area…") {}
            .disabled(true)
        Button("Capture Window…") {}
            .disabled(true)
        Button("Capture Fullscreen") {}
            .disabled(true)

        Divider()

        Text("Lightshot — core v\(LightshotKit.version)")

        Divider()

        Button("Quit Lightshot") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
