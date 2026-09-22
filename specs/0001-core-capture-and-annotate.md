# Spec 0001 — Core Capture & Annotate (v1)

**Status:** ready-for-agent
**Platform:** Native macOS (Swift / SwiftUI), macOS 14+ (ScreenCaptureKit)
**Scope:** Local-only. No accounts, no backend, no cloud upload.

---

## Problem Statement

I take a lot of screenshots to explain things, file bugs, and share UI. The
built-in macOS screenshot tool captures an image but stops there: I can't
quickly circle the thing I mean, blur a password before I share, add a couple
of numbered steps, or keep the shot floating on screen while I type about it.
So I paste the raw image somewhere and then fight another app to mark it up,
which breaks my flow every single time. I want CleanShot X's core experience —
capture, immediately annotate, then copy or save — without paying for or being
locked into that product, and running entirely on my own machine.

## Solution

A native macOS menu-bar app that owns the capture-to-annotation flow end to end.
I press a global hotkey, drag to select an area (or pick a window, or grab the
full screen), and a small toolbar appears at the selection. From there the
capture opens instantly in an **annotation editor** where I can draw arrows,
boxes, lines, freehand strokes, and text; highlight regions; blur or pixelate
anything sensitive; drop auto-incrementing numbered step markers; and crop.
When I'm done I copy to the clipboard, save to disk, or **pin** the shot so it
floats on top while I work. A local history keeps my recent captures so I can
re-open and re-annotate them. Everything happens locally; nothing leaves the
machine.

## User Stories

### Capture

1. As a user, I want a global hotkey to start an **area capture**, so that I can grab any region without clicking through menus.
2. As a user, I want to drag a selection rectangle over the screen, so that I can capture exactly the region I care about.
3. As a user, I want to see the pixel dimensions of my selection while dragging, so that I can size the capture precisely.
4. As a user, I want to adjust the selection edges/corners after the initial drag but before capturing, so that I can fine-tune without starting over.
5. As a user, I want to press Escape during selection, so that I can cancel a capture I no longer want.
6. As a user, I want a hotkey to capture a **specific window**, so that I can grab a single app window cleanly without its surroundings.
7. As a user, I want windows to highlight as I hover them in window-capture mode, so that I can see what will be captured before I click.
8. As a user, I want a hotkey to capture the **entire screen** (or a chosen display on multi-monitor setups), so that I can grab everything at once.
9. As a user, I want to re-trigger the **last capture mode** with one shortcut, so that I can take repeated shots of the same kind quickly.
10. As a user, I want a **self-timer / delayed capture** option, so that I can set up transient UI (menus, tooltips, hover states) before the shot is taken.
11. As a user, I want the app to capture at native Retina resolution, so that my screenshots are crisp.
12. As a user, I want to choose whether the mouse cursor is included in the capture, so that I can point at things or keep the shot clean.
13. As a user, I want a captured image to open immediately in the editor (configurable), so that I don't have to hunt for the file first.
14. As a user, I want a post-capture toolbar at the selection offering quick actions (annotate, copy, save, pin, discard), so that common outcomes are one click away.

### Annotation editor

15. As a user, I want to draw an **arrow**, so that I can point at a specific element.
16. As a user, I want to draw a **straight line**, so that I can underline or connect things.
17. As a user, I want to draw a **rectangle** outline, so that I can frame an area of interest.
18. As a user, I want to draw an **ellipse/circle** outline, so that I can circle an element.
19. As a user, I want to draw **freehand** strokes, so that I can scribble a mark naturally.
20. As a user, I want to add a **text label**, so that I can caption or explain part of the image.
21. As a user, I want to edit the text of a label after placing it, so that I can fix typos without redrawing.
22. As a user, I want a **highlighter** tool that lays a translucent colored fill over a region, so that I can draw attention without hiding content.
23. As a user, I want a **blur / pixelate** tool over a region, so that I can redact sensitive information before sharing.
24. As a user, I want a **blackout (opaque) redaction** that is flattened into the exported image, so that secrets like passwords genuinely can't be recovered from the file I share. (Blur/pixelate are offered for visual obscuring but are explicitly **not** promised as secure redaction.)
25. As a user, I want **numbered step markers** that auto-increment (1, 2, 3 …) as I place them, so that I can annotate a sequence without renumbering by hand.
26. As a user, I want to change an element's **color**, so that annotations stand out against the underlying image.
27. As a user, I want to change an element's **stroke width / size**, so that marks read at the right weight.
28. As a user, I want to change **font size** for text and step markers, so that labels are legible.
29. As a user, I want to **select** an existing element by clicking it, so that I can modify it.
30. As a user, I want to **move** a selected element by dragging, so that I can reposition it.
31. As a user, I want to **resize / reshape** a selected element via handles, so that I can adjust it after drawing.
32. As a user, I want to **delete** a selected element, so that I can remove a mistake.
33. As a user, I want elements to have a stable **stacking order** (later on top) with a way to reorder, so that overlapping marks layer predictably.
34. As a user, I want **undo** and **redo**, so that I can experiment freely and step back.
35. As a user, I want undo/redo to cover every editing action (add, move, resize, style change, delete, crop), so that history is trustworthy.
36. As a user, I want to **crop** the image to a rectangle, so that I can trim away irrelevant parts.
37. As a user, I want crop to be adjustable/undoable, so that a wrong crop isn't destructive to my session.
38. As a user, I want annotation coordinates to stay correct **relative to the image after a crop**, so that marks don't drift.
39. As a user, I want to open an **existing image file** in the editor (not just fresh captures), so that I can annotate screenshots I already have.

