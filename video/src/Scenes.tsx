import React from 'react';
import { AbsoluteFill, Easing, Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { APP_H, APP_W, BEST, FakeApp, barRect } from './FakeApp';
import { FinalShot } from './Product';
import { Icon } from './Icons';
import { C, SERIF } from './palette';
import TL from './timeline.json';

export const NAVY = C.ink;
export const PAPER = C.cream;
export const RED = C.red;

const smooth = Easing.bezier(0.65, 0, 0.35, 1);
const clamp = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' } as const;
const ramp = (f: number, a: number, b: number) => interpolate(f, [a, b], [0, 1], { ...clamp, easing: smooth });
const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
const pop = (f: number, start: number, fps: number, stiffness = 160, damping = 18) =>
  spring({ frame: f - start, fps, config: { damping, stiffness } });

const font: React.CSSProperties = { fontFamily: 'Inter, sans-serif' };

/** Rounded iris: the next scene opens out of the centre of the frame. */
const Iris: React.FC<{ f: number; color: string; children: React.ReactNode; dur?: number }> = ({ f, color, children, dur = 18 }) => {
  const p = ramp(f, 0, dur);
  const inset = (1 - p) * 50;
  return (
    <AbsoluteFill style={{ background: color, clipPath: `inset(${inset}% ${inset}% round ${lerp(140, 0, p)}px)` }}>
      {children}
    </AbsoluteFill>
  );
};

/** A line of type that rises out of a mask. */
const Line: React.FC<{ f: number; start: number; size: number; color?: string; weight?: number; serif?: boolean; children: React.ReactNode; style?: React.CSSProperties }> = ({
  f, start, size, color = C.ink, weight = 800, serif = false, children, style,
}) => {
  const { fps } = useVideoConfig();
  const s = pop(f, start, fps, 150, 22);
  return (
    <div style={{ overflow: 'hidden', paddingBottom: size * 0.16, marginBottom: -size * 0.16, ...style }}>
      <div
        style={{
          fontSize: size, fontWeight: weight, color, letterSpacing: -size * 0.04, lineHeight: 1.0,
          transform: `translateY(${(1 - s) * 110}%)`, whiteSpace: 'nowrap', ...(serif ? SERIF : {}),
        }}
      >
        {children}
      </div>
    </div>
  );
};

/** A stroke that draws itself, like a marker on the screen. */
const Draw: React.FC<{ d: string; p: number; width?: number; color?: string }> = ({ d, p, width = 8, color = C.red }) => (
  <path d={d} fill="none" stroke={color} strokeWidth={width} strokeLinecap="round" strokeLinejoin="round" pathLength={1} strokeDasharray={1} strokeDashoffset={1 - p} />
);

const Counter: React.FC<{ n: number; x: number; y: number; s: number; size?: number }> = ({ n, x, y, s, size = 52 }) => (
  <div
    style={{
      position: 'absolute', left: x - size / 2, top: y - size / 2, width: size, height: size, borderRadius: size / 2, background: C.red,
      border: '4px solid #fff', boxSizing: 'border-box', color: '#fff', fontSize: size * 0.46, fontWeight: 800,
      display: 'flex', alignItems: 'center', justifyContent: 'center', transform: `scale(${s})`, boxShadow: '0 6px 14px rgba(27,27,77,0.2)',
    }}
  >
    {n}
  </div>
);

const shadow = '0 30px 60px rgba(27,27,77,0.16), 0 6px 14px rgba(27,27,77,0.08)';

// ---------------------------------------------------------------- Hook: chaos, then one clear point
const CARDS = [
  { x: 300, y: 250, r: -8, c: C.sky },
  { x: 800, y: 190, r: 5, c: C.sun },
  { x: 1300, y: 270, r: -4, c: C.lilac },
  { x: 330, y: 720, r: 6, c: C.mint },
  { x: 820, y: 660, r: -5, c: C.white },   // the hero card, it survives
  { x: 1290, y: 740, r: 4, c: C.coral },
];
const HERO = 4;
const BUBBLES = [
  { x: 520, y: 120, text: 'Which number?' },
  { x: 1080, y: 420, text: 'Where do I look?' },
  { x: 120, y: 470, text: 'What changed?' },
  { x: 1010, y: 870, text: 'Is this the new one?' },
  { x: 560, y: 520, text: 'Wait, what?' },
];
const MINI = 0.3;
const FINAL = { x: 1235, y: 505, s: 0.5 };

export const Hook: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const H = TL.hook;
  const conv = ramp(f, H.converge[0], H.converge[1]);
  const circle = ramp(f, H.circle[0], H.circle[1]);
  const arrow = ramp(f, H.arrow[0], H.arrow[1]);
  const head = ramp(f, H.head[0], H.head[1]);
  const best = barRect(BEST);
  const peak = { x: FINAL.x + (best.x + best.w / 2 - APP_W / 2) * FINAL.s, y: FINAL.y + (best.y - APP_H / 2) * FINAL.s };

  return (
    <AbsoluteFill style={{ ...font, background: C.cream }}>
      {CARDS.map((card, i) => {
        const inn = pop(f, i * 5, fps, 120, 16);
        const dx = Math.sin(f / 38 + i * 1.7) * 10;
        const dy = Math.cos(f / 46 + i * 1.3) * 8;
        const dr = Math.sin(f / 55 + i) * 1.4;
        const hero = i === HERO;
        const x = hero ? lerp(card.x + dx, FINAL.x, conv) : lerp(card.x + dx, 800, conv * 0.6);
        const y = hero ? lerp(card.y + dy, FINAL.y, conv) : lerp(card.y + dy, 500, conv * 0.6);
        const rot = hero ? lerp(card.r + dr, 0, conv) : card.r + dr + conv * card.r * 2;
        const sc = hero ? lerp(MINI, FINAL.s, conv) : MINI * (1 - conv * 0.4);
        const op = hero ? 1 : inn * (1 - ramp(f, H.converge[0], H.converge[0] + 18));
        const pad = hero ? lerp(14, 0, conv) : 14;
        return (
          <div
            key={i}
            style={{
              position: 'absolute', left: x, top: y, transform: `translate(-50%, -50%) rotate(${rot}deg) scale(${inn})`, opacity: op,
              padding: pad, background: card.c, borderRadius: 18, boxShadow: shadow,
            }}
          >
            <div style={{ width: APP_W * sc, height: APP_H * sc, borderRadius: 10, overflow: 'hidden', position: 'relative' }}>
              <div style={{ transform: `scale(${sc})`, transformOrigin: '0 0' }}>
                <FakeApp />
              </div>
            </div>
          </div>
        );
      })}

      {BUBBLES.map((b, i) => {
        const s = pop(f, H.bubbles[i], fps, 220, 14);
        const out = ramp(f, H.converge[0] - 6, H.converge[0] + 6);
        if (f < H.bubbles[i]) return null;
        return (
          <div
            key={i}
            style={{
              position: 'absolute', left: b.x, top: b.y, padding: '14px 22px', borderRadius: 22, borderBottomLeftRadius: 6,
              background: C.ink, color: '#fff', fontSize: 28, fontWeight: 600, letterSpacing: -0.4, boxShadow: '0 14px 30px rgba(27,27,77,0.22)',
              transform: `scale(${s * (1 - out * 0.3)})`, transformOrigin: '0 100%', opacity: 1 - out, whiteSpace: 'nowrap',
            }}
          >
            {b.text}
          </div>
        );
      })}

      {/* Order: a headline, a circled word, and an arrow to the detail that matters */}
      <div style={{ position: 'absolute', left: 120, top: 318 }}>
        <Line f={f} start={H.lines[0]} size={92}>Screenshots that</Line>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 26 }}>
          <Line f={f} start={H.lines[1]} size={92}>make the</Line>
          <div style={{ position: 'relative' }}>
            <Line f={f} start={H.lines[1] + 4} size={150} serif color={C.ink}>point.</Line>
            <svg viewBox="0 0 400 140" preserveAspectRatio="none" style={{ position: 'absolute', left: '-14%', top: '-2%', width: '128%', height: '104%', overflow: 'visible' }}>
              <Draw p={circle} width={5} d="M 360 40 C 300 6, 120 4, 46 30 C -4 50, 6 112, 90 128 C 190 146, 360 134, 392 92 C 410 64, 380 34, 330 22" />
            </svg>
          </div>
        </div>
      </div>
      <svg width={1600} height={1000} style={{ position: 'absolute', inset: 0, overflow: 'visible' }}>
        <Draw p={arrow} width={7} d={`M 700 640 C 860 760, 1180 700, ${peak.x - 18} ${peak.y + 14}`} />
        <Draw p={head} width={7} d={`M ${peak.x - 52} ${peak.y + 6} L ${peak.x - 16} ${peak.y + 14} L ${peak.x - 38} ${peak.y + 44}`} />
      </svg>
      <Counter n={1} x={peak.x + 4} y={peak.y - 30} s={pop(f, H.counter, fps, 220, 14)} />
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------- Intro: logo with orbiting features
const CHIPS = [
  { label: 'Capture', icon: 'crop', c: C.sky, a: 205 },
  { label: 'Annotate', icon: 'arrow', c: C.coral, a: 262 },
  { label: 'Magnify', icon: 'magnifier', c: C.sun, a: 318 },
  { label: 'Blur', icon: 'blur', c: C.lilac, a: 25 },
  { label: 'Record', icon: 'spotlight', c: C.mint, a: 92 },
  { label: 'Share', icon: 'link', c: C.cream, a: 155 },
];

