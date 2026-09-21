# Spec 0003 — CleanShot Parity: Arrow Styles and Blur

**Status:** implemented on branch, not yet tracked in Linear
**Linear:** _none yet — create two issues (arrow, redaction) and link them here_
**Platform:** Native macOS (Swift / SwiftUI), macOS 14+
**Scope:** Local-only. Two editor tools brought in line with CleanShot X 4.8.3. Amends Spec 0001's `arrow` and `redaction` elements; adds no new seams.

Vocabulary used here is defined in [`CONTEXT.md`](../CONTEXT.md). The Core Image decision is recorded in [ADR 0001](../docs/adr/0001-core-image-blur-and-shared-redaction-patch.md).

---

## Problem Statement

Two tools don't feel like the CleanShot X tools they stand in for.

**The arrow** is a constant-width line with a triangle on the end. CleanShot's default arrow tapers from a thin tail into the head, and it offers three more styles, two of them curved. Ours can't bend, and a selected arrow gets an eight-handle bounding box, so I can't put the tip exactly where I want it.

**The blur** doesn't look like a blur — it is the region shrunk and stretched back — and I can't see it at all while I work: the canvas shows a flat grey box until I export. There is no way to make it stronger or weaker.

## Solution

**Arrows** come in CleanShot's four styles — **standard**, **fancy**, **curved**, **double** — chosen from a picker that appears while drawing arrows or with one selected. The last style used is remembered across launches. Curved and double arrows are drawn with a gentle arc and carry a **bend** handle on the middle of the shaft; a selected line or arrow is reshaped by round **endpoint handles** (tail, tip, bend) instead of a bounding box.

**Blur** is a real Gaussian blur and **pixelate** real blocks, both scrambled first, with one **Intensity** slider shared by the two. The canvas shows the actual obscured pixels — while dragging the region out, and afterwards — cut by the same code the export uses.

## What "same as CleanShot" rests on

| Claim | Evidence |
|---|---|
| Four arrow styles named Standard, Fancy, Curved, Double; last style remembered | Asset and defaults-key names in the 4.8.3 bundle (`annotateArrowStyle*`, `annotateLastArrowStyle`) |
| Shape of each style (taper, soft vs. barbed head, open heads on curved/double) | The four style icons extracted from the bundle (`.context/reference/`) |
| Blur is `CIGaussianBlur`; pixelate is randomized; one intensity setting | Filter names and `annotatePixelateIntensity` in the binary; changelog v3.5, v4.1 |
| Styles: Pixelate, Blur, Secure Blur, Black Out | Asset names; changelog v4.2 |
| Bend handle sits on the curve; blur previews live; blur covers annotations beneath it; hard region edges | **Not documented — our judgment.** Verify against the app and amend. |
| Sizes: head length, taper, blur radius range, block-size range | **Tuned by eye** against the icons; not measured from CleanShot output. |

## User Stories

### Arrows

1. As a user, I want the default arrow to taper from a thin tail into a solid head, so that it reads as a CleanShot arrow.
2. As a user, I want to pick between standard, fancy, curved, and double arrow styles, so that I can match the arrow to what I'm pointing at.
3. As a user, I want the picker to restyle a selected arrow in place, so that I don't have to redraw it.
4. As a user, I want the editor to remember the last arrow style I used, so that my preferred style is the default next time.
5. As a user, I want a curved or double arrow to be drawn already curved, so that the style is visible the moment I draw it.
6. As a user, I want to drag a handle on the middle of a curved arrow to bend it, so that I can route it around content.
7. As a user, I want to drag an arrow's tail or tip on its own, so that I can land the tip precisely; the curve keeps its shape as I do.
8. As a user, I want the head of a curved arrow to follow the curve where it ends, so that it points the way the shaft arrives.

### Redaction

9. As a user, I want blur to look like a smooth Gaussian blur, so that it reads as a blur and not a smeared thumbnail.
10. As a user, I want to see the real blurred / pixelated pixels on the canvas while I drag and afterwards, so that I know what I'm about to share.
11. As a user, I want an intensity slider for blur and pixelate, so that I can obscure fine print lightly or a face heavily. One drag of it is one undo step.
12. As a user, I want the slider and style picker to act on a selected redaction, so that I can adjust one after placing it.
13. As a user, I want a blur to obscure annotations beneath it as well as the screenshot, so that a label I typed over a secret is hidden too.
14. As a user, I want the same redaction to export identically every time, so that undo, redo, and re-export never reshuffle it.
15. As a user, I want the editor to keep my last redaction style for the rest of the launch, so that blurring several captures in a row doesn't mean re-picking Blur — while a fresh launch still starts at blackout.
16. As a user, I want blur and pixelate to stay labelled "not secure", so that I'm never led to hide a password with them.

