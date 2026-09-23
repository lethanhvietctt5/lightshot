# AGENTS.md

Canonical working agreement for any AI agent (Claude Code, Copilot, Codex, …) operating in this repository. `CLAUDE.md` points here; this file is the single source of truth.

## What this is

**Lightshot** — a native **macOS (Swift / SwiftUI, macOS 14+)** screenshot and screen-recording app, a local-only alternative to CleanShot X: capture → annotate → copy / save / pin, and record → edit in the Studio → export. No cloud, no accounts, no network — captions are transcribed on-device.

## Current state — read first

The app is shipping (see [`docs/releases/`](docs/releases) for per-version highlights). Specs [`0001`](specs)–`0008` are implemented: screenshot capture and annotation, release and distribution, the editor passes, the menu-bar menu, screen recording, the Studio video editor, and light/dark appearance.

- [`LightshotKit/`](LightshotKit) — the SwiftPM domain-core package. Pure Swift, **no AppKit / ScreenCaptureKit imports**, with a Swift Testing suite per module.
- [`App/`](App) — the menu-bar app (`LSUIElement`) and the concrete ScreenCaptureKit / AVFoundation / AppKit services.
- [`project.yml`](project.yml) — the XcodeGen spec. **`Lightshot.xcodeproj` is generated, not committed** (it's gitignored); run `xcodegen generate` after cloning or after editing `project.yml`.
- [`scripts/`](scripts) — the release script; [`docs/adr/`](docs/adr) — architecture decision records.

Guidance:

- The commands below work — but **run them; don't claim a pass you didn't observe.**
- The spec is the contract. Before writing feature code, read the spec and the matching Linear issue; if they disagree, reconcile before coding.

## Project layout

The spec's testing strategy dictates the structure:

- **A SwiftPM package for the domain core** (`LightshotKit/`) — `AnnotationDocument`, the pure `render` function, `StudioDocument` and its pure models (`StudioTimeline`, `ZoomCamera`, `CursorPath`, `CanvasLayout`, `StudioCaptions`), `RecordingSession`, `HistoryStore`, `AppCoordinator`, `ThemePalette`, and the service *protocols* (`CaptureService`, `RecordingService`, `ImageSource`, `ImageSink`, `MediaSink`, `HotkeyService`, `AudioInputService`, `CameraService`, `InputEventSource`, `SettingsStore`, …). Pure Swift, **no AppKit / ScreenCaptureKit imports**. This is what makes `swift test` fast and screen-free.
- **An Xcode app target for the OS shell** (`App/`, built via the generated `Lightshot.xcodeproj`) — the menu-bar app plus the concrete ScreenCaptureKit / AVFoundation / AppKit implementations of those protocols (capture, recording, overlays, pin board, hotkeys, sinks, the Studio compositor and exporter).

The seam between the two is the point: the app depends on the package, never the reverse.

## Commands

```bash
# Domain core (SwiftPM package) — the fast inner loop
cd LightshotKit
swift build
swift test
swift test --filter CropTests                                   # one suite
swift test --filter AddSelectDeleteTests/addDoesNotChangeSelection # one test (Swift Testing)

# Full app (Xcode project) — requires a real macOS destination.
# Regenerate the (gitignored) project from project.yml first:
xcodegen generate
xcodebuild -project Lightshot.xcodeproj -scheme Lightshot -destination 'platform=macOS' build
xcodebuild -project Lightshot.xcodeproj -scheme Lightshot -destination 'platform=macOS' test
```

Tooling: **XcodeGen** (`brew install xcodegen`) generates the app project. Prefer **Swift Testing** over XCTest for new tests. The domain test target having zero AppKit/ScreenCaptureKit imports is the litmus test that a seam is placed correctly — treat a new framework import in that target as a design smell to justify or fix.

## Releasing

Releases are cut locally by the maintainer with one command (spec 0002; details in [`scripts/README.md`](scripts/README.md)):

```bash
scripts/release.sh 0.1.0 --dry-run   # test → build universal Release → sign → verify → DMG; nothing tagged or uploaded
scripts/release.sh 0.1.0             # same, then pushes tag v0.1.0 and creates a DRAFT GitHub Release (publish is a manual click)
```

The app is signed with one fixed self-signed certificate (`Lightshot Release Signing`) so users' permissions survive updates; the expected designated requirement is pinned in `scripts/release-identity.txt` and the script refuses to ship a build that does not match it. Never change the bundle identifier `dev.lightshot.app` or that certificate without a deliberate, announced permission reset. Optional per-version highlights go in `docs/releases/<version>.md`.

## Architecture — the big picture

Everything interesting is a pure function over a value type; everything OS-facing hides behind a protocol.

- **`AnnotationDocument` is the primary seam.** A value type (base image ref + ordered `AnnotationElement`s + selection + crop rect) mutated **only** through a command API (`add`, `select`, `transform`, `setStyle`, `updateText`, `delete`, `reorder`, `applyCrop`, `undo`, `redo`). It owns undo/redo history, step-number auto-increment, crop math, and hit-testing. Element geometry is stored in **image pixel coordinates**, never view coordinates — this is what keeps crop and multi-scale export correct. Push new editing behavior *into the document*, not into views.
- **`render(document) -> image` is a pure function.** Deterministic flatten of base + elements respecting crop and z-order. `blackout` redaction erases pixels (secure); `blur`/`pixelate` only obscure and are **not** secret-safe — never describe them as secure redaction.
- **OS services are thin and protocol-fronted:** `CaptureService` (ScreenCaptureKit), `ImageSource` (open existing file), `ImageSink` (clipboard/disk/drag), `HotkeyService`, plus `OverlayController` / `PinBoardController` windows. Capture and file-load return `Result<CapturedImage, …Error>` — never a silently empty image.
- **`AppCoordinator` composes, and ordering matters:** for area/window capture the **overlay runs first** to resolve a `CaptureRegion`, *then* `CaptureService` captures it; fullscreen skips the overlay; open-file goes through `ImageSource`. All three converge on one `openEditor(with: CapturedImage)` entry. The post-capture toolbar is a step *after* the image exists, not part of the selection overlay. `CaptureError.permissionDenied` routes to a System-Settings recovery path, never a blank editor.
- **`StudioDocument` is the recording seam.** A take is recorded as a clean screen movie plus pointer, click and keystroke data and a separate camera movie; every edit (clips, speed, zooms, cursor, canvas, captions, text) lives in the value-type document with its own undo/redo. One compositor draws both the live preview and the export, so they cannot drift. Push new Studio behavior into the document and its pure models.

When in doubt about a behavior, the spec's User Stories and Implementation Decisions are authoritative.

## The main workflow

This project is spec-driven and issue-tracked. Follow the loop:

1. **Spec** lives in `specs/NNNN-*.md` **and** as a Linear issue — keep the two in sync when either changes.
2. **Tracker:** Linear team **Lightshot**. A spec ready to build carries the **`ready-for-agent`** label. Feature/Bug/Improvement labels classify the kind.
3. **Branch per issue**, using Linear's suggested name (e.g. `…/lig-5-core-capture-annotate-v1`). Branch off `main`.
4. **PR targets `main`.** Title it **`<type>(LIG-<n>): <title>`** — Conventional-Commits type with the Linear issue as the scope, e.g. `feat(LIG-100): add scrolling capture`. Use `feat` for a story/feature, `fix` for a bug, `chore`/`docs`/`refactor`/`test` otherwise. Keep the PR description linked to the Linear issue.
5. **Verify, then merge.** Run `swift test` (and the app build/tests for app-side work) and confirm the behavior before merging; there is no separate review bot. Mirror any spec change into the Linear issue so all three (file, issue, PR) stay consistent.
6. Only `main` and the feature branches are long-lived.

## Working principles

Mirror the discipline these encode; they override speed.

- **Think before coding.** State assumptions out loud instead of guessing. Surface tradeoffs and give a recommendation rather than an exhaustive menu. For anything with a fork in it (platform, scope, a seam), confirm the fork before committing to it.
- **Simplicity first.** Prefer the smallest change that satisfies the story. Would a senior engineer call this overcomplicated? Then it is. New seams are a cost — the ideal number added is zero; reuse the document/render/protocol seams already defined.
- **Surgical changes.** Match the surrounding style. Don't reformat, rename, or "tidy" code the task didn't ask you to touch. Keep edits reviewable.
- **Goal-driven execution.** Tie every change to a specific user story and a concrete, checkable outcome — not "make it work." For domain behavior, write the test first (red → green); the value-type core is built to be tested without a screen or permissions, so there is no excuse to skip it.

## Guardrails

- **Local-only.** Do not add networking, accounts, analytics, or cloud upload — they are explicitly out of scope (a later spec). If a task seems to need them, stop and confirm.
- **Never present blur/pixelate as secure redaction.** Only `blackout` is safe for secrets.
- **macOS 14+ / ScreenCaptureKit only.** Do not reach for deprecated `CGWindowListCreateImage`.
