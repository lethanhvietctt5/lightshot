# Releasing Lightshot

`scripts/release.sh <X.Y.Z>` turns a clean, up-to-date `main` into a **draft** GitHub Release: it tests, builds a universal Release app, signs it with one fixed self-signed certificate, verifies the signature against the requirement pinned in `release-identity.txt`, packages a drag-to-Applications DMG, writes the update feed (`appcast.xml`, signed with the update signing key), tags `vX.Y.Z`, and uploads the DMG and the feed. Publishing the draft is a manual click, and it is also what ships the update: installed copies read the feed of the latest *published* release. The full contract is [spec 0002](../specs/0002-release-and-distribution.md), plus [spec 0015](../specs/0015-software-updates.md) for the feed.

```bash
scripts/release.sh 0.1.0 --dry-run   # steps 1–6 only: nothing tagged or uploaded; works on any branch
scripts/release.sh 0.1.0             # the real thing: must be on main == origin/main
```

Everything lands in `build/release/` (gitignored): the app, `Lightshot-<version>.dmg`, `appcast.xml`, `release-notes.md`, and `xcodebuild.log`. Swift packages (Sparkle and its release tools) resolve into `build/spm/`. If `docs/releases/<version>.md` exists, its contents are placed at the top of the release notes, ahead of the install instructions and checksum, and embedded in the feed as the update window's release notes.

## Why the identity is pinned

macOS ties Screen Recording (and every other TCC grant) to the app's *designated requirement*. For a self-signed identity that is `identifier "dev.lightshot.app" and certificate leaf = H"<sha1 of the certificate>"`. Sign every release with the same certificate and users keep their permissions across updates; sign one with a different certificate and every user's capture silently breaks. `release-identity.txt` holds the expected requirement and the script refuses to continue if the signed build's requirement differs (compared case-insensitively: `codesign` prints the hash in lowercase hex, `security find-identity` in uppercase). It contains only a public hash and is safe to commit.

Two things must never change casually: the bundle identifier `dev.lightshot.app` and this certificate.

## One-time setup: the signing certificate

The identity is a self-signed **Code Signing** certificate with common name **`Lightshot Release Signing`** and a **10-year** validity, stored in the maintainer's login keychain and marked as trusted for code signing (an untrusted certificate shows up in `security find-identity` as `CSSMERR_TP_NOT_TRUSTED`, and `codesign` refuses to use it).

### Option A — Keychain Access (GUI)

1. Open **Keychain Access** → **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `Lightshot Release Signing`. Identity Type: **Self Signed Root**. Certificate Type: **Code Signing**. Tick **Let me override defaults**.
3. Continue through the pages; set **Validity Period** to `3650` days. Leave the rest at defaults. Create it in the **login** keychain.
4. Certificates created this way are trusted for your account automatically. Confirm:

   ```bash
   security find-identity -v -p codesigning     # must list "Lightshot Release Signing" as valid
   ```

### Option B — command line

```bash
cat > /tmp/lightshot-signing.cnf <<'CNF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = Lightshot Release Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config /tmp/lightshot-signing.cnf -extensions ext \
  -keyout /tmp/lightshot-signing.key -out /tmp/lightshot-signing.crt
openssl pkcs12 -export -inkey /tmp/lightshot-signing.key -in /tmp/lightshot-signing.crt \
  -name "Lightshot Release Signing" -out ~/lightshot-release-signing.p12      # choose a password; keep it
security import ~/lightshot-release-signing.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign -A
# Trust it for code signing (asks for your login password):
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db /tmp/lightshot-signing.crt
rm /tmp/lightshot-signing.key /tmp/lightshot-signing.cnf
security find-identity -v -p codesigning     # must list "Lightshot Release Signing" as valid
```

If the identity is already in the keychain but untrusted, only the `add-trusted-cert` line is needed (or in Keychain Access: double-click the certificate → **Trust** → **Code Signing: Always Trust**).

### Back it up

Export the identity as a password-protected `.p12` and store it, with its password, in a password manager — never in the repo. In Keychain Access: **My Certificates** → right-click **Lightshot Release Signing** → **Export…** → file format **.p12**. Losing the key is recoverable but costly: a new certificate means every user re-grants permissions once, and `release-identity.txt` changes in a reviewed, announced commit.

### Pin the requirement

`release-identity.txt` is derived from the certificate. To generate or check it from a signed build:

```bash
scripts/release.sh 0.1.0 --dry-run                          # signs and prints the requirement if the file is missing
codesign -d -r- build/release/Build/Products/Release/Lightshot.app 2>/dev/null | sed -n 's/^designated => //p'
```

The `H"…"` value is the certificate's SHA-1 fingerprint (`security find-identity -p codesigning` shows it next to the name). Commit the file; the script compares against it on every run.

## One-time setup: the update signing key

In-app updates (spec 0015) trust a DMG only if it is signed with the **update signing key**, an EdDSA key pair made by Sparkle's `generate_keys`. The private half lives in the maintainer's login keychain; the public half is `SUPublicEDKey` in `App/Resources/Info.plist`. `release.sh` refuses to run if the keychain has no key or if its public half doesn't match the plist.

The key was created on 2026-09-27; its public half is committed. On a new Mac, restore it instead of creating a new one:

```bash
xcodebuild -resolvePackageDependencies -project Lightshot.xcodeproj -scheme Lightshot -clonedSourcePackagesDirPath build/spm
build/spm/artifacts/sparkle/Sparkle/bin/generate_keys -f lightshot-update-key.txt   # import the backup
build/spm/artifacts/sparkle/Sparkle/bin/generate_keys -p                            # must print SUPublicEDKey
```

### Back it up

```bash
build/spm/artifacts/sparkle/Sparkle/bin/generate_keys -x lightshot-update-key.txt   # export the private key
```

Store the file in a password manager next to the certificate's `.p12`, then delete it; never commit it. Losing the key strands users: every installed copy rejects updates signed with a new key, so each user would have to download the next version by hand once, and `SUPublicEDKey` would change in a reviewed, announced commit.

## Cutting a release

1. Make sure `main` is green, merged, and pushed; `git checkout main && git pull`.
2. Optionally write `docs/releases/<version>.md` with a `## Highlights` section (commit it first — the tree must be clean).
3. `scripts/release.sh <version> --dry-run` and look at `build/release/release-notes.md`; open the DMG.
4. `scripts/release.sh <version>` — creates and pushes tag `v<version>` and a draft release, then prints its URL.
5. Review the draft on GitHub and click **Publish release**. This is what ships the update: from then on, every installed copy that checks is offered this version.

## Before the first public release

Spec 0002's core claim, that a Screen Recording grant survives an update when both builds are signed with this certificate, has been reasoned about but **not yet observed**. On a Mac or a fresh macOS user account that has never run Lightshot: install a `--dry-run` build from its DMG, pass Gatekeeper, grant Screen Recording, capture; then build a second version with `--dry-run`, replace the app, and capture again. If it re-prompts or captures come back black, do not publish the "permissions carry over" wording — change the install copy in `release.sh` and `README.md` to say "re-grant after each update" and treat Developer ID signing as the real fix.
