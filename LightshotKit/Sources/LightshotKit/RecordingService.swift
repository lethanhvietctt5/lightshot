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
    func start(_ options: RecordingOptions, writingTo url: URL) async -> Result<Void, RecordingError>

    /// Stop feeding frames and audio without ending the file (story 13).
    func pause() async

    /// Continue feeding frames after `pause()`.
    func resume() async

    /// Finalise the file and return its URL, or a typed failure if the writer could not finish.
    func stop() async -> Result<URL, RecordingError>

    /// Tear the stream down without finalising. The partial file is the caller's to delete — the
    /// session hands its URL back from `discard`/`restart`.
    func cancel() async
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
}
