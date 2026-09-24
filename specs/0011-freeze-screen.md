# Spec 0011 — Freeze Screen

**Status:** revised 2026-09-24 (whole-desktop freeze, frozen window capture) — see *Revision* and *As built*
**Linear:** [LIG-69](https://linear.app/light-shot/issue/LIG-69) (label `ready-for-agent`)
**Platform:** Native macOS (Swift / AppKit + SwiftUI), macOS 14+
**Scope:** Local-only. When I start Capture Area, Capture Window or OCR Text, the whole desktop freezes, as it does in CleanShot X. Every display shows a still taken the moment I triggered it, the selection overlay covers every display, and what I get comes from that moment: an area is cut from the still, and a window is the clean image of that window from that moment. It is always on, with no setting. It adds two methods to `CaptureService`, a frozen-backdrop parameter to two `OverlayController` methods, and one pure value type with its crop in the domain core. Fullscreen capture and recording are unchanged.

Vocabulary used here is defined in [`CONTEXT.md`](../CONTEXT.md). New terms (**frozen screen**, **freeze**) are defined under *Further Notes*.

Parity reference: CleanShot X's **Freeze screen** ("Freeze screen when taking a screenshot"). Its bundle has a `FreezerController` holding one `Freezer` per display, a `freezeScreenButton`, and a `freezeScreen` preference. CleanShot makes it optional. Lightshot always freezes (a user decision).

---

## Revision

The first build froze only the main display, and Capture Window grabbed the picked window live after the click. The user expected CleanShot X's behaviour, where the whole screen state is frozen. This revision:

- freezes **every connected display**, and the selection overlay covers every display;
- makes Capture Window return the picked window **as it was at the trigger**, clean, captured on its own at freeze time.

The self-timer paths are unchanged. Capture Area with a timer captures live after the countdown, and Capture Window with a timer captures the window live after the wait.

## Problem Statement

I trigger a screenshot or OCR Text because something is on screen right now: a hover tooltip, an open menu, a video frame, a notification banner, a progress state, a live-updating log. Today the selection overlay sits over the live screen. While I'm dragging, the video plays on, the log scrolls, and the tooltip or menu can vanish because the overlay takes focus. The capture fires only when I release the drag, so I get whatever the screen shows then, not what I wanted. I keep retrying, or I pause things by hand before I capture. For OCR Text this is worse: the text I wanted to copy has often scrolled away by the time I finish the drag. And the overlay only covers my main display, so I can't select anything on my other displays at all.

## Solution

When I start Capture Area, Capture Window or OCR Text (from the menu, a hotkey, or Repeat Last Capture), Lightshot first freezes the whole desktop. It takes a still of every display, and for Capture Window a clean image of every on-screen window. The selection overlay then covers every display, over those stills, not over the live screens. Nothing under the overlay moves: the video, the menu, the tooltip and the cursor stay exactly as they were when I triggered it. I drag on any display, or pick any window. An area is cut out of the still of the display I dragged on, pixel for pixel. A window is that window's clean image from the moment I triggered it, with nothing overlapping it, even if it has since changed or closed. Escape unfreezes and cancels with nothing captured. It always happens; there is no setting.

## User Stories

### Freezing on start

1. As a user, I want the screen to freeze the moment I start Capture Area, so that what I'm selecting doesn't change under me.
2. As a user, I want the screen to freeze the moment I start OCR Text, so that text scrolling in a log or chat is still there when I finish the drag.
3. As a user, I want the screen to freeze the moment I start Capture Window, so that both the picker and the window I pick are from that moment.
4. As a user, I want a playing video to stop on the frame showing when I triggered the capture, so that I can grab that exact frame.
5. As a user, I want an open menu or a hover tooltip to stay visible in the frozen screen even though the overlay has taken focus, so that I can capture transient UI.
6. As a user, I want a notification banner that was on screen when I triggered the capture to stay in the frozen screen, so that it doesn't slide away mid-drag.
7. As a user, I want the frozen screen to match the live screen exactly (same position, same scale, no shift or blur), so that freezing doesn't feel like a mode change, only a pause.
8. As a user, I want the overlay to appear just as quickly as it does today (no visible lag from freezing), so that capturing still feels instant.
9. As a user, I want freezing triggered from the hotkey, the menu-bar menu and Repeat Last Capture alike, so that it behaves the same however I start it.
10. As a user, I don't want Lightshot's own overlay, menu or notices in the frozen still, so that nothing of Lightshot's leaks into my capture.

### Every display

11. As a user with more than one display, I want every display to freeze at once, so that the whole desktop is from one moment.
12. As a user with more than one display, I want the selection overlay on every display, so that I can capture an area on any of them.
13. As a user with more than one display, I want the window picker on every display, so that I can capture a window on any of them.
14. As a user, I want an area I drag on one display to be cut from that display's still at that display's native resolution, so that mixed Retina and non-Retina setups each capture at full quality.
15. As a user, I want a drag that runs over the edge onto another display to be clamped to the display that holds most of it, so that an overshoot never fails the capture.

### Selecting on the frozen screen

16. As a user, I want the dimming, the crosshair, the selection rectangle and the pixel-size readout to work exactly as they do today, so that nothing new has to be learned.
17. As a user, I want the live pointer to stay usable over the frozen screen, so that I can still drag and aim precisely.
18. As a user, I want the area inside my selection to show the frozen screen undimmed, so that I can see exactly what will be captured.
19. As a user, I want the window picker to highlight windows at the positions they had when I triggered it, so that the highlight lines up with the frozen image.

### What gets captured

20. As a user, I want Capture Area to produce the frozen pixels inside my selection, so that the result is what I saw while selecting.
21. As a user, I want the result at full native (Retina) resolution, so that freezing costs no quality.
22. As a user, I want OCR Text to read the frozen pixels inside my selection, so that the copied text is the text I selected.
23. As a user, I want Capture Window to give me just the clicked window as it was at the trigger, cleanly, with no overlapping windows and the shadow trimmed, so that window capture keeps its point and is frozen too.
24. As a user, I want a window that changed or closed after I triggered the capture to still be captured as it was, so that the freeze really holds.
25. As a user, I want the include-cursor setting honoured in the frozen stills, so that the pointer appears in my area captures only when I asked for it.
26. As a user, I want captures of the frozen screen to go to the editor or the post-capture toolbar, into history, and through Repeat Last Capture exactly as live captures do today, so that freezing changes only what is captured, not where it goes.
27. As a user, I want the post-capture toolbar to appear next to my selection on whichever display I captured, so that it's where I'm looking.
28. As a user, I want OCR Text on the frozen screen to keep its current behaviour (clipboard, notice, no editor, no history), so that only the source pixels change.

### Unfreezing

29. As a user, I want every display to unfreeze the moment the overlay closes (confirm or Escape on any display), so that I'm never left looking at a stale image.
30. As a user, I want Escape to unfreeze and do nothing else, with no capture, no clipboard change and no notice, so that cancelling stays harmless.
31. As a user, I don't want the frozen stills or window images kept anywhere after the overlay closes (not on disk, not in history, not in memory), so that a capture I cancelled leaves no trace.

### Self-timer

32. As a user with a self-timer set, I want Capture Area to wait and then capture the live screen as it does today, so that the timer still lets me set up UI after choosing the area.
33. As a user with a self-timer set, I want Capture Window to show the frozen picker, wait, then capture the window live, so that the timer still captures a later state.

### Permissions and edge cases

34. As a first-time user, I want the Screen Recording permission prompt to come before any freeze, as it does today, so that I'm not frozen behind a system prompt.
35. As a user without the Screen Recording grant, I want triggering a capture to go straight to the permission recovery path, with no overlay and no blank frozen screen, so that I can fix the grant.
36. As a user, if the stills can't be taken for any other reason, I want the usual capture-failure message with no overlay, so that I never select over a blank or black screen.
37. As a user, I want OCR Text still ignored while a recording is active, with no freeze, so that nothing flickers over my take.
38. As a user, if I trigger a new capture while an overlay is already up, I want the old one to cancel cleanly and the new one to freeze afresh, so that I never see a stale still.
39. As a user, if a window's own image couldn't be taken at the freeze (it was too small, or it vanished mid-freeze), I want clicking it to fall back to capturing it live, with the existing "no longer available" message if it's gone, so that I never get a blank window capture.

## Implementation Decisions

### Coordinates

- **`CaptureRegion` coordinates become desktop-wide.** `.rect` and `.window`'s frame are in **global screen points, top-left origin at the primary display's top-left** (Core Graphics' global display space, the space `SCWindow.frame` and `CGDisplayBounds` already use). For a single display this is unchanged. The overlay converts from each display's local coordinates to global ones before resolving.

### Modules

- **`FrozenScreen` (new value type, domain core).** The frozen state of the desktop at the trigger:
  - `displays: [FrozenDisplay]`. Each has the display id (`UInt32`), its frame in global points, and its still at native pixels.
  - `windows: [FrozenWindow]`, front-most first. Each has the window id (`UInt32`), its frame in global points at the trigger, and its clean image, or `nil` when it wasn't grabbed.
  - The stills and window images can be any ImageIO-readable encoding. Anything cut from them is PNG.
- **Pure crop (domain core, CoreGraphics/ImageIO only, as `render` already uses).** `FrozenScreen.image(of: CaptureRegion) -> CapturedImage?`:
  - `.rect`: standardize, then pick the display the rect overlaps most. Subtract that display's origin, scale by that display's own pixel/point ratio (derived from its still and frame), floor the origin and round the size, clamp to the still, crop, and encode as PNG. `nil` when the rect touches no display or the clamp is empty.
  - `.window(id, _)`: that window's frozen image, re-encoded as PNG. `nil` when the id isn't there or it has no image.
  - `.display`: `nil` (the coordinator never passes it).
- **`CaptureService` (existing seam, two new methods).**
  - `freezeScreen() async -> Result<FrozenScreen, CaptureError>` grabs every display at once with `SCScreenshotManager`, honouring include-cursor, and leaves Lightshot's own windows above the floating level out of the stills. It also lists the on-screen, normal-layer windows of other apps with their frames (no images): these are the picker's candidates. It runs before any overlay window exists.
  - `freezeWindowImages() async -> [UInt32: CapturedImage]` grabs each candidate window on its own, concurrently, shadow trimmed. A window whose grab fails is missing from the result.
  - No deprecated `CGWindowListCreateImage`.
- **`OverlayController` (existing seam).** `selectRegion(over:)` / `selectWindow(over:)` keep their signatures. The concrete overlay now presents **one overlay window per display**:
  - With a frozen screen, each window draws its display's still as an opaque backdrop under the existing dimming and selection chrome.
  - The window picker's candidates come from the frozen screen's windows (their positions at the trigger). With no frozen screen (the self-timer area path) it enumerates live, as today.
  - A confirm or Escape on any display closes every overlay window.
  - `selectRecording` is unchanged and stays on the main display.
- **`AppCoordinator` (existing seam, no new use case).**
  - `captureArea()` (no timer) and `captureText()`: `freezeScreen()`, then `selectRegion(over:)`, then the crop. `captureRegion(_:)` is not called. A crop that comes out `nil` goes to `presentCaptureFailure`, never a blank image.
  - `captureWindow()` with no timer: start `freezeWindowImages()` and `freezeScreen()` together. The picker waits only for `freezeScreen()`; the window images are collected at the click and put into the frozen screen, and the result is the picked window's frozen image. When there's no frozen image for the picked window, it falls back to `captureRegion(_:)` live (story 39).
  - `captureWindow()` with a timer: `freezeScreen()` only, then `selectWindow(over:)`, then the wait, then `captureRegion(_:)` live.
  - `captureArea()` with a timer: no freeze. The live overlay, then the wait, then `captureRegion(_:)` live.
  - A freeze failure routes exactly as a capture failure (`permissionDenied` goes to Screen Recording recovery, `userCancelled` is silent, the rest go to `presentCaptureFailure`), and the overlay is never shown.
  - Everything downstream (history, editor vs. toolbar, Repeat Last Capture, OCR notices) is unchanged.
- **Live capture and the toolbar follow global coordinates.**
  - `SCCaptureService`'s live rect path picks the display the rect overlaps most and crops in that display's pixels.
  - Its live window path scales by the backing scale of the display holding the window.
  - The post-capture toolbar converts the global rect to AppKit coordinates and clamps to the screen that holds it.
- **Lifetime.** The frozen screen is a local in the coordinator's use case. It's dropped when the use case returns, and never stored on the coordinator, written to disk, or recorded in history.

### Settings

- None. Freezing is always on (a user decision).

## Testing Decisions

- **What makes a good test here:** assert what the user would observe through the coordinator's fakes. Which image reached the editor, toolbar, history or text recogniser. Whether the overlay was shown, and over what. Whether a live capture happened. Which error UI appeared. No test touches a screen or a permission.
- **`AppCoordinator` (primary seam), Swift Testing, extending the existing fakes.** The stub capture service counts `freezeScreen()` and `freezeWindowImages()` calls and records its `captureRegion` calls. The stub overlay records the backdrop it was given.
  - Area and OCR: freeze with no window images, the overlay gets the frozen screen, the result is its crop, and there's no live capture. Also covered: cancel, a crop that misses, freeze-failure routing, and the self-timer area path staying live.
  - Window, no timer: the window images are grabbed, and the editor gets the picked window's frozen image with no live capture. A window with no frozen image falls back to the live capture. Freeze failures route and the overlay never shows.
  - Window with a timer: no window images, the wait, then a live capture.
  - Repeat Last Capture freezes afresh, and fullscreen never freezes.
- **`FrozenScreen` crop (pure), Swift Testing, generated images.**
  - One quadrant of a 2x display. A reversed drag, an overshoot, a miss.
  - A display away from the origin.
  - Two displays side by side at different scales: a rect on the second one crops from it at its own scale, and a rect straddling both crops from the one it overlaps most, clamped.
  - Window images come out as PNG, and an unknown id or a missing image gives `nil`.
  - A TIFF still crops to PNG, and live-path rounding matches.
- **Prior art:** `AppCoordinatorTests` (stubs, area/OCR routing), `DocumentRenderTests` / `ExportTests` (generated images in the domain target).
- **App side (no unit-test target in `App/`):** verify by hand with the isolated `.verify` Debug build. The DEBUG `-previewSurface frozenArea|frozenWindow -previewFile <png>` shows the overlay on every display over a still. With the Screen Recording grant, also check:
  - a video frozen on the trigger frame;
  - an open menu captured;
  - OCR on a scrolling log;
  - a window captured as it was even after it changed;
  - a second display, if one is attached.

## Out of Scope

- A setting or toggle to turn freezing off.
- Freezing fullscreen capture (it fires with no overlay).
- Freezing the recording overlay, recording or the Studio; the recording overlay stays on the main display.
- A selection spanning two displays (it is clamped to one).
- Freezing during the self-timer paths.
- Magnifier / loupe over the frozen image.
- Any change to the editor, history or OCR text assembly.

## Further Notes

- **Glossary** (in `CONTEXT.md`):
  - **Frozen screen:** the desktop at the moment a capture or OCR Text starts: a still of every display, plus each window's own image for Capture Window. The overlay shows it as its backdrop, and results are taken from it. Never stored. _Avoid_: snapshot, freeze-frame image.
  - **Freeze:** taking the frozen screen and showing it under the overlay. _Avoid_: pause, lock.
- **Why window images are grabbed at the freeze.** Cutting the window's frame from the display still would drag in whatever overlaps it. Grabbing the window live at the click wouldn't be frozen. Grabbing every candidate window on its own at the trigger gives a clean window from the frozen moment. It's only done for Capture Window, and the picker doesn't wait for it, so no freeze is slower to appear.
- **Why the self-timer paths stay live.** The timer exists to capture a later screen, so freezing before it would make it pointless.
- **Cursor in the backdrop.** With include-cursor on, the frozen pointer shows in the backdrop next to the live crosshair, since the backdrop is exactly what the capture will contain.

## As built

- **Measured on this Mac** (one 2560 × 1440 display at 1x, five candidate windows, the verify build with the Screen Recording grant, DEBUG `-previewSurface freeze -previewFile <folder>`). A warm `freezeScreen()` took 65–86 ms, and a cold first one 145–232 ms. Grabbing the window images together with the freeze took 190–230 ms. That's why the window images are a separate call the picker doesn't wait for: done in one call, they'd have held the picker back by ~200 ms. The stills and window images were checked by eye: the display still matched the screen, and a window image was that window alone.

- **The stills are uncompressed TIFF, not PNG.** Measured offline: a PNG encode of a full-display still took 88 ms at 2940 × 1912 and 157 ms at 5120 × 2880, and the backdrop's decode added 36–69 ms. Uncompressed TIFF took 6–13 ms to encode and 4–7 ms to decode. Anything cut from a still is PNG.
- **Lightshot's own windows are left out of the stills.** The grab excludes this process's windows above the floating level: a previous overlay still closing when a new capture starts (story 38), the post-capture toolbar, the OCR notice, and the status menu. Pins (floating level) and editor windows stay in, as they do in a live capture.
- **Memory.** An uncompressed 5K still is about 59 MB. It's decoded again for the backdrop and for the crop, so peak memory is roughly 2–3× that per display while the overlay is up. Window images add their own sizes in window mode. Everything is released when the use case returns.
- **Backdrop.** Each overlay window's content view is a layer-backed container whose layer draws its display's still, with the SwiftUI overlay as a subview above it.
- **DEBUG preview.** `-previewSurface frozenArea|frozenWindow -previewFile <png>` opens the overlay on every display over a still from a file; the window picker uses the real freeze's candidates when it can list them. `-previewSurface freeze -previewFile <folder>` runs the real freeze and window grab, and writes the stills, window images and timings into the folder.
