#!/usr/bin/env bash
#
# scripts/release.sh — turn a clean, up-to-date `main` into a draft GitHub Release.
#
#   scripts/release.sh <X.Y.Z> [--dry-run]
#
# Steps (spec 0002): preflight → test → build Release (universal) → sign with the one
# pinned self-signed identity → verify → package DMG → tag + draft release.
# `--dry-run` runs everything except the tag/release step, so the pipeline can be
# exercised on any branch without publishing anything.
#
# Everything is written under build/release/ (gitignored). Nothing is tagged or
# uploaded until every local check has passed.
set -euo pipefail

REPO_SLUG="lethanhvietctt5/lightshot"
IDENTITY="Lightshot Release Signing"
BUNDLE_ID="dev.lightshot.app"
SCHEME="Lightshot"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
usage() {
  echo "usage: $0 <X.Y.Z> [--dry-run]" >&2
  exit 2
}

VERSION=""
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage ;;
    -*) echo "unknown flag: $arg" >&2; usage ;;
    *) [[ -z "$VERSION" ]] || usage; VERSION="$arg" ;;
  esac
done
[[ -n "$VERSION" ]] || usage

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TAG="v$VERSION"
BUILD_DIR="build/release"
IDENTITY_FILE="scripts/release-identity.txt"
NOTES_TEMPLATE="docs/releases/$VERSION.md"

# The maintainer's shell sets GH_HOST to an SSH alias that is not a real API host.
export GH_HOST=github.com

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
fail() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Preflight — every check that can fail cheaply, before anything is built
# ---------------------------------------------------------------------------
step "Preflight ($TAG$([[ $DRY_RUN == 1 ]] && echo ', dry run'))"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like X.Y.Z, got '$VERSION'"

for tool in git xcodegen xcodebuild codesign lipo hdiutil shasum gh; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done

