import React from 'react';
import { C } from './palette';

// A flat red snapper, facing right. Its eye and gill line are drawn the way the app icon draws them:
// a white ring on ink, with a white curve sweeping down behind it.
export const FISH_W = 1000;
export const FISH_H = 520;
export const EYE = { x: 842, y: 222, disc: 56, ring: 34, ringWidth: 17 };

const BODY =
  'M 968 268 C 950 205, 892 150, 800 126 C 650 90, 430 106, 290 156 C 220 182, 168 212, 132 232 ' +
  'L 132 300 C 172 320, 232 352, 302 374 C 470 424, 700 428, 832 384 C 904 358, 952 322, 968 268 Z';

export const Fish: React.FC<{ tail?: number; style?: React.CSSProperties; fins?: number }> = ({ tail = 0, fins = 0, style }) => (
  <svg viewBox={`0 0 ${FISH_W} ${FISH_H}`} width={FISH_W} height={FISH_H} style={{ overflow: 'visible', ...style }}>
    <defs>
      <clipPath id="fish-body">
        <path d={BODY} />
      </clipPath>
    </defs>

    {/* Tail, gently swinging */}
    <g style={{ transformOrigin: '140px 266px', transform: `rotate(${tail}deg)` }}>
      <path d="M 150 244 C 104 196, 62 136, 18 96 C 40 170, 56 228, 74 266 C 56 304, 40 362, 18 436 C 62 396, 104 336, 150 288 Z" fill={C.coral} />
      <path d="M 150 244 C 118 210, 86 166, 54 128 C 70 190, 82 236, 96 266 C 82 296, 70 342, 54 404 C 86 366, 118 322, 150 288 Z" fill="#E8503F" />
    </g>

    {/* Dorsal, anal and pelvic fins */}
    <path d="M 742 128 L 716 56 L 684 112 L 656 46 L 624 106 L 596 44 L 562 104 C 506 70, 426 72, 364 110 C 340 124, 320 140, 306 152 Z" fill="#E8503F" style={{ transformOrigin: '520px 140px', transform: `skewX(${fins}deg)` }} />
    <path d="M 404 398 C 364 446, 302 466, 250 460 C 280 424, 312 398, 344 386 Z" fill="#E8503F" />
    <path d="M 650 408 C 618 456, 566 486, 524 490 C 550 454, 572 424, 598 408 Z" fill="#E8503F" />

    {/* Body: coral, a deeper back, a blush belly */}
    <path d={BODY} fill={C.coral} />
    <g clipPath="url(#fish-body)">
      <path d="M 980 250 C 880 236, 700 222, 470 228 C 330 232, 220 244, 120 262 L 120 60 L 980 60 Z" fill="#F0584A" />
      <path d="M 950 300 C 840 330, 640 352, 430 346 C 320 342, 220 326, 140 300 L 140 470 L 950 470 Z" fill="#FFC2B4" />
      {/* A quiet lateral line */}
      <path d="M 700 250 C 560 236, 380 240, 170 262" stroke="#FF8A7C" strokeWidth={5} fill="none" strokeLinecap="round" />
    </g>

    {/* Pectoral fin */}
    <path d="M 712 296 C 652 312, 610 342, 588 378 C 640 372, 690 346, 724 316 Z" fill="#FF8A7C" style={{ transformOrigin: '716px 304px', transform: `rotate(${fins * 1.5}deg)` }} />

    {/* Gill line, as in the icon */}
    <path d="M 764 150 C 738 214, 734 296, 768 368" stroke="#fff" strokeWidth={11} fill="none" strokeLinecap="round" />

    {/* Mouth */}
    <path d="M 968 268 L 922 278" stroke={C.ink} strokeWidth={5} strokeLinecap="round" />

    {/* Eye: ink disc, white ring, ink pupil */}
    <circle cx={EYE.x} cy={EYE.y} r={EYE.disc} fill={C.ink} />
    <circle cx={EYE.x} cy={EYE.y} r={EYE.ring} fill="none" stroke="#fff" strokeWidth={EYE.ringWidth} />
  </svg>
);
