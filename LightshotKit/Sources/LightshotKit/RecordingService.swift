import Foundation

/// The OS recording seam (spec 0006), fronted as a protocol so the domain core never imports
/// ScreenCaptureKit or AVFoundation.
///
/// The concrete implementation (app target, R2) streams the `RecordingOptions.region` through
/// `SCStream` into an `AVAssetWriter`; a fake in tests records the calls, which is how the
/// coordinator's routing is verified without a display. The permission surface is inherited from
/// `PermissionAuthorizing` for Screen Recording, exactly as `CaptureService` does; the extra
/// permissions recording can need (microphone, camera, input monitoring) are requested lazily by
/// their own features and surface here only as `RecordingError.permissionDenied(kind)`.
///
/// Lifecycle mirrors `RecordingSession`: the coordinator moves the session first, then asks the
/// service to do the matching OS work, so an illegal command never reaches the encoder.
public protocol RecordingService: PermissionAuthorizing {
    /// Start streaming `options.region` into a file at `url`. Returns once frames are flowing, or a
    /// typed failure — never a silently empty file. `permissionDenied` still routes to the
    /// System-Settings recovery for the named kind.
    ///
    /// `onEvent` is called from any thread for things that happen mid-take: `.failed` at most once
    /// if the stream dies (the display goes away, permission is revoked, the writer fails) — the
    /// service has already torn itself down, and the coordinator fails the session and routes the
    /// error; `.audioInputLost` if the microphone disappears — the service keeps recording video
    /// and the coordinator asks whether to continue without audio or stop. Neither is sent for
    /// failures `start` or `stop` return directly.
    func start(
        _ options: RecordingOptions,
        writingTo url: URL,
        onEvent: @escaping @Sendable (RecordingEvent) -> Void
    ) async -> Result<Void, RecordingError>

    /// Stop feeding frames and audio without ending the file (story 13).
    func pause() async

    /// Continue feeding frames after `pause()`.
    func resume() async

    /// Finalise the file and return its URL, or a typed failure if the writer could not finish.
    func stop() async -> Result<URL, RecordingError>

    /// Tear the stream down without finalising and delete whatever was written. The service owns
    /// its partial files on every path that ends without a finished file (cancel, a failed stop,
    /// a stream death); the coordinator never has to clean up after it.
    func cancel() async
}

/// Something that happened to a take in progress, reported by `RecordingService`.
public enum RecordingEvent: Equatable, Sendable {
    /// The stream died; the service has torn itself down.
    case failed(RecordingError)
    /// The microphone was disconnected mid-take (story 24); video continues.
    case audioInputLost
}

/// Where a finished recording goes (spec 0006, stories 32–34): the file-level counterpart of
/// `ImageSink`. Recordings are files on disk from the moment they finish, so the sink moves and
/// references files rather than encoding pixels.
public protocol MediaSink {
    /// Put a file reference on the pasteboard so it pastes into Finder, Slack, Mail.
    func copyFile(at url: URL)

    /// Move a finished recording to its final destination (the default save location + filename
    /// pattern, or a Save-As choice), replacing nothing silently — a collision is an error.
    func save(_ url: URL, to destination: URL) throws

    /// Throw a recording away (story 32's Delete): to the Trash where the OS offers one.
    func trash(_ url: URL) throws

    /// Remove a scratch file the user never saw (the MP4 behind a converted GIF, a partial): gone
    /// for good, not to the Trash.
    func delete(_ url: URL) throws

    /// Copy a history-owned recording to its destination (story 39: history keeps the original),
    /// replacing nothing silently — a collision is an error.
    func copy(_ url: URL, to destination: URL) throws
}

/// What only the app can read about a finished video (spec 0006, story 39): its frame size from
/// the asset's video track, its length, and a first-frame thumbnail — the store never guesses
/// these from the thumbnail.
public struct VideoMetadata: Equatable, Sendable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: TimeInterval
    public let thumbnailPNG: Data

    public init(pixelWidth: Int, pixelHeight: Int, duration: TimeInterval, thumbnailPNG: Data) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.thumbnailPNG = thumbnailPNG
    }
}

/// The AVFoundation seam behind history's video records (story 39).
public protocol MediaMetadataSource: Sendable {
    /// `nil` when the file cannot be read as a video.
    func videoMetadata(for url: URL) async -> VideoMetadata?
}

/// A finished take waiting in the post-recording overlay (stories 32–34): still in the scratch
/// directory until Save, a dismissal (which saves) or Delete decides where it goes.
public struct PendingRecording: Equatable, Sendable {
    public let file: URL
    public let kind: RecordingOutputKind
    public let duration: TimeInterval
    /// Set once the take is in history (story 39): the file is history's, so Save copies it out
    /// and Delete removes the record.
    public let historyRecordID: UUID?
    /// A take that just finished (`true`) or a history item reopened in the overlay (`false`, so
    /// a dismissal keeps nothing more than it already has).
    public let isNew: Bool

    public init(file: URL, kind: RecordingOutputKind, duration: TimeInterval, historyRecordID: UUID? = nil, isNew: Bool = true) {
        self.file = file
        self.kind = kind
        self.duration = duration
        self.historyRecordID = historyRecordID
        self.isNew = isNew
    }
}
