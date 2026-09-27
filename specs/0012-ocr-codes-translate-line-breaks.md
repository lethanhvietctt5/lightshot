# Spec 0012 — OCR Text extras: QR codes and barcodes, Translate, line breaks

**Status:** implemented — see *As built* at the end
**Linear:** [LIG-70](https://linear.app/light-shot/issue/LIG-70) (label `ready-for-agent`)
**Platform:** Native macOS (Swift / AppKit + SwiftUI), macOS 14+ (Translate needs macOS 14.4+)
**Scope:** Local-only. Three additions to OCR Text (spec 0010): a QR code or barcode in the selected area is decoded and its content copied, the "Text copied" notice offers **Translate** through macOS's built-in translation, and a **Keep line breaks** setting chooses between one line per row (today) and one paragraph. Amends spec 0010's *Out of Scope*, which listed all three.

Vocabulary is defined in [`CONTEXT.md`](../CONTEXT.md). New terms (**code capture**) are under *Further Notes*.

Parity reference: CleanShot X's Capture Text has a with/without line breaks choice. TextSniper and Shottr read QR codes and barcodes in the same selection as text. Neither CleanShot nor Shottr translate; TextSniper does. Nothing here needs a network call from Lightshot.

---

## Problem Statement

OCR Text only reads words. When the area I select holds a QR code (a Wi-Fi code, a 2FA setup key, a link on a slide) or a barcode, I get nothing useful: I have to find my phone, scan it, and send the result back to my Mac. When I grab a paragraph from a PDF or a web page rendered as an image, every visual line becomes its own line, so pasting into a document or chat gives me a ragged block I have to rejoin by hand. And when the text is in a language I can't read, I have to paste it into a translator myself.

## Solution

OCR Text now looks for QR codes and barcodes in the same pass as text. If the selected area contains one, its content is what lands on the clipboard (several codes: one per line, in reading order) and the notice says "QR code copied" or "Barcode copied" with the content. Text around the code is ignored in that case.

A new **OCR Text** section in Settings → Screenshots has **Keep line breaks**, on by default. Turned off, the rows of text are joined with spaces into one paragraph.

When text was copied, the notice shows a **Translate** button (macOS 14.4 and later). Clicking it opens a small Translate window with the text and macOS's translation popover, where I pick the languages. **Replace with Translation** in the popover swaps the window's text for the translation, and **Copy** puts whatever the window shows on the clipboard. The notice now stays about four seconds, and it stays while the pointer is over it.

## User Stories

### QR codes and barcodes

1. As a user, I want a QR code in my OCR Text selection decoded and its content copied, so that I don't need my phone to read a code on my screen.
2. As a user, I want barcodes (EAN, UPC, Code 128, PDF417, Data Matrix, Aztec and the other kinds macOS reads) decoded the same way, so that product and shipping codes work too.
3. As a user, I want the code's content, not the text around it, when the selection has both, so that I get the thing I aimed at.
4. As a user, I want several codes in one selection copied one per line, top to bottom and left to right, so that I get all of them.
5. As a user, I want the same code found twice copied only once, so that the clipboard isn't doubled up.
6. As a user, I want the notice to say "QR code copied" or "Barcode copied" with the content, so that I can check it before pasting.
7. As a user, I want a link in a QR code copied, not opened, so that a code on my screen can't send my browser anywhere I didn't choose.
8. As a user, I want a code whose content isn't text (binary data) skipped, so that I never paste garbage; if that leaves nothing, the text in the area is copied as before.
9. As a user, I want decoding on my Mac, so that nothing leaves it.

### Line breaks

10. As a user, I want a Keep line breaks setting for OCR Text, so that I can choose between lines as they looked and one flowing paragraph.
11. As a user, I want it on by default, so that OCR Text behaves as it did until I change it.
12. As a user, with it off, I want every row joined with a single space, so that a paragraph pastes as a paragraph.
13. As a user, I want the setting read at the moment I capture, so that a change applies to my next OCR Text.
14. As a user, I want the setting to leave QR code content alone, so that a multi-line code payload keeps its lines.

### Translate

15. As a user, I want a Translate button on the "Text copied" notice, so that I can read text in a language I don't know.
16. As a user, I want the notice to stay a little longer and to wait while my pointer is on it, so that I have time to click Translate.
17. As a user, I want Translate to open a small window with the text and macOS's translation popover, so that I choose the target language in the system's own UI.
18. As a user, I want Replace with Translation to put the translation in the window, and a Copy button that copies what the window shows, so that I can paste the translation.
19. As a user, I want the original text to stay on the clipboard until I click Copy, so that Translate never changes my clipboard behind my back.
20. As a user, I want to translate again from the window after closing the popover, so that I can try another language.
21. As a user, I want Translate to use macOS's translation (on my Mac, with any language download handled by macOS), so that Lightshot itself never sends my text anywhere.
22. As a user on macOS older than 14.4, I want no Translate button, so that I never click something that can't work.
23. As a user, I want no Translate button for a QR code or barcode, so that I'm not offered to translate a URL.

## Implementation Decisions

### Modules

- **`TextRecognizer` returns a `TextRecognition` (domain core).** `recognizeText(in:)` now returns `Result<TextRecognition, TextRecognitionError>`. `TextRecognition` holds `lines: [RecognizedLine]` and `codes: [RecognizedCode]`. `RecognizedCode` is a new value type: `payload: String`, `kind: .qrCode | .barcode`, `box: Rect` in image pixels, top-left origin. One recogniser call covers both, so the image is decoded once.
- **Pure assembly, `TextCapture` (domain core):**
  - `plainText(from:keepingLineBreaks:)`: rows as today, joined with `"\n"` when keeping line breaks and `" "` otherwise. The default argument keeps line breaks.
  - `codeCapture(from:) -> (text, kind)?`: the payloads that aren't empty after trimming, in reading order (the same row rule as lines: sorted by top, a code overlapping the row's anchor by half its height shares the row, left to right within a row), exact duplicates dropped after the first, joined with `"\n"`, plus the first of them's kind. Payloads aren't trimmed or altered otherwise. `nil` when no payload is left, so the code-wins rule lives in one place.