export const Intro: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const I = TL.intro;
  const exit = ramp(f, I.exit[0], I.exit[1]);
  const icon = pop(f, I.icon, fps, 120, 15);
  return (
    <Iris f={f} color={C.ink}>
      <AbsoluteFill style={{ ...font, opacity: 1 - exit, transform: `scale(${1 + exit * 0.05})` }}>
        {CHIPS.map((chip, i) => {
          const s = pop(f, I.chips + i * 5, fps, 140, 15);
          if (f < I.chips + i * 5) return null;
          const a = ((chip.a + f * 0.07) * Math.PI) / 180;
          const x = 800 + Math.cos(a) * 660;
          const y = 470 + Math.sin(a) * 390 + Math.sin(f / 30 + i) * 6;
          return (
            <div
              key={chip.label}
              style={{
                position: 'absolute', left: x, top: y, height: 66, padding: '0 28px 0 22px', borderRadius: 33, background: chip.c,
                display: 'flex', alignItems: 'center', gap: 12, color: C.ink, fontSize: 26, fontWeight: 700, letterSpacing: -0.4,
                transform: `translate(-50%, -50%) scale(${s})`, boxShadow: '0 16px 30px rgba(0,0,0,0.25)',
              }}
            >
              <Icon name={chip.icon} size={26} color={C.ink} width={2.2} />
              {chip.label}
            </div>
          );
        })}
        <Img
          src={staticFile('icon-4k.png')}
          style={{ position: 'absolute', left: 725, top: 225, width: 150, height: 150, opacity: Math.min(1, icon * 1.4), transform: `scale(${0.6 + 0.4 * icon}) rotate(${(1 - icon) * -14}deg)` }}
        />
        <div style={{ position: 'absolute', left: 0, right: 0, top: 410, display: 'flex', flexDirection: 'column', alignItems: 'center' }}>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 24 }}>
            <Line f={f} start={I.title} size={124} color="#fff">Meet</Line>
            <Line f={f} start={I.title + 5} size={166} serif color="#fff">Snapper.</Line>
          </div>
          <div style={{ height: 14 }} />
          <Line f={f} start={I.sub} size={34} weight={500} color="rgba(255,255,255,0.7)">
            Capture, annotate and share from your menu bar.
          </Line>
        </div>
      </AbsoluteFill>
    </Iris>
  );
};