### Output

40. As a user, I want to **copy** the annotated result to the clipboard, so that I can paste it straight into chat or a doc.
41. As a user, I want to **save** the annotated result to disk as PNG, so that I keep a file.
42. As a user, I want to choose the save format (PNG / JPEG) and, for JPEG, quality, so that I can trade size for fidelity.
43. As a user, I want a configurable default save location and filename pattern, so that files land where I expect without a dialog every time.
44. As a user, I want the exported image to be a **faithful flattened render** of the base image plus all annotations, so that what I see is what I share.
45. As a user, I want to **drag the result out** of the editor into another app, so that I can drop it directly where it's needed.

### Pinned / floating screenshots

46. As a user, I want to **pin** a capture as an always-on-top floating window, so that I can reference it while I work in other apps.
47. As a user, I want to move and resize a pinned screenshot, so that I can place it out of the way.
48. As a user, I want to close a pinned screenshot when I'm done, so that it doesn't clutter my screen.
49. As a user, I want to copy or save directly from a pinned screenshot, so that I can act on it without reopening the editor.

### History

50. As a user, I want a **local history** of my recent captures, so that I can find a shot I took earlier.
51. As a user, I want to re-open a history item in the editor, so that I can annotate or re-export it.
52. As a user, I want to copy or reveal-in-Finder a history item, so that I can reuse it quickly.
53. As a user, I want to delete a history item, so that I can clean up.
54. As a user, I want to set how many captures history retains (or clear it), so that I control disk use and privacy.

### App shell, permissions, settings

55. As a user, I want the app to live in the **menu bar** with a menu of capture actions, so that it's always available and out of the way.
56. As a user, I want to **customize the global hotkeys**, so that they don't clash with my other tools.
57. As a user, I want the app to guide me through granting **Screen Recording permission** the first time, so that capture works without cryptic failures.
58. As a user, I want a clear message and a path to System Settings if permission is missing or revoked, so that I'm never stuck on a blank capture.
59. As a user, I want the app to **launch at login** (optional), so that my hotkeys are ready after a restart.
60. As a user, I want a settings window for hotkeys, defaults (format, save location, open-in-editor, cursor inclusion), and history retention, so that I can tailor the app.

## Implementation Decisions

### Architecture & modules

- **`AnnotationDocument` (primary domain module, the primary test seam).** A value type holding: a reference/handle to the immutable base image, its pixel size, an ordered array of `AnnotationElement`s, the current selection, and a crop rect. All mutation happens through an explicit command API rather than direct property mutation:
  - `add(_ element)`, `select(id?)`, `transform(id, by:)` (move/resize deltas), `setStyle(id, style)`, `updateText(id, string)`, `delete(id)`, `reorder(id, to:)`, `applyCrop(rect)`, `undo()`, `redo()`.
  - `AnnotationElement` is an enum/struct-with-kind covering: `arrow`, `line`, `rectangle`, `ellipse`, `freehand(points)`, `text(string)`, `highlight(rect)`, `redaction(rect, style: blackout|blur|pixelate)`, `stepMarker(number)`. Each carries geometry (in **image coordinates**, not view coordinates) plus a `Style` (color, stroke width, font size, fill). **Only `blackout` (a fully opaque fill) is secure redaction** — `blur` and `pixelate` are reversible/inferable obscuring, not secret-safe (see Key contracts).
  - **Step-number auto-increment** is owned by the document: adding a `stepMarker` assigns the next integer based on existing markers; deleting a marker does not renumber existing ones (matches CleanShot behavior — numbers are stable once placed) — *this rule is a decision, confirm against real CleanShot if parity matters.*
  - **Undo/redo** is a bounded history of document snapshots (or inverse commands) held inside the document module; every command pushes an entry. Redo stack clears on a new command after undo.
  - **Crop math:** `applyCrop` records the crop rect; element coordinates remain in the original image space, and the exported/visible frame is the crop rect. Reversing the crop restores the full frame with all elements intact (satisfies stories 37–38).
  - Geometry is defined so that **hit-testing** (`elementID(at: point)`) and handle resolution are pure functions of the document — no view involvement.

