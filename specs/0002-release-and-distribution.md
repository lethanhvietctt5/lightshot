# Spec 0002 — Release & Distribution (self-signed, direct download)

**Status:** draft — needs maintainer review before `ready-for-agent`
**Platform:** Native macOS, macOS 14+ · universal binary (arm64 + x86_64)
**Scope:** Build tooling and docs only. No app or domain code changes. The app stays local-only — nothing here adds networking to Lightshot itself.
**Depends on:** LIG-22 / PR #22 (`App/Config/Signing.xcconfig` — signing lives in the xcconfig, not `project.yml`).

---

## Problem Statement

Lightshot is open source and I want people to be able to download it and use it
without building from source. Spec 0001 deliberately left "notarization,
code-signing, and installer mechanics" out of scope, so today there is no
repeatable way to produce a downloadable app at all.

I am not enrolled in the paid Apple Developer Program, so I cannot notarize. That
leaves two problems for anyone who downloads a build:

1. **Gatekeeper blocks the first launch.** Unavoidable without a Developer ID;
   the best I can do is explain the one-time workaround clearly.
2. **macOS forgets the app's permissions on every update.** This is the same bug
   LIG-22 fixed for developers: an unsigned or ad-hoc build is identified by a
   per-build hash, so each new version is a different app to the permission
   system (TCC). For a screenshot tool that means capture silently breaks after
   every update while System Settings still shows the toggle as on. This one I
   *can* fix for free, and it is the point of this spec.

## Solution

A single script, `scripts/release.sh <version>`, run by the maintainer on their
Mac, that turns a clean `main` into a published download:

build Release (universal) → sign with **one fixed self-signed certificate** →
verify the signature is the expected one → package as a DMG → create a **draft**
GitHub Release with the DMG and its SHA-256.

Signing every release with the same certificate makes the app's designated
requirement `identifier "dev.lightshot.app" and certificate leaf = H"<hash>"`,
which is identical from version to version, so a user's Screen Recording grant
should carry across updates. Gatekeeper still warns on first launch; the README
and every release's notes carry step-by-step install instructions for that.

The script refuses to publish if the built app's designated requirement differs
from the one committed in the repo — signing a release with the wrong identity
would silently strand every existing user's permissions, so that mistake must be
impossible to make quietly.

## User Stories

Numbering continues from spec 0001 (which ends at 60).

### Users installing Lightshot

61. As a user, I want to **download a ready-made app** from the GitHub Releases page, so that I don't need Xcode to use Lightshot.
62. As a user, I want a **DMG with a drag-to-Applications layout**, so that installing works the way I expect on a Mac.
63. As a user, I want **clear instructions for the "Apple could not verify…" warning** for my macOS version, so that I can get past first launch without guessing.
64. As a user, I want my **permissions to survive an update**, so that capture doesn't silently break every time I install a new version.
65. As a user, I want a **published SHA-256 checksum**, so that I can confirm my download is the file the maintainer built.
66. As a user, I want the app to run natively on **both Apple Silicon and Intel** Macs from one download.
67. As a user, I want **update and uninstall instructions**, including how to clear leftover permission entries.

### Maintainer cutting a release

68. As the maintainer, I want **one command** to build, sign, package, and publish, so that a release is repeatable and not a checklist I can get wrong.
69. As the maintainer, I want the script to **fail before publishing anything** if the tree is dirty, I'm not on an up-to-date `main`, the tag already exists, or the signing identity is missing.
70. As the maintainer, I want the script to **fail if the signed app's identity is not the pinned one**, so that I can never ship a build that resets users' permissions.
71. As the maintainer, I want the GitHub Release created as a **draft**, so that I review the notes and artifact before anything is public.
72. As the maintainer, I want a documented **one-time procedure to create and back up the signing certificate**, so that losing a laptop doesn't mean losing the identity.

## Implementation Decisions

### The signing identity