- **`TextCaptureStatus.codeCopied(String, RecognizedCode.Kind)` (new case).** The text and kind are `codeCapture`'s.
- **`AppCoordinator.captureText()` routing, after recognition:**
  - `codeCapture` returns a capture → `copyText` once with its text, then `.codeCopied(text, kind)`.
  - Otherwise, as spec 0010, with `plainText(from:keepingLineBreaks: settings.ocrKeepsLineBreaks)`.
- **`SettingsStore.ocrKeepsLineBreaks: Bool` (new).** Stored under `ocr.keepLineBreaks`, missing means `true`.
- **Vision recogniser (App).** The same `VNImageRequestHandler` performs the text request (unchanged settings) and a `VNDetectBarcodesRequest` with all supported symbologies. An observation with a `payloadStringValue` becomes a `RecognizedCode`; `.qr` and `.microQR` are `.qrCode` and everything else is `.barcode`. A barcode request failure alone doesn't fail recognition (text still counts).
- **Notice (App).**
  - `.copied` shows a **Translate** button when `#available(macOS 14.4, *)`. The panel accepts the mouse only in that state, stays about 4 s instead of 2, and its dismissal is paused while the pointer is inside it and restarts on exit. Other states are unchanged and still ignore the mouse.
  - `.codeCopied` reads "QR code copied" / "Barcode copied" with the first line of the content as detail, symbol `qrcode` / `barcode`, 2 s, no button.
- **Translate window (App, new, thin).** A small titled, non-modal window ("Translate") holding a read-only, selectable, scrolling text view of the recognised text, a **Translate** button and a **Copy** button. It attaches SwiftUI's `translationPresentation(isPresented:text:replacementAction:)` (macOS 14.4+) to the text, shown as soon as the window opens. The replacement action swaps the window's text for the translation. Copy writes the window's current text to the pasteboard as plain text. One window at a time: Translate from a newer notice replaces its text, the window keeps its place and size, and the popover opens again. Closing the window releases it.

### Settings

- Settings → Screenshots gets an **OCR Text** section with the **Keep line breaks** toggle. Footer: "Off joins the lines into one paragraph. A QR code or barcode in the area is copied instead of the text."

## Testing Decisions

- **What makes a good test:** as in spec 0010, assert the clipboard, the notice statuses and that nothing else happened, through the coordinator's fakes and hand-built lines and codes. Vision, the notice and the Translate window are verified by hand.
- **`TextCapture` (pure):**
  - Without line breaks, rows join with one space, and side-by-side lines still join with one space.
  - `codeCapture` orders codes by row then left to right, drops duplicates and blank payloads, keeps a multi-line payload intact, names the first copied code's kind, and returns `nil` when no payload is left.