- **`render(_ document) -> RenderedImage` (supporting pure-function seam).** Deterministic flattening of base image + elements (respecting crop and z-order) into a bitmap via Core Graphics / `ImageRenderer`. Redaction elements are rasterized destructively; `blackout` replaces the covered pixels with an opaque fill so the underlying pixels are gone (story 24/44), while `blur`/`pixelate` transform them in place (obscuring, not erasing). Output size equals the crop rect size at native scale.

- **`ImageSink` protocol.** `write(_ image, to:URL, format: ImageFormat)`, `copyToClipboard(_ image)`, plus a drag-provider. Real implementation uses `NSPasteboard` / file APIs; a fake captures calls in tests. Keeps disk/clipboard out of the render tests.
  - **`ImageFormat`** is an explicit value the encoder consumes, not a bare enum name: `png` or `jpeg(quality: Double)` where quality is a normalized `0.0...1.0`. Story 42's selectable quality lives here — the same value type carries the **default** (from `SettingsStore`) and any **per-save override**, so the editor passes the chosen setting straight through to the encoder with no separate quality channel. Formats that ignore quality (PNG) simply carry no quality field. Test: writing `jpeg(quality:)` reaches the fake sink with the exact requested value; the default from settings is used when no override is given.

- **`HistoryStore` (supporting persistence seam).** Records `CaptureRecord` (id, timestamp, source kind, file URL, thumbnail). Backed by files on disk plus a lightweight index (JSON or SwiftData). Public API: `add`, `all`, `remove`, `clear`, `setRetention(_:)`, enforcing retention by trimming oldest. Testable against a temp directory.

- **OS-facing controllers behind protocols (thin, protocol-fronted, not the unit-test focus):**
  - `CaptureService` — wraps ScreenCaptureKit (`SCShareableContent`, `SCScreenshotManager` / stream) for area/window/fullscreen; resolves the target display; honors cursor-inclusion and self-timer. Exposes `authorizationStatus` and a `requestAuthorization()` flow. Every capture entry point returns a `Result<CapturedImage, CaptureError>` (or throws `CaptureError`) rather than an optional image — a capture never silently yields an empty/black image.
    - **`CaptureError`** is a typed enum covering at least: `permissionDenied` (includes the revoked-after-status-check race — the check is advisory, the actual capture call is authoritative), `noDisplayAvailable`, `userCancelled`, and `systemFailure(underlying)`. Distinguishing `permissionDenied` from other failures is what drives stories 57–58.
  - `HotkeyService` — registers/unregisters global hotkeys (Carbon `RegisterEventHotKey` or a maintained wrapper); maps a `HotkeyBinding` set to capture actions; conflict handling surfaced to settings.
  - `OverlayController` — the full-screen **pre-capture** selection overlay window: dimming, live selection rect with dimension readout, edge/corner handles, window-hover highlighting, Escape-to-cancel. It resolves the user's choice into a `CaptureRegion` (rect or window id) that is handed to `CaptureService`; it does not itself capture. The **post-capture action toolbar** (annotate/copy/save/pin/discard) is a separate surface shown after the image exists, not part of this overlay.
  - `PinBoardController` — creates always-on-top borderless `NSWindow`s for pinned captures; move/resize/close; copy/save passthrough to `ImageSink`.
  - `SettingsStore` — user defaults for hotkey bindings, default format/quality, save location, filename pattern, open-in-editor, cursor inclusion, launch-at-login, history retention.

