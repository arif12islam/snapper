# Snapper explainer video

A Remotion project that renders the 46 second explainer on the launch page into `../site/media`.

```
cd video
npm install
npm run voice       # optional: regenerates the narration clips in audio/vo (needs Kokoro, see below)
npm run audio       # mixes music, effects and narration into public/audio.wav (python3, numpy, scipy)
npm run studio      # preview and edit in the browser
npm run render      # writes snapper-explainer.mp4, snapper-poster.jpg and app-shot.png
```

The page also ships a WebM copy for browsers without H.264. Make it after rendering:

```
ffmpeg -y -i ../site/media/snapper-explainer.mp4 -c:v libvpx-vp9 -b:v 0 -crf 37 -row-mt 1 -c:a libopus -b:a 128k ../site/media/snapper-explainer.webm
```

On Linux without Chrome, point Remotion at a Chromium build with `REMOTION_BROWSER=/path/to/headless_shell`.

## Narration

The voice is Kokoro (open weights, Apache 2.0), run locally: a blend of 70 percent `am_onyx` (the deepest male voice) and 30 percent `am_michael` (the clearest), around 96 Hz. The clips are committed in `audio/vo`, so you only need Kokoro to change the script:

```
pip install kokoro-onnx soundfile
# download kokoro-v1.0.onnx and voices-v1.0.bin from github.com/thewh1teagle/kokoro-onnx/releases into ~/tts
KOKORO_DIR=~/tts python3 audio/voiceover.py
```

The script lives in `src/timeline.json` under `voice`: each line has a cue point (`at`: scene start, frame within the scene) and the latest frame it may run to (`until`). Lines that run long are sped up slightly to fit; the run prints each line's length and speed. It also writes the captions file `site/media/snapper-explainer.vtt`.

## How it fits together

- The film runs at 30 fps and the music at 120 BPM, so one beat is 15 frames and one bar is 60. Cuts and pops land on beats.
- `src/timeline.json` is the single source of timing: scene starts, every animation beat, the outro words and the narration cues. The scenes, the sound effects and the voice all read it, so edit timing there and re-run `voice`, `audio` and `render`.
- `src/Product.tsx` is the editor walkthrough.
- `src/Scenes.tsx` holds the type-driven scenes.
- `audio/make_audio.py` builds the music and every sound effect from scratch, timed from `timeline.json`, and ducks the music under the narration.
- The app in the film ("Orbit") and the people in the chat are invented.
