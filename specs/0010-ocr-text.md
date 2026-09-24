# Spec 0010 — OCR Text

**Status:** implemented — see *As built* at the end for where the build refined a decision
**Linear:** [LIG-68](https://linear.app/light-shot/issue/LIG-68) (label `ready-for-agent`)
**Platform:** Native macOS (Swift / AppKit + SwiftUI), macOS 14+
**Scope:** Local-only. A new capture action, **OCR Text**, directly under Record Screen in the menu-bar menu. I drag an area of the screen, and the text in it is recognised on-device and copied to the clipboard as plain text. There's no editor and no image. Adds one coordinator use case, one small service protocol and one pure text-assembly function. Amends Spec 0005's *Out of Scope* (which listed CleanShot's Capture Text).

Vocabulary used here is defined in [`CONTEXT.md`](../CONTEXT.md). New terms (**OCR Text**, **text capture**) are defined under *Further Notes*.

Parity reference: CleanShot X's **Capture Text**. Its bundle shows the same flow (area selection → recognised text on the clipboard), a "No text detected" message, automatic language detection, and a with/without line breaks choice. We ship the "with line breaks" behaviour only.

---

## Problem Statement

I often need text that is on my screen but can't be selected: a line from a screenshot someone sent, an error in a dialog, a code sample in a video, a label in an app that blocks selection, a table in a PDF that's really an image. Today I retype it by hand, which is slow and error-prone, especially for long IDs, error codes and URLs. Lightshot can already capture the pixels, but I want the words.

## Solution

The menu-bar menu gets a new row, **OCR Text**, directly under **Record Screen**, with its own rebindable global shortcut (unbound by default). Choosing it shows the same area-selection overlay as Capture Area. When I finish the drag, Lightshot captures that area, recognises the text in it on my Mac, and puts the text on the clipboard as plain text. Lines stay on separate lines in reading order. A short notice near the bottom of the screen says "Reading text…" if recognition is slow, then a self-dismissing "Text copied" with a preview of the first line, or "No text found" when there was nothing to read. In that case the clipboard is left alone. Escape cancels without touching anything. No editor opens, nothing is saved to disk, and nothing is added to history.

## User Stories

### Starting it

1. As a user, I want an OCR Text row in the menu-bar menu directly under Record Screen, so that I find it next to the other capture actions.
2. As a user, I want the OCR Text row to carry an icon like the other capture rows, so that the menu stays scannable.
3. As a user, I want to bind a global shortcut to OCR Text in Settings, so that I can grab text without opening the menu.
4. As a user, I want OCR Text to have no shortcut until I bind one, so that Lightshot doesn't claim another global chord behind my back.
5. As a user, I want the menu row to show whatever shortcut I bound, so that the menu teaches me my own hotkey.
6. As a user, I want a shortcut that conflicts with another Lightshot action flagged in Settings, so that one chord never fires two things.

### Selecting the area

7. As a user, I want the same area-selection overlay as Capture Area, so that I don't have to learn a second way to select.
8. As a user, I want Escape (or a click without a drag) to cancel, so that nothing is copied and the clipboard keeps what it had.
9. As a user, I want the selection to work on any display, so that I can read text on a second monitor.
10. As a user, I want the capture to fire right after I release the drag, with no self-timer, so that grabbing text feels instant.

### Getting the text

11. As a user, I want the recognised text copied to the clipboard as plain text, so that I can paste it anywhere.
12. As a user, I want the text in reading order (top to bottom, then left to right), so that what I paste reads the way it looked.
13. As a user, I want each visual line on its own line, so that lists, code and addresses keep their shape.
14. As a user, I want pieces of text that sit side by side on the same row joined with a space, so that a row doesn't split into fragments.
15. As a user, I want leading and trailing whitespace trimmed, so that I don't paste stray blank lines.
16. As a user, I want recognition to detect the language automatically, so that non-English text works without settings.
17. As a user, I want recognition to run entirely on my Mac, so that what's on my screen is never sent anywhere.
18. As a user, I want it to work on Retina and non-Retina displays alike, so that small text is still read.
19. As a user, I want only the text inside my selection, so that surrounding UI doesn't leak into what I paste.

### Feedback

20. As a user, I want a short "Text copied" notice with a preview of the first line, so that I know it worked and roughly what I got.
21. As a user, I want a clear "No text found" notice when the area had nothing readable, so that I know it ran rather than silently failed.
22. As a user, I want my clipboard left untouched when no text is found, so that I don't lose what I'd copied before.
23. As a user, I want the notice to disappear on its own and never take focus, so that I can paste straight away into the app I was in.
24. As a user, I want a clear error message if recognition itself fails, so that I don't mistake a failure for an empty area.

### Permissions and edge cases

25. As a user, I want the same first-run permission guidance as a screenshot, so that OCR Text isn't the one feature that fails mysteriously on a fresh install.
26. As a user, I want the Screen Recording recovery path if the permission is missing, so that I know how to fix it.
27. As a user, I want OCR Text unavailable while a recording is in progress, so that the selection overlay never ends up in my take.
28. As a user, I want OCR Text to leave Repeat Last Capture alone, so that repeating still re-takes my last screenshot rather than re-running OCR.
29. As a user, I want OCR Text to add nothing to History, so that the image history holds only images I captured.
30. As a user, I want no file written anywhere, so that the text I grabbed doesn't linger on disk.

## Implementation Decisions

### Modules

- **`AppCoordinator.captureText()` (new use case on the existing seam).** It's the main test seam, and it mirrors `captureArea()`: first-run permission onboarding → `OverlayController.selectRegion()` → `CaptureService.captureRegion(_:)` → `TextRecognizer.recognizeText(in:)` → pure text assembly → `ImageSink.copyText(_:)`, with `CaptureUI.presentTextCaptureStatus(_:)` reporting `.reading` before recognition and the result after. Ordering is the same as area capture: **the overlay runs first**, then the capture. There's no self-timer and no post-capture toolbar, `openEditor` is never called, and nothing is recorded in `HistoryStore`. It doesn't update the last-capture memory that Repeat Last Capture uses.
- **`TextRecognizer` (new service protocol, domain core).** It takes one `CapturedImage` and asynchronously returns a result: the recognised lines (the existing `RecognizedLine` value type from spec 0009, text plus word boxes in image pixel coordinates) or a recognition error. It imports no Vision. It's the one new seam and exists so the coordinator can be tested with a fake.
- **Vision text recogniser (new, App side, thin).** The concrete `TextRecognizer`. It runs `VNRecognizeTextRequest` with `.accurate`, `automaticallyDetectsLanguage = true` and **`usesLanguageCorrection = true`**. That differs from auto redact on purpose: OCR Text wants readable prose, while auto redact must not "correct" keys into words. It works off the main actor and converts Vision's normalised, bottom-left boxes to top-left image pixels. It can share the line and word extraction with the auto-redact recogniser, but auto redact's settings and behaviour must not change.
- **Pure text assembly (new, domain core, Foundation only).** A function from `[RecognizedLine]` to a `String`:
  - Lines are grouped into **rows**. Two lines share a row when their vertical extents overlap by at least half of the shorter one's height.
  - Rows are ordered top to bottom by their top edge, and lines within a row left to right. Lines in a row are joined with a single space, and rows with `\n`.
  - Each line's text is kept as recognised. The whole result is trimmed of leading and trailing whitespace and newlines.
  - No lines, or only whitespace, gives an empty string, which the coordinator treats as "no text".
- **`ImageSink.copyText(_ text: String)` (existing seam, one new method).** The real sink clears the general pasteboard and writes the string as plain text (`.string`) only. The fake records the call.
- **`CaptureAction.captureText` (new case).** Its title is "OCR Text". It's declared directly after `recordScreen`, so Settings lists it in menu order. It has no entry in `HotkeyBindings.defaults`. Existing conflict detection covers it unchanged.
- **`CaptureUI.presentTextCaptureStatus(_:)` (existing seam, one new method).** It takes a `TextCaptureStatus`: `reading`, `copied(text)`, `noText`, or `failed(message)`. Each status replaces the one before. The app turns it into a non-activating HUD centred near the bottom of the screen under the pointer. "Reading text…" appears only if recognition takes longer than about 0.3 s and stays until the result replaces it. Results are dismissed after about two seconds, and errors after four. "Text copied" shows the first line, truncated to about 60 characters with an ellipsis. "No text found" is the second. A failure shows the recogniser's localised message.

### Routing

- **Overlay cancelled** (`nil` region): silent no-op. No capture, recognition, clipboard write or notice.
- **Capture failures** route exactly as in `captureArea()`. `permissionDenied` goes to `presentPermissionDenied(.screenRecording)`, `userCancelled` is silent, and the rest go to `presentCaptureFailure`.
- **After a successful capture:** `.reading`, then recognition.
- **Recognition failure:** no clipboard write, then `.failed(message)`.
- **Empty assembly result:** no clipboard write, then `.noText`.
- **Otherwise:** `copyText` exactly once with the assembled string, then `.copied(text)`.
- **While a recording session is active** (anything but idle), `captureText()` is a no-op, and the menu row is disabled. That covers the countdown, a running or paused take, and finishing. The hotkey is ignored in the same states.

### Menu placement

- In the capture section, **directly after the Record Screen row** and before the separator above Open Image…. It uses the same `captureItem` path, so the live shortcut shows on the row.
- Icon: SF Symbol `text.viewfinder`, on the same 24 × 24 pt template canvas as the other rows, with `preferredImageVisibility = .visible` on macOS 27.
- Label: **"OCR Text"**, as the user asked. CleanShot's label is "Capture Text" (see *Further Notes*).

### Settings

- The hotkey list in Settings gains an OCR Text row, unbound by default and rebindable like the others. There are no other OCR preferences in v1: no language picker, no line-break toggle.

## Testing Decisions

- **What makes a good test here:** assert what the user would observe. Assert what ends up on the clipboard, whether the clipboard was touched at all, which notice was shown, and that no editor opened. Don't assert Vision settings or call internals beyond that. Inputs are fakes and hand-built `RecognizedLine`s. No test touches Vision, a screen or a permission.
- **`AppCoordinator.captureText()` (primary seam), Swift Testing, with fake overlay, capture service, recogniser, sink and UI:**
  - The happy path copies the assembled text once and presents `.reading` then `.copied` with it. `openEditor` isn't called and nothing goes into history.
  - A cancelled overlay doesn't capture, recognise, copy or show a notice.
  - An empty recognition result, or only whitespace, doesn't copy and presents `.noText`.
  - A recognition failure doesn't copy and presents `.failed`.
  - `permissionDenied` routes to the Screen Recording recovery path, and a `systemFailure` routes to `presentCaptureFailure`.
  - The overlay runs before the capture, and the capture uses the region the overlay returned.
  - The self-timer isn't applied even when `captureDelay` > 0.
  - After an area capture then OCR Text, Repeat Last Capture re-runs the area capture.
  - During an active recording session, `captureText()` does nothing.
- **Text assembly (pure):**
  - Lines given out of order come back top to bottom.
  - Two lines on one row (a label and its value in two columns) join with a space, in left-to-right order.
  - Lines on separate rows join with `\n`.
  - Slightly skewed lines that overlap by half are the same row, and less than half are separate rows.
  - Leading and trailing whitespace is trimmed, and empty input gives an empty string.
- **`CaptureAction` / `HotkeyBindings`:** `captureText` has the title "OCR Text", sorts after `recordScreen`, has no default binding, and takes part in conflict detection.
- **Prior art:**
  - `AppCoordinatorTests` covers area/fullscreen routing with fakes. Its fake overlay, capture service, sink and UI extend to this use case.
  - `AutoRedactTests` covers pure transforms over hand-built `RecognizedLine`s.
  - `HotkeyBindingTests` covers defaults and conflicts.
- **App side (no unit-test target in `App/`):** verify the Vision recogniser, the pasteboard write, the HUD and the menu row by hand with the isolated `.verify` Debug build. Recognise fixture PNGs (a paragraph, a two-column settings form, a code snippet, a non-English sample, an empty area) through the recogniser directly. That doesn't need the Screen Recording grant. Then do one live run from the menu on a real screen. Record the pasted output in the PR.

## Out of Scope

- A "without line breaks" variant or a line-break toggle (CleanShot has both, and we ship line breaks only).
- Paragraph detection (blank lines between blocks), column detection beyond same-row joining, and preserving indentation or table structure.
- Rich text, Markdown, or keeping fonts and colours on the clipboard.
- OCR from inside the annotation editor, on an opened image file, on history items, or on recordings and the Studio.
- A language picker or custom recognition languages.
- Detecting URLs, QR codes or barcodes and opening them.
- Translating the text.
- Window or fullscreen OCR. Area only.
- Saving recognised text to disk or to history.
- Any change to auto redact's recognition settings.
- Any network or cloud OCR.

## Further Notes

- **Glossary additions** (add to `CONTEXT.md`):
  - **OCR Text:** the capture action that turns a selected screen area into plain text on the clipboard. _Avoid_: Capture Text (CleanShot's name), text grab, scan.
  - **Text capture:** one run of OCR Text, from selection to clipboard. Unlike a **capture**, it produces no image and no history item.
- **Naming.** The user asked for "OCR Text", so it's the menu and Settings label, even though CleanShot calls the feature "Capture Text".
- **Why a `TextRecognizer` protocol when auto redact uses an enum.** Auto redact calls its recogniser from the editor model, which has no unit tests. OCR Text runs through `AppCoordinator`, whose routing (cancel, empty, failure, permission) is exactly what needs testing. So the recogniser has to be swappable there. This is the only new seam.
- **Clipboard honesty.** Recognition can misread characters, like `0`/`O` and `l`/`1`. The preview in the notice is the user's chance to spot that, so the notice never claims the text is exact.
- **Performance:** accurate recognition of a typical selection takes well under a second on Apple silicon once Vision's models are loaded. A cold first run is much slower (see *As built*).

## As built

- **"Reading text…" state.** Verification measured a cold first recognition at about 26 s while Vision loaded its models. Warm runs took 40–150 ms. So the coordinator now presents `.reading` before recognition. The outcome type became `TextCaptureStatus`, and the UI method became `presentTextCaptureStatus(_:)`. The HUD shows "Reading text…" only after about 0.3 s, so warm runs don't flash two notices.
- **Notice position.** The HUD is centred near the bottom of the screen under the pointer, not at the selection. `CaptureUI` isn't given the region, and the pointer is where the drag just ended.
- **Disabled menu row.** `NSMenu` auto-enables items, so the row is greyed out during a take by clearing its action. The coordinator also ignores the hotkey then.
- **Recogniser.** `VisionTextRecognizer` is a separate app type. `SensitiveContentRecognizer` (auto redact) is untouched. Each Vision observation becomes one `RecognizedLine` with a single word spanning its box, because reading order only needs line boxes.
- **Development aid:** DEBUG builds accept `-previewTextNotice reading|copied|none|failed` to show the notice without capturing.
- **Verified offline** by running the real recogniser and assembly on 2× fixture PNGs, without the Screen Recording grant:
  - A paragraph, a two-column form ("Username viet.le" and so on, correctly joined per row) and Vietnamese/French text all came back right.
  - An empty image gave `noText`, and undecodable bytes gave a clean failure.
  - Vision's own limits showed on code: `->` read as `>`, a lone `}` line was dropped, and `0x` read as `Ox`. Turning language correction off didn't fix any of these, so it stays on.
  - The menu row and all three notice states were checked in an isolated `.verify` build.
- **Not verified live:** a real drag → clipboard run needs the Screen Recording grant, which the verify build doesn't have on this machine.
