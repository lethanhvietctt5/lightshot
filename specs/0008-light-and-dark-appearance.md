# Spec 0008 — Light and Dark appearance

**Status:** accepted — decisions taken below
**Linear:** [LIG-58](https://linear.app/light-shot/issue/LIG-58) (label `ready-for-agent`)
**Platform:** Native macOS (Swift / SwiftUI + AppKit), macOS 14+
**Scope:** Local-only. Every piece of Lightshot's own interface looks right in both macOS appearances, follows the system by default, and switches live. What Lightshot *produces* (screenshots, annotations, recordings, studio exports) never depends on the appearance.

Parity reference: CleanShot X follows the system appearance: its asset catalog ships a Dark Aqua variant for 126 assets, including its window and box colours.

---

## Problem Statement

Lightshot's interface was built in two halves that disagree:

- **The system-styled half** follows the macOS appearance: the screenshot editor's chrome, Settings, History, onboarding, the post-capture toolbar, pins, the post-recording card and the GIF progress panel.
- **The recording and studio half is always dark**, whatever I pick in System Settings: the recorder toolbar, the recording controls pill, the microphone and camera picker, the instant tips, and the whole Studio editor window with its popovers.

In Light Mode that makes the app feel like two products stitched together. The Studio editor is a black window among light ones.

Some chrome is drawn with hard-coded white or black, so it only works on one background:

- a white selection ring;
- `white.opacity(…)` text and fills;
- a black 25% edge on colour swatches, which disappears in Dark Mode.

Nothing lets me choose a different appearance for Lightshot than for the rest of my Mac.

## Solution

Lightshot gets one **appearance** for all of its interface. It is decided like this:

- **Match System** (the default) tracks the macOS setting live.
- A new **Appearance** choice in Settings → General (**Match System / Light / Dark**) can pin it.

Every surface is sorted into one of two kinds:

- **Chrome** is Lightshot's own interface: windows, panels, toolbars, popovers, tips and menus. It follows the appearance.
  - Standard controls use the system's semantic colours and materials.
  - Lightshot's custom chrome (the recorder toolbar, the controls pill and the Studio editor) takes its colours from one **theme palette**. The palette defines every custom colour for both Light and Dark and is tested for legibility in both.
- **Content** is left as it is: the thing being captured, annotated, recorded or exported, and the overlays drawn *on top of the screen* that must read against arbitrary pixels.
  - The selection dim, the recording border, the countdown HUD, the camera bubble and the letterbox black keep fixed colours.
  - Renderers never see the appearance, so an export is identical in Light and Dark.

Changing the appearance, from the system or from Settings, updates every open window immediately, with no reopening or relaunch.

## Vocabulary

- **Appearance**: Light or Dark, the look Lightshot's chrome is drawn in right now.
- **Appearance preference**: the Settings choice, which is Match System, Light or Dark.
- **Chrome**: Lightshot's own interface, which follows the appearance.
- **Content**: captured, annotated or rendered pixels, and the on-screen overlays drawn over arbitrary screen pixels. It never follows the appearance.
- **Theme palette**: the named colours for custom chrome, each defined for Light and Dark.
- **Theme token**: one named colour in the palette, for example *panel*, *control fill (on)*, *primary text* or *timeline clip*.

## User Stories

### Following the system

1. As a Light Mode user, I want the recorder toolbar to be light, so that it matches the rest of my Mac.
2. As a Light Mode user, I want the recording controls pill to be light, so that it doesn't look like a different app floating over my work.
3. As a Light Mode user, I want the microphone and camera picker popover to be light and legible, so that choosing a device feels native.
4. As a Light Mode user, I want the Studio editor window, including its title bar, rail, inspector, transport, timeline and popovers, to be light, so that it sits naturally beside Finder and my other apps.
5. As a Dark Mode user, I want the screenshot editor, Settings, History, onboarding, the post-capture toolbar, pins, the post-recording card and the GIF progress panel to be dark, as they are today, with nothing drawn for a light background.
6. As a Dark Mode user, I want the recorder toolbar, pill and Studio editor to stay dark, so that nothing I rely on changes.
7. As a user whose Mac switches appearance automatically (Auto at sunset), I want every open Lightshot window to switch at the same moment, so that I never see half-light, half-dark chrome.
8. As a user, I want a Studio editor that is open during an appearance change to keep its playback position, selection, undo history and open panel, so that switching appearance never interrupts editing.
9. As a user, I want the recorder toolbar to change appearance while it is on screen, even mid-selection, so that it never lags behind the system.
10. As a user, I want the recording controls pill to change appearance during a take without affecting the recording, so that a sunset switch can't spoil a take.

### Choosing an appearance

11. As a user, I want an **Appearance** setting (Match System, Light or Dark) in Settings → General, so that Lightshot can look different from the rest of my Mac when I prefer.
12. As a new user, I want Match System to be the default, so that Lightshot looks right without my touching anything.
13. As a user, I want my Appearance choice remembered across relaunches, so that I set it once.
14. As a user, I want the Appearance choice to apply the moment I pick it, including to the Settings window I'm in, so that I can compare the options.
15. As a user who pinned Light or Dark, I want system appearance changes to leave Lightshot alone, so that my choice holds.

### Legible chrome in both appearances

16. As a user, I want every label, glyph and value in custom chrome to have enough contrast in both appearances, so that I can read it at a glance.
17. As a user, I want the hover, on and selected states of toolbar controls to be clearly visible in both appearances, so that I know what is active.
18. As a user, I want the instant tip above a hovered control to be legible in both appearances, so that I can learn the toolbar.
19. As a user, I want the orange warning badge and its message to stay legible in both appearances, so that I don't miss a permission problem.
20. As a user, I want the selection ring on inspector choices (backgrounds, wallpapers, cursor styles) to be visible in both appearances, so that I can tell which one is picked.
21. As a user, I want timeline clips, zoom pills, text pills, the waveform, the playhead, tick labels and selection outlines to be distinct in both appearances, so that I can edit precisely.
22. As a user, I want transcript words, including struck-through cut words, to be legible in both appearances, so that I can edit captions.
23. As a user, I want the Studio editor's secondary text and dividers to stay subtle in both appearances, never invisible and never shouting.
24. As a user, I want the colour swatches in the screenshot editor and Studio inspector to show a visible edge in both appearances, so that black swatches on a dark background and white ones on a light background can still be seen.
25. As a user, I want the recording toolbar's size fields, ratio lock, device toggles and Studio row to be legible in both appearances, so that setting up a take is easy.
26. As a user, I want disabled controls to look disabled in both appearances, and not merely dim in one and invisible in the other.
27. As a user, I want accent colours (the Studio pink and violet, the zoom purple, the playhead red and the selection yellow) to keep their meaning in both appearances, adjusted only as much as legibility needs.
28. As a user, I want native controls inside custom chrome (sliders, toggles, menus, text fields, colour wells, steppers) to match the surrounding appearance, and not mix a light control into dark chrome or the reverse.
29. As a user, I want sheets, alerts and open panels shown from Lightshot windows to match Lightshot's appearance.
30. As a user, I want panel shadows and edges to suit each appearance, so that there is no grey halo in Light and no invisible edge in Dark.

### Content stays content

31. As a user, I want the dimmed backdrop, selection handles, size readout and window highlight during a capture to look the same in both appearances, so that they read against whatever is on my screen.
32. As a user, I want the recording area's border and dim, the countdown, the camera bubble, click highlights and keystroke badges to look the same in both appearances, so that what I see while recording matches what gets recorded.
33. As a user, I want my screenshots, annotations and exported videos to be pixel-identical whichever appearance I used while making them, so that the output never depends on my system setting.
34. As a user, I want the Studio preview to show exactly what the export will be, with only the stage around it following the appearance.
35. As a user, I want the screenshot editor's default annotation colours and palette to be unchanged by the appearance, so that a red arrow is the same red everywhere.
36. As a user, I want the video player letterbox in the post-recording card and the Studio preview to stay black, so that the video reads as video.
37. As a user, I want the crop mask and rule-of-thirds guides in the screenshot editor to look the same in both appearances, because they are drawn over my image.

### Menu bar and system surfaces

38. As a user, I want the menu-bar icon (and the stop icon while recording) to adapt to the menu bar as it does today.
39. As a user, I want the status menu, including the Studio Projects submenu and its thumbnails, to follow the system menu appearance.

### Maintenance

40. As a contributor, I want one place that defines every custom chrome colour for both appearances, so that a new panel can't reintroduce a colour for one appearance only.
41. As a contributor, I want a test that fails when a palette colour pair drops below the contrast threshold in either appearance, so that legibility is protected by CI and not by eyeballing.
42. As a contributor, I want a debug way to open each surface in a chosen appearance without recording or capturing, so that visual checks are fast and repeatable.

## Implementation Decisions

### The appearance model (kit)

- **The preference type.** A new pure kit type, `AppearancePreference`, with the cases `system`, `light` and `dark`. It is `Codable`, `CaseIterable`, has titles, and defaults to `system`.
- **Settings.** `SettingsStore` gains `appearance: AppearancePreference`, persisted with the other settings. The UserDefaults implementation stores the raw value; a missing or unknown value reads as `system`.
- **Resolved appearance.** A pure `Appearance` enum (`light`, `dark`). The function `AppearancePreference.resolved(system:) -> Appearance` returns the pinned value, or the system's when the preference is `system`.

### The theme palette (kit)

- **Tokens.** The kit gets a `ThemeToken` enum naming every custom-chrome colour. It is grouped:
  - **Surfaces:** panel, panel edge, popover, tip background, tip edge, editor canvas, stage, inspector well.
  - **Text:** primary, secondary, tertiary, disabled.
  - **Controls:** control fill at rest, hover and on; control edge on hover; cell fill when on; divider; selection ring.
  - **Timeline:** clip, clip label, track background, zoom pill, text pill, waveform, tick label, playhead, selection.
  - **Accents:** studio pink, studio violet, blue, warning.
  - **Shadow:** panel shadow.
- **Values.** `ThemePalette.color(_ token: ThemeToken, in: Appearance) -> RGBAColor` is a pure lookup. The Dark values reproduce today's dark chrome exactly, so Dark Mode users see no change. The Light values are new.
- **Legibility pairs.** The palette declares its **legibility pairs**: which text or glyph token is drawn on which surface token, and at what minimum contrast. Text needs 4.5:1. Large glyphs, edges and state fills that carry meaning need 3:1. The declared pairs are the contract that the test enforces.
- **Colour maths.** `RGBAColor` gains two pure helpers: relative luminance, and a contrast ratio against another colour (compositing translucent foregrounds over the surface first).

### Chrome in the app

- **Applying the appearance.** The app applies the resolved appearance through the application-wide `NSAppearance`: `nil` for Match System, Aqua for Light, Dark Aqua for Dark. It re-applies whenever the setting changes. Windows, panels, popovers, menus, sheets and alerts inherit it; no window pins its own appearance any more.
- **Token colours in the app.** An app-side adapter turns each `ThemeToken` into one **dynamic colour**. It is an `NSColor` whose provider picks the Light or Dark palette value from the drawing appearance, bridged to SwiftUI `Color`. Views therefore never branch on appearance themselves, and a live switch re-resolves every colour with no view code.
- **Removing the forced dark.** The code that forces dark goes:
  - the colour-scheme overrides on the toolbar panel, the recorder toolbar, the device picker and the Studio editor;
  - the Dark Aqua pins on the Studio editor window and its popover.

  `ToolbarChrome` keeps its geometry constants, and its slate becomes the *panel* token. `StudioStyle` becomes a thin alias over tokens.
- **Replacing hard-coded colours.** Every `white`/`black`/`white.opacity(…)` used as chrome in the recorder toolbar, the controls pill, the toolbar tips, the Studio editor, inspector, choices, timeline, captions and text panels becomes a token or a system semantic colour: label, secondary label, separator, control background, or a material.
  - The swatch edge is drawn so it shows on both backgrounds: a dark hairline outside a light one.
- **Layer-backed AppKit views.** Views that set `CGColor`s (layer backgrounds, badges) re-resolve them when their effective appearance changes. A `CGColor` is a snapshot and does not update on its own. Views whose layer colour is **content** keep their fixed colours: the camera bubble, the video letterbox and the Studio preview's backing.
- **Surfaces that stay fixed by design.** These keep their colours in both appearances, and a code comment marks each as content:
  - the overlay canvas (selection dim, handles, size pill);
  - the window-hover highlight;
  - the recording dim and border;
  - the countdown HUD;
  - the camera bubble;
  - the click-highlight preview;
  - the editor's crop mask and thirds;
  - the letterbox.
- **Renderers never read the appearance.** The kit `render` function, the Studio renderer, the compositor and the exporters take no appearance input and use no dynamic colours. Annotation defaults and the colour palette are content colours and stay as they are.
- **The Studio preview stage.** The area around the video canvas uses the *stage* token, so it follows the appearance. The canvas itself is rendered content, so the preview and the export match.
- **The Settings control.** Settings → General gets an **Appearance** picker (Match System / Light / Dark) near the top, bound to the setting.

### Rollout

The work ships as slices, one surface family each. Every slice keeps Dark exactly as it is today and adds a correct Light.

1. **Appearance model and palette.**
   - Kit: `AppearancePreference`, the setting, `Appearance`, `ThemeToken` and `ThemePalette` with the legibility pairs, plus the contrast helpers.
   - App: the app-wide appearance, the dynamic-colour adapter, the Settings picker, and the debug surface hooks (see Testing).
   - The audit: screenshot every surface in both appearances, and file each defect found against the slice that owns the surface.
2. **Recorder toolbar, controls pill, device picker and tips.**
3. **Studio editor:** the window, rail, inspector, choices, transport, timeline, captions, text panel and popovers.
4. **System-styled surfaces:**
   - fix the defects the audit found in the screenshot editor, Settings, History, onboarding, the post-capture toolbar, pins, the post-recording card and the GIF progress panel;
   - fix the swatch edge;
   - make layer colours react to appearance changes.

## Testing Decisions

- **What makes a good test here.** Test the behaviour a user or contributor relies on, through public interfaces: which appearance a preference resolves to; that a setting round-trips; that every declared text-on-surface pair is legible in both appearances. Don't test which SwiftUI modifier a view uses, or snapshot view hierarchies.
- **Seam 1: the theme palette, in kit unit tests (the main seam).** For every legibility pair and both appearances, the contrast ratio must meet the pair's threshold.
  - The same suite checks that every `ThemeToken` has a value in both appearances.
  - It also checks that the Dark values equal today's dark chrome for the tokens that existed before (panel slate, canvas, divider, secondary, control and so on), which pins the "Dark doesn't change" promise.
  - The contrast helpers get known-value tests: white on black is 21:1, and a colour against itself is 1:1.
- **Seam 2: the preference, in kit unit tests.** `resolved(system:)` is checked for every preference × system combination. The setting defaults to `system`, persists through the settings store, and an unknown stored value falls back to `system`.
- **Content invariance.** Renderers get no appearance input, so the existing render and export tests already cover their output.
  - Nothing in the renderers, compositors, exporters or the kit `render` refers to a theme token, an `NSAppearance` or a colour scheme; each slice checks this with a grep. The Studio preview canvas is compared in the Light and Dark screenshots.
- **The visual verify loop (not CI; done before each PR).** This extends the existing isolated `dev.lightshot.app.verify` Debug build and its DEBUG launch arguments.
  - A new `-previewAppearance light|dark` argument overrides the preference for that launch.
  - A new `-previewSurface <name> [-previewFile <path>]` argument opens one surface with no capture or recording: `editor`, `postCapture` and `pin` (with the image at `-previewFile`, or a generated sample), `settings`, `history`, `onboarding`, `postRecording` (the movie at `-previewFile`) and `preparing` (the progress panel that GIF making and take preparation share).
  - These join the existing `-previewRecordingControls`, `-previewDevicePicker` and `-openStudioProject`.
  - Each slice screenshots its surfaces in both appearances with `screencapture -l` and inspects them before the PR. For the pill and toolbar, the shadow-edge alpha check from LIG-42 also runs in both appearances.
- **Prior art.**
  - The kit tests in the Swift Testing style: `StyleFieldsTests`, `SeamTests` and `RecordingOptionsTests` for settings round-trips.
  - The Studio verify loop, and the offline render and export harness used for spec 0007.

## Out of Scope

- Per-window appearance choices. Lightshot has one appearance for all of its chrome.
- Accessibility modes: Increase Contrast, Reduce Transparency and Differentiate Without Color. System-styled surfaces get them for free; tuning custom chrome for them is later work.
- Custom accent colours or themes beyond Light and Dark, and a tinted app icon.
- Changing what any output looks like: annotation defaults, caption and text defaults, Studio backgrounds, cursor, click and keystroke styling, and export colours.
- Redesigning layouts. This spec changes colours and appearance behaviour only; geometry, spacing and controls stay as they are.
- Localising the new strings beyond English.

## Further Notes

- **Why the recording chrome goes light.** The recording chrome was made dark on purpose in LIG-42, after CleanShot's dark toolbar. The user asked for full Light and Dark support; CleanShot's own chrome follows the system and ships Dark variants of its colours. The dark look is kept exactly as Lightshot's Dark appearance, and anyone who prefers it everywhere can pin **Dark** in Settings.
- **Why `NSApp.appearance` and not per-view overrides.** One application-wide switch is what makes AppKit popovers, menus, sheets, open panels and native controls agree with SwiftUI chrome. Per-view colour-scheme overrides left those mismatched.
- **The keystroke overlay's own System style.** The keystroke overlay has a **System** style (spec 0006, story 30) that follows macOS's Dark Mode when a take starts. That is a look the user picked for the *recording*, so it stays tied to macOS and not to Lightshot's pinned appearance.
- **Guardrails.**
  - The appearance never reaches a renderer, so exports stay deterministic.
  - Redaction is unaffected: blackout is content and stays black in both appearances.
