import React from 'react';
import { AbsoluteFill, Audio, Sequence, staticFile } from 'remotion';
import { PRODUCT_LEN, ProductScene } from './Product';
import { Chat, Hook, Intro, Outro, PAPER, Record } from './Scenes';

// 120 BPM at 30 fps: one beat is 15 frames, one bar is 60 frames.
export const EXPLAINER_LEN = 960;
export const AT = { hook: 0, intro: 120, product: 240, chat: 625, record: 750, outro: 840 };

export const Explainer: React.FC<{ withAudio?: boolean }> = ({ withAudio = true }) => (
  <AbsoluteFill style={{ background: PAPER }}>
    {withAudio ? <Audio src={staticFile('audio.wav')} /> : null}
    <Sequence from={AT.hook} durationInFrames={140}><Hook /></Sequence>
    <Sequence from={AT.intro} durationInFrames={AT.product - AT.intro}><Intro /></Sequence>
    <Sequence from={AT.product} durationInFrames={PRODUCT_LEN}><ProductScene /></Sequence>
    <Sequence from={AT.chat} durationInFrames={140}><Chat /></Sequence>
    <Sequence from={AT.record} durationInFrames={100}><Record /></Sequence>
    <Sequence from={AT.outro} durationInFrames={EXPLAINER_LEN - AT.outro}><Outro /></Sequence>
  </AbsoluteFill>
);
