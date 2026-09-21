# Core Image blur inside `LightshotKit`, and one patch path for canvas and export

**Status:** accepted

`LightshotKit` is meant to be a framework-light domain core, and its public surface deliberately avoids image types (`RenderedImage` carries bytes, not a `CGImage`). Blur breaks both habits on purpose. `RedactionEffect.swift` imports **Core Image** for `CIGaussianBlur` — the filter CleanShot X's binary references — because the shrink-and-resample blur it replaces did not look like a blur, and a hand-written Gaussian would be more code to be slower. It runs on a **software-renderer `CIContext` with colour management off**, trading GPU speed for the same bytes on every machine, so `render` stays deterministic and its pixel tests stay stable (measured: ~10 ms for a 1600×600 region, fast enough to recompute per drag frame).

The second break is `RedactionBackdrop` / `RedactionPatch`, which expose a `CGImage` publicly. The editor canvas used to show a grey scrim for blur and pixelate because re-implementing the filter in the view would drift from the export. Instead the view now asks the core for the real pixels: the backdrop is the flatten of everything beneath the redaction, the patch is the obscured region cut from it, and `render` draws that same patch. A `CGImage` crosses the seam because encoding a PNG per drag frame would not be live. AppKit and ScreenCaptureKit are still never imported by the package — that rule is unchanged.

## Considered options

- **Hand-written box/Gaussian blur in pure Swift** — keeps the core import-free, but slow in debug builds and one more thing to get subtly wrong at region edges.
- **GPU `CIContext`** — faster, but output can differ across GPUs, which breaks "deterministic flatten".
- **Blur only the base image in the preview** — cheap, but the export blurs annotations beneath the redaction too (a typed password label, say), so preview and export would disagree exactly where it matters.
