import AppKit
import Carbon.HIToolbox
import LightshotKit

/// The OS side of `InputEventSource` for the keyboard (spec 0006, stories 30–31): a **listen-only**
/// `CGEvent` tap for key-downs and modifier changes, which macOS gates behind Input Monitoring
/// (requested lazily when the toggle is first switched on, story 41). The tap never modifies or
/// swallows an event. It runs its own run loop on a background thread so key delivery is
/// independent of the main thread.
///
/// Story 31: every event also reports whether secure event input is on — macOS turns it on
/// system-wide while a password field has focus and withholds those keystrokes from taps — so the
/// overlay model blacks out conservatively, whatever was delivered.
final class KeyEventTap: InputEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var session: Session?

    /// One tap's lifetime: the mach port, its run-loop source and the thread spinning it.
    private final class Session {
        let onEvent: @Sendable (InputEvent) -> Void
        var tap: CFMachPort?
        var runLoop: CFRunLoop?

        init(onEvent: @escaping @Sendable (InputEvent) -> Void) { self.onEvent = onEvent }

        func handle(_ type: CGEventType, _ event: CGEvent) {
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                // macOS disables a slow tap; ours only forwards, so re-enable and carry on.
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            case .keyDown:
                onEvent(.key(.secureInput(IsSecureEventInputEnabled())))
                let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let characters = NSEvent(cgEvent: event)?.charactersIgnoringModifiers
                guard let label = KeyLabel.label(keyCode: keyCode, characters: characters) else { return }
                onEvent(.key(.keyDown(KeyPress(label: label, modifiers: KeyModifiers(event.flags), isRepeat: isRepeat))))
            case .flagsChanged:
                onEvent(.key(.secureInput(IsSecureEventInputEnabled())))
                onEvent(.key(.modifiersChanged(KeyModifiers(event.flags))))
            default:
                break
            }
        }
    }

    func start(onEvent: @escaping @Sendable (InputEvent) -> Void) {
        stop()
        let session = Session(onEvent: onEvent)
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let info = Unmanaged.passRetained(session).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                Unmanaged<Session>.fromOpaque(info).takeUnretainedValue().handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: info
        ) else {
            // No Input Monitoring grant (the toolbar gate should have caught it): nothing to show.
            Unmanaged<Session>.fromOpaque(info).release()
            return
        }
        session.tap = tap
        lock.lock()
        self.session = session
        lock.unlock()

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let thread = Thread {
            let runLoop = CFRunLoopGetCurrent()
            session.runLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
            CFMachPortInvalidate(tap)
            Unmanaged<Session>.fromOpaque(info).release()
        }
        thread.name = "dev.lightshot.keytap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        guard let session else { return }
        if let tap = session.tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop = session.runLoop { CFRunLoopStop(runLoop) }
    }
}

extension KeyModifiers {
    init(_ flags: CGEventFlags) {
        var result: KeyModifiers = []
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskSecondaryFn) { result.insert(.function) }
        self = result
    }
}
