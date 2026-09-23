# Spec 0004 — Editor Usability Pass

**Status:** implemented on branch, not yet tracked in Linear
**Linear:** _none yet — create the issue and link it here_
**Platform:** Native macOS (Swift / SwiftUI), macOS 14+
**Scope:** Local-only. Editor window, toolbar, and two tool defaults. Amends Specs 0001, 0002 (window fronting) and 0003; adds no new seams.

Vocabulary used here is defined in [`CONTEXT.md`](../CONTEXT.md).

---

## Problem Statement

The editor opens small, with the image jammed against the window edges and a toolbar crowded with small buttons I rarely use. With no Dock icon I lose the editor behind other windows. I almost always pixelate rather than black out, and a curved arrow arrives already bowed and in a different look from the standard arrow, so I have to fix it before I can use it.

## Solution

The editor opens larger, keeps clear space around the image, and shows Lightshot in the Dock while it is open. The toolbar is two rows: big tool buttons and three actions — **Save As…**, **Copy**, **Done** — on top, the style controls for the active tool beneath. The redact tool starts at **Pixelate** every time. **Curved** and **double** arrows are the standard arrow with a bend handle — double with a head at both ends: drawn straight, bent on demand. Tool names appear the instant the pointer is over a button.

## User Stories

1. As a user, I want the editor to open at a roomy size, so that I can work without resizing first. It never opens larger than the screen allows.
2. As a user, I want clear space between the image and the window edges, so that the image and the handles on its border are easy to see and grab.
3. As a user, I want Lightshot in the Dock and the ⌘-Tab switcher while the editor is open, so that I can get back to it like any other app. When the editor closes, Lightshot is menu-bar-only again.
4. As a user, I want the editor's only actions to be Save As…, Copy, and Done, so that the toolbar is about finishing, not managing.
5. As a user, I want undo, redo, delete, and z-order to keep their standard keys (⌘Z, ⇧⌘Z, ⌫, ⌘[, ⌘]) even without buttons, so that I can still fix a mistake.
6. As a user, I want larger tool and arrow-style buttons whose whole area is clickable, so that I hit the tool I aim for.
7. As a user, I want the redact tool to start at Pixelate whenever I open it, so that my usual redaction is one drag away — while blur and pixelate stay labelled "not secure".
8. As a user, I want a curved arrow to look exactly like the standard arrow and to be drawn straight, so that it only curves when I drag its bend handle. The taper and head follow the curve once bent.
9. As a user, I want a double arrow to carry that same solid head at both ends, drawn straight and bendable the same way, so that the two bendable styles behave alike.
10. As a user, I want a tool's name to appear the moment I hover its button, so that I can learn the icon-only palette by sweeping across it instead of waiting on each icon.

## Implementation Decisions

- **Window.** Opens at 1180×800, capped to 90% × 85% of the screen's visible frame. Minimum content size 760×520.
- **Padding.** `CanvasProjection(imageSize:viewSize:inset:)` fits the image inside the view shrunk by `inset` on every side (24 pt in the editor). The canvas itself still spans the full area, so handles on the image border draw and hit-test in the margin.
- **Dock.** `openEditor` sets the activation policy to `.regular` before presenting; the editor window's `willClose` returns it to `.accessory`. This **reverses Spec 0002's "activation policy is unchanged"** for the editor only — settings, history, and onboarding still open as accessory windows through `WindowPresenter`.
- **App icon.** `App/Resources/Assets.xcassets/AppIcon.appiconset` (16–512 pt, 1x/2x), wired through `ASSETCATALOG_COMPILER_APPICON_NAME` in `project.yml`. The artwork sits on the macOS icon grid — an 824 px body centred in the 1024 px canvas — so it matches its Dock neighbours in size.
- **Actions.** Removed from the editor: Send Backward, Bring Forward, Delete, Undo, Redo, drag-out, Save (default location), Pin. Save and Pin remain on the post-capture toolbar and pins; the drag-out seam (`AppCoordinator.dragItem`) stays in the kit, unused by the editor. The five editing commands survive as invisible key-equivalent buttons. **Reset Crop** stays: it is a contextual control of the crop tool, shown only while a crop is in effect.
- **Redaction default.** Selecting the redact tool clears the selection and sets the style to `pixelate`. The intensity is still remembered for the launch; the last *style* no longer is. **Amends Spec 0001's "default to blackout" and Spec 0003 story 15.** The guardrail is unchanged: only blackout is secure, and blur/pixelate keep the "Not secure — visual only" warning.
- **Curved arrow.** `arrowShape` draws `.curved` as the standard taper laid along the quadratic through the bend: shaft edges are the curve offset by a half-width growing from tail to neck; the head sits where the curve is one head-length short of the tip and points along that chord. With the bend on the midpoint the outline is the standard arrow's. `defaultArrowBend` is the midpoint, so both bendable styles (curved, double) start straight. **Amends Spec 0003 story 5.** `.double` is the same construction with a second head on the tail and a shaft of constant width (the width at which the standard shaft meets its head); each head takes at most 40% of a short arrow so the two never meet. The stroked open-head look is gone. The picker's curved/double glyphs stay bowed so the styles read as bendable.
- **Instant tooltips.** Tool and arrow-style buttons show a short title in a tag hung below the button on `onHover`, replacing the delayed system `.help` tooltip there; the longer description moves to the accessibility hint. The toolbar rows are z-ordered above what follows so the tag isn't covered.

## Follow-up (2026-09-22): tools stay put, bigger defaults, typed font size — [LIG-25](https://linear.app/light-shot/issue/LIG-25)

Three usability fixes reported after using the editor. Same seams, no new ones.

