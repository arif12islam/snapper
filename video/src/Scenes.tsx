import React from 'react';
import { AbsoluteFill, Easing, Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { FinalShot } from './Product';
import { Icon } from './Icons';

export const NAVY = '#1b1b4d';
export const PAPER = '#f4f3ef';
export const RED = '#ff3b30';

const ease = Easing.bezier(0.45, 0, 0.2, 1);
const clamp = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' } as const;
const ramp = (f: number, a: number, b: number) => interpolate(f, [a, b], [0, 1], { ...clamp, easing: ease });
const pop = (f: number, start: number, fps: number, stiffness = 180, damping = 15) =>
  spring({ frame: f - start, fps, config: { damping, stiffness } });

const font: React.CSSProperties = { fontFamily: 'Inter, sans-serif' };

/** A line of type that rises out of a mask. */
const Line: React.FC<{ f: number; start: number; size: number; color?: string; weight?: number; children: React.ReactNode; style?: React.CSSProperties }> = ({
  f, start, size, color = NAVY, weight = 800, children, style,
}) => {
  const { fps } = useVideoConfig();
  const s = pop(f, start, fps, 200, 20);
  return (
    <div style={{ overflow: 'hidden', paddingBottom: size * 0.12, marginBottom: -size * 0.12, ...style }}>
      <div
        style={{
          fontSize: size, fontWeight: weight, color, letterSpacing: -size * 0.04, lineHeight: 1.02,
          transform: `translateY(${(1 - s) * 110}%)`, whiteSpace: 'nowrap',
        }}
      >
        {children}
      </div>
    </div>
  );
};

/** A stroke that draws itself, like a marker on the screen. */
const Draw: React.FC<{ d: string; p: number; width?: number; color?: string }> = ({ d, p, width = 9, color = RED }) => (
  <path d={d} fill="none" stroke={color} strokeWidth={width} strokeLinecap="round" strokeLinejoin="round" pathLength={1} strokeDasharray={1} strokeDashoffset={1 - p} />
);

const Counter: React.FC<{ n: number; x: number; y: number; s: number; size?: number }> = ({ n, x, y, s, size = 56 }) => (
  <div
    style={{
      position: 'absolute', left: x - size / 2, top: y - size / 2, width: size, height: size, borderRadius: size / 2, background: RED,
      border: '4px solid #fff', boxSizing: 'border-box', color: '#fff', fontSize: size * 0.48, fontWeight: 800,
      display: 'flex', alignItems: 'center', justifyContent: 'center', transform: `scale(${s})`, boxShadow: '0 6px 14px rgba(0,0,0,0.18)',
    }}
  >
    {n}
  </div>
);

// ---------------------------------------------------------------- Hook (0 to 140)
export const Hook: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const circle = ramp(f, 56, 72);
  const arrow = ramp(f, 70, 86);
  const head = ramp(f, 84, 90);
  return (
    <AbsoluteFill style={{ ...font, background: PAPER }}>
      <div style={{ position: 'absolute', left: 150, top: 230 }}>
        <Line f={f} start={9} size={150}>A screenshot</Line>
        <Line f={f} start={24} size={150}>rarely explains</Line>
        <Line f={f} start={39} size={150}>itself.</Line>
      </div>
      <svg width={1600} height={1000} style={{ position: 'absolute', inset: 0 }}>
        {/* Loose marker circle around "itself." */}
        <Draw p={circle} d="M 560 600 C 600 520, 380 500, 250 515 C 120 532, 110 640, 200 680 C 320 730, 560 712, 600 650 C 625 610, 585 560, 520 545" />
        {/* Arrow sweeping in toward it */}
        <Draw p={arrow} d="M 1330 860 C 1150 900, 860 860, 640 680" />
        <Draw p={head} d="M 668 742 L 636 676 L 708 680" />
      </svg>
      <Counter n={1} x={612} y={590} s={pop(f, 92, fps)} />
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------- Intro (120 to 240)
export const Intro: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const panel = ramp(f, 0, 14);
  const exit = ramp(f, 100, 116);
  const icon = pop(f, 16, fps, 150, 12);
  return (
    <AbsoluteFill style={{ ...font, background: NAVY, transform: `translateY(${(1 - panel) * 100}%)` }}>
      <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', flexDirection: 'column', opacity: 1 - exit, transform: `translateY(${-exit * 60}px)` }}>
        <Img src={staticFile('icon.png')} style={{ width: 170, height: 170, transform: `scale(${icon}) rotate(${(1 - icon) * -20}deg)` }} />
        <div style={{ height: 30 }} />
        <Line f={f} start={24} size={150} color="#fff">Meet Snapper.</Line>
        <div style={{ height: 22 }} />
        <Line f={f} start={40} size={42} weight={500} color="rgba(255,255,255,0.72)">
          Capture, annotate and share, right from your menu bar.
        </Line>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------- Chat (625 to 765)
const Avatar: React.FC<{ bg: string; text: string }> = ({ bg, text }) => (
  <div style={{ width: 46, height: 46, borderRadius: 12, background: bg, color: '#fff', fontWeight: 700, fontSize: 18, display: 'flex', alignItems: 'center', justifyContent: 'center', flex: 'none' }}>
    {text}
  </div>
);

const Message: React.FC<{ f: number; start: number; top: number; who: string; bg: string; initials: string; time: string; children: React.ReactNode }> = ({
  f, start, top, who, bg, initials, time, children,
}) => {
  const { fps } = useVideoConfig();
  const s = pop(f, start, fps, 190, 18);
  if (f < start) return null;
  return (
    <div style={{ position: 'absolute', left: 28, right: 28, top, display: 'flex', gap: 16, opacity: s, transform: `translateY(${(1 - s) * 30}px)` }}>
      <Avatar bg={bg} text={initials} />
      <div style={{ minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
          <div style={{ fontSize: 20, fontWeight: 700, color: NAVY }}>{who}</div>
          <div style={{ fontSize: 15, color: '#8a8ca0' }}>{time}</div>
        </div>
        <div style={{ fontSize: 21, color: '#33354d', marginTop: 4 }}>{children}</div>
      </div>
    </div>
  );
};

export const Chat: React.FC = () => {
  const f = useCurrentFrame();
  const panel = ramp(f, 0, 14);
  const underline = ramp(f, 40, 56);
  const SHOT = 0.45;
  return (
    <AbsoluteFill style={{ ...font, background: PAPER, transform: `translateX(${(1 - panel) * 100}%)` }}>
      <div style={{ position: 'absolute', left: 120, top: 330 }}>
        <Line f={f} start={14} size={124}>Paste it</Line>
        <Line f={f} start={26} size={124}>anywhere.</Line>
      </div>
      <svg width={760} height={1000} style={{ position: 'absolute', left: 0, top: 0 }}>
        <Draw p={underline} width={10} d="M 128 612 C 260 596, 420 600, 640 590" />
      </svg>

      <div
        style={{
          position: 'absolute', left: 780, top: 120, width: 700, height: 760, borderRadius: 20, background: '#fff',
          border: '1px solid rgba(27,27,77,0.12)', boxShadow: '0 30px 60px rgba(27,27,77,0.12)', overflow: 'hidden',
          transform: `translateY(${(1 - ramp(f, 4, 22)) * 40}px)`,
        }}
      >
        <div style={{ height: 70, borderBottom: '1px solid rgba(27,27,77,0.1)', display: 'flex', alignItems: 'center', padding: '0 28px', gap: 10 }}>
          <div style={{ fontSize: 22, fontWeight: 800, color: NAVY }}># launch-review</div>
          <div style={{ flex: 1 }} />
          <div style={{ fontSize: 16, color: '#8a8ca0' }}>4 members</div>
        </div>
        <div style={{ position: 'relative' }}>
          <Message f={f} start={18} top={26} who="Maya" bg={RED} initials="M" time="9:41">
            Which month did best?
          </Message>
          <Message f={f} start={40} top={118} who="You" bg={NAVY} initials="A" time="9:42">
            <div>Here you go</div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 6, color: '#2f5bd3', fontWeight: 600, marginTop: 2 }}>
              <Icon name="link" size={18} color="#2f5bd3" />
              snapper.link/k7Qm
            </div>
            <div
              style={{
                marginTop: 10, width: 1100 * SHOT, height: 700 * SHOT, borderRadius: 10, overflow: 'hidden',
                border: '1px solid rgba(27,27,77,0.14)', position: 'relative',
              }}
            >
              <div style={{ transform: `scale(${SHOT})`, transformOrigin: '0 0' }}>
                <FinalShot />
              </div>
            </div>
          </Message>
          <Message f={f} start={88} top={600} who="Maya" bg={RED} initials="M" time="9:42">
            October. Clear as day, thanks.
          </Message>
        </div>
      </div>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------- Record (750 to 850)
export const Record: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const panel = ramp(f, 0, 12);
  const left = 150 + 150 * ramp(f, 50, 64);
  const right = 1450 - 210 * ramp(f, 54, 68);
  const play = left + (right - left) * interpolate(f, [66, 99], [0, 1], clamp);
  const secs = Math.max(0, Math.floor((f - 14) / 15));
  const pill = pop(f, 12, fps);
  return (
    <AbsoluteFill style={{ ...font, background: NAVY, transform: `translateY(${(1 - panel) * 100}%)` }}>
      <div style={{ position: 'absolute', left: 150, top: 170, display: 'flex', gap: 44 }}>
        <Line f={f} start={14} size={140} color="#fff">Record.</Line>
        <Line f={f} start={29} size={140} color="#fff">Trim.</Line>
        <Line f={f} start={44} size={140} color={RED}>Send.</Line>
      </div>

      <div
        style={{
          position: 'absolute', left: 150, top: 450, height: 54, display: 'flex', alignItems: 'center', gap: 12, padding: '0 22px',
          borderRadius: 27, background: '#fff', color: NAVY, fontSize: 22, fontWeight: 700, fontVariantNumeric: 'tabular-nums',
          transform: `scale(${pill})`, transformOrigin: '0 50%',
        }}
      >
        <div style={{ width: 16, height: 16, borderRadius: 8, background: RED, opacity: Math.floor(f / 8) % 2 ? 1 : 0.35 }} />
        REC 00:{String(secs).padStart(2, '0')}
      </div>

      {/* Filmstrip with trim handles */}
      <div style={{ position: 'absolute', left: 150, top: 540, width: 1300, height: 150, display: 'flex', gap: 6, opacity: ramp(f, 10, 22) }}>
        {Array.from({ length: 10 }).map((_, i) => (
          <div key={i} style={{ flex: 1, borderRadius: 8, background: '#2b2b66', position: 'relative', overflow: 'hidden' }}>
            <div style={{ position: 'absolute', left: 12, top: 14, width: '55%', height: 10, borderRadius: 5, background: 'rgba(255,255,255,0.5)' }} />
            <div style={{ position: 'absolute', left: 12, top: 34, width: '35%', height: 10, borderRadius: 5, background: 'rgba(255,255,255,0.25)' }} />
            <div style={{ position: 'absolute', left: 12, right: 12, bottom: 14, height: 56 - (i % 4) * 8, borderRadius: 6, background: i === 6 ? RED : 'rgba(255,255,255,0.14)' }} />
          </div>
        ))}
      </div>
      <div style={{ position: 'absolute', left: 150, top: 540, width: left - 150, height: 150, background: 'rgba(10,10,30,0.65)' }} />
      <div style={{ position: 'absolute', left: right, top: 540, width: 1450 - right, height: 150, background: 'rgba(10,10,30,0.65)' }} />
      <div style={{ position: 'absolute', left: left - 8, top: 530, width: right - left + 16, height: 170, border: '6px solid #fff', borderRadius: 12, boxSizing: 'border-box', opacity: ramp(f, 10, 22) }} />
      {f >= 66 ? <div style={{ position: 'absolute', left: play - 2, top: 518, width: 4, height: 194, borderRadius: 2, background: RED }} /> : null}
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------- Outro (840 to 960)
export const Outro: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const panel = ramp(f, 0, 12);
  const words = ['Capture.', 'Annotate.', 'Record.', 'Share.'];
  const starts = [15, 30, 45, 60];
  const brand = pop(f, 75, fps, 150, 13);
  const fadeOut = ramp(f, 108, 119);
  return (
    <AbsoluteFill style={{ ...font, background: PAPER, transform: `translateY(${(1 - panel) * 100}%)` }}>
      {words.map((w, i) => {
        const s = pop(f, starts[i], fps, 260, 18);
        const gone = i < 3 ? f >= starts[i + 1] : f >= 75;
        if (f < starts[i] || gone) return null;
        return (
          <AbsoluteFill key={w} style={{ alignItems: 'center', justifyContent: 'center' }}>
            <div style={{ fontSize: 210, fontWeight: 800, letterSpacing: -9, color: i === 3 ? RED : NAVY, transform: `scale(${1.25 - 0.25 * s})`, opacity: s }}>
              {w}
            </div>
          </AbsoluteFill>
        );
      })}
      {f >= 75 ? (
        <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', flexDirection: 'column', opacity: 1 - fadeOut }}>
          <Img src={staticFile('icon.png')} style={{ width: 170, height: 170, transform: `scale(${brand})` }} />
          <div style={{ marginTop: 26, fontSize: 120, fontWeight: 800, color: NAVY, letterSpacing: -5, opacity: brand, transform: `translateY(${(1 - brand) * 30}px)` }}>
            Snapper
          </div>
          <div
            style={{
              marginTop: 22, padding: '12px 24px', borderRadius: 999, background: NAVY, color: '#fff', fontSize: 22, fontWeight: 600,
              opacity: pop(f, 88, fps), transform: `scale(${0.9 + 0.1 * pop(f, 88, fps)})`,
            }}
          >
            Invite only. For macOS 14 and later
          </div>
        </AbsoluteFill>
      ) : null}
    </AbsoluteFill>
  );
};