## Implementation Decisions

### 1 — Arrows

- `Kind.arrow(from:to:bend:style:)`. `bend` is the on-shaft midpoint, present only for a bendable style; the invariant is kept by `setArrowStyle`, which adds the default arc when switching to a bendable style and drops the bend when switching away.
- All outline math is the pure `arrowShape(from:to:bend:style:lineWidth:)` in `ArrowGeometry.swift`, returning path elements plus a paint mode. Every size derives from `lineWidth` (no absolute minimums), so the view-space canvas and the image-space export are the same shape at different scales — asserted by test.
- `Transform.reshape(handle:dx:dy:)` drags one `EndpointHandle`. Moving the tail or tip carries the bend in the shaft's own frame (rotates and scales with it). Lines accept `tail`/`tip` too: a bounding box is as wrong for a line as for an arrow, and it is the same code path.
- A curved arrow is hit-tested along its sampled centerline, not its chord.
- Left out: CleanShot's "inverse arrow direction" button, Shift-to-constrain (undocumented for arrows), drop shadows.

### 2 — Redaction

- `Kind.redaction(rect, style:, strength:, seed:)`. `strength` is `0...1`; blur maps it to a Gaussian sigma of 3–30 px, pixelate to a block of 6–40 px; blackout ignores it. `seed` is rolled once when the region is first dragged out and never changes.
- `setRedaction(id, style:, strength:)` restyles in place, clamps strength, and coalesces like `setStyle`.
- The effect (`RedactionEffect.swift`): **scramble** — average the region down to coarse cells and give each the colour of a seeded-random neighbour — then enlarge the cells (pixelate) or Gaussian-blur them with clamped edges (blur).
- `redactionBackdrop(document, below:)` flattens everything beneath a redaction; `RedactionBackdrop.patch(...)` cuts the obscured region. `render` and the canvas both draw that patch, so they cannot drift. The editor caches one backdrop per redaction and re-cuts only the patch while the region moves.
- **The guardrail is unchanged.** CleanShot ships a style called "Secure Blur"; we clone its behaviour (scramble, then blur) but **not its name or its claim**. There is one blur and one pixelate, both always scrambled, both still labelled "Not secure — visual only". Only blackout is secure redaction.

## Testing Decisions

- **Arrow geometry** (`ArrowGeometryTests`): shape facts a person would name — tapered styles widen tail → neck → head; fancy barbs sweep back past the neck; a short arrow shrinks its head rather than overshooting; the curved head rotates with the tangent; double has two heads; outlines scale linearly with their inputs. Never exact coordinates, so constants stay tunable.
- **Document commands** (`ArrowAndRedactionCommandTests`): reshape moves one endpoint; a quarter-turn of the tip carries the bend a quarter turn; bend drags are ignored by straight styles; style switches add/drop the bend and undo; a curved arrow is hit on its curve and missed on its chord; `setRedaction` keeps rect and seed, clamps, and one slider drag is one undo step.
- **Render** (`RenderArrowStyleTests`, `RenderRedactionEffectTests`): the standard arrow is thin at the tail and wide at the head; a curved arrow passes through its bend; the same element flattens to identical bytes; a different seed or strength changes them; blur reaches well past the seam yet leaves pixels outside its region untouched; blur obscures elements beneath and not above; **the preview patch equals the exported pixels**; a region crossing the crop is clipped to the visible frame. Blur/pixelate tests still assert only *obscuring* — never recoverability.
- The shared `Pixels` test helper was reading rows bottom-up; every earlier render test happened to be vertically symmetric, so it never showed. Fixed here because the curved-arrow test is not.

## Out of Scope

- Calibrating blur radius / block size against CleanShot output, and confirming the undocumented behaviours in the table above.
- Arrow drop shadows, inverse direction, Shift-constrain; curved lines.
- Any change to blackout, or to what the app calls secure.

## Further Notes

- The editor's arrow style is persisted in `UserDefaults` directly (`editor.lastArrowStyle`) rather than through `SettingsStore`: it is editor-local memory, not a setting the settings window shows.
- Editing an element that sits *beneath* a blur re-flattens that blur's backdrop on each drag frame (a PNG decode of the base image each time). Fine on the sizes tried; a decoded-base cache is the fix if it ever janks.
