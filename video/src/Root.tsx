import React from 'react';
import { Composition, continueRender, delayRender, staticFile } from 'remotion';
import { EXPLAINER_LEN, Explainer } from './Explainer';
import { APP_H, APP_W, FakeApp } from './FakeApp';
import { FeatureShot, SHOT_NAMES, shotSize } from './FeatureShots';

const handle = delayRender('Loading fonts');
const faces = [
  new FontFace('Inter', `url(${staticFile('fonts/inter.woff2')}) format('woff2')`, { weight: '100 900' }),
  new FontFace('Instrument Serif', `url(${staticFile('fonts/serif-italic.woff2')}) format('woff2')`, { style: 'italic', weight: '400' }),
  new FontFace('Instrument Serif', `url(${staticFile('fonts/serif.woff2')}) format('woff2')`, { style: 'normal', weight: '400' }),
];
Promise.all(faces.map((face) => face.load()))
  .then((loaded) => {
    loaded.forEach((face) => document.fonts.add(face));
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
    {SHOT_NAMES.map((name) => (
      <Composition key={name} id={`F-${name}`} component={FeatureShot} durationInFrames={1} fps={30} width={shotSize(name).w} height={shotSize(name).h} defaultProps={{ name }} />
    ))}
    <Composition id="AppShot" component={AppShot} durationInFrames={1} fps={30} width={APP_W} height={APP_H} />
  </>
);