- **`AppCoordinator.captureText()`:**
  - A code in the result copies its content (not the text) and presents `.codeCopied` with the first code's kind.
  - Codes with only blank payloads fall back to the text.
  - `ocrKeepsLineBreaks = false` copies the paragraph form; the default keeps lines.
  - The line-break setting doesn't change a code's content.
  - Mixed kinds are named by the first code in reading order.
  - Each new case also asserts nothing else happened: no image copied or written, no editor, no toolbar.
  - Existing spec 0010 and 0011 OCR tests keep passing with the new result type.
- **App side (manual, in the isolated `.verify` build):** run the real recogniser on fixture PNGs (a QR code, an EAN-13 barcode, a QR next to a caption, two QR codes, a paragraph) without the Screen Recording grant; check the notice's code and Translate states with the DEBUG `-previewTextNotice` switch; open the Translate window and translate a sample.

## Out of Scope

- Opening a link from a QR code, or any action on a code other than copying it.
- Generating QR codes.
- Choosing which of the text or the code to copy when both are present.
- Translation without the system UI (`TranslationSession`), a default target language setting, or translating automatically.
- Translate in the editor, on history items or on images opened from disk.
- A line-break choice per capture (for example a modifier key).
- Hyphenation repair when joining lines into a paragraph.

## Further Notes

- **Glossary additions** (`CONTEXT.md`):
  - **Code capture:** an OCR Text run whose selection held a QR code or barcode; its content is what's copied. _Avoid_: scan, QR read.
- **Why codes win over text.** A selection with a code in it is almost always aimed at the code. The caption next to it ("Scan to join Wi-Fi") is noise. A fixed rule keeps the flow one step with no chooser.
- **Why not open links.** Opening a scanned URL is a common phishing path. Copying keeps the user in charge of where it goes.
- **Local-only and translation.** Lightshot makes no network call. macOS's translation runs on the Mac with language models it manages; if a language isn't installed yet, macOS asks before downloading it. That download is the system's, not Lightshot's, and the user can decline it.

## As built

- **Verified offline** with the real `VisionTextRecognizer` and `TextCapture` on 2× fixture PNGs, without the Screen Recording grant:
  - A QR code with a URL gave `qrCode` and the URL.
  - A Code 128 barcode (`LS-4006381333931`) gave `barcode` and its content. CoreImage can't draw EAN-13, so Code 128 stood in.
  - A Wi-Fi QR code under the caption "Scan to join Wi-Fi" copied the `WIFI:…` payload, not the caption.
  - Two QR codes drawn right-then-left came back `first\nsecond`.
  - A three-line paragraph gave three lines with line breaks kept and one sentence with them off.
- **Timing:** barcode detection adds little. Warm runs took 31–185 ms. The first text request after launch is still slow while Vision loads its models (12–15 s here), as spec 0010 measured.
- **Barcodes are a second `perform` on the same handler**, so a barcode failure can't fail the text.
- **The system popover also has Copy Translation.** macOS's translation UI shows Replace with Translation and Copy Translation. So the translation can be copied straight from the popover, or put in the window with Replace and copied with the window's Copy. Both were checked in the `.verify` build: Replace swapped the window's text for the Spanish translation.
- **Notice:** "Text copied" with Translate stayed on screen past 6 s while hovered and faded after the pointer left. "QR code copied" and "Barcode copied" were checked with DEBUG `-previewTextNotice qr|barcode`.
- **Binary payloads (story 8):** Vision returned `payloadStringValue == nil` for a QR code holding 10 non-UTF-8 bytes (and `"hello"` for a text one), so the recogniser drops it before the core sees it.
- **Review follow-up:**
  - The Translate window is reused: a second Translate keeps the window where the user moved it and swaps in the new text. That was checked with DEBUG `-previewTextNotice copiedTwice`, which shows two "Text copied" notices 6 s apart.
  - The popover opens 150 ms after the window is ordered front. Asked for in the same turn, it has no on-screen view to anchor to and doesn't show.
- **Not verified live:** a real drag over an on-screen QR code, because the verify build has no Screen Recording grant of its own.
