# Snapper

Built by Bykorp.

Menu-bar capture, markup, recording and sharing for macOS 14+. Builds from the command line, no Xcode needed.

## Build and run

```bash
xcode-select --install     # once, if you don't have the Command Line Tools
chmod +x build.sh
./setup-signing.sh         # once: stable signing so permissions survive updates
./build.sh                 # compile, update /Applications/Snapper.app in place, relaunch
./build.sh --zip           # build/Snapper-<version>.zip for in-app updates (see Updates)
./build.sh --no-run        # build only (output: build/Snapper.app)
```

This code was written without access to a Swift compiler (it has been syntax-checked, not type-checked),
so the first build may show a few compile errors. Send them over and they are quick to fix.

Without typing commands: double-click `Build Snapper.command` (build and launch) or `Make DMG.command`
(build the installer). If macOS blocks them, right-click the file, choose Open, then Open.

## Hotkeys

Every shortcut can be changed in **Settings > Shortcuts** (click a field, press the keys; Esc cancels,
Delete clears). Snapper checks each one against macOS's own shortcuts (read from your current
System Settings, e.g. ⌘⇧3/4/5 screenshots, Spotlight, input sources, Mission Control, Spaces), against
standard app shortcuts (⌘C, ⌘Q, ⌘Tab…), against its own other actions, and tells you if another app already
owns it. To give ⌘⇧4 to Snapper, turn off the macOS screenshot shortcuts first (there's a button for it).

Defaults:

| Keys | Action |
|---|---|
| `Ctrl+Shift+X` | All-in-one (select an area, then screenshot / record / GIF / scrolling / OCR / pin / timer) |
| `Ctrl+Shift+A` | Capture area |
| `Ctrl+Shift+W` | Capture window |
| `Ctrl+Shift+F` | Capture fullscreen |
| `Ctrl+Shift+R` | Start / stop screen recording (display under the mouse) |
| `Ctrl+Shift+T` | Copy text from an area (OCR, also reads QR codes) |
| `Ctrl+Shift+Z` | Restore the most recently closed overlay |
| `Ctrl+Shift+H` | Hide / show Quick Access overlays |
| `Esc` | Cancel an overlay |

## App behaviour

- Snapper lives in the menu bar. While a window is open (editor, Settings, History, video editor, About) it also
  shows in the Dock and gets a full menu bar: Snapper, File, Edit, View, Go, Window, Help. Close the last window
  and it goes back to being a menu bar item.
- Menus show your own shortcuts and update the moment you change one in Settings > Shortcuts.
- Copy closes the editor and the Quick Access card (Settings > Quick Access > Close after copying).

## Design

- **Liquid Glass:** on macOS 26 Tahoe, toasts, the recording controls, countdown, all-in-one toolbar, scrolling
  HUD, Quick Access cards and the annotate window's floating bars use the system glass material, and the annotate
  toolbar is a native toolbar. On earlier macOS the same surfaces use the HUD blur.
- **Branding:** the Snapper badge and wordmark appear in toasts, HUDs, overlays, the About window, Settings,
  Welcome, History and on the share pages of your upload server. Brand navy is #1B1B4D.
- **Icons:** `design/make_icons.py` renders every size from the SVGs, aligned to the pixel grid, with
  the 16 and 32 px sizes hand-tuned (thicker snail, guaranteed gap to the lens). `build.sh` turns the iconset
  into the `.icns` with `iconutil`. The menu bar icon ships at @1x and @2x.

## Performance

- Desktop icons are hidden with a wallpaper window instead of restarting Finder.
- The capture overlay is GPU layers only (no full-screen CPU redraw while moving the mouse).
- Each capture is PNG-encoded once, off the main thread; history writes happen in the background.
- Quick Access shows a downsampled preview; the annotate canvas draws a display-sized copy and repaints only
  the area that changed while you draw.
- Pins zoom and pan with GPU layers. No timers run while Snapper is idle. Built with whole-module optimisation.

## Features

### Capture
- **Modes:** area, window, fullscreen, previous area, scrolling (vertical and horizontal), self-timer
  (area or fullscreen, 3/5/10 s), pin area, OCR.
- **All-in-one:** one shortcut. Drag a selection, then move or resize it with handles, nudge it with the
  arrow keys, type an exact width and height, lock the aspect ratio. The last selection is remembered.
  A toolbar under the selection picks screenshot, video, GIF, scrolling, text, pin or self-timer.
- **Precision:** crosshair, 5× magnifier with coordinates, size label. Each can be turned off.
- **Freeze screen** (default) or capture live, so menus and videos are grabbed as they are when you release.
- **Window capture:** with a background (wallpaper, plain colour or any built-in gradient, adjustable
  padding), or transparent with or without the window shadow.
- **After capture:** show Quick Access, copy, and/or save to your folder; shutter sound; desktop icons hidden.

### Quick Access overlay
- Compact card in a screen corner of the display you captured (bottom/top, left/right), three sizes.
- Several captures stack; the newest sits in the corner.
- Hover for buttons: copy, save, annotate, pin, copy text, upload. Drag the card into any app.
- Pinch or scroll over the card to zoom into the picture; two-finger scroll pans while zoomed; double-tap resets.
- Save goes straight to your save folder; ⌥-click or `⇧⌘S` for Save As.
- Swipe with two fingers towards the screen edge to dismiss, away from it to save.
- Auto-close timer (paused while hovering), close after copy / save / drag (each optional).
- Restore recently closed overlays, temporarily hide all overlays, close all.
- Recordings and GIFs get a card too (copy file, save, edit, upload).

### Annotate
- **Tools:** select, crop, arrow (filled, open, tapered, double, curved), line, rectangle (outline or
  filled), ellipse, pencil (auto-smoothed), highlighter (fits the height of the text you drag over),
  text (7 styles), callout, counter (1, 2, 3…), spotlight (rectangle or ellipse), pixelate (randomised),
  blur (smooth or secure).
- **Editing:** resize handles on shapes, arrow end and bend handles, rotate one annotation, arrow keys nudge,
  undo/redo (bottom bar, `⌘Z` / `⇧⌘Z`), per-tool remembered styles.
- **Colour:** colour well, eyedropper (picks from anywhere on screen), favourite colours palette.
- **Picture:** rotate, flip horizontally/vertically, resize, crop with aspect ratios
  (free, original, 1:1, 4:3, 3:2, 16:9, 9:16, 4:5), crop handles, snapping to edges and centre lines,
  rule-of-thirds guides.
- **Combine images:** drop or paste (`⌘V`) another screenshot onto the canvas and position or resize it.
- **Background tool:** 20 built-in backgrounds, your own images, the desktop wallpaper or any plain colour;
  padding, corner radius, shadow, 9-way alignment, aspect ratio, Auto Balance (trims plain margins so
  spacing looks even), saved presets. Shown live on the canvas.
- **Share:** Copy (`⌘C`), Save (`⌘S`), save to folder, `.snapper` project files with editable layers.
- Zoom with pinch, `⌘`-scroll, `⌘+` / `⌘−`, `⌘0` fit, `⌘1` actual size; scroll to pan. Light and dark mode.

### Screen recording
- Fullscreen, area, window, or GIF. MP4 (H.264) with quality, frame rate (15/30/60) and resolution
  (native, 1080p, 720p) settings.
- Microphone and computer audio (separate tracks), countdown, pause/resume, floating controls hidden from
  the video, recording time in the menu bar (click it to stop), crash recovery.
- Show or hide the cursor; "editable cursor" records without it so the editor can draw it.
- Clicks: colour, size, outline or filled, animation. Keystrokes: position, size, dark or light, all keys
  or only shortcuts. Camera: position, size, circle or rounded rectangle, double-click for fullscreen camera.
- Optional Do Not Disturb (see below) and hidden desktop icons while recording.

### Video editor
- Background (gradients, wallpaper), padding, corners, shadow.
- Formats: original, landscape 16:9, square 1:1, vertical 9:16, portrait 4:5.
- Smart zoom: zooms in on clicks and follows the cursor, with adjustable zoom and motion blur.
- Cursor (editable-cursor recordings): smooth movement, size, click effects.
- Live preview, trim, export MP4 (hardware encoder via AVFoundation) or GIF, copy, reveal, upload.

### Pins, OCR, history
- **Pins:** rounded, float above all windows. Pinch to zoom into the picture (around the pointer), scroll or
  drag to pan while zoomed, double-click to reset. Scroll wheel or two-finger scroll zooms, `⌥`-scroll for opacity, `⌘`-scroll, `⌘+` / `⌘−`
  or an edge to resize, `⌘0` 100 %, arrow keys to position, hover for a close button, lock mode, right-click menu.
- **OCR:** on-device Vision with automatic language detection (30+ languages incl. CJK), QR and barcodes.
- **History:** window with thumbnails, filters (screenshots, windows, scrolling, recordings), restore,
  annotate, copy, reveal, delete; keeps 1 day to 1 month.

### Cloud (self-hosted)
`server/server.js` is a dependency-free Node 18+ server:

```bash
PORT=8787 TOKEN=secret BASE_URL=https://snaps.example.com node server/server.js
```

Settings > Cloud: Upload URL `https://snaps.example.com/u`, token `secret`.
Upload from Quick Access (`⌘U`) or the video window; the link is copied. ⌥-click Upload to set a
**password**, an **expiry** (1 hour to 30 days), or **delete after first view** for that upload. Share pages
support **comments**, video range requests, and `DELETE /f/<id>` with the token. `/library?token=…` lists uploads.

Not included: hosted accounts, teams/SSO/SCIM, transcription, custom-domain branding as a service
(put the server behind your own domain for that).

## URL scheme

`snapper://<command>` from Shortcuts, Raycast, Alfred or `open`:

`all-in-one`, `capture-area`, `capture-window`, `capture-fullscreen` (`?timer=1`), `capture-previous-area`,
`self-timer`, `scrolling-capture` (`?horizontal=1`), `capture-text`, `pin-area`, `record-screen`,
`record-area`, `record-window`, `record-gif`, `stop-recording`, `restore`, `toggle-overlays`, `history`,
`open-annotate` (`?filepath=~/Desktop/shot.png`), `open-settings`.

## Permissions

- **Screen Recording:** required. Ad-hoc signing changes the app's identity on every rebuild, so if captures
  come back blank, remove Snapper from the list, re-add it and relaunch.
- **Accessibility:** scrolling capture.
- **Input Monitoring:** keystroke display.
- **Microphone / Camera:** only when those options are on.

## Do Not Disturb while recording

macOS has no public API for Focus, so Snapper runs two Shortcuts you create once in the Shortcuts app:
- `Snapper Focus On`: action "Set Focus" → Do Not Disturb → On
- `Snapper Focus Off`: action "Set Focus" → Do Not Disturb → Off

Then turn on Settings > Recording > "Turn on Do Not Disturb".

## Updates

Snapper can update itself. Put a release feed in Settings > General > Updates, then use "Check for Updates" in the
menu bar (it also checks quietly at launch).

1. Create a GitHub repository for the builds, for example `arif12islam/snapper-releases`.
2. Raise the version in `build.sh`, run `./build.sh --zip`, and publish `build/Snapper-<version>.zip` as a release
   whose tag is the version (`gh release create 1.3 build/Snapper-1.3.zip`).
3. In Settings > General > Updates enter `arif12islam/snapper-releases`.

A private repository will not work, since the app downloads without credentials. Any URL returning
`{"version": "1.3", "url": "https://.../Snapper-1.3.zip"}` works as a feed too.

To skip the manual zip and release steps, push this folder to the repository: `.github/workflows/release.yml` builds
the app on a GitHub Mac runner and publishes the release whenever you push a new version number.
