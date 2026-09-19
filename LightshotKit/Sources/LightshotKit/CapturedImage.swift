import Foundation

/// The source-agnostic image value that flows through the whole app.
///
/// Both a fresh capture (`CaptureService`) and an opened file (`ImageSource`) resolve to
/// the *same* `CapturedImage`, so the editor entry point `openEditor(with:)` never needs
/// to know where the pixels came from. It is a pure value type carrying raw bytes and the
/// native pixel dimensions — no AppKit `NSImage`, so the domain core stays framework-free.
///
/// Stubbed here for the seam; the capture/open tickets (LIG-7, LIG-16) flesh out how the
/// bytes are produced. Element geometry elsewhere is expressed in *these* image pixel
/// coordinates.
public struct CapturedImage: Equatable, Sendable {
    /// Native (Retina) pixel width.
    public var pixelWidth: Int
    /// Native (Retina) pixel height.
    public var pixelHeight: Int
    /// Encoded image bytes (PNG in v1). Kept opaque so the core avoids image frameworks.
    public var data: Data

    public init(pixelWidth: Int, pixelHeight: Int, data: Data) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.data = data
    }
}
