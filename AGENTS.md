# AGENTS.md

Canonical working agreement for any AI agent (Claude Code, Copilot, Codex, …) operating in this repository. `CLAUDE.md` points here; this file is the single source of truth.

## What this is

**Lightshot** — a native **macOS (Swift / SwiftUI, macOS 14+)** screenshot capture-and-annotation app, a local-only alternative to CleanShot X's core flow: capture → annotate → copy / save / pin. No cloud, no accounts, no network in v1.

## Current state — read first

This repo is **spec-first and not yet scaffolded**. There is no Swift package, no Xcode project, and no build system on disk yet — only [`specs/0001-core-capture-and-annotate.md`](specs/0001-core-capture-and-annotate.md).

- **Do not fabricate build/lint/test commands or claim they pass.** The commands below are the *intended* toolchain; they only work once the package/project exists. When you scaffold it, update this section to match reality.
- The spec is the contract. Before writing feature code, read the spec and the matching Linear issue; if they disagree, reconcile before coding.

## Intended project layout

The spec's testing strategy dictates the structure — follow it when scaffolding:

- **A SwiftPM package for the domain core** — `AnnotationDocument`, the pure `render` function, `HistoryStore`, and the service *protocols* (`CaptureService`, `ImageSink`, `ImageSource`, `HotkeyService`). Pure Swift, **no AppKit / ScreenCaptureKit imports**. This is what makes `swift test` fast and screen-free.
- **An Xcode app target for the OS shell** — the SwiftUI menu-bar app plus the concrete ScreenCaptureKit / AppKit implementations of those protocols (`OverlayController`, `PinBoardController`, real capture/hotkey/sink).

The seam between the two is the point: the app depends on the package, never the reverse.

## Intended commands (once scaffolded)

```bash
# Domain core (SwiftPM package) — the fast inner loop
swift build
swift test
swift test --filter AnnotationDocumentTests            # one suite
swift test --filter AnnotationDocumentTests/appliesCrop # one test (Swift Testing)

# Full app (Xcode project) — requires a real macOS destination
xcodebuild -scheme Lightshot -destination 'platform=macOS' build
xcodebuild -scheme Lightshot -destination 'platform=macOS' test
```

Prefer **Swift Testing** over XCTest for new tests. The domain test target having zero AppKit/ScreenCaptureKit imports is the litmus test that a seam is placed correctly — treat a new framework import in that target as a design smell to justify or fix.

## Architecture — the big picture

Everything interesting is a pure function over a value type; everything OS-facing hides behind a protocol.

- **`AnnotationDocument` is the primary seam.** A value type (base image ref + ordered `AnnotationElement`s + selection + crop rect) mutated **only** through a command API (`add`, `select`, `transform`, `setStyle`, `updateText`, `delete`, `reorder`, `applyCrop`, `undo`, `redo`). It owns undo/redo history, step-number auto-increment, crop math, and hit-testing. Element geometry is stored in **image pixel coordinates**, never view coordinates — this is what keeps crop and multi-scale export correct. Push new editing behavior *into the document*, not into views.
- **`render(document) -> image` is a pure function.** Deterministic flatten of base + elements respecting crop and z-order. `blackout` redaction erases pixels (secure); `blur`/`pixelate` only obscure and are **not** secret-safe — never describe them as secure redaction.
- **OS services are thin and protocol-fronted:** `CaptureService` (ScreenCaptureKit), `ImageSource` (open existing file), `ImageSink` (clipboard/disk/drag), `HotkeyService`, plus `OverlayController` / `PinBoardController` windows. Capture and file-load return `Result<CapturedImage, …Error>` — never a silently empty image.
- **`AppCoordinator` composes, and ordering matters:** for area/window capture the **overlay runs first** to resolve a `CaptureRegion`, *then* `CaptureService` captures it; fullscreen skips the overlay; open-file goes through `ImageSource`. All three converge on one `openEditor(with: CapturedImage)` entry. The post-capture toolbar is a step *after* the image exists, not part of the selection overlay. `CaptureError.permissionDenied` routes to a System-Settings recovery path, never a blank editor.

When in doubt about a behavior, the spec's User Stories and Implementation Decisions are authoritative.

## The main workflow

This project is spec-driven and issue-tracked. Follow the loop:

1. **Spec** lives in `specs/NNNN-*.md` **and** as a Linear issue — keep the two in sync when either changes.
2. **Tracker:** Linear team **Lightshot**. A spec ready to build carries the **`ready-for-agent`** label. Feature/Bug/Improvement labels classify the kind.
3. **Branch per issue**, using Linear's suggested name (e.g. `…/lig-5-core-capture-annotate-v1`). Branch off `main`.
4. **PR targets `main`.** Title it **`<type>(LIG-<n>): <title>`** — Conventional-Commits type with the Linear issue as the scope, e.g. `feat(LIG-100): add scrolling capture`. Use `feat` for a story/feature, `fix` for a bug, `chore`/`docs`/`refactor`/`test` otherwise. Keep the PR description linked to the Linear issue.
5. **Review loop (Copilot reviews PRs):** for each finding — fix in the spec/code, reply on the thread referencing the commit, resolve the thread, then **re-request review** (request reviewer `Copilot`). Mirror any spec change into the Linear issue so all three (file, issue, PR) stay consistent.
6. Only `main` and the feature branches are long-lived; `main` had to be pushed explicitly (the repo started with no `main` on the remote).

## Working principles

Mirror the discipline these encode; they override speed.

- **Think before coding.** State assumptions out loud instead of guessing. Surface tradeoffs and give a recommendation rather than an exhaustive menu. For anything with a fork in it (platform, scope, a seam), confirm the fork before committing to it.
- **Simplicity first.** Prefer the smallest change that satisfies the story. Would a senior engineer call this overcomplicated? Then it is. New seams are a cost — the ideal number added is zero; reuse the document/render/protocol seams already defined.
- **Surgical changes.** Match the surrounding style. Don't reformat, rename, or "tidy" code the task didn't ask you to touch. Keep edits reviewable.
- **Goal-driven execution.** Tie every change to a specific user story and a concrete, checkable outcome — not "make it work." For domain behavior, write the test first (red → green); the value-type core is built to be tested without a screen or permissions, so there is no excuse to skip it.

## Guardrails

- **Local-only v1.** Do not add networking, accounts, analytics, or cloud upload — they are explicitly out of scope (a later spec). If a task seems to need them, stop and confirm.
- **Never present blur/pixelate as secure redaction.** Only `blackout` is safe for secrets.
- **macOS 14+ / ScreenCaptureKit only.** Do not reach for deprecated `CGWindowListCreateImage`.
