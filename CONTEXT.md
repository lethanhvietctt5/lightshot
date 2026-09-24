# Lightshot

The language of capturing a screenshot and annotating it before sharing. CleanShot X is the reference product; where its name for a thing differs from ours, ours is listed here and theirs under _Avoid_.

## Language

### Arrows

**Arrow**:
A pointer from a tail to a tip. It is straight unless its arrow style is bendable and it carries a bend.
_Avoid_: Pointer, connector

**Arrow style**:
How an arrow is drawn: **standard** (tapered shaft, solid soft-cornered head), **fancy** (tapered shaft, sharp swept-back head), **curved** (the standard arrow on a bendable shaft), or **double** (the standard head at both ends of a bendable shaft).
_Avoid_: Arrow type, arrowhead

**Bendable**:
An arrow style whose shaft can curve — curved and double. Both are drawn straight and curve only once their bend is dragged. Standard and fancy arrows are never bent.

**Bend**:
The point a bendable arrow's shaft passes through at its middle. It lies *on* the shaft, not off to the side of it.
_Avoid_: Control point, curvature, midpoint

**Endpoint handle**:
A grab point on a selected line or arrow: tail, tip, or bend. Lines and arrows are reshaped by these, never by a bounding box.
_Avoid_: Resize handle (that is the bounding-box kind), anchor

**Line**:
A straight segment with no head. It has a tail and a tip but never a bend.

### Redaction

**Redaction**:
A rectangular region of the image made unreadable. Every redaction has a redaction style.
_Avoid_: Blur (that is one style), Pixelate tool (CleanShot's name for the tool), censor, mask

**Redaction style**:
How a redaction hides its region: **blackout**, **blur**, or **pixelate**.

**Blackout**:
The redaction style that replaces the region with an opaque fill. The only secure redaction.
_Avoid_: Black Out, solid redaction

**Blur** / **Pixelate**:
Redaction styles that obscure the region by scrambling and then smoothing (blur) or enlarging (pixelate) its pixels. Obscuring, never secure.
_Avoid_: Secure blur, smooth blur

**Secure redaction**:
A redaction that leaves nothing of the covered pixels in the exported file. Only blackout qualifies; a scrambled blur does not.

**Obscuring**:
Making a region unreadable to the eye without guaranteeing it cannot be recovered. What blur and pixelate do.

**Strength**:
How hard a blur or pixelate obscures, from 0 to 1. Blackout has none.
_Avoid_: Intensity (the on-screen label only), radius, block size

**Scramble**:
The seeded shuffling of a region's coarse cells that blur and pixelate apply first. A given redaction always scrambles the same way.
_Avoid_: Randomization, noise

**Backdrop**:
Everything a redaction sits on — the base image plus every element beneath it — flattened. A blur obscures its backdrop, so it hides annotations under it and never those above it.

**Auto redact**:
Adding redactions over every detection in one step, in the current redaction style. It chooses *where* redactions go, never whether they are secure.
_Avoid_: Smart redact, auto blur, secure scan

**Detection**:
One found item: a sensitive-data category and an image-space rectangle. It is not a redaction until auto redact applies it.

**Sensitive-data category**:
A kind of thing auto redact looks for (secrets, payment cards, emails, faces, …). The user chooses which are on.

### Recording

**Recording**:
One video or GIF produced by a single start→stop session.
_Avoid_: Capture (that is a screenshot), clip

**Recording region**:
What a recording targets: a rect, a window, or a display. The same `CaptureRegion` screenshots use, plus the display case.

**Recorder toolbar**:
The pre-start toolbar at the selection: Start Video, Start GIF and the per-recording toggles.
_Avoid_: Recorder overlay

**Recording controls**:
The pause / resume / stop / restart / discard pill shown while recording.
_Avoid_: Controls overlay, HUD

**Take**:
One attempt within a session. Restart throws the current take away and begins another with the same options; discard throws it away and ends the session.

**Post-recording overlay**:
The result popup after stop, with copy / save / trim / delete.
_Avoid_: Quick Access Overlay (CleanShot's name), QAO

**Video editor**:
The trim / resize / quality / audio window. Not the annotation editor.

**Input visualisation**:
Click highlighting and the keystroke overlay, collectively.

### OCR Text

**OCR Text**:
The capture action that turns a selected screen area into plain text on the clipboard. It opens no editor and adds nothing to history.
_Avoid_: Capture Text (CleanShot's name), text grab, scan

**Text capture**:
One run of OCR Text, from selection to clipboard. Unlike a capture, it produces no image.
