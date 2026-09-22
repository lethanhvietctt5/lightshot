import Foundation

/// The pure state machine behind one recording (spec 0006, stories 2, 12–14, 18).
///
/// A value type with no clock and no OS: every transition takes the current time (in seconds)
/// from the caller, so elapsed-time arithmetic across pauses is tested with injected values, and
/// every command either moves the state or throws `IllegalTransition` **without mutating** — the
/// app never has to guess what a stray "pause" while idle did. The coordinator drives this from
/// hotkeys, the controls pill and the `RecordingService`'s callbacks; only the session decides what
/// is legal.
///
/// ```
/// idle → countdown → recording ⇄ paused → stopping → finished(URL) | failed(RecordingError)
/// ```
///
/// Two take-ending transitions sit beside the happy path (implementation decision "restart and
/// discard are transitions, not side channels"): `restart` (from recording/paused) throws the
/// partial file away, resets the timer and goes back to `countdown` — or straight to `recording`
/// when no countdown is configured; `discard` (from countdown/recording/paused) throws the partial
/// file away and ends in `idle`. `stop` from `countdown` behaves like `discard`, since nothing has
/// been written. Both hand back the partial file's URL so the caller deletes it; the session never
/// touches disk. Only `stopping → finished(URL)` produces a file the rest of the app ever sees.
public struct RecordingSession: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case countdown
        case recording
        case paused
        case stopping
        case finished(URL)
        case failed(RecordingError)
    }

    /// Every command the session understands — named in `IllegalTransition` so a rejected call
    /// says exactly what was attempted from where.
    public enum Command: String, Equatable, Sendable {
        case start, beginRecording, pause, resume, stop, finish, fail, restart, discard
    }

    /// A command that is not legal from the current state. The session is unchanged.
    public struct IllegalTransition: Error, Equatable, Sendable {
        public let state: State
        public let command: Command
    }

    /// What `stop` did: entered `stopping` (the writer is finalising) or, from `countdown`, ended
    /// the take like `discard`, handing back the partial file to delete.
    public enum StopOutcome: Equatable, Sendable {
        case stopping
        case discarded(partialFile: URL)
    }

    public private(set) var state: State = .idle
    /// The options this take runs with; `nil` while idle.
    public private(set) var options: RecordingOptions?
    /// Where the writer is putting the file; `nil` while idle.
    public private(set) var outputURL: URL?

    /// Seconds recorded in earlier segments (before the current pause or the current run).
    private var recordedBeforeSegment: TimeInterval = 0
    /// When the current recording segment began; `nil` unless `recording`.
    private var segmentStart: TimeInterval?

    public init() {}

    /// True from `countdown` until the take ends (`finished`, `failed`, or back to `idle`).
    public var isActive: Bool {
        switch state {
        case .countdown, .recording, .paused, .stopping: return true
        case .idle, .finished, .failed: return false
        }
    }

    /// Seconds of footage so far, excluding paused intervals (story 11's timer). While recording
    /// the open segment is measured against `now`; otherwise only completed segments count.
    public func elapsed(at now: TimeInterval) -> TimeInterval {
        if case .recording = state, let start = segmentStart {
            return recordedBeforeSegment + max(0, now - start)
        }
        return recordedBeforeSegment
    }

    // MARK: - Transitions

    /// Begin a take. Legal from `idle`, `finished` and `failed` (a finished take is over; starting
    /// again needs no explicit reset). Goes to `countdown` when the options ask for one, otherwise
    /// straight to `recording` with the clock starting at `now`.
    public mutating func start(_ options: RecordingOptions, writingTo url: URL, at now: TimeInterval) throws {
        switch state {
        case .idle, .finished, .failed: break
        default: throw IllegalTransition(state: state, command: .start)
        }
        self.options = options
        self.outputURL = url
        resetClock()
        enterRecordingOrCountdown(options, at: now)
    }

    /// The countdown reached zero: `countdown → recording`, clock starts at `now`.
    public mutating func beginRecording(at now: TimeInterval) throws {
        guard state == .countdown else { throw IllegalTransition(state: state, command: .beginRecording) }
        state = .recording
        segmentStart = now
    }

    /// `recording → paused`. The open segment is banked into the elapsed total.
    public mutating func pause(at now: TimeInterval) throws {
        guard state == .recording else { throw IllegalTransition(state: state, command: .pause) }
        bankSegment(at: now)
        state = .paused
    }

    /// `paused → recording`. A new segment opens at `now`; the pause itself is not counted.
    public mutating func resume(at now: TimeInterval) throws {
        guard state == .paused else { throw IllegalTransition(state: state, command: .resume) }
        state = .recording
        segmentStart = now
    }

    /// End the take. From `recording`/`paused` this enters `stopping` and the caller finalises the
    /// writer, then calls `finish(_:)`. From `countdown` nothing was written, so it behaves like
    /// `discard` and returns the partial file to delete.
    public mutating func stop(at now: TimeInterval) throws -> StopOutcome {
        switch state {
        case .recording:
            bankSegment(at: now)
            state = .stopping
            return .stopping
        case .paused:
            state = .stopping
            return .stopping
        case .countdown:
            let url = try discard()
            return .discarded(partialFile: url)
        default:
            throw IllegalTransition(state: state, command: .stop)
        }
    }

    /// The writer finalised the file: `stopping → finished(url)`.
    public mutating func finish(_ url: URL) throws {
        guard state == .stopping else { throw IllegalTransition(state: state, command: .finish) }
        state = .finished(url)
        outputURL = url
    }

    /// The service reported a failure at `now`. Legal from any active state; the open segment is
    /// banked so the elapsed total survives for diagnostics. Whether a partial file is recoverable
    /// is the crash-recovery path's concern (R5).
    public mutating func fail(_ error: RecordingError, at now: TimeInterval) throws {
        guard isActive else { throw IllegalTransition(state: state, command: .fail) }
        bankSegment(at: now)
        state = .failed(error)
    }

    /// Throw the current take away and begin again with the same options (story 14). Legal from
    /// `recording` and `paused`. The timer resets to zero and the session re-enters `countdown` (or
    /// `recording` when no countdown is configured). Returns the partial file the caller must
    /// delete.
    @discardableResult
    public mutating func restart(at now: TimeInterval) throws -> URL {
        guard state == .recording || state == .paused,
              let options, let url = outputURL
        else { throw IllegalTransition(state: state, command: .restart) }
        resetClock()
        enterRecordingOrCountdown(options, at: now)
        return url
    }

    /// Throw the current take away and end the session (story 14). Legal from `countdown`,
    /// `recording` and `paused`; ends in `idle` — no history entry, no post-recording overlay.
    /// Returns the partial file the caller must delete.
    @discardableResult
    public mutating func discard() throws -> URL {
        switch state {
        case .countdown, .recording, .paused: break
        default: throw IllegalTransition(state: state, command: .discard)
        }
        guard let url = outputURL else { throw IllegalTransition(state: state, command: .discard) }
        state = .idle
        options = nil
        outputURL = nil
        resetClock()
        return url
    }

    // MARK: - Internals

    private mutating func enterRecordingOrCountdown(_ options: RecordingOptions, at now: TimeInterval) {
        if options.hasCountdown {
            state = .countdown
        } else {
            state = .recording
            segmentStart = now
        }
    }

    private mutating func resetClock() {
        recordedBeforeSegment = 0
        segmentStart = nil
    }

    private mutating func bankSegment(at now: TimeInterval) {
        if let start = segmentStart {
            recordedBeforeSegment += max(0, now - start)
        }
        segmentStart = nil
    }
}
