import CoreGraphics
import Foundation

/// One still of a display, taken the moment a capture or OCR Text starts (spec 0011, Freeze
/// Screen). The selection overlay shows it as its backdrop, and an area result is cut from it, so
/// what the user selected is exactly what they get. It lives only for the length of one capture:
/// never stored, written to disk or recorded in history.
public struct FrozenScreen: Equatable, Sendable {
    /// The window server's `CGDirectDisplayID`, as `UInt32` exactly as `CaptureRegion.display` is.
    public var displayID: UInt32
    /// The display's frame in **screen point coordinates** (top-left origin).
    public var frame: Rect
    /// The still at the display's native pixels, in any ImageIO-readable encoding — the app uses
    /// uncompressed TIFF so freezing adds no visible delay. A cut from it is always PNG.
    public var image: CapturedImage

    public init(displayID: UInt32, frame: Rect, image: CapturedImage) {
        self.displayID = displayID
        self.frame = frame
        self.image = image
    }

    /// The frozen pixels inside `region`, at native resolution — `nil` when the selection misses
    /// the display entirely, or for a window or display region, which are never cut from a still.
    ///
    /// Same math as the live rect capture: standardize, scale to pixels (origin floored, size
    /// rounded), clamp to the image — so a frozen area and a live area of one rect match in size.
    /// The scale comes from the image and frame sizes, so the two can never disagree.
    public func image(of region: CaptureRegion) -> CapturedImage? {
        guard case let .rect(rect) = region, frame.width > 0,
              let still = decodeImage(image.data)
        else { return nil }
        let scale = Double(still.width) / frame.width
        let selection = rect.standardized
        let pixelRect = CGRect(
            x: ((selection.minX - frame.minX) * scale).rounded(.down),
            y: ((selection.minY - frame.minY) * scale).rounded(.down),
            width: (selection.width * scale).rounded(),
            height: (selection.height * scale).rounded()
        ).intersection(CGRect(x: 0, y: 0, width: still.width, height: still.height))
        guard !pixelRect.isNull, !pixelRect.isEmpty, let cropped = still.cropping(to: pixelRect) else {
            return nil
        }
        return CapturedImage(pixelWidth: cropped.width, pixelHeight: cropped.height, data: encodePNG(cropped))
    }
}
