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

## Install

**Requirements:** a Mac running **macOS 14 (Sonoma) or later**, Apple Silicon or Intel.

There are two ways to install Lightshot:

- **[Download a release](#option-1--download-a-release-recommended)** — the quick way, no developer tools needed.
- **[Build from source](#option-2--build-from-source)** — if you want the latest `main`, or the [Releases page](https://github.com/lethanhvietctt5/lightshot/releases) has no download yet.

### Option 1 — Download a release (recommended)

1. **Download** `Lightshot-<version>.dmg` from the [latest release](https://github.com/lethanhvietctt5/lightshot/releases/latest) (under **Assets**).
2. **Install.** Open the DMG and drag **Lightshot** into **Applications**. Eject the DMG afterwards. Always run Lightshot from Applications, not from the DMG or your Downloads folder — otherwise macOS runs it from a temporary location, which breaks launch-at-login and confuses the permission entry.
3. **Get past the first-launch warning.** Lightshot is open source and **not notarized by Apple** (that requires a paid developer account), so macOS blocks the first launch with *"Apple could not verify…"*. This is expected. Allow it once:
   - **macOS 15 (Sequoia) or later:** open Lightshot and dismiss the warning with **Done**. Go to **System Settings → Privacy & Security**, scroll down to the message about Lightshot, click **Open Anyway**, and confirm.
   - **macOS 14 (Sonoma):** in Applications, right-click (or Control-click) **Lightshot** → **Open**, then click **Open** in the dialog.
   - **Or, on any version, in Terminal:**

     ```bash
     xattr -dr com.apple.quarantine /Applications/Lightshot.app
     ```

4. **[Grant Screen Recording](#grant-screen-recording)** when the app asks.

**Verify your download (optional).** Each release's notes include a SHA-256 checksum. Compare it with your file's:

```bash
shasum -a 256 ~/Downloads/Lightshot-*.dmg
```

### Option 2 — Build from source

Takes a few minutes and needs no Apple Developer account.

1. **Get the tools.** Install **Xcode** (with Swift 6) from the Mac App Store and open it once to finish setup, then install [XcodeGen](https://github.com/yonaskolb/XcodeGen) with [Homebrew](https://brew.sh):

   ```bash
   brew install xcodegen
   ```

2. **Build the app** and wait for `** BUILD SUCCEEDED **`:

   ```bash
   git clone https://github.com/lethanhvietctt5/lightshot.git
   cd lightshot
   xcodegen generate
   xcodebuild -project Lightshot.xcodeproj -scheme Lightshot -configuration Release \
     -destination 'platform=macOS' -derivedDataPath build build
   ```

3. **Move it to Applications and launch.** Because you built it on your own Mac, there is no first-launch warning:

   ```bash
   cp -R build/Build/Products/Release/Lightshot.app /Applications/
   open /Applications/Lightshot.app
   ```

4. **[Grant Screen Recording](#grant-screen-recording)** when the app asks.

### Grant Screen Recording

Lightshot is a **menu-bar app** — it has no main window, and appears in the Dock only while the editor is open. Look for its icon in the menu bar.

On first launch, follow the in-app onboarding to allow **Screen Recording** in **System Settings → Privacy & Security → Screen & System Audio Recording** (named **Screen Recording** on macOS 14), then relaunch Lightshot if macOS asks. This is the only permission Lightshot needs; without it captures come back black or empty.

### Updating

Lightshot never connects to the network, so it does not update itself. Choose **Quit Lightshot** from its menu-bar menu, then:

- **Release download:** download the new DMG and drag Lightshot into Applications again, choosing **Replace**. The first-launch warning appears once more for each new download.
- **Source build:** `git pull`, repeat the `xcodegen generate` and `xcodebuild` commands above, then replace the installed copy:

  ```bash
  rm -rf /Applications/Lightshot.app
  cp -R build/Build/Products/Release/Lightshot.app /Applications/
  ```

> **If captures come back black or empty after an update,** macOS has lost the Screen Recording grant even though System Settings still shows the toggle as on. Run `tccutil reset All dev.lightshot.app`, relaunch, and grant the permission again. Source builds hit this on **every** rebuild unless you set up [local code signing](#local-code-signing--keep-permissions-across-rebuilds) once (a free Apple ID is enough).

### Uninstalling

Quit Lightshot, then remove the app and its permission entries:

```bash
rm -rf /Applications/Lightshot.app
tccutil reset All dev.lightshot.app
```

## Architecture

Everything interesting is a pure function over a value type; everything OS-facing hides behind a protocol. The app depends on the package, never the reverse.

- **[`LightshotKit/`](LightshotKit)** — the SwiftPM domain core. Pure Swift, **no AppKit / ScreenCaptureKit imports**, so it tests fast and screen-free. It holds:
  - `AnnotationDocument` — a value type mutated only through a command API (`add`, `select`, `transform`, `setStyle`, `updateText`, `delete`, `reorder`, `applyCrop`, `undo`, `redo`). Owns undo/redo history, step-number auto-increment, crop math, and hit-testing. Geometry is stored in **image pixel coordinates**.
  - `render(document) -> image` — a pure, deterministic flatten of base image + elements, respecting crop and z-order.
  - `HistoryStore`, `AppCoordinator`, and the service *protocols* (`CaptureService`, `ImageSource`, `ImageSink`, `HotkeyService`, `OverlayController`, `PinBoardController`).
- **[`App/`](App)** — the SwiftUI menu-bar app shell (`MenuBarExtra`, `LSUIElement`) plus the concrete ScreenCaptureKit / AppKit implementations of those protocols.
- **[`project.yml`](project.yml)** — the XcodeGen spec. **`Lightshot.xcodeproj` is generated, not committed** — run `xcodegen generate` after cloning or after editing `project.yml`.

## Getting started

For contributors — if you just want to use the app, see [Install](#install).

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

### Local code signing — keep permissions across rebuilds

The committed default builds **unsigned** ([`App/Config/Signing.xcconfig`](App/Config/Signing.xcconfig)), so CI and fresh clones need no certificate. The catch: an unsigned build gets a new code identity on every rebuild, so macOS forgets Screen Recording (and every other granted permission) each time — while System Settings still shows the stale toggle as on.

To fix it, sign with your own stable identity via a gitignored override:

1. In Xcode → **Settings → Accounts**, add your Apple ID (a free one works), then **Manage Certificates → + → Apple Development**.
2. Find your **team ID** — it is the certificate's `OU` field, *not* the code in parentheses in the certificate name:

   ```bash
   security find-certificate -a -c "Apple Development" -p | openssl x509 -noout -subject
   # subject=UID=…, CN=Apple Development: you@example.com (NOT-THIS-ONE), OU=ABCDE12345, …
   ```

3. Create `App/Config/Local.xcconfig`:

   ```
   CODE_SIGNING_ALLOWED = YES
   CODE_SIGNING_REQUIRED = YES
   CODE_SIGN_STYLE = Automatic
   DEVELOPMENT_TEAM = ABCDE12345
   ```

4. Regenerate, rebuild, and clear the grants left over from unsigned builds (one time), then grant the permissions once more:

   ```bash
   xcodegen generate
   xcodebuild -project Lightshot.xcodeproj -scheme Lightshot -destination 'platform=macOS' build
   tccutil reset All dev.lightshot.app
   ```

Verify with `codesign -dr - <path-to>/Lightshot.app` — the designated requirement should name your certificate rather than a `cdhash`.

Don't set `CODE_SIGN*` keys in `project.yml`: target build settings there override the xcconfig. If you use [Conductor](https://conductor.build), [`.conductor/settings.toml`](.conductor/settings.toml) copies `Local.xcconfig` from your main checkout into each new workspace, so create it there.

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
