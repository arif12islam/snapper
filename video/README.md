# Snapper explainer video

A Remotion project that renders the 32 second explainer on the launch page into `../site/media`.

```
cd video
npm install
npm run audio       # synthesizes public/audio.wav (needs python3 with numpy and scipy)
npm run studio      # preview and edit in the browser
npm run render      # writes snapper-explainer.mp4, snapper-poster.jpg and app-shot.png
```

The page also ships a WebM copy for browsers without H.264. Make it after rendering:

```
ffmpeg -y -i ../site/media/snapper-explainer.mp4 -c:v libvpx-vp9 -b:v 0 -crf 37 -row-mt 1 -c:a libopus -b:a 128k ../site/media/snapper-explainer.webm
```

On Linux without Chrome, point Remotion at a Chromium build with `REMOTION_BROWSER=/path/to/headless_shell`.

## How it fits together

- The film runs at 30 fps and the music at 120 BPM, so one beat is 15 frames and one bar is 60. Cuts and pops land on beats.
- `src/Explainer.tsx` places the scenes: hook (0), intro (120), product walkthrough (240), chat (625), record (750), outro (840).
- `src/Product.tsx` is the editor walkthrough; its timing is the `T` table at the top.
- `src/Scenes.tsx` holds the type-driven scenes.
- `audio/make_audio.py` builds the music and every sound effect from scratch, timed to the same frame numbers. If you move an event in the film, move its sound in the `events` list too.
- The app in the film ("Orbit") and the people in the chat are invented.
