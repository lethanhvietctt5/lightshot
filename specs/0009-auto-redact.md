# Spec 0009 — Auto Redact

**Status:** implemented — see *As built* at the end for where the build refined a decision
**Linear:** [LIG-63](https://linear.app/light-shot/issue/LIG-63) (label `ready-for-agent`)
**Platform:** Native macOS (Swift / SwiftUI + AppKit), macOS 14+
**Scope:** Local-only. The screenshot editor finds sensitive text, faces and codes in a capture on-device and redacts them in one step, using the redaction style the user has selected. Adds one pure module and one document command; no language model, no network.

Vocabulary used here is defined in [`CONTEXT.md`](../CONTEXT.md) (redaction, redaction style, blackout, obscuring, strength, scramble, backdrop). New terms (**auto redact**, **detection**, **sensitive-data category**) are defined under *Further Notes*.

Parity reference: this goes **beyond CleanShot X**. The installed bundle links Vision's text recognition (for its OCR capture), but shows no auto-redact or sensitive-data feature. No claim here rests on CleanShot behaviour.

---

## Problem Statement

Before I share a screenshot I have to find every secret in it myself: the email in a header, the API key in a terminal, the card number on a checkout page, the token in a URL bar. I draw a redaction over each one by hand. On a busy screenshot I miss things, and the thing I miss is exactly what I didn't want to leak. Redacting ten email addresses in a table takes ten separate drags.

## Solution

The redact tool gains an **Auto Redact** button (⇧⌘R). Pressing it recognises the text in the capture on-device, finds the sensitive parts, and immediately adds a redaction over each one. Every new redaction uses the **redaction style and strength currently selected** in the redact tool (pixelate by default, or blur, or blackout). The whole batch is one undo step. The redactions are ordinary: I can move, resize, restyle or delete each one afterwards.

A small chevron next to the button opens a checklist of sensitive-data categories (secrets, payment cards, emails, phone numbers, faces, …), remembered across launches. After a run, a short notice says what was redacted and reminds me that recognition can miss text. When the selected style is blur or pixelate, it also says that style is not secure.

## User Stories

### Running it

1. As a user, I want an Auto Redact button in the redact tool's options bar, so that I can hide everything sensitive in one click instead of dragging a region for each item.
2. As a user, I want ⇧⌘R to run Auto Redact from anywhere in the editor, so that I can do it without switching tools.
3. As a user, I want detection to run entirely on my Mac, so that the secrets I'm trying to hide are never sent anywhere.
4. As a user, I want the button to show that it is working while it scans, so that I don't press it again or think it did nothing.
5. As a user, I want to keep using the editor while a scan runs, so that a large Retina capture doesn't freeze the window.
6. As a user, I want the redactions to appear as soon as the scan finishes, with no confirmation step, so that the common case is one action.
7. As a user, I want the whole batch to be one undo step, so that ⌘Z removes all of it if the result is wrong.
8. As a user, I want ⌘⇧Z to bring the whole batch back after undoing it, so that undo and redo behave like every other edit.

### Style

9. As a user, I want auto redactions to use the redaction style I have selected, so that a batch matches the redactions I draw by hand.
10. As a user, I want them to use my current strength for blur and pixelate, so that the batch is as strong as I set it.
11. As a user, I want to restyle a single auto redaction afterwards with the style picker and slider, so that I can switch one item to blackout without redoing the batch.
12. As a user, I want each auto redaction to scramble differently and consistently, so that re-export never reshuffles it (the same guarantee as a hand-drawn redaction).
13. As a user, I want to be told when I've auto-redacted with blur or pixelate that the style is not secure, so that I'm never led to hide a password with obscuring.

### What it finds

14. As a user, I want API keys and access tokens redacted (AWS, GitHub, Stripe, Slack, Google, OpenAI/Anthropic-style keys, JWTs, private-key blocks), so that a terminal or dashboard screenshot doesn't leak credentials.
15. As a user, I want the value after a label like "Password:", "Token =", "Secret" or "API key" redacted, so that credentials without a recognisable format are still hidden.
16. As a user, I want the label itself left visible, so that the reader still knows what was hidden.
17. As a user, I want a value in a separate column on the same row as its label redacted, so that settings screens and forms laid out in two columns are covered.
18. As a user, I want long random-looking strings redacted, so that secrets with unknown prefixes are caught.
19. As a user, I want commit hashes and similar hex identifiers left alone unless they're labelled as secret, so that developer screenshots aren't covered in false positives.
20. As a user, I want card numbers redacted only when they pass the checksum, so that order numbers and other long digit runs stay readable.
21. As a user, I want IBANs redacted when they pass the IBAN checksum, so that bank details are hidden.
22. As a user, I want email addresses redacted, so that a mail client or user list can be shared.
23. As a user, I want phone numbers redacted, so that contact details are hidden.
24. As a user, I want US Social Security numbers redacted, so that ID numbers are hidden.
25. As a user, I want IPv4 and IPv6 addresses redacted, so that network screenshots don't expose hosts.
26. As a user, I want to opt in to redacting postal addresses, so that I can hide them when they matter without false positives the rest of the time.
27. As a user, I want to opt in to redacting links, so that URLs carrying tokens can be hidden without covering every link by default.
28. As a user, I want to opt in to redacting faces, so that people in a video call or photo can be hidden.
29. As a user, I want QR codes and barcodes redacted, so that login, pairing and 2FA-setup codes can't be scanned from my screenshot.
30. As a user, I want only the sensitive part of a line covered, not the whole line, so that the rest of the screenshot stays readable.
31. As a user, I want a margin around each redaction, so that the edges of glyphs don't peek out.
32. As a user, I want neighbouring matches on the same line merged into one redaction, so that a card number split by spaces becomes one box, not four.
33. As a user, I want text I typed as an annotation to be scanned too, so that a secret I pasted into a text box is caught.

### Categories

34. As a user, I want a checklist of categories next to the button, so that I choose what counts as sensitive for my work.
35. As a user, I want my category choices remembered across launches, so that I set them once.
36. As a user, I want sensible defaults on first use, so that the button is useful before I open the checklist.
37. As a user, I want the checklist to say which categories are on, so that I know what a run will look for.

### Re-running and crop

38. As a user, I want a second run to skip anything already covered by a redaction, so that pressing the button twice doesn't stack duplicates.
39. As a user, I want a second run to catch what I've enabled since, so that turning on Faces and re-running adds only faces.
40. As a user, I want only what's inside my crop redacted, so that items outside the exported area don't clutter the document.
41. As a user, I want a redaction on an item that crosses the crop edge clipped to the crop, so that it covers the visible part exactly.

### Feedback and honesty

42. As a user, I want a notice after each run saying how many items were redacted, by category, so that I can tell at a glance whether it found what I expected.
43. As a user, I want that notice to remind me that text recognition can miss things, so that I still look before I share.
44. As a user, I want a clear "nothing found" notice when a run adds nothing, so that I know it ran rather than failed silently.
45. As a user, I want a clear error if recognition itself fails, so that I don't mistake a failure for a clean screenshot.
46. As a user, I want the notice to go away on its own and not block editing, so that it doesn't get in the way.
47. As a user, I want the app never to describe Auto Redact as a guarantee, so that I'm not given false confidence.

## Implementation Decisions

### Modules

- **`SensitiveDataScanner` (new, pure, in the domain core).** Takes recognised text plus face and code rectangles and returns categorised **detections**: image-space rectangles, padded and merged. It uses Foundation only (`NSDataDetector` and regular expressions are Foundation) and imports no Vision, AppKit or ScreenCaptureKit. This is the main test seam. It's the same split as captions: the App-side transcriber produces a pure `StudioTranscript`, and the core turns it into caption lines.
- **`AnnotationDocument` (existing seam, one new command).** `add(contentsOf: [AnnotationElement]) -> [ElementID]` appends every element on top of the z-order in a **single** history entry. An empty list is a no-op and records no undo step. It shares `add`'s semantics per element (a step marker is still renumbered), so it isn't a redaction-only command.
- **A pure planning function beside the scanner** turns detections into redaction elements for a given document. It takes the detections, the document, the redaction style, the strength, and a seed source. It clips each detection to the document's visible frame, drops detections outside the frame, and drops any detection at least 80% covered by one existing redaction. Then it builds one `.redaction` element per remaining detection, each with its own seed. Deduplication and crop clipping are domain behaviour, so they live here, not in the editor.
- **Text/face/code recogniser (new, App side, thin).** A caseless enum like `SpeechTranscriber`. It runs Vision's `VNRecognizeTextRequest`, `VNDetectFaceRectanglesRequest` and `VNDetectBarcodesRequest` on one image and returns the scanner's input value types. Vision is imported **only** here. It holds no detection logic.
- **Editor model and view (App).** They wire the button, the shortcut, the category menu, the in-flight state and the notice, and call the three pieces above in order.

### Data shapes

The scanner's input and output, in prose (names may change in implementation):

- A **recognised line** is its text exactly as recognised, plus a list of **words**. Each word is a character range into the line's text and an image-space rectangle. The line's own rectangle is the union of its words.
- The **scan input** is the recognised lines, the face rectangles, and the code rectangles, all in image pixel coordinates (top-left origin), plus the frame they were recognised in.
- A **detection** is a sensitive-data category plus one image-space rectangle.
- **Sensitive-data categories:** `secret`, `paymentCard`, `bankAccount`, `email`, `phone`, `idNumber`, `ipAddress`, `postalAddress`, `link`, `face`, `code`. The set is `CaseIterable` and `Codable` so the settings can store it by raw value.

### Scanning rules

- **Matching runs over each line's text.** The matched character range is mapped to rectangles through the words it overlaps. A match that covers only part of a word (`password:hunter2`) takes a horizontal slice of that word's rectangle, in proportion to character offsets. Vision's own per-character boxes are approximations, so the adapter asks only for word boxes.
- **Secrets:**
  - Known key formats by prefix and shape: AWS access keys (`AKIA`/`ASIA` + 16), GitHub (`ghp_`, `gho_`, `ghs_`, `ghu_`, `github_pat_`), Stripe (`sk_live_`, `rk_live_`, `sk_test_`), Slack (`xox[abpors]-`), Google (`AIza` + 35), `sk-`-style LLM keys, JWTs (three dot-separated base64url segments starting `eyJ`), and a `-----BEGIN … PRIVATE KEY-----` line. In a key block, the header line, every following line and the `END` line are each covered (lines are never merged with each other).
  - **Labelled values:** a label (`password`, `passwd`, `pwd`, `passcode`, `secret`, `token`, `api key`/`api_key`/`apikey`, `access key`, `client secret`, `private key`, case-insensitive) followed by `:` or `=`. The value is the rest of that line after the separator. A line that is *only* a label (optionally with its colon) takes as its value the nearest line to its right whose vertical extent overlaps the label's by at least half. The label is never covered. Requiring the separator keeps "Token count: 5" readable.
  - **High-entropy tokens:** a whitespace-free token of at least 20 characters that mixes upper case, lower case and digits, with Shannon entropy of at least 3.5 bits per character. Pure-hex tokens don't qualify (commit hashes) unless labelled. URLs and file paths are judged by their longest segment, not as a whole. These thresholds are a starting point, tuned against the fixtures.
- **Payment cards:** 13–19 digits, with optional single spaces or dashes between groups, passing the Luhn check.
- **Bank accounts:** IBANs (country code, check digits, up to 30 alphanumerics, optional spaces) passing mod-97.
- **Email:** a regular expression. **Phone, postal address, link:** `NSDataDetector`, whose readings are the weakest: one that overlaps any other match (a card number read as a phone, an email inside a link) is dropped before the category filter, so switching a category off never lets its text resurface as another. A phone number must have 7–15 digits (E.164), so a 16-digit order number is not one.
- **ID numbers:** US SSNs, `###-##-####`, excluding invalid area numbers (`000`, `666`, `9xx`), group `00` and serial `0000`.
- **IP addresses:** dotted IPv4 with each octet 0–255, and IPv6 in full or compressed form.
- **Faces and codes:** every rectangle the recogniser returns, in its category.
- **Overlaps across categories:** when two detections overlap, both are kept. Merging below removes the duplicate area.
- **Padding:** text detections grow by 20% of their line's height on every side. Faces grow by 10% of their size. Codes grow by 4 px. Everything is rounded outward to whole pixels.
- **Merging:** detections on the same line are merged into one rectangle when their padded rectangles touch or overlap, whatever their categories. The merged detection keeps the first match's category. Detections on different lines are never merged.

### Default categories

- On: `secret`, `paymentCard`, `bankAccount`, `email`, `phone`, `idNumber`, `ipAddress`, `code`.
- Off: `postalAddress` (address detection is noisy), `link` (most links aren't sensitive), `face` (avatars would be covered on every chat screenshot).
- The enabled set is stored in user defaults by the editor, like the last arrow style, and survives relaunch.

### Recognition

- The adapter scans the **backdrop of the whole document**: the base image plus every existing element, flattened over the visible frame. `redactionBackdrop(document, below: elements.count)` already produces it. Text annotations are scanned too, and pixels already under a blackout are gone and can't be detected twice.
- Text recognition uses `.accurate`, `usesLanguageCorrection = false` (correction would "fix" keys into words), and `automaticallyDetectsLanguage = true`. It works on the backdrop's image and converts Vision's normalised, bottom-left rectangles into image pixel coordinates by adding the backdrop frame's origin.
- Words come from splitting each observation's top candidate on whitespace and asking `boundingBox(for:)` for each word's range.
- Recognition runs off the main actor. The editor stays interactive. While a scan is in flight the button is disabled, a second press is ignored, and the notice area shows "Looking for sensitive text…" with a spinner (the first scan after launch can take several seconds while Vision loads its models).
- If recognition throws, no elements are added and the notice shows the error. An empty result is a success with nothing found, not an error.

### Applying

- When the scan finishes, the planning function runs against the document **as it is at that moment** (so a crop made during the scan is respected), and `add(contentsOf:)` commits the result as one undo step.
- The style and strength are the editor's current redaction style and strength when the scan **finishes**. That's the same pair a new hand-drawn redaction would use; it's pixelate by default because the redact tool opens at pixelate (spec 0004). Seeds are random per element, like hand-drawn ones.
- The selection is cleared after applying. The document has a single selection, and selecting one of many new items would be arbitrary.
- Pressing ⇧⌘R or the button doesn't switch the active tool.

### Notice

- A transient, non-modal notice in the editor, dismissed after about five seconds or by clicking it.
- On success: "Redacted N items — 3 emails, 2 secrets, 1 card" (categories that occurred, largest first), then "Text recognition can miss things — check before sharing."
- If the style is blur or pixelate, it adds: "Pixelate isn't secure — use Blackout for passwords and keys." (or "Blur isn't secure — …").
- Nothing found: "Found nothing to redact — text recognition can miss things, so check before sharing."
- Failure: the recogniser's localised error.
- The UI never uses "secure", "guaranteed" or "all" about auto redact. The existing "Not secure" label beside the style picker is unchanged.

### UI placement

- The redact tool's options bar gets an Auto Redact button (`wand.and.sparkles`) after the "Secure"/"Not secure" label, with a narrow chevron beside it. The wand runs Auto Redact; the chevron opens a popover with the category checklist (checkboxes). The wand's tooltip names the shortcut. The pair is compact (about 40 px), not a bordered split button, because a split button pushed Copy and Done into the toolbar's overflow in a 1180 px editor window.
- ⇧⌘R is bound in the editor window and works whichever tool is active. It's unused in the editor today.

## Testing Decisions

- **What makes a good test here:** assert what a user would see — which rectangles are redacted, in what style, and how many undo steps they take — given recognised text. Don't assert which regex or detector produced a match, the order rules run in, or internal token lists. Inputs are hand-built recognised lines with word boxes, so no test touches Vision, a screen or a permission.
- **`SensitiveDataScanner` (the primary seam), Swift Testing:**
  - Each category finds a positive example and ignores a near miss:
    - Payment cards: a Luhn-valid card is found; the same digits with one changed are not.
    - IBANs: a valid IBAN is found; a bad check digit is not.
    - SSNs: a real-format SSN is found; `000-12-3456` is not.
    - IPs: valid IPv4 and IPv6 are found; `999.1.1.1` is not.
    - Known key formats are found.
    - Git SHAs: a 40-character SHA is not found unless it follows "token:".
  - Only the value is covered: "Password: hunter2" produces one rectangle over `hunter2` only. A label in one column with its value in the next produces a rectangle over the value line.
  - A partial-word match's rectangle is the proportional slice of the word.
  - A private-key block covers every line from `BEGIN` to `END`.
  - Padding and merging: a spaced card number yields one merged rectangle. Two emails on different lines stay two.
  - Disabling a category removes exactly its detections.
  - Faces and codes pass through padded.
- **Planning function:**
  - A detection straddling the crop is clipped to it; one outside is dropped.
  - A detection 80% or more covered by an existing redaction is dropped; one less covered is kept.
  - Elements carry the given style and strength, and distinct seeds.
- **`AnnotationDocument`:**
  - `add(contentsOf:)` adds all elements on top in order.
  - One `undo` removes all of them; `redo` restores all of them.
  - An empty list leaves history unchanged.
  - A later edit still undoes separately.
- **`render`:** no new tests are needed. An auto redaction is an ordinary `.redaction` element, and `DocumentRenderTests` already asserts that blackout erases a sentinel while blur and pixelate obscure it.
- **Prior art:**
  - `AnnotationDocumentTests` covers command and undo semantics.
  - `StudioCaptionTests` covers a pure transform over recognised-speech value types. It's the same shape as recognised text in, detections out.
  - `DocumentRenderTests` covers redaction output.
- **Vision adapter (no unit-test target in `App/`):** verified with the isolated `.verify` Debug build and a set of fixture PNGs rendered at 1× and 2×. The set covers a terminal with an AWS key and a JWT, a mail list with emails, a checkout form with a card number and a "Password" label/value pair, a network panel with IPs, and a QR code. Each fixture's expected redaction rectangles are checked by eye against the output. No Screen Recording permission is needed, since fixtures are opened as files. Record the results in the PR.

## Out of Scope

- Any language model, on-device or remote, and the Foundation Models framework.
- Personal and organisation names (`NLTagger`) and any other "looks confidential" judgement.
- A review step before applying (checkboxes per detection, dashed previews). Auto Redact applies immediately; ⌘Z and per-item delete are the review.
- Running automatically on capture or on opening the editor.
- User-defined patterns or custom labels.
- Values on the line **below** a label (stacked form layouts). Only same-line and same-row values are covered.
- Rotated, curved or handwritten text, and text Vision doesn't recognise. Recognition quality is Vision's.
- Non-US national ID formats.
- Auto redact in the Studio video editor or on recordings.
- New redaction styles, and any change to what counts as secure redaction.
- A multi-selection of the new redactions.

## Further Notes

- **Glossary additions** (now in `CONTEXT.md` under *Redaction*):
  - **Auto redact:** adding redactions over detections in one step, using the current redaction style. _Avoid_: smart redact, auto blur, secure scan.
  - **Detection:** one found item — a sensitive-data category and an image-space rectangle. It's not a redaction until applied.
  - **Sensitive-data category:** a kind of thing auto redact looks for. The user chooses which are on.
- **The guardrail holds.** Auto redact only chooses *where* redactions go. Only blackout is secure redaction, and it stays that way. Because auto redact follows the user's selected style (pixelate by default), the notice's "isn't secure" line is what keeps a pixelated batch from reading as safe. Changing the default style for auto redact would be a spec change to this section.
- **Why OCR the backdrop, not the base image.** Scanning what the user will actually export catches typed annotations and skips blacked-out areas. It also keeps the geometry in the same frame `redactionBackdrop` already defines (see [ADR 0001](../docs/adr/0001-core-image-blur-and-shared-redaction-patch.md)).
- **Performance expectation:** accurate text recognition on a full 5K capture takes roughly half a second to a couple of seconds on Apple silicon. That's why it runs off the main actor with a progress state, and not on every edit.
- **Detection is best-effort by nature.** Every piece of user-facing copy must keep telling the user to check before sharing.

## As built

- **Button.** A compact wand plus a narrow chevron instead of a bordered split button: the wand runs Auto Redact, the chevron opens a popover with the checklist (see *UI placement*). Press-and-hold was tried first and dropped as hard to discover. Even so, in an editor window narrower than about 1230 px, Done moves into the toolbar's `>>` overflow while the redact tool is active. Without the button that happens below about 1175 px; ⌘S still works either way.
- **Category storage.** User defaults via the editor, not `SettingsStore` (see *Default categories*).
- **Labels need a separator**, a bare label takes the next column, key-block lines are covered one by one, and phone numbers are capped at 15 digits (see *Scanning rules*).
- **Progress** shows in the notice area (see *Recognition*).
- **Development aid:** DEBUG builds accept `-previewAutoRedact YES` alongside `-previewSurface editor -previewFile <png>` to open the redact tool and run Auto Redact once.
- **Verified** on fixture PNGs (terminal with an AWS key, JWT, commit hash and IP; mail list with emails and a phone number; checkout form with card, password column, IBAN, a Luhn-invalid order number and a TOTP QR code). Everything expected was covered; the commit hash, the order number and every label stayed readable.