// ---------------------------------------------------------------- Chat
const Avatar: React.FC<{ bg: string; text: string; color?: string }> = ({ bg, text, color = '#fff' }) => (
  <div style={{ width: 46, height: 46, borderRadius: 14, background: bg, color, fontWeight: 700, fontSize: 18, display: 'flex', alignItems: 'center', justifyContent: 'center', flex: 'none' }}>
    {text}
  </div>
);

const Message: React.FC<{ f: number; start: number; top: number; who: string; bg: string; initials: string; time: string; children: React.ReactNode }> = ({
  f, start, top, who, bg, initials, time, children,
}) => {
  const { fps } = useVideoConfig();
  const s = pop(f, start, fps, 170, 18);
  if (f < start) return null;
  return (
    <div style={{ position: 'absolute', left: 28, right: 28, top, display: 'flex', gap: 16, opacity: s, transform: `translateY(${(1 - s) * 26}px)` }}>
      <Avatar bg={bg} text={initials} />
      <div style={{ minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
          <div style={{ fontSize: 20, fontWeight: 700, color: C.ink }}>{who}</div>
          <div style={{ fontSize: 15, color: '#8a8ca0' }}>{time}</div>
        </div>
        <div style={{ fontSize: 21, color: '#33354d', marginTop: 4 }}>{children}</div>
      </div>
    </div>
  );
};

export const Chat: React.FC = () => {
  const f = useCurrentFrame();
  const underline = ramp(f, 40, 58);
  const tilt = ramp(f, 4, 40);
  const SHOT = 0.45;
  const M = TL.chat.messages;
  return (
    <Iris f={f} color={C.lilac}>
      <AbsoluteFill style={font}>
        <div style={{ position: 'absolute', left: 120, top: 320 }}>
          <Line f={f} start={14} size={116}>Paste it</Line>
          <div style={{ position: 'relative', display: 'inline-block' }}>
            <Line f={f} start={24} size={170} serif>anywhere.</Line>
            <svg viewBox="0 0 600 40" preserveAspectRatio="none" style={{ position: 'absolute', left: 0, bottom: -6, width: '100%', height: 40, overflow: 'visible' }}>
              <Draw p={underline} width={7} color={C.ink} d="M 6 24 C 160 10, 380 16, 590 12" />
            </svg>
          </div>
        </div>

        <div style={{ position: 'absolute', inset: 0, perspective: 2200 }}>
          <div
            style={{
              position: 'absolute', left: 790, top: 120, width: 690, height: 760, borderRadius: 24, background: '#fff', overflow: 'hidden',
              boxShadow: '0 40px 80px rgba(27,27,77,0.22)',
              transform: `translateY(${(1 - tilt) * 80}px) rotateY(${lerp(-24, -7, tilt)}deg) rotateX(${lerp(10, 2, tilt)}deg)`,
              transformOrigin: '30% 50%',
            }}
          >
            <div style={{ height: 70, borderBottom: '1px solid rgba(27,27,77,0.1)', display: 'flex', alignItems: 'center', padding: '0 28px', gap: 10 }}>
              <div style={{ fontSize: 22, fontWeight: 800, color: C.ink }}># launch-review</div>
              <div style={{ flex: 1 }} />
              <div style={{ display: 'flex' }}>
                {[C.coral, C.sun, C.mint, C.sky].map((c, i) => (
                  <div key={c} style={{ width: 26, height: 26, borderRadius: 13, background: c, border: '3px solid #fff', marginLeft: i ? -8 : 0 }} />
                ))}
              </div>
            </div>
            <div style={{ position: 'relative' }}>
              <Message f={f} start={M[0]} top={26} who="Maya" bg={C.coral} initials="M" time="9:41">
                Which month did best?
              </Message>
              <Message f={f} start={M[1]} top={118} who="You" bg={C.ink} initials="A" time="9:42">
                <div>Here you go</div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6, color: '#2f5bd3', fontWeight: 600, marginTop: 2 }}>
                  <Icon name="link" size={18} color="#2f5bd3" />
                  snapper.link/k7Qm
                </div>
                <div style={{ marginTop: 10, width: 1100 * SHOT, height: 700 * SHOT, borderRadius: 12, overflow: 'hidden', border: '1px solid rgba(27,27,77,0.12)', position: 'relative' }}>
                  <div style={{ transform: `scale(${SHOT})`, transformOrigin: '0 0' }}>
                    <FinalShot />
                  </div>
                </div>
              </Message>
              <Message f={f} start={M[2]} top={600} who="Maya" bg={C.coral} initials="M" time="9:42">
                October. Clear as day, thanks.
              </Message>
            </div>
          </div>
        </div>
      </AbsoluteFill>
    </Iris>
  );
};

