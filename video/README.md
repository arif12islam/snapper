# Snapper promo video

A Remotion project that renders the launch page video into `../site/media`.

```
cd video
npm install
npm run studio      # preview and edit in the browser
npm run render      # writes site/media/snapper-promo.mp4 and snapper-poster.jpg
```

The page also ships a WebM copy for browsers without H.264. Make it from the MP4 after rendering:

```
ffmpeg -y -i ../site/media/snapper-promo.mp4 -c:v libvpx-vp9 -b:v 0 -crf 38 -row-mt 1 -an ../site/media/snapper-promo.webm
```

On Linux without Chrome, point Remotion at a Chromium build with `REMOTION_BROWSER=/path/to/headless_shell`.

The app shown in the video ("Orbit") is invented. All timing lives in the `T` table at the top of `src/Promo.tsx`.
