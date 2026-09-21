# Lightshot

The language of capturing a screenshot and annotating it before sharing. CleanShot X is the reference product; where its name for a thing differs from ours, ours is listed here and theirs under _Avoid_.

## Language

### Arrows

**Arrow**:
A pointer from a tail to a tip. It is straight unless its arrow style is bendable and it carries a bend.
_Avoid_: Pointer, connector

**Arrow style**:
How an arrow is drawn: **standard** (tapered shaft, solid soft-cornered head), **fancy** (tapered shaft, sharp swept-back head), **curved** (even stroke, open head), or **double** (even stroke, open head at both ends).
_Avoid_: Arrow type, arrowhead

**Bendable**:
An arrow style whose shaft can curve — curved and double. Standard and fancy arrows are never bent.

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