- **One self-signed Code Signing certificate, common name `Lightshot Release Signing`**, created once in Keychain Access (Certificate Assistant → Create a Certificate → Identity Type: Self Signed Root, Certificate Type: Code Signing, override defaults to set a **10-year** validity). It lives in the maintainer's login keychain.
- **Backed up as a password-protected `.p12`** stored outside the repo (password manager). The private key is never committed. Losing it is recoverable but costly: a new certificate means every user re-grants permissions once, and the pinned requirement below changes in a reviewed commit.
- **The expected designated requirement is pinned in the repo** at `scripts/release-identity.txt` — a single line, e.g. `identifier "dev.lightshot.app" and certificate leaf = H"…"`. It contains only a public certificate hash, so it is safe to commit. It is the contract that makes story 70 checkable.
- **Invariants that must never change without a deliberate, announced break:** the bundle identifier `dev.lightshot.app` and this certificate. Either change resets every user's grants.
- **Separate from developer signing.** `Local.xcconfig` (LIG-22) keeps using each developer's Apple Development identity for Debug builds. The release script does not read it for signing: it builds with signing disabled on the command line and signs explicitly afterwards, so a release is identical no matter whose machine or `Local.xcconfig` produced it.
- **No Hardened Runtime, no entitlements file** in this spec. They are requirements of notarization, which is out of scope; enabling them with a self-signed identity adds risk and no benefit.

### `scripts/release.sh <version>` — step contract

Bash, `set -euo pipefail`, no dependencies beyond Xcode command-line tools, XcodeGen, and `gh`. Each step fails loudly and nothing is tagged or uploaded until every local check has passed.

1. **Preflight.** `<version>` matches `X.Y.Z`; working tree clean; on `main` and equal to `origin/main` after a fetch; tag `v<version>` does not exist locally or on the remote; `security find-identity -p codesigning` lists `Lightshot Release Signing`; `gh auth status` succeeds; `scripts/release-identity.txt` exists.
2. **Test.** `swift test` in `LightshotKit/` must pass.
3. **Build.** `xcodegen generate`, then `xcodebuild -configuration Release` into a throwaway `build/release/` derived-data path with `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO MARKETING_VERSION=<version> CURRENT_PROJECT_VERSION=<commit count> CODE_SIGNING_ALLOWED=NO`. Command-line settings override the xcconfig, so the developer's `Local.xcconfig` cannot leak into a release.
4. **Sign.** `codesign --force --sign "Lightshot Release Signing" --timestamp=none Lightshot.app`. Sign nested code inside-out first if any exists; do **not** use `--deep`. (A Release build has no `Lightshot.debug.dylib`; LightshotKit links statically — the script asserts there is no unsigned nested Mach-O rather than assuming.)
5. **Verify.** `codesign --verify --strict` passes; the output of `codesign -d -r-` equals `scripts/release-identity.txt` byte-for-byte (story 70); `lipo -archs` reports both architectures; the built `Info.plist` reports `<version>`. `spctl --assess` is run for information only — it is *expected* to reject a self-signed app.
6. **Package.** Stage `Lightshot.app` plus an `/Applications` symlink, then `hdiutil create -volname "Lightshot <version>" -srcfolder <stage> -format UDZO Lightshot-<version>.dmg`. Compute `shasum -a 256`. No third-party DMG tooling, no custom background art.
7. **Publish.** Create and push the annotated tag `v<version>`, then `gh release create v<version> Lightshot-<version>.dmg --draft --generate-notes` with the install-instructions block and the SHA-256 appended to the notes. The script prints the draft URL and stops; **publishing the draft is a manual click** (story 71).

- A `--dry-run` flag runs steps 1–6 and skips step 7, so the pipeline can be exercised without creating a tag or release.
- `build/` is already gitignored; the script writes nowhere else.

### Why a DMG rather than a zip

- A DMG with an `/Applications` alias steers the user to copy the app into `/Applications` before running it. That matters here beyond convention: a quarantined app launched from `~/Downloads` runs under App Translocation (a random read-only path), which interferes with launch-at-login and makes the permission entry confusing.
- `hdiutil` ships with macOS, so the DMG costs no extra dependency. A zip is not produced — one artifact, one checksum, one set of instructions.

### Install instructions (user-facing copy)

Added to `README.md` as a new **Install** section above *Getting started*, and appended to every release's notes by the script. Draft copy:

