import React from 'react';
import { AbsoluteFill, Audio, Sequence, staticFile } from 'remotion';
import { ProductScene } from './Product';
import { Chat, Hook, Intro, Outro, PAPER, Record } from './Scenes';
import TL from './timeline.json';

// 120 BPM at 30 fps: one beat is 15 frames, one bar is 60 frames. All timing lives in timeline.json.
export const EXPLAINER_LEN = TL.length;
const S = TL.scenes;
const len = (k: keyof typeof S) => S[k][1] - S[k][0];

export const Explainer: React.FC<{ withAudio?: boolean }> = ({ withAudio = true }) => (
  <AbsoluteFill style={{ background: PAPER }}>
    {withAudio ? <Audio src={staticFile('audio.wav')} /> : null}
    <Sequence from={S.hook[0]} durationInFrames={len('hook')}><Hook /></Sequence>
    <Sequence from={S.intro[0]} durationInFrames={len('intro')}><Intro /></Sequence>
    <Sequence from={S.product[0]} durationInFrames={len('product')}><ProductScene /></Sequence>
    <Sequence from={S.chat[0]} durationInFrames={len('chat')}><Chat /></Sequence>
    <Sequence from={S.record[0]} durationInFrames={len('record')}><Record /></Sequence>
    <Sequence from={S.outro[0]} durationInFrames={len('outro')}><Outro /></Sequence>
  </AbsoluteFill>
);