- **`ImageSource` protocol (open-existing-image seam).** `loadImage(from: URL) -> Result<CapturedImage, ImageLoadError>` plus a file-picker entry `openDocument() -> Result<CapturedImage, ImageLoadError>` behind the same protocol — **both return the same result type** so cancellation and decode failures are always surfaced, never silently dropped. This is the input contract for story 39: opening an existing file produces the **same `CapturedImage` value** that `CaptureService` yields, so the editor entry point is source-agnostic and no ad-hoc file/UI dependency leaks into the editor. `ImageLoadError` covers `unreadable`, `unsupportedFormat`, and `userCancelled` (the last returned when the user dismisses the panel). The real implementation uses `NSOpenPanel` / `ImageIO`; a fake returns fixtures in tests.
- **Composition.** A thin `AppCoordinator` / menu-bar controller sequences each capture mode correctly:
  - **Area / window capture (stories 2, 6, 7):** hotkey → **`OverlayController` first** (drag a selection rect, or hover-highlight and click a window) → the resolved `CaptureRegion` (rect or window id) is passed **into `CaptureService`** → `CapturedImage`. The overlay runs *before* capture because the service needs a target to capture.
  - **Fullscreen capture (story 8):** hotkey → `CaptureService` directly (no overlay; the display is the target).
  - **Open existing file (story 39):** open-file → `ImageSource` → `CapturedImage`.
  - All three converge on a single editor entry `openEditor(with: CapturedImage)` → document → editor window. The **post-capture toolbar** (annotate/copy/save/pin/discard, story 14) is a **separate step that runs after the image is produced**, not part of the pre-capture selection overlay. Editor output → `ImageSink` / `PinBoardController` / `HistoryStore`.
  - The coordinator holds protocol references so the domain core never imports AppKit capture APIs.
  - **Error routing (stories 57–58):** when `CaptureService` returns `CaptureError.permissionDenied`, the coordinator routes to a user-visible recovery path — a message plus a deep link to the Screen Recording pane in System Settings — never a blank editor. `userCancelled` is a silent no-op; `noDisplayAvailable` / `systemFailure` surface a distinct error message. `ImageLoadError` is routed analogously for the open-file path.

### Key contracts / decisions

- **Coordinate system:** all element geometry is stored in **image pixel coordinates**; the editor view maps to/from view space. This is what keeps crop and multi-scale export correct.
- **Redaction is destructive on export** (rasterized into the pixels, never a maskable overlay) — but destructiveness alone is *not* a secrecy guarantee. **Only `blackout` (opaque fill) is treated as secure redaction:** the covered pixels are replaced with an opaque solid, so nothing underneath survives in the file. `blur` and `pixelate` are visual obscuring only — they can be deblurred, inferred, or brute-forced — so they are **not** secret-safe and must not be presented as such. Story 24's password example maps specifically to `blackout`; the UI must surface a warning (or omit the security framing) for `blur`/`pixelate`. (The redact tool's default style is `pixelate` as of [Spec 0004](0004-editor-usability-pass.md); the warning is what keeps it from reading as secure.) Render-time test: after a `blackout` over a known sentinel pattern, the sentinel is absent from the output; the `blur`/`pixelate` tests assert only obscuring, not recoverability.
- **macOS 14+ / ScreenCaptureKit** is the capture baseline; legacy `CGWindowListCreateImage` is *not* used (deprecated, and screen-recording permission model differs). Confirm minimum-OS with the developer if older support is needed.
- **No cloud, no accounts, no network** in v1. History and files are local only.
- **Distribution/signing** (notarization, Screen Recording entitlement) is acknowledged as required for a shippable build but its mechanics are out of this spec's behavioral scope.

## Testing Decisions

- **What makes a good test here:** it exercises **external behavior through a module's public API** and asserts observable outcomes — never internal representation. For the document model that means: issue commands, then assert on element count, selection, resulting geometry, step numbers, and undo/redo results. For render it means: feed a document, assert output dimensions and coarse pixel facts (e.g. a redaction region contains none of a known sentinel color; a crop reduces size to the crop rect). We do **not** assert private field layout, snapshot internal structs, or test AppKit/ScreenCaptureKit call sequencing.