// ---------------------------------------------------------------- Record
export const Record: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const R = TL.record;
  const left = 150 + 150 * ramp(f, R.trim[0], R.trim[1] - 4);
  const right = 1450 - 210 * ramp(f, R.trim[0] + 4, R.trim[1]);
  const play = left + (right - left) * interpolate(f, [R.play[0], R.play[1]], [0, 1], clamp);
  const secs = Math.max(0, Math.floor((f - 14) / 15));
  const pill = pop(f, 12, fps);
  const strip = ramp(f, 10, 26);
  return (
    <Iris f={f} color={C.sun}>
      <AbsoluteFill style={font}>
        <div style={{ position: 'absolute', left: 150, top: 160, display: 'flex', alignItems: 'baseline', gap: 40 }}>
          <Line f={f} start={R.words[0] - 4} size={136}>Record.</Line>
          <Line f={f} start={R.words[1] - 4} size={136}>Trim.</Line>
          <Line f={f} start={R.words[2] - 4} size={190} serif>Send.</Line>
        </div>

        <div
          style={{
            position: 'absolute', left: 150, top: 452, height: 54, display: 'flex', alignItems: 'center', gap: 12, padding: '0 22px',
            borderRadius: 27, background: C.ink, color: '#fff', fontSize: 22, fontWeight: 700, fontVariantNumeric: 'tabular-nums',
            transform: `scale(${pill})`, transformOrigin: '0 50%',
          }}
        >
          <div style={{ width: 14, height: 14, borderRadius: 7, background: C.coral, opacity: Math.floor(f / 8) % 2 ? 1 : 0.35 }} />
          REC 00:{String(secs).padStart(2, '0')}
        </div>

        <div style={{ position: 'absolute', left: 150, top: 540, width: 1300, height: 150, display: 'flex', gap: 8, opacity: strip, transform: `translateY(${(1 - strip) * 30}px)` }}>
          {Array.from({ length: 10 }).map((_, i) => (
            <div key={i} style={{ flex: 1, borderRadius: 12, background: [C.white, C.cream][i % 2], position: 'relative', overflow: 'hidden' }}>
              <div style={{ position: 'absolute', left: 12, top: 14, width: '55%', height: 10, borderRadius: 5, background: 'rgba(27,27,77,0.5)' }} />
              <div style={{ position: 'absolute', left: 12, top: 34, width: '35%', height: 10, borderRadius: 5, background: 'rgba(27,27,77,0.2)' }} />
              <div style={{ position: 'absolute', left: 12, right: 12, bottom: 14, height: 56 - (i % 4) * 8, borderRadius: 8, background: [C.sky, C.coral, C.mint, C.lilac][i % 4] }} />
            </div>
          ))}
        </div>
        <div style={{ position: 'absolute', left: 150, top: 540, width: left - 150, height: 150, background: 'rgba(255,201,74,0.72)' }} />
        <div style={{ position: 'absolute', left: right, top: 540, width: 1450 - right, height: 150, background: 'rgba(255,201,74,0.72)' }} />
        <div style={{ position: 'absolute', left: left - 8, top: 530, width: right - left + 16, height: 170, border: `6px solid ${C.ink}`, borderRadius: 16, boxSizing: 'border-box', opacity: strip }} />
        {f >= R.play[0] ? <div style={{ position: 'absolute', left: play - 2, top: 516, width: 4, height: 198, borderRadius: 2, background: C.ink }} /> : null}
      </AbsoluteFill>
    </Iris>
  );
};

