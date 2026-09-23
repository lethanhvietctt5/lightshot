import AppKit
import Carbon.HIToolbox
import LightshotKit

/// The menu-bar status item and its drop-down menu, styled after CleanShot X (spec 0005).
///
/// An AppKit `NSStatusItem` + `NSMenu` rather than SwiftUI's `MenuBarExtra`, because the CleanShot
/// look needs three things `MenuBarExtra` can't give: a 24 pt template icon on every capture item
/// (which is what makes the rows tall), a per-row shortcut that mirrors the *current* global hotkey
/// rather than a static `.keyboardShortcut`, and a menu rebuilt each time it opens so a rebound hotkey
/// or a newly attached display shows up immediately.
///
/// The shortcuts shown here are display-only: a status-item menu is outside the key-equivalent
/// responder path, so the authoritative bindings remain the global hotkeys registered through
/// `HotkeyService` (story 56). This just makes the menu tell the truth about them.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let controller: AppController
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var recordingTimer: Timer?

    init(controller: AppController) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        showIdleStatusItem()
        menu.delegate = self
        statusItem.menu = menu

        // While recording, the status item becomes the stop button with the elapsed time (story 11).
        controller.recordingStateObserver = { [weak self] session in
            self?.recordingStateDidChange(session)
        }
    }

    // MARK: - Recording indicator (spec 0006, story 11)

    private func recordingStateDidChange(_ session: RecordingSession) {
        if session.isActive {
            showRecordingStatusItem()
        } else {
            showIdleStatusItem()
        }
    }

    private func showIdleStatusItem() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        statusItem.length = NSStatusItem.squareLength
        let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Lightshot")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "Lightshot"
        statusItem.button?.contentTintColor = nil
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        statusItem.menu = menu
    }

    /// A red stop glyph and `mm:ss`; clicking stops the take directly instead of opening the menu.
    /// The glyph is drawn red itself (not through `contentTintColor`, which the macOS 26+ menu
    /// bar ignores, leaving glyph and time black on a dark bar); the time keeps the menu bar's own
    /// text colour, so it reads on a light or dark bar like every other item.
    private func showRecordingStatusItem() {
        guard recordingTimer == nil else { return }
        statusItem.length = NSStatusItem.variableLength
        let red = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let icon = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop Recording")?
            .withSymbolConfiguration(red)
        icon?.isTemplate = false
        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.contentTintColor = nil
        statusItem.button?.toolTip = "Stop Recording"
        statusItem.menu = nil
        statusItem.button?.target = self
        statusItem.button?.action = #selector(stopRecordingClicked)
        refreshRecordingTimer()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRecordingTimer() }
        }
        // `.common` so the clock keeps ticking while a menu or modal alert is open.
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    private func refreshRecordingTimer() {
        guard controller.showsRecordingTimeInMenuBar else {
            statusItem.button?.title = ""
            return
        }
        let seconds = Int(controller.recordingElapsed.rounded(.down))
        statusItem.button?.title = String(format: " %02d:%02d", seconds / 60, seconds % 60)
    }

    #if DEBUG
    /// Development aid: the recording look of the status item, without a take.
    func debugShowRecordingItem() { showRecordingStatusItem() }
    #endif

    @objc private func stopRecordingClicked() {
        controller.toggleRecording()
    }

    // MARK: - NSMenuDelegate

    /// Rebuild the whole menu on every open. It is a dozen items, so this is cheaper than tracking
    /// which of hotkeys / displays / history changed since last time.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hotkeys = controller.hotkeys

        // Capture section — every item carries an icon, and its shortcut is the live hotkey.
        menu.addItem(captureItem(.area, icon: "viewfinder", hotkeys: hotkeys) { [controller] in
            controller.captureArea()
        })
        menu.addItem(captureItem(.repeatLast, icon: "arrow.clockwise", hotkeys: hotkeys) { [controller] in
            controller.repeatLast()
        })
        menu.addItem(fullscreenItem(hotkeys: hotkeys))
        menu.addItem(captureItem(.window, icon: "macwindow", hotkeys: hotkeys) { [controller] in
            controller.captureWindow()
        })
        menu.addItem(recordItem(hotkeys: hotkeys))

        menu.addItem(.separator())

        // Open an existing image to annotate (LIG-16) — CleanShot's "Open…" with the pencil.
        menu.addItem(item("Open Image…", icon: "pencil", key: "o", modifiers: .command) { [controller] in
            controller.openFile()
        })

        menu.addItem(.separator())

        menu.addItem(item("History…", icon: "clock.arrow.circlepath", key: "y", modifiers: [.command, .shift]) { [controller] in
            controller.showHistory()
        })
        if let studio = studioProjectsItem() { menu.addItem(studio) }

        menu.addItem(.separator())

        // App section — plain text rows, like CleanShot's About / Preferences.
        menu.addItem(item("About Lightshot…") { [controller] in
            controller.showAbout()
        })
        // ⌘, keeps working from the menu (spec 0002, story 34).
        menu.addItem(item("Settings…", key: ",", modifiers: .command) { [controller] in
            controller.showSettings()
        })
        // Re-open the first-run permission checklist any time (LIG-21).
        menu.addItem(item("Set Up Permissions…") { [controller] in
            controller.showPermissionOnboarding()
        })

        menu.addItem(.separator())

        menu.addItem(item("Quit Lightshot", key: "q", modifiers: .command) {
            NSApplication.shared.terminate(nil)
        })
    }

    // MARK: - Items

    /// A capture row: the action's title, its icon, and whatever chord is currently bound to it.
    private func captureItem(
        _ action: CaptureAction, title: String? = nil, icon: String, hotkeys: HotkeyBindings,
        run: @escaping () -> Void
    ) -> NSMenuItem {
        let item = item(title ?? action.title, icon: icon, run: run)
        if let binding = hotkeys[action], let (key, modifiers) = Self.keyEquivalent(for: binding) {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }

    /// Record Screen (spec 0006, stories 1–2): the same row and chord start and stop a take, so it
    /// reads "Stop Recording" with the stop glyph while one is active.
    private func recordItem(hotkeys: HotkeyBindings) -> NSMenuItem {
        let recording = controller.isRecording
        return captureItem(
            .recordScreen,
            title: recording ? "Stop Recording" : nil,
            icon: recording ? "stop.circle" : "record.circle",
            hotkeys: hotkeys
        ) { [controller] in
            controller.toggleRecording()
        }
    }

    /// Recent studio projects (spec 0007, story 4), reopened in the Studio editor; hidden until
    /// there is one.
    private func studioProjectsItem() -> NSMenuItem? {
        let projects = controller.recentStudioProjects()
        guard !projects.isEmpty else { return nil }
        let item = self.item("Studio Projects", icon: "film.stack") {}
        item.action = nil
        let submenu = NSMenu()
        for project in projects {
            submenu.addItem(self.item(project.name) { [controller] in
                controller.openStudioProject(at: project.url)
            })
        }
        item.submenu = submenu
        return item
    }

    /// Fullscreen capture, with a per-display submenu on a multi-monitor setup (story 8): a single
    /// display keeps the plain one-click row, so the common case stays simple.
    private func fullscreenItem(hotkeys: HotkeyBindings) -> NSMenuItem {
        let displays = controller.availableDisplays()
        let item = captureItem(.fullscreen, icon: "desktopcomputer", hotkeys: hotkeys) { [controller] in
            controller.captureFullscreen()
        }
        guard displays.count > 1 else { return item }

        let submenu = NSMenu()
        for display in displays {
            submenu.addItem(self.item(display.name) { [controller] in
                controller.captureFullscreen(displayID: display.id)
            })
        }
        item.submenu = submenu
        item.action = nil
        return item
    }

    private func item(
        _ title: String, icon: String? = nil, key: String = "",
        modifiers: NSEvent.ModifierFlags = [], run: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.representedObject = Action(run)
        if let icon {
            item.image = Self.menuIcon(icon)
            // macOS 27 hides menu-item images unless the item asks for them; the icons are the
            // point of this menu, so ask.
            if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
        }
        return item
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? Action)?.run()
    }

    /// A closure the menu item can carry as its `representedObject`.
    private final class Action {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    // MARK: - Icons

    /// CleanShot's menu icons are 24 × 24 pt template images; drawing each SF Symbol centred on a
    /// canvas of that size gives the same tall, evenly aligned rows regardless of glyph proportions.
    /// Rendered to bitmap reps (1× and 2×) up front: `NSMenu` does not reliably rasterise a
    /// drawing-handler image, and a template image needs real pixels to build its mask from.
    private static func menuIcon(_ symbolName: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }

        let canvas = NSSize(width: 24, height: 24)
        let image = NSImage(size: canvas)
        for scale in [1, 2] as [CGFloat] {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }
            rep.size = canvas
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let size = symbol.size
            symbol.draw(in: NSRect(
                x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                width: size.width, height: size.height
            ))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Shortcuts

    /// Translate a stored chord into what `NSMenuItem` needs to render it. Printable keys pass through
    /// as themselves; the keys the recorder labels with a glyph or a name (`Space`, `↩`, `F5`, …) are
    /// mapped from their key code to the AppKit function-key character, so the menu draws the same
    /// symbol the system does. `nil` for a key we can't name — the row simply shows no shortcut.
    private static func keyEquivalent(for binding: HotkeyBinding) -> (String, NSEvent.ModifierFlags)? {
        var flags: NSEvent.ModifierFlags = []
        if binding.modifiers.contains(.command) { flags.insert(.command) }
        if binding.modifiers.contains(.shift) { flags.insert(.shift) }
        if binding.modifiers.contains(.option) { flags.insert(.option) }
        if binding.modifiers.contains(.control) { flags.insert(.control) }

        if let special = functionKeyEquivalents[Int(binding.keyCode)] {
            return (special, flags)
        }
        // Prefer the layout's *unmodified* character for the key code, so a chord recorded as ⇧⌘4
        // reads "⇧⌘4" rather than "⇧⌘$"; fall back to the stored label when the layout can't say.
        if let key = unmodifiedCharacter(forKeyCode: binding.keyCode) {
            return (key, flags)
        }
        guard binding.keyLabel.count == 1 else { return nil }
        return (binding.keyLabel.lowercased(), flags)
    }

    /// The character the current keyboard layout produces for `keyCode` with no modifiers held.
    private static func unmodifiedCharacter(forKeyCode keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            let layout = bytes.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, chars.count, &length, &chars
            )
        }
        guard status == noErr, length == 1 else { return nil }
        let character = String(utf16CodeUnits: chars, count: 1)
        return character.rangeOfCharacter(from: .controlCharacters) == nil ? character : nil
    }

    private static let functionKeyEquivalents: [Int: String] = {
        func char(_ code: Int) -> String { String(Character(UnicodeScalar(code)!)) }
        return [
            kVK_Space: " ", kVK_Return: "\r", kVK_Tab: "\t", kVK_Delete: "\u{8}",
            kVK_ForwardDelete: char(NSDeleteFunctionKey), kVK_Home: char(NSHomeFunctionKey),
            kVK_End: char(NSEndFunctionKey), kVK_PageUp: char(NSPageUpFunctionKey),
            kVK_PageDown: char(NSPageDownFunctionKey), kVK_LeftArrow: char(NSLeftArrowFunctionKey),
            kVK_RightArrow: char(NSRightArrowFunctionKey), kVK_DownArrow: char(NSDownArrowFunctionKey),
            kVK_UpArrow: char(NSUpArrowFunctionKey),
            kVK_F1: char(NSF1FunctionKey), kVK_F2: char(NSF2FunctionKey), kVK_F3: char(NSF3FunctionKey),
            kVK_F4: char(NSF4FunctionKey), kVK_F5: char(NSF5FunctionKey), kVK_F6: char(NSF6FunctionKey),
            kVK_F7: char(NSF7FunctionKey), kVK_F8: char(NSF8FunctionKey), kVK_F9: char(NSF9FunctionKey),
            kVK_F10: char(NSF10FunctionKey), kVK_F11: char(NSF11FunctionKey), kVK_F12: char(NSF12FunctionKey),
        ]
    }()
}
