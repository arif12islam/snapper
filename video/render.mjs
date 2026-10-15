// Renders the explainer into ../site/media.
//   node render.mjs            full render: mp4 with audio, poster, app still
//   node render.mjs --stills   preview frames into ./stills (FRAMES=10,20,...)
import path from 'node:path';
import fs from 'node:fs';
import { bundle } from '@remotion/bundler';
import { renderMedia, renderStill, selectComposition } from '@remotion/renderer';

const browserExecutable = process.env.REMOTION_BROWSER || undefined;
const out = path.resolve('../site/media');
fs.mkdirSync(out, { recursive: true });

const serveUrl = await bundle({ entryPoint: path.resolve('src/index.ts') });

if (process.argv.includes('--stills')) {
  const inputProps = { withAudio: false };
  const composition = await selectComposition({ serveUrl, id: 'Explainer', browserExecutable, inputProps });
  const frames = (process.env.FRAMES || '100,180,420,560,700,800,920').split(',').map(Number);
  for (const frame of frames) {
    await renderStill({ serveUrl, composition, frame, inputProps, output: path.resolve(`stills/f${frame}.png`), browserExecutable });
    console.log('still', frame);
  }
  process.exit(0);
}

const inputProps = { withAudio: true };
const composition = await selectComposition({ serveUrl, id: 'Explainer', browserExecutable, inputProps });
await renderMedia({
  serveUrl, composition, inputProps, browserExecutable,
  codec: 'h264', crf: 23, pixelFormat: 'yuv420p', audioCodec: 'aac', audioBitrate: '160k',
  outputLocation: path.join(out, 'snapper-explainer.mp4'),
  onProgress: ({ progress }) => process.stdout.write(`\r${Math.round(progress * 100)}%`),
});
await renderStill({ serveUrl, composition, inputProps: { withAudio: false }, frame: 560, output: path.join(out, 'snapper-poster.jpg'), imageFormat: 'jpeg', jpegQuality: 84, browserExecutable });
const shot = await selectComposition({ serveUrl, id: 'AppShot', browserExecutable });
await renderStill({ serveUrl, composition: shot, frame: 0, output: path.join(out, 'app-shot.png'), browserExecutable, scale: 1 });
console.log('\ndone');
