import AppKit
import Carbon.HIToolbox
import LightshotKit

/// Carbon-backed `HotkeyService` (the OS side of the global-hotkey seam, story 56).
///
/// `RegisterEventHotKey` remains the supported way to claim a *system-wide* hotkey from a menu-bar
/// app without accessibility permissions — SwiftUI `keyboardShortcut` only fires while the app is
/// active. A thin, untested OS wrapper: it maps the pure `HotkeyBindings` onto Carbon registrations,
/// dispatches presses back to a handler on the main actor, and reports any chord it couldn't claim.
@MainActor
final class CarbonHotkeyService: HotkeyService {
    private struct Registration {
        let ref: EventHotKeyRef
        let action: CaptureAction
    }

    private var registrations: [Registration] = []
    private var actionByID: [UInt32: CaptureAction] = [:]
    private var handler: ((CaptureAction) -> Void)?
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    /// Carbon signature for our hotkey IDs (`'LGHK'`), keeping our presses distinct from any other
    /// hotkeys installed in the process.
    private static let signature: OSType = 0x4C47_484B  // 'LGHK'

    func register(_ bindings: HotkeyBindings, handler: @escaping (CaptureAction) -> Void) -> [CaptureAction] {
        unregisterAll()
        self.handler = handler
        installEventHandlerIfNeeded()

        var failed: [CaptureAction] = []
        for (action, binding) in bindings.assignments.sorted(by: { $0.key < $1.key }) {
            let id = nextID
            nextID += 1
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)

            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode),
                Self.carbonModifiers(binding.modifiers),
                hotKeyID,
                GetEventDispatcherTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                registrations.append(Registration(ref: ref, action: action))
                actionByID[id] = action
            } else {
                failed.append(action)
            }
        }
        return failed
    }

    func unregisterAll() {
        for registration in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
        actionByID.removeAll()
    }

    // MARK: - Dispatch

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                // Carbon delivers hotkey presses on the main run loop, so we're already on the main
                // thread — assume the isolation rather than hopping and losing the synchronous press.
                MainActor.assumeIsolated {
                    let service = Unmanaged<CarbonHotkeyService>.fromOpaque(userData).takeUnretainedValue()
                    service.fire(id: hotKeyID.id)
                }
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &eventHandler
        )
    }

    private func fire(id: UInt32) {
        guard let action = actionByID[id] else { return }
        handler?(action)
    }

    /// Maps our OS-agnostic modifiers onto Carbon's flag masks.
    private static func carbonModifiers(_ modifiers: HotkeyModifiers) -> UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { mask |= UInt32(shiftKey) }
        if modifiers.contains(.option) { mask |= UInt32(optionKey) }
        if modifiers.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }
}