// ---------------------------------------------------------------- Outro
const WORD_COLORS = [C.coral, C.sky, C.mint, C.cream];

export const Outro: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const O = TL.outro;
  const words = ['Capture.', 'Annotate.', 'Record.', 'Share.'];
  const brand = pop(f, O.brand, fps, 130, 16);
  const tag = pop(f, O.tagline, fps, 130, 20);
  const fadeOut = ramp(f, O.fade[0], O.fade[1]);
  const idx = O.words.filter((w) => f >= w).length - 1;
  const ending = f >= O.brand;
  const bg = ending ? C.cream : idx >= 0 ? WORD_COLORS[idx] : C.cream;
  return (
    <Iris f={f} color={bg} dur={14}>
      <AbsoluteFill style={font}>
        {!ending && idx >= 0 ? (
          <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center' }}>
            {(() => {
              const s = pop(f, O.words[idx], fps, 260, 20);
              const serif = idx === 3;
              return (
                <div style={{ fontSize: serif ? 280 : 200, fontWeight: 800, letterSpacing: -8, color: C.ink, transform: `scale(${1.15 - 0.15 * s}) translateY(${(1 - s) * 30}px)`, opacity: s, ...(serif ? SERIF : {}) }}>
                  {words[idx]}
                </div>
              );
            })()}
          </AbsoluteFill>
        ) : null}
        {ending ? (
          <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', flexDirection: 'column', opacity: 1 - fadeOut }}>
            <Img src={staticFile('icon.png')} style={{ width: 150, height: 150, transform: `scale(${brand})`, filter: 'drop-shadow(0 14px 24px rgba(27,27,77,0.2))' }} />
            <div style={{ marginTop: 24, fontSize: 124, fontWeight: 800, color: C.ink, letterSpacing: -5, opacity: brand, transform: `translateY(${(1 - brand) * 30}px)` }}>
              Snapper
            </div>
            <div style={{ marginTop: 6, fontSize: 46, fontWeight: 500, color: '#55586f', letterSpacing: -1, opacity: tag, transform: `translateY(${(1 - tag) * 16}px)` }}>
              Screenshots that make the <span style={{ ...SERIF, fontSize: 64, color: C.ink }}>point.</span>
            </div>
          </AbsoluteFill>
        ) : null}
      </AbsoluteFill>
    </Iris>
  );
};
