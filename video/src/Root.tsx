import React from 'react';
import { Composition, continueRender, delayRender, staticFile } from 'remotion';
import { DURATION, Promo } from './Promo';

const handle = delayRender('Loading Inter');
const inter = new FontFace('Inter', `url(${staticFile('fonts/inter.woff2')}) format('woff2')`, { weight: '100 900' });
inter
  .load()
  .then((font) => {
    document.fonts.add(font);
    continueRender(handle);
  })
  .catch(() => continueRender(handle));

export const Root: React.FC = () => (
  <Composition id="Promo" component={Promo} durationInFrames={DURATION} fps={30} width={1600} height={1000} />
);
