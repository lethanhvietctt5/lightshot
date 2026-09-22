# CleanShot X — screen-recording feature inventory (parity reference)

**Researched:** 2026-09-22, from the installed `/Applications/CleanShot X.app` (**4.8.3**, 10 Sep 2025) plus cleanshot.com (features, screen-recording, changelog, FAQ). Latest upstream is **5.0.1** (18 Sep 2026); everything below is 4.8.3 unless marked **[5.0+]**.

Evidence tags: **[bin]** string/symbol in the main binary · **[nib]** string in a `Contents/Resources/*.nib` · **[defaults]** key in the live `pl.maketheweb.cleanshotx` defaults · **[asset]** `Assets.car` image name · **[plist]** Info.plist · **[fw]** bundled framework/tool · **[web]** cleanshot.com · **[3p]** third-party review · **[inf]** inference.

This file is the parity target for [`specs/0006-screen-recording.md`](../../specs/0006-screen-recording.md). It records what CleanShot does, not what Lightshot will do — the spec decides that.

## 1. Entry points and capture modes

- **Record Screen** menu-bar row and hotkey action, labelled "Record Screen / Stop Recording" — one chord toggles start and stop. [nib, bin; asset `menubarRecordVideo`]
- **All-In-One overlay** offers recording on key **R** next to Area (A), Fullscreen (F), Window (Space/W), Scrolling (S), Text (O). [bin; asset `oneOverlayRecord`]
- **Area recording** — "Drag to record a part of the screen." Aspect-ratio lock (`OneRatioControl`, `RatioMenuItem`, `recorderLastSelectedRatio`; 16:9, 5:4, 9:16 …), Option for a square selection, arrow keys nudge/resize, typed width/height (`VideoSizeControl`). [bin, nib, web changelog 3.1.2 / 3.9.4 / 4.8.1]
- **Window recording** — `selectWindowVideo`; `lastRecordingArea` stores `windowID` + `screenID` + `area`. [bin, defaults]
- **Fullscreen recording** — `recorderFullscreen`; the controls stay usable but are excluded from the capture. [bin, asset, changelog 4.6]
- **Remember last recording area** — "Recording area: Remember last selection" (`rememberRecordingArea`, `lastRecordingArea`). [nib, defaults]
- **Video or GIF** — two start buttons, "Start Video Recording" / "Start GIF Recording" (`startVideoRecordingClicked`, `startGIFRecordingClicked`, `recordingToGif`). [bin; assets `recorderVideoButton`, `recorderGifButton`]
- **Engine** — ScreenCaptureKit (`SCStream`, `SCStreamConfiguration`, `SCShareableContent`, `SCStreamOutput`) + AVFoundation (`AVAssetWriter`, `AVAssetWriterInput`, `AVCaptureSession` for mic/camera). No ReplayKit, no ffmpeg, no gifski. [bin, `otool -L`]
- **Self-Timer** is a separate *screenshot* mode, not a recording countdown. [nib]
- **Presenter Overlay** support. [web changelog 4.6.2 only — no bundle string]
- `cleanshot://` URL scheme exists with verified actions `capture-fullscreen`, `capture-previous-area`, `open-from-clipboard`; a bare `record` token also appears in the binary, but no recording endpoint name was confirmed. [plist, bin]

## 2. Recorder toolbar (pre-start) and in-recording controls

