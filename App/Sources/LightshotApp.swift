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
        controller.applyStoredAppearance()
        statusMenu = StatusMenuController(controller: controller)
        // Claim the persisted global hotkeys up front so shortcuts fire before the settings window
        // is ever opened (story 56).
        controller.registerStoredHotkeys()
        // Guide the user through granting the permissions capture needs, the first time they launch
        // (LIG-21). A no-op once every required permission is granted.
        controller.showPermissionOnboardingIfNeeded()
        // Surface any take a crashed session left behind (spec 0006, story 18).
        controller.recoverOrphanedRecordings()
        #if DEBUG
        // Development aid (spec 0008): `-previewAppearance light|dark` draws this launch in one
        // appearance; `-previewSurface <name> [-previewFile <path>]` opens one surface to look at.
        if let appearance = UserDefaults.standard.string(forKey: "previewAppearance") {
            AppAppearance.apply(AppearancePreference(storedValue: appearance))
        }
        if let surface = UserDefaults.standard.string(forKey: "previewSurface") {
            let file = UserDefaults.standard.string(forKey: "previewFile").map { URL(fileURLWithPath: $0) }
            controller.debugPreviewSurface(surface, file: file)
        }
        // Development aid: `-previewRecordingControls YES` shows the controls pill as during a take.
        if UserDefaults.standard.bool(forKey: "previewRecordingControls") { controller.debugShowRecordingControls() }
        if UserDefaults.standard.string(forKey: "previewDevicePicker") != nil { controller.toggleRecording() }
        // Development aid: `-openStudioProject <folder>` opens a studio project at launch, so the
        // Studio editor can be exercised without recording a take.
        if let path = UserDefaults.standard.string(forKey: "openStudioProject") {
            let url = URL(fileURLWithPath: path)
            if ["mp4", "mov"].contains(url.pathExtension.lowercased()) {
                let input = StudioTake.inputURL(forScreen: url)
                controller.openVideoEditor(at: url, input: FileManager.default.fileExists(atPath: input.path) ? input : nil)
            } else {
                controller.openStudioProject(at: url)
            }
            let seek = UserDefaults.standard.double(forKey: "studioSeek")
            let panel = UserDefaults.standard.string(forKey: "studioPanel")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [controller] in
                if seek > 0 { controller.debugSeekStudio(to: seek) }
                if let panel { controller.debugStudioPanel(panel) }
            }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.keepPendingRecordingOnQuit()
    }
}
