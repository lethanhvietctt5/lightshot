import CoreGraphics
import Foundation

/// The desktop at the moment a capture or OCR Text starts (spec 0011, Freeze Screen): a still of
/// every display, plus — for Capture Window — each candidate window's own clean image. The
/// selection overlay shows it as its backdrop, and the result is taken from it, so what the user
/// selected is exactly what they get. It lives only for the length of one capture: never stored,
/// written to disk or recorded in history.
///
/// Frames are in **global screen points**, top-left origin at the primary display's top-left —
/// the space `CaptureRegion` uses. Stills and window images may be in any ImageIO-readable
/// encoding (the app freezes to uncompressed TIFF for speed); anything taken from them is PNG.
public struct FrozenScreen: Equatable, Sendable {
    /// Every display's still.
    public var displays: [FrozenDisplay]
    /// The window picker's candidates at the trigger, front-most first.
    public var windows: [FrozenWindow]

    public init(displays: [FrozenDisplay], windows: [FrozenWindow]) {
        self.displays = displays
        self.windows = windows
    }

    /// What `region` shows in the frozen screen, as a PNG capture — `nil` when there is nothing to
    /// take (a rect that touches no display, a window with no frozen image, a display region).
    ///
    /// A rect is cut from the still of the display it overlaps most, clamped to that display, with
    /// the same math as the live rect capture: scale to that display's pixels (origin floored, size
    /// rounded), clamp to the still — so a frozen area and a live area of one rect match in size.
    public func image(of region: CaptureRegion) -> CapturedImage? {
        switch region {
        case let .rect(rect):
            let selection = rect.standardized
            guard let display = displays.max(by: { overlap($0.frame, selection) < overlap($1.frame, selection) }),
                  overlap(display.frame, selection) > 0
            else { return nil }
            return display.crop(selection)
        case let .window(id, _):
            guard let image = windows.first(where: { $0.id == id })?.image,
                  let decoded = decodeImage(image.data)
            else { return nil }
            return CapturedImage(pixelWidth: decoded.width, pixelHeight: decoded.height, data: encodePNG(decoded))
        case .display:
            return nil
        }
    }

    /// Give each window its own image from `images` (by window id), as `freezeWindowImages()`
    /// returns them; a window missing from `images` keeps no image and is captured live if picked.
    public mutating func setWindowImages(_ images: [UInt32: CapturedImage]) {
        for index in windows.indices {
            windows[index].image = images[windows[index].id]
        }
    }

    /// The area two rects share, `0` when they don't meet.
    private func overlap(_ a: Rect, _ b: Rect) -> Double {
        let width = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let height = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return width > 0 && height > 0 ? width * height : 0
    }
}

/// One display's still at the trigger.
public struct FrozenDisplay: Equatable, Sendable {
    /// The window server's `CGDirectDisplayID`, as `UInt32` exactly as `CaptureRegion.display` is.
    public var displayID: UInt32
    /// The display's frame in global screen points (top-left origin).
    public var frame: Rect
    /// The still at the display's native pixels. Its point→pixel scale comes from its size against
    /// `frame`, so the two can never disagree.
    public var image: CapturedImage

    public init(displayID: UInt32, frame: Rect, image: CapturedImage) {
        self.displayID = displayID
        self.frame = frame
        self.image = image
    }

    /// The still's pixels under `selection` (global points), clamped to this display.
    fileprivate func crop(_ selection: Rect) -> CapturedImage? {
        guard frame.width > 0, let still = decodeImage(image.data) else { return nil }
        let scale = Double(still.width) / frame.width
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

/// A window picker candidate at the trigger: where it was, and — for Capture Window — its own
/// clean image from that moment (shadow trimmed, nothing overlapping it).
public struct FrozenWindow: Equatable, Sendable {
    /// The window server's `CGWindowID`, as `UInt32` exactly as `CaptureRegion.window` carries it.
    public var id: UInt32
    /// The window's frame in global screen points (top-left origin).
    public var frame: Rect
    /// The window's own image, or `nil` when it wasn't grabbed (an area freeze, or a grab that
    /// failed) — the coordinator then captures the window live.
    public var image: CapturedImage?

    public init(id: UInt32, frame: Rect, image: CapturedImage?) {
        self.id = id
        self.frame = frame
        self.image = image
    }
}