- **Recorder toolbar** (`RecorderView`, `RecorderControlsView`, `RecorderSettingsView`, `RecorderOverlay`) with buttons: video, GIF, microphone, system sound, camera, highlight cursor/clicks, keystrokes, ratio, fullscreen, minimize, settings, anchor. [assets `recorder*`]
- **Per-recording toggles** override the global preferences (mic, computer audio, camera, clicks, keystrokes). [bin; 3p]
- **Countdown** — "Show countdown" pref, `CountDownOverlay`, `countdown.aif`. [nib, bin, resource; changelog 4.6]
- **Controls during recording** — Pause, Resume, Stop, Restart, Trash (`recorderControlPause/Resume/Stop/Restart/Trash`); confirmations "Are you sure you want to cancel this recording and start a new one?" / "…delete this recording?" (`confirmVideoDelete`). [asset, bin, defaults]
- "Show controls while recording" + controls **position** (`showRecordingControls`). [nib; changelog 4.6]
- **Audio level meter** in the controls (`VUMeter`, `PowerMeter`, `micPowerMeter`, `computerAudioPowerMeter`). [bin; changelog 4.6]
- **Menu bar while recording** — "Display recording time" (`displayRecordingTime`), stop glyph (`menubarStop`), tooltip "Press to stop recording". [nib, bin, asset]
- **Pause/Resume** (`pauseResumeScreenRecording`, `PausableTimer`, `pauseRecording.aif`). [bin; changelog 3.8]
- **Dim screen while recording** outside the area (`dimScreenWhileRecording`). [nib; changelog 4.7.5]
- **"Do Not Disturb" while recording** (`doNotDisturbWhileRecording`; binary observes `com.apple.notificationcenterui.dndprefs_changed`). [nib, defaults, bin]
- **Hide desktop icons** (shared with screenshots; hides widgets since 4.7). [nib, bin]
- **Prevent display sleep while recording.** [web changelog 3.8.1 only]
- **Sounds** — `startRecording.aif`, `stopRecording.aif`, `pauseRecording.aif`, `countdown.aif`. [resources]
- **Crash recovery** — "Your screen recording has been successfully recovered." (`restoredVideoAfterCrash`). [bin]
- **Permissions** — Screen Recording, Camera, Microphone, Accessibility (keystrokes) prompts with System Settings deep links. [bin, plist]

## 3. Audio

- **Record Microphone** with device picker (`AVDeviceMenuItem`, `micDeviceID`), "Do Not Record Microphone", "No microphone selected". [bin]
- **Record Computer Audio** — on macOS Ventura+ driverless ("the new screen recorder no longer requires a driver"), i.e. ScreenCaptureKit audio [bin, changelog 4.6, inf]; legacy path bundles `AudioLoop.framework` wrapping a Background-Music loopback driver with install/uninstall UI. [fw, nib]
- **Audio merging** — "Record on a single track" vs "Record on separate tracks" (`mergeAudioTracks`). [nib]
- **Record audio in mono** (`recordAudioInMono`). [nib; changelog 4.6]
- **Computer Audio Settings…** sheet — "Microphone volume:" and "Computer audio volume:" sliders (`micVolume`, `audioVolume`). [nib, bin]
- **Muted-mic warning** (`warnAboutMutedMicrophone`) and **mic disconnected** dialog ("Continue Without Audio" / stop). [bin]

## 4. Webcam overlay

- **Record camera** toggle, device picker, "Don't Record Camera". [bin]
- **Size** (`tiny/small/medium/large/huge`), **shape** (`circle/rounded/square`), **mirror** (`CameraFlipSettingDidChange`), **draggable position** (`use_default_camera_position`), **click to toggle fullscreen camera** (`toggleCameraFullscreen`). [bin; changelog 3.9.4 / 4.3]
- Composited into the recording (`CameraOverlay`, `CameraOverlayView`); warns when camera is on but no mic is selected. [bin]

## 5. Input visualisation

- **Show cursor** on recordings (`showCursorOnRecordings`). [nib]
- **Highlight clicks** (`highlightClicks`) — style `ring/filled/outline` (`cursorHighlightStyle`), size (`cursorHighlightSize`), colour (Blue/Red/Green/Yellow/Orange/Purple/Pink/Gray/System Accent; `cursorColor1…8`), "Animate clicks" (`cursorHighlightAnimate`); classes `CursorHighlighter`, `CursorOverlay`, `MouseEventTapListener`; "Click here to preview". [nib, bin, defaults]
- **Show keystrokes** (`showKeystrokes`) — `KeyboardOverlay` + `KeyEventTapListener`; CleanShot prompts for **Accessibility** for this ("CleanShot needs accessibility permissions to display keystrokes while recording"); Lightshot's listen-only tap needs Input Monitoring instead (spec 0006): "Show all keys" / "Show only command keys" (`keyboardOverlayDisplayAll`), position Top/Bottom × Left/Center/Right (`keyboardOverlayPosition`), size, appearance Light/Dark/System (`keyboardOverlayStyle`), "Blur background"; cannot show keys typed in password fields; repeated-press animation (4.2.2); held modifiers shown (4.7). [nib, bin, changelog]

## 6. Post-recording flow

