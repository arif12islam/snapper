import React from 'react';
import { Composition, continueRender, delayRender, staticFile } from 'remotion';
import { EXPLAINER_LEN, Explainer } from './Explainer';
import { APP_H, APP_W, FakeApp } from './FakeApp';

const handle = delayRender('Loading Inter');
const inter = new FontFace('Inter', `url(${staticFile('fonts/inter.woff2')}) format('woff2')`, { weight: '100 900' });
inter
  .load()
  .then((font) => {
    document.fonts.add(font);
    continueRender(handle);
  })
  .catch(() => continueRender(handle));

const AppShot: React.FC = () => (
  <div style={{ fontFamily: 'Inter, sans-serif' }}>
    <FakeApp />
  </div>
);

export const Root: React.FC = () => (
  <>
    <Composition id="Explainer" component={Explainer} durationInFrames={EXPLAINER_LEN} fps={30} width={1600} height={1000} defaultProps={{ withAudio: true }} />
    <Composition id="AppShot" component={AppShot} durationInFrames={1} fps={30} width={APP_W} height={APP_H} />
  </>
);
