// Renders the promo into ../site/media. Usage: node render.mjs [--stills]
import path from 'node:path';
import fs from 'node:fs';
import { bundle } from '@remotion/bundler';
import { renderMedia, renderStill, selectComposition } from '@remotion/renderer';

const browserExecutable = process.env.REMOTION_BROWSER || undefined;
const out = path.resolve('../site/media');
fs.mkdirSync(out, { recursive: true });

const serveUrl = await bundle({ entryPoint: path.resolve('src/index.ts') });
const composition = await selectComposition({ serveUrl, id: 'Promo', browserExecutable });

if (process.argv.includes('--stills')) {
  const frames = (process.env.FRAMES || '40,90,180,290,340,400,500').split(',').map(Number);
  for (const frame of frames) {
    await renderStill({ serveUrl, composition, frame, output: path.resolve(`stills/f${frame}.png`), browserExecutable });
    console.log('still', frame);
  }
  process.exit(0);
}

await renderMedia({
  serveUrl, composition, codec: 'h264', crf: 24, pixelFormat: 'yuv420p', browserExecutable,
  outputLocation: path.join(out, 'snapper-promo.mp4'),
  onProgress: ({ progress }) => process.stdout.write(`\r${Math.round(progress * 100)}%`),
});
await renderStill({ serveUrl, composition, frame: 300, output: path.join(out, 'snapper-poster.jpg'), imageFormat: 'jpeg', jpegQuality: 82, browserExecutable });
console.log('\ndone');
