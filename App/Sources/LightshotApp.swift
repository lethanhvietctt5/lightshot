import SwiftUI
import AppKit
import LightshotKit

/// The menu-bar app shell (the OS side of the seam).
///
/// It depends on `LightshotKit`; the package never depends back. The `AppController` owns the
/// `AppCoordinator` and the concrete ScreenCaptureKit / AppKit implementations of the domain
/// protocols. For LIG-7 the fullscreen spine is live — capture → editor → copy — while the
/// area/window actions remain inert stubs until their tickets land.
@main
struct LightshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Lightshot", systemImage: "camera.viewfinder") {
            LightshotMenu(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Holds the `AppController` so it lives for the app's lifetime and is reachable from the menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()
}

private struct LightshotMenu: View {
    let controller: AppController

    var body: some View {
        // The fullscreen spine is wired (LIG-7). Area (LIG-13) and window (LIG-14) capture stay
        // inert until their tickets land.
        Button("Capture Area…") {}
            .disabled(true)
        Button("Capture Window…") {}
            .disabled(true)
        Button("Capture Fullscreen") {
            controller.captureFullscreen()
        }
        .keyboardShortcut("3", modifiers: [.command, .shift])

        Divider()

        Text("Lightshot — core v\(LightshotKit.version)")

        Divider()

        Button("Quit Lightshot") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
