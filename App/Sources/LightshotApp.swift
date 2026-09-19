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

        // The settings window (story 60), reachable from the menu's Settings… item and ⌘,.
        Settings {
            SettingsView(model: appDelegate.controller.settingsModel)
        }
    }
}

/// Holds the `AppController` so it lives for the app's lifetime and is reachable from the menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Claim the persisted global hotkeys up front so shortcuts fire before the settings window
        // is ever opened (story 56).
        controller.registerStoredHotkeys()
    }
}

private struct LightshotMenu: View {
    let controller: AppController

    var body: some View {
        // Fullscreen (LIG-7), area (LIG-13), and window (LIG-14) capture are all wired. No
        // `.keyboardShortcut` here on purpose: these are just click targets. The authoritative,
        // *rebindable* shortcuts are the global hotkeys registered via `HotkeyService` (story 56) —
        // a static menu equivalent would duplicate `HotkeyBindings`' defaults and then silently lie
        // once the user rebinds one.
        Button("Capture Area…") {
            controller.captureArea()
        }
        Button("Capture Window…") {
            controller.captureWindow()
        }
        fullscreenCaptureItem

        // Re-fire the most recently used capture mode (story 9). A no-op until the first capture, so
        // it's always present rather than appearing and disappearing.
        Button("Repeat Last Capture") {
            controller.repeatLast()
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        // Open an existing image to annotate (LIG-16): file picker → same editor as a capture.
        Button("Open Image…") {
            controller.openFile()
        }
        .keyboardShortcut("o", modifiers: [.command])

        Divider()

        Button("History…") {
            controller.showHistory()
        }
        .keyboardShortcut("y", modifiers: [.command, .shift])

        Divider()

        Text("Lightshot — core v\(LightshotKit.version)")

        Divider()

        Button("Quit Lightshot") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Fullscreen capture, with a per-display submenu on a multi-monitor setup (story 8): a single
    /// display keeps the plain one-click action, so the common case stays simple.
    @ViewBuilder
    private var fullscreenCaptureItem: some View {
        let displays = controller.availableDisplays()
        if displays.count > 1 {
            Menu("Capture Fullscreen") {
                ForEach(displays) { display in
                    Button(display.name) {
                        controller.captureFullscreen(displayID: display.id)
                    }
                }
            }
        } else {
            Button("Capture Fullscreen") {
                controller.captureFullscreen()
            }
        }
    }
}