[[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean; commit or discard changes first"

git fetch --quiet origin main
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" || "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  if [[ $DRY_RUN == 1 ]]; then
    warn "not on an up-to-date main (on '$BRANCH'); allowed only because this is a dry run"
  else
    fail "releases are cut from main only, and it must equal origin/main (on '$BRANCH')"
  fi
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  fail "tag $TAG already exists locally"
fi
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  fail "tag $TAG already exists on origin"
fi

if ! security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    fail "signing identity '$IDENTITY' exists but is not trusted for code signing — see scripts/README.md (trust the certificate)"
  fi
  fail "signing identity '$IDENTITY' not found in the keychain — see scripts/README.md (create the certificate)"
fi

gh auth status >/dev/null 2>&1 || fail "gh is not authenticated (run: GH_HOST=github.com gh auth login)"

if [[ -f "$IDENTITY_FILE" ]]; then
  EXPECTED_REQUIREMENT="$(tr -d '\n' < "$IDENTITY_FILE")"
  [[ -n "$EXPECTED_REQUIREMENT" ]] || fail "$IDENTITY_FILE is empty"
elif [[ $DRY_RUN == 1 ]]; then
  EXPECTED_REQUIREMENT=""
  warn "$IDENTITY_FILE is missing; the verify step will print the requirement to pin"
else
  fail "$IDENTITY_FILE is missing — run a --dry-run first and commit the pinned requirement"
fi

BUILD_NUMBER="$(git rev-list --count HEAD)"
note "commit $(git rev-parse --short HEAD), build number $BUILD_NUMBER"

# ---------------------------------------------------------------------------
# 2. Test — the domain core must be green
# ---------------------------------------------------------------------------
step "Test (swift test in LightshotKit/)"
(cd LightshotKit && swift test 2>&1 | tail -n 3) || fail "swift test failed"

# ---------------------------------------------------------------------------
# 3. Build — Release, universal, unsigned; command-line settings win over any
#    developer Local.xcconfig so the build is the same on every machine.
# ---------------------------------------------------------------------------
step "Build Release (arm64 + x86_64)"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
xcodegen generate --quiet
xcodebuild \
  -project Lightshot.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  build > "$BUILD_DIR/xcodebuild.log" 2>&1 || {
    tail -n 40 "$BUILD_DIR/xcodebuild.log"
    fail "xcodebuild failed (full log: $BUILD_DIR/xcodebuild.log)"
  }

APP="$BUILD_DIR/Build/Products/Release/Lightshot.app"
[[ -d "$APP" ]] || fail "built app not found at $APP"
EXECUTABLE="$APP/Contents/MacOS/Lightshot"
note "built $APP"

# ---------------------------------------------------------------------------
# 4. Sign — one explicit codesign on the bundle, no --deep. LightshotKit links
#    statically and a Release build has no debug dylib, so there must be no
#    nested Mach-O to sign inside-out; assert that rather than assume it.
# ---------------------------------------------------------------------------
step "Sign with '$IDENTITY'"
NESTED="$(find "$APP" -type f ! -path "$EXECUTABLE" -print0 \
  | xargs -0 file --no-pad 2>/dev/null | grep 'Mach-O' | cut -d: -f1 || true)"
if [[ -n "$NESTED" ]]; then
  echo "$NESTED"
  fail "unexpected nested Mach-O code in the bundle; it would need signing inside-out first"
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
note "signed"

# ---------------------------------------------------------------------------
# 5. Verify — signature, pinned designated requirement, both architectures,
#    version and bundle id. spctl is informational only.
# ---------------------------------------------------------------------------
step "Verify"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

ACTUAL_REQUIREMENT="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p')"
[[ -n "$ACTUAL_REQUIREMENT" ]] || fail "could not read the designated requirement"
if [[ -z "$EXPECTED_REQUIREMENT" ]]; then
  note "designated requirement: $ACTUAL_REQUIREMENT"
  note "pin it with:  printf '%s\\n' '$ACTUAL_REQUIREMENT' > $IDENTITY_FILE"
  fail "$IDENTITY_FILE is missing — commit the pinned requirement above, then rerun"
fi
# codesign prints the certificate hash in lowercase hex; `security find-identity` shows it
# in uppercase. Compare case-insensitively so a hand-pinned file cannot fail a correct build.
if [[ "$(tr '[:upper:]' '[:lower:]' <<< "$ACTUAL_REQUIREMENT")" != "$(tr '[:upper:]' '[:lower:]' <<< "$EXPECTED_REQUIREMENT")" ]]; then
  note "expected: $EXPECTED_REQUIREMENT"
  note "actual:   $ACTUAL_REQUIREMENT"
  fail "signed with a different identity than the one pinned in $IDENTITY_FILE — shipping this would reset every user's permissions"
fi
note "designated requirement matches $IDENTITY_FILE"

ARCHS="$(lipo -archs "$EXECUTABLE")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || fail "expected a universal binary, got: $ARCHS"
note "architectures: $ARCHS"

PLIST="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
[[ "$(plist CFBundleShortVersionString)" == "$VERSION" ]] || fail "Info.plist version is $(plist CFBundleShortVersionString), expected $VERSION"
[[ "$(plist CFBundleVersion)" == "$BUILD_NUMBER" ]] || fail "Info.plist build is $(plist CFBundleVersion), expected $BUILD_NUMBER"
[[ "$(plist CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail "bundle identifier is $(plist CFBundleIdentifier), expected $BUNDLE_ID"
note "version $VERSION ($BUILD_NUMBER), bundle id $BUNDLE_ID"

if spctl --assess --type execute "$APP" >/dev/null 2>&1; then
  note "spctl: accepted"
else
  note "spctl: rejected (expected for a self-signed app; users get the first-launch warning)"
fi

# ---------------------------------------------------------------------------
# 6. Package — drag-to-Applications DMG plus its SHA-256 and the release notes
# ---------------------------------------------------------------------------
step "Package"
STAGE="$BUILD_DIR/dmg-root"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Lightshot.app"
ln -s /Applications "$STAGE/Applications"

DMG="$BUILD_DIR/Lightshot-$VERSION.dmg"
hdiutil create -quiet -ov -volname "Lightshot $VERSION" -srcfolder "$STAGE" -format UDZO "$DMG"
SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
note "$DMG"
note "sha256 $SHA256"

NOTES="$BUILD_DIR/release-notes.md"
{
  if [[ -f "$NOTES_TEMPLATE" ]]; then
    cat "$NOTES_TEMPLATE"
    echo
  fi
  cat <<NOTES_EOF
## Install

1. Download \`Lightshot-$VERSION.dmg\` below.
2. Open the DMG and drag **Lightshot** into **Applications**. Run it from there, not from the DMG or Downloads.
3. **First launch.** Lightshot is open source and not notarized by Apple (that requires a paid developer account), so macOS blocks it once:
   - **macOS 15 or later:** open Lightshot, dismiss the warning, then go to **System Settings → Privacy & Security**, scroll to the message about Lightshot, and click **Open Anyway**.
   - **macOS 14:** right-click Lightshot in Applications → **Open** → **Open**.
   - **Or in Terminal:** \`xattr -dr com.apple.quarantine /Applications/Lightshot.app\`
4. Follow the in-app onboarding to grant **Screen Recording**.

**Verify your download (optional):** \`shasum -a 256 ~/Downloads/Lightshot-$VERSION.dmg\` should print the checksum below.

**Updating:** quit Lightshot, download the new DMG, and replace the app in Applications. Every release is signed with the same certificate, so your permissions carry over. You will see the first-launch warning again for each new download.

**Uninstalling:** quit Lightshot, delete it from Applications, and run \`tccutil reset All $BUNDLE_ID\`.

Requires macOS 14 or later. Universal binary (Apple Silicon and Intel).

## Checksum

\`\`\`
$SHA256  Lightshot-$VERSION.dmg
\`\`\`
NOTES_EOF
} > "$NOTES"
note "release notes: $NOTES"

# ---------------------------------------------------------------------------
# 7. Publish — annotated tag, then a DRAFT release. Publishing the draft is a
#    manual click after reviewing the notes and the artifact.
# ---------------------------------------------------------------------------
if [[ $DRY_RUN == 1 ]]; then
  step "Dry run complete — nothing tagged or uploaded"
  note "artifact: $DMG"
  note "notes:    $NOTES"
  exit 0
fi

step "Publish draft release $TAG"
git tag -a "$TAG" -m "Lightshot $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$DMG" \
  --repo "$REPO_SLUG" \
  --draft \
  --generate-notes \
  --title "Lightshot $VERSION" \
  --notes-file "$NOTES"

step "Done — review and publish the draft:"
gh release view "$TAG" --repo "$REPO_SLUG" --json url --jq .url
