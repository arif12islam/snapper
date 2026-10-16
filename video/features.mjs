// Renders the website's feature images into ../site/media/features (PNG, converted to WebP afterwards).
import path from 'node:path';
import fs from 'node:fs';
import { bundle } from '@remotion/bundler';
import { renderStill, selectComposition, getCompositions } from '@remotion/renderer';

const browserExecutable = process.env.REMOTION_BROWSER || undefined;
const out = path.resolve('../site/media/features');
fs.mkdirSync(out, { recursive: true });
const serveUrl = await bundle({ entryPoint: path.resolve('src/index.ts') });
const only = process.argv.slice(2);
const comps = (await getCompositions(serveUrl, { browserExecutable })).filter((c) => c.id.startsWith('F-') && (!only.length || only.includes(c.id.slice(2))));
for (const c of comps) {
  const composition = await selectComposition({ serveUrl, id: c.id, browserExecutable, inputProps: c.defaultProps });
  await renderStill({ serveUrl, composition, frame: 0, inputProps: c.defaultProps, output: path.join(out, `${c.id.slice(2)}.png`), browserExecutable });
  console.log('rendered', c.id);
}
