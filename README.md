# Lightshot

A native **macOS (Swift / SwiftUI, macOS 14+)** screenshot capture-and-annotation app — a local-only alternative to CleanShot X's core flow: **capture → annotate → copy / save / pin**.

Everything happens on your machine. No cloud, no accounts, no network in v1.

## Features

- **Capture** an area (drag-to-select with live pixel dimensions and adjustable edges), a specific window (with hover highlight), or the full screen / a chosen display — all via rebindable global hotkeys.
- **Capture options** — self-timer / delayed capture, cursor inclusion toggle, repeat-last-mode shortcut, and multi-display selection.
- **Annotation editor** — arrows, lines, rectangles, ellipses, freehand strokes, text labels, highlights, auto-incrementing numbered step markers, and crop.
- **Redaction** — `blackout` (secure, erases pixels), plus `blur` / `pixelate` (obscure only — **not** safe for secrets).
- **Finish** — copy to clipboard, save to disk, or **pin** the shot so it floats on top while you work.
- **Local history** — recent captures persist; reopen, re-annotate, reveal in Finder, or delete, with configurable retention.
- **Open existing images** in the editor.
- **First-run onboarding** for the Screen Recording permission, with recovery when it's revoked.
- **Settings** — rebindable hotkeys, defaults, and launch-at-login.

See [`specs/0001-core-capture-and-annotate.md`](specs/0001-core-capture-and-annotate.md) for the full contract.

## Architecture

Everything interesting is a pure function over a value type; everything OS-facing hides behind a protocol. The app depends on the package, never the reverse.

- **[`LightshotKit/`](LightshotKit)** — the SwiftPM domain core. Pure Swift, **no AppKit / ScreenCaptureKit imports**, so it tests fast and screen-free. It holds:
  - `AnnotationDocument` — a value type mutated only through a command API (`add`, `select`, `transform`, `setStyle`, `updateText`, `delete`, `reorder`, `applyCrop`, `undo`, `redo`). Owns undo/redo history, step-number auto-increment, crop math, and hit-testing. Geometry is stored in **image pixel coordinates**.
  - `render(document) -> image` — a pure, deterministic flatten of base image + elements, respecting crop and z-order.
  - `HistoryStore`, `AppCoordinator`, and the service *protocols* (`CaptureService`, `ImageSource`, `ImageSink`, `HotkeyService`, `OverlayController`, `PinBoardController`).
- **[`App/`](App)** — the SwiftUI menu-bar app shell (`MenuBarExtra`, `LSUIElement`) plus the concrete ScreenCaptureKit / AppKit implementations of those protocols.
- **[`project.yml`](project.yml)** — the XcodeGen spec. **`Lightshot.xcodeproj` is generated, not committed** — run `xcodegen generate` after cloning or after editing `project.yml`.

## Getting started

**Prerequisites:** macOS 14+, Xcode with Swift 6, and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
```

### Domain core (SwiftPM package) — the fast inner loop

```bash
cd LightshotKit
swift build
swift test
swift test --filter AnnotationDocumentTests            # one suite
swift test --filter AnnotationDocumentTests/appliesCrop # one test
```

### Full app (Xcode project) — requires a real macOS destination

```bash
# Regenerate the (gitignored) project from project.yml first:
xcodegen generate
xcodebuild -project Lightshot.xcodeproj -scheme Lightshot -destination 'platform=macOS' build
xcodebuild -project Lightshot.xcodeproj -scheme Lightshot -destination 'platform=macOS' test
```

## Contributing

This project is spec-driven and issue-tracked. Read [`AGENTS.md`](AGENTS.md) first — it is the single source of truth for the working agreement.

1. **Spec** lives in `specs/NNNN-*.md` and as a Linear issue (team **Lightshot**) — keep the two in sync.
2. A spec ready to build carries the **`ready-for-agent`** label.
3. **Branch per issue** off `main`, using Linear's suggested branch name.
4. **PR targets `main`**, titled `<type>(LIG-<n>): <title>` (e.g. `feat(LIG-100): add scrolling capture`).
5. Work through the Copilot review loop: fix → reply → resolve → re-request review.

### Guardrails

- **Local-only v1** — no networking, accounts, analytics, or cloud upload.
- **Never present blur/pixelate as secure redaction** — only `blackout` is safe for secrets.
- **macOS 14+ / ScreenCaptureKit only** — no deprecated `CGWindowListCreateImage`.