> **Install**
>
> 1. Download `Lightshot-<version>.dmg` from the [latest release](https://github.com/lethanhvietctt5/lightshot/releases/latest).
> 2. Open the DMG and drag **Lightshot** into **Applications**. Run it from there, not from the DMG or Downloads.
> 3. **First launch.** Lightshot is open source and not notarized by Apple (that requires a paid developer account), so macOS blocks it once:
>    - **macOS 15 or later:** open Lightshot, dismiss the warning, then go to **System Settings → Privacy & Security**, scroll to the message about Lightshot, and click **Open Anyway**.
>    - **macOS 14:** right-click Lightshot in Applications → **Open** → **Open**.
>    - **Or in Terminal:** `xattr -dr com.apple.quarantine /Applications/Lightshot.app`
> 4. Follow the in-app onboarding to grant **Screen Recording** (and any other listed permission).
>
> **Verify your download (optional):** `shasum -a 256 ~/Downloads/Lightshot-<version>.dmg` should match the checksum in the release notes.
>
> **Updating:** quit Lightshot, download the new DMG, and replace the app in Applications. Your permissions carry over — every release is signed with the same certificate. You will see the first-launch warning again for each new download.
>
> **Uninstalling:** quit Lightshot, delete it from Applications, and run `tccutil reset All dev.lightshot.app` to remove its permission entries.
>
> Prefer to build it yourself? See *Getting started*.

### Maintainer docs

- A **Releasing** section in `AGENTS.md` (commands) and a short `scripts/README.md` covering: creating the certificate, exporting/backing up the `.p12`, generating `scripts/release-identity.txt` from a first signed build, and running the script.

## Testing Decisions

- **The script's own verify step is the automated test.** Signature validity, the pinned designated requirement, both architectures, and the version string are all asserted on every run; `--dry-run` exercises everything short of publishing. There is no Swift code here, so nothing is added to `swift test`.
- **The core assumption is unproven and gates the first public release.** That a grant made against a self-signed designated requirement survives an update has been reasoned about but **not observed**. Before the first non-draft release, run this human-in-the-loop check on a Mac (or a fresh macOS user account) that has never run Lightshot:
  1. Build `0.0.1` with `--dry-run`, install from the DMG, get past Gatekeeper, grant Screen Recording, take a capture.
  2. Build `0.0.2` with `--dry-run`, replace the app, launch.
  3. **Pass:** capture works with no new permission prompt and no stale entry to remove. **Fail:** any re-prompt or black/empty capture.
- **If that check fails,** stop and revisit: the fallback is to ship anyway with "re-grant after each update" instructions and treat Developer ID + notarization as the real fix. Do not publish with the "permissions carry over" wording unless the check passed.
- **Install instructions are verified by following them** on both a macOS 14 and a macOS 15+ machine during that same check; wording is corrected to match what the OS actually shows.

## Out of Scope

- **Developer ID signing, Hardened Runtime, and notarization** — the real fix for the Gatekeeper warning; a later spec once there is a paid Apple Developer membership. The pinned-identity check is designed so that migration is a one-line change plus a one-time, announced permission reset.
- **Auto-update / in-app update checks (e.g. Sparkle).** They need networking inside the app, which the local-only v1 guardrail forbids. Users update by downloading the new DMG.
- **CI-built releases (GitHub Actions).** v1 is a local script; moving the `.p12` into CI secrets is a follow-up once the local flow is proven.
- **Homebrew cask.** Homebrew has been tightening its rules on casks that fail Gatekeeper; check the current policy before investing in this.
- **Mac App Store distribution** (requires App Sandbox and review).
- **Custom DMG artwork, license agreement panels, or a `.pkg` installer.**

## Further Notes

- **The repo has no `LICENSE` file.** "Open source" without a license means nobody else legally has the right to use, modify, or redistribute the code. Pick one (MIT and Apache-2.0 are the usual choices for a tool like this) **before** the first public release. Not part of this spec's implementation, but a prerequisite for shipping it.
- **`gh` on the maintainer's machine:** `GH_HOST` is currently set to the SSH alias `github.com-viet`, which is not a real API host, so plain `gh` calls fail. The script should pass `--repo lethanhvietctt5/lightshot` and run `gh` with `GH_HOST=github.com`, or the variable should be fixed in the shell profile.
- **Trust model, stated honestly.** A self-signed certificate proves only that two releases came from the same key holder — not who that is. The SHA-256 in the release notes and the public source are what a cautious user can actually check. The install copy must not imply Apple has vetted the app.
- **Certificate expiry.** How macOS treats an app whose self-signed certificate has expired (signatures here carry no secure timestamp, since Apple's timestamp service is not used) has **not been verified**. The 10-year validity is chosen so the question does not arise in practice; do not shorten it. Revisit if Developer ID has not replaced this certificate well before then.
