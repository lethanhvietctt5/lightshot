import CoreGraphics
import Carbon.HIToolbox
import Foundation
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

    /// Whether Input Monitoring is granted right now (no prompt).
    static var isAuthorized: Bool { CGPreflightListenEventAccess() }

    /// One tap's lifetime: the mach port, its run-loop source and the thread spinning it. The tap
    /// thread and `stop()` (any thread) both touch it, so its state sits behind a lock.
    private final class Session: @unchecked Sendable {
        let onEvent: @Sendable (InputEvent) -> Void
        private let lock = NSLock()
        private var tap: CFMachPort?
        private var runLoop: CFRunLoop?
        private var cancelled = false

        init(onEvent: @escaping @Sendable (InputEvent) -> Void) { self.onEvent = onEvent }

        func attach(_ tap: CFMachPort) {
            lock.lock(); self.tap = tap; lock.unlock()
        }

        /// Called on the tap thread just before it starts spinning: records the run loop and
        /// enables the tap, unless `stop()` already came — then the thread must not start at all,
        /// or the tap would keep listening for the rest of the process (a privacy leak, story 31).
        func begin(on runLoop: CFRunLoop) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled, let tap else { return false }
            self.runLoop = runLoop
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let tap = self.tap, runLoop = self.runLoop
            lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            if let runLoop { CFRunLoopStop(runLoop) }
        }

        func handle(_ type: CGEventType, _ event: CGEvent) {
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                // macOS disables a slow tap; ours only forwards, so re-enable and carry on.
                lock.lock(); let tap = self.tap; let cancelled = self.cancelled; lock.unlock()
                if let tap, !cancelled { CGEvent.tapEnable(tap: tap, enable: true) }
            case .keyDown:
                onEvent(.key(.secureInput(IsSecureEventInputEnabled())))
                let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                guard let label = KeyLabel.label(keyCode: keyCode, characters: Self.unmodifiedCharacters(of: event)) else { return }
                onEvent(.key(.keyDown(KeyPress(label: label, modifiers: KeyModifiers(event.flags), isRepeat: isRepeat))))
            case .flagsChanged:
                onEvent(.key(.secureInput(IsSecureEventInputEnabled())))
                onEvent(.key(.modifiersChanged(KeyModifiers(event.flags))))
            default:
                break
            }
        }

        /// What the key types with no modifier held — so ⇧1 prints "⇧1", as menus do, not "⇧!".
        private static func unmodifiedCharacters(of event: CGEvent) -> String? {
            guard let copy = event.copy() else { return nil }
            copy.flags = []
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 4)
            copy.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
            guard length > 0 else { return nil }
            return String(utf16CodeUnits: buffer, count: length)
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
            // No Input Monitoring grant (the toggle gates should have caught it): nothing to show.
            Unmanaged<Session>.fromOpaque(info).release()
            return
        }
        session.attach(tap)
        lock.lock()
        self.session = session
        lock.unlock()

        let handle = TapHandle(tap: tap, source: CFMachPortCreateRunLoopSource(nil, tap, 0), sessionRef: info)
        let thread = Thread {
            if let runLoop: CFRunLoop = CFRunLoopGetCurrent() {
                CFRunLoopAddSource(runLoop, handle.source, .commonModes)
                if session.begin(on: runLoop) { CFRunLoopRun() }
            }
            CFMachPortInvalidate(handle.tap)
            Unmanaged<Session>.fromOpaque(handle.sessionRef).release()
        }
        thread.name = "dev.lightshot.keytap"
        thread.qualityOfService = QualityOfService.userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.cancel()
    }
}

/// What the tap thread needs, handed over once at start: CoreFoundation types are thread-safe but
/// not marked `Sendable`.
private struct TapHandle: @unchecked Sendable {
    let tap: CFMachPort
    let source: CFRunLoopSource?
    let sessionRef: UnsafeMutableRawPointer
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
