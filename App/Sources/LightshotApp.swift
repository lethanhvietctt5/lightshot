import SwiftUI
import AppKit
import LightshotKit

/// The menu-bar app shell (the OS side of the seam).
///
/// It depends on `LightshotKit`; the package never depends back. The `AppController` owns the
/// `AppCoordinator` and the concrete ScreenCaptureKit / AppKit implementations of the domain
/// protocols; the `StatusMenuController` owns the menu-bar item and its CleanShot-style menu
/// (spec 0005).
@main
struct LightshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The real status item is the AppKit one in `AppDelegate` (an `NSMenu` can carry the icons
        // and live shortcuts CleanShot's menu has; `MenuBarExtra`'s menu can't). SwiftUI still needs
        // a scene to run the app lifecycle, so this one is declared but never inserted.
        MenuBarExtra("Lightshot", systemImage: "camera.viewfinder", isInserted: .constant(false)) {
            EmptyView()
        }
    }
}

/// Holds the `AppController` so it lives for the app's lifetime, and the status item that fronts it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenuController(controller: controller)
        // Claim the persisted global hotkeys up front so shortcuts fire before the settings window
        // is ever opened (story 56).
        controller.registerStoredHotkeys()
        // Guide the user through granting the permissions capture needs, the first time they launch
        // (LIG-21). A no-op once every required permission is granted.
        controller.showPermissionOnboardingIfNeeded()
        // Surface any take a crashed session left behind (spec 0006, story 18).
        controller.recoverOrphanedRecordings()
    }
}
