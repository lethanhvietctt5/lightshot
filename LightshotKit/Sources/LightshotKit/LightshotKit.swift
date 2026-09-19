import Foundation

/// Namespace + version marker for the domain core.
///
/// Everything interesting in Lightshot is a pure function over a value type; every
/// OS-facing capability hides behind a protocol. Those types land in this package as
/// their tickets are picked up (`AnnotationDocument`, `render`, `HistoryStore`, and the
/// `CaptureService` / `ImageSource` / `ImageSink` / `HotkeyService` protocols).
///
/// This file is intentionally minimal: LIG-6 only establishes the seam and a passing
/// test harness. Do not add AppKit / ScreenCaptureKit imports to this target.
public enum LightshotKit {
    /// Package version, surfaced by the app shell to prove the dependency is wired.
    public static let version = "0.0.1"
}