- **Quick Access Overlay** shows the video/GIF (`VideoPopup`, `GIFPopup`; assets `popupVideoFile`, `popupGifFile`, `popupWithSound`, `popupTrim`); tips "Double-click on the overlay to trim or compress the video", "Large videos can be compressed…"; right-click menu. [bin, asset]
- **After-recording actions** are a separate list from screenshot actions (`afterVideoActions`): Copy file to clipboard, Save to export location, Upload to Cloud (+ variants), Open Video Editor, Trim & encode video, Delete, Rename, Quick Look (Space). [bin; changelog 3.2]
- **Open Video Editor after recording** pref (`openVideoEditorAfterCapture`). [nib]
- **GIF processing popup** with cancel — "You can delete the recording or stop the GIF conversion and save it as a video instead." GIF is recorded as video, then converted. [bin]
- **Video Editor ("Trim & Convert")** — `VideoConverter`, `VideoTrimmerEncoder`, `GIFTrimmer`: trim handles (start/end only), "Trim Only" / "Trim & Convert", "Dimensions:" (Original + presets, Width/Height), "Video quality:" slider, "Estimated File Size" (`EncoderEstimateCalculator`), audio Don't change / Mute / Change volume / Convert to mono, "Remove the Audio", "Save as New Video" or replace, "Revert to Original". `lastUsedEncoderSettings` = `{"volume":1,"convertAudioToMono":false,"muteAudio":true,"quality":3}`. [nib, bin, defaults]
- **[5.0+] Studio Mode** — smart zoom following the cursor, cursor smoothing, motion blur, backgrounds, post-hoc cursor/keystroke/camera adjustment, hardware-encoded rendering, landscape/square/vertical export. Not in 4.8.3. [web]

## 7. Formats and export

- **MP4 (H.264)** video. [web; bin `AVVideoCodecType`, `mp4URL`] HEVC not evidenced (one `ftyphevc` string, likely a sniffing table). [inf]
- **GIF** via `Regift` (ImageIO) + bundled **gifsicle 1.93** for `gifsicleOptimize` / `gifsicleTrim`. [fw, bin]
- **GIF prefs** — GIF FPS, GIF quality ("maximum can speed up processing but increases file size"), GIF size (max width 200/256/320/480/500/640/800 (default)/960/1200 × auto, or Original), "Optimize GIFs". [nib, bin]
- **Retina** — "Scale Retina videos to 1x" (`downscaleRetinaVideos`). [nib, bin]

## 8. Recording preferences pane (`RecordingPreferences.nib`)

- **Video** — "Video FPS:" popup (`fps10Option`, `fps15Option` visible; 30/60 claimed [3p]), "Max resolution:" popup (`maxRecordingResolution`, "Set maximum resolution to reduce file size and upload time."), "Video Encoder:" + "Options…", "Scale Retina videos to 1x", "Open Video Editor after recording".
- **GIF** — FPS, quality, size, Optimize.
- **Audio** — Record Computer Audio, single/separate tracks, mono, Computer Audio Settings…, Uninstall Driver.
- **Cursor** — Show cursor, Highlight clicks, Animate clicks, Style / Size / Color, preview.
- **Keystrokes** — Show keystrokes, all keys / command keys, Position, Size, Appearance, Blur background.
- **Controls / general** — Show controls while recording (+ position), Show countdown, Dim screen, "Do Not Disturb", Display recording time, Remember last selection.

## 9. Keyboard shortcuts

- One hotkey action "Record Screen / Stop Recording"; "Pause/Resume Recording" and "Restart Recording" are separate rebindable actions. Inside All-In-One: **R** record, **A** area, **F** fullscreen, **Space/W** window, **S** scrolling, **O** OCR; **Space** = Quick Look on the overlay. [bin]
- The **default chord for Record Screen is unverified**: the bundle stores chords only when customised, cleanshot.com publishes no table, and third-party lists conflict (one says ⌘⇧R; another lists chords for actions that do not exist in the binary).

## 10. Unverifiable from the bundle

FPS / max-resolution / encoder option values, cursor size steps, video-quality steps, camera size labels (Swift inline literals); whether the encoder popup offers HEVC; the URL-scheme recording endpoint; Presenter Overlay and display-sleep prevention (changelog only); per-video history behaviour.