11. As a user, I want the tool I picked to stay active after I draw a mark, so that I can draw several arrows in a row and switch tools myself. The mark I just drew stays selected, and its handles are still grabbable with the drawing tool active.
12. As a user, I want new marks and labels to start at a weight that reads on a Retina capture, so that I don't enlarge every one.
13. As a user, I want to type the font size instead of dragging a slider, so that I can hit an exact size.

- **Tool persistence.** Finishing a drag with a drawing tool adds and selects the element but no longer switches back to Select (previously `EditorModel.end` set `tool = .select`). With a drawing tool active, a press within the grab radius of the selection's handles starts the same reshape/resize drag the Select tool would (`beginHandleDrag`); any other press starts a new mark. Text and step placement were already tool-preserving.
- **Defaults.** `Style.default` is now `strokeWidth: 6, fontSize: 32` (was 3 / 17), in image pixels — 3 pt / 16 pt on a 2× capture. Step markers, whose radius starts at `max(fontSize, 14)`, grow with it. **Amends Spec 0001's implied defaults.** *Amended by [LIG-64](https://linear.app/light-shot/issue/LIG-64):* the default `fontSize` is now **20** image pixels (10 pt on a 2× capture), and new step markers start at 20 px with it; `strokeWidth` stays 6.
- **Font size entry.** The font-size slider is a numeric text field (Return applies, clamped 6…200 and rounded; one edit is one undo step via `commitStyleEdit`). The field mirrors the selection's size like the slider did. Focus: the field yields keyboard focus when Return is pressed, a tool is picked, or the canvas is pressed, and once when the window first becomes key, so ⌫ / ⌘Z keep reaching the editor. The stroke-width control stays a slider.

## Testing Decisions

- `ArrowGeometryTests`: an unbent curved arrow has every corner of the standard outline and its shaft points lie on the standard arrow's edges; a new bendable arrow's bend is the midpoint; the head's barbs rotate with the tangent; a bent arrow still widens tail → neck → head and leaves the chord; a double arrow has the standard head at the tip and its mirror image at the tail, and a short one keeps each head on its own half.
- `CanvasProjectionTests`: an inset fits the image to the inner area and offsets it; an inset larger than the view degrades to the zero-scale projection.
- The app shell has no unit tests; window size, padding, Dock presence, the three actions, key equivalents, the Pixelate default, instant tooltips, and drawing/bending curved and double arrows were verified by hand against a debug build.

## Out of Scope

- Main-menu commands (Edit ▸ Undo etc.) wired to the editor.

## As built after LIG-46 (one compact toolbar row)

The two toolbar rows became **one row in the window's toolbar**, beside the traffic lights (the title is hidden), after CleanShot X's annotate window: **Crop** on its own; the drawing tools as one group, the selected tool on a blue pill; an **options** group showing only what applies to the active tool — or, with Select, the selected element — per the pure `StyleFields.fields(for:)` in the kit (colour swatch with presets and Custom…; stroke width as a menu of sizes for arrows, lines, shapes and freehand; the arrow styles for arrows; font size for text and step markers; redaction style, intensity and the secure / not-secure marker for redactions; **Reset Crop** while a crop is applied); and **Save As… / Copy / Done** at the trailing edge. On macOS 26 each group is a glass capsule (`ToolbarSpacer`s separate them); earlier systems keep the same items in the classic toolbar. **Instant tooltips** (story 10) now come from the system tooltip with its delay shortened app-wide (`NSInitialToolTipDelay`, registered, not persisted): a hand-drawn tag would be clipped inside a toolbar item.

## As built after LIG-47 (text box, crop chrome, Focus, History)

- **Text box.** A label sits `padding` inside its box (`TextLayout` in the kit: Helvetica, one CoreText layout drawn by both the canvas and the export). A new label has its **natural width** and grows as it is typed; selected or being edited it shows a thin rounded border, round handles on its side edges and a small square at the bottom-right. A side handle sets the width (the text wraps, the opposite edge stays); the corner scales the type and the box together. Typing into a label whose width was set by hand keeps the width and rewraps; changing the font size refits the box. A finished label opens for editing again from a click with the Text tool, a click on it once it is selected, or a double-click.
- **Crop** looks like CleanShot's: the outside dimmed, a thin white edge, the recorder's corner brackets and edge bars (`OverlayCanvas.drawSelectionChrome`, shared), and a rule-of-thirds grid while cropping. The whole border can be grabbed (corners first, then any point along an edge), and the pointer says what a drag will do: the matching resize arrow over the border, an open hand over the crop and a closed one while moving it, a crosshair outside it (`PointerCursor`, shared with the recorder).
- **Focus** (new tool, `AnnotationElement.Kind.focus`): draw one or more areas and everything outside all of them is dimmed (`focusDimAlpha`), in the canvas and the export. The dim is drawn once, under every mark and into every redaction's backdrop; overlapping areas never dim each other. Its corners are slightly rounded (`focusCornerRadius`), and in the editor it shows a solid edge. A focus area is picked up anywhere inside — with Select (where a mark it frames still wins the click) or with the Focus tool itself (a press outside every area draws a new one) — and resizes and deletes like a shape; it has no style controls.
- **History** closes itself when a screenshot or a recording is opened from it.
- **Selection is the user's act.** A newly drawn mark — any shape, a step marker, a focus area — is not selected; a click with a drawing tool that draws nothing lets go of the selection. With any drawing tool, a press on an existing mark picks it up — selects it and moves it — instead of drawing over it (`AnnotationDocument.grabbableElementID`: an unfilled rectangle or ellipse only near its outline, so a new mark can still be started inside one); the options bar then shows that mark's controls. A label placed or reopened with the Text tool is selected only while it is typed (so the style controls apply to it) and let go when the typing ends; one the user selected stays selected after editing.