- **Modules under test:**
  - **`AnnotationDocument` (primary):** add/select/move/resize/delete; z-order and reordering; hit-testing returns the topmost element at a point; step-marker auto-increment and stability after deletion; undo/redo across every command type, including redo-stack invalidation; crop applied then reversed leaves elements intact; element geometry survives crop. This is the bulk of the suite.
  - **`render` (supporting):** output size equals crop rect at native scale; a `blackout` redaction leaves no trace of a known sentinel pattern in the output (secure-erase assertion), while `blur`/`pixelate` are asserted only to have changed the region (obscuring, not secure erase); element z-order reflected; empty document renders the base image unchanged in size.
  - **`HistoryStore` (supporting):** add/list/remove/clear against a temp directory; retention trims oldest beyond the limit; survives reload.
  - **`ImageSink` fake:** used to verify the editor's output path calls copy/save with the rendered image and the exact `ImageFormat` (including `jpeg(quality:)`) requested — behavior of the coordinator's output step, not the OS.
  - **`AppCoordinator` error routing (supporting):** with fake `CaptureService` / `ImageSource`, assert that `CaptureError.permissionDenied` routes to the System-Settings recovery path (not a blank editor), `userCancelled` is a silent no-op, and a successful capture *or* a loaded existing image both reach `openEditor(with:)` with an equivalent `CapturedImage`. This makes stories 39 and 57–58 testable without a real display or TCC state.

- **Not unit-tested (verified manually / via light integration):** `CaptureService`, `HotkeyService`, `OverlayController`, `PinBoardController` — these are thin OS wrappers requiring real displays, TCC permissions, and window server state. They sit behind protocols so the tested modules never touch them; a short manual test checklist (grant permission → area capture → annotate → copy → pin) covers the wiring.

- **Prior art:** none in this repo (greenfield). Establish the pattern with this spec: pure value-type domain model + command API as the primary seam, protocol-fronted OS services with in-memory fakes. Test framework: **Swift Testing** (or XCTest) with the domain tests having **no AppKit/ScreenCaptureKit imports**, which is the structural signal that the seam is placed correctly.

## Out of Scope

- **Cloud upload, shareable links, accounts, and CleanShot Cloud–style history sync** (a later spec; the local `HistoryStore` is designed so a cloud sync layer can sit above it).
- **Screen / video recording, GIF capture, webcam overlay, system-audio & mic capture, click/keystroke visualization** — deferred; the biggest follow-up.
- **Scrolling capture** (stitched long screenshots).
- **OCR / "extract text from screenshot."**
- **Background & padding compositing** (gradient/wallpaper backgrounds, window shadow, spacing) — a later "beautify" spec.
- **Hide desktop icons / hide notifications during capture.**
- **Windows / Linux support** (native-macOS decision fixes v1 to macOS).
- **Notarization, code-signing, and installer mechanics** (build/release concern, not behavioral spec).
- **Non-core annotation extras** (emoji stamps, image stamps, counters beyond numeric step markers, spotlight/zoom effects).

## Further Notes

- **Why the document model is the single primary seam:** every interesting rule in this feature — undo/redo integrity, step-marker numbering, crop-coordinate correctness, hit-testing, destructive redaction — is expressible as pure functions over a value-type document. Concentrating tests there gives high behavioral coverage with zero reliance on displays or permissions, and it makes the AppKit/ScreenCaptureKit layer swappable without touching the test suite. The absence of framework imports in the domain test target is the litmus test that the seam held.
- **Permissions are the top real-world failure mode.** Stories 57–58 matter more than they look: without robust Screen Recording permission handling the whole app appears broken (black or empty captures). Budget for the first-run flow and the revoked-permission recovery path.
- **Parity flags to confirm with the developer / against real CleanShot X:** exact step-number behavior on deletion; whether area selection should offer "capture previous area" and window-shadow inclusion; default hotkey assignments; and whether the post-capture toolbar or immediate editor-open is the default outcome.
- **Settings window, as built after LIG-44 (story 60).** Laid out like CleanShot X's: a sidebar of panes with coloured icons — General, Shortcuts, Screenshots, Screen Recording, Advanced, and About pinned at the bottom — headed by the app icon, name and `Version x · Local only` (no account). **General** holds launch at login, Play sounds, the export location (folder icon + name, Choose…) and an **After Capture** table (Action × Screenshot / Recording) that edits `openInEditor` and `afterRecording`, one action per column, a dash where an action does not apply. Screenshots holds cursor, self-timer, format, JPEG quality and the file-name pattern; Screen Recording groups spec 0006's rows as Video · GIF · Audio · Camera · Cursor & Clicks · Keystrokes · While Recording; Advanced holds history retention. No store keys changed. A chord saved before the recorder asked for the unshifted key (`⇧⌘4` stored as `"$"`) displays as its digit.
