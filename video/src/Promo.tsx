import React from 'react';
import { AbsoluteFill, Easing, Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { APP_H, APP_W, BEST, FakeApp, barRect, emailCell } from './FakeApp';
import { Icon } from './Icons';

// ---------- Timeline (frames at 30 fps) ----------
const T = {
  selStart: 14, selEnd: 52, flash: 54, flyStart: 58, flyEnd: 88,
  rectStart: 100, rectEnd: 122, c1: 126,
  arrowStart: 140, arrowEnd: 160,
  textStart: 168, textEnd: 198, c2: 204,
  blurStart: 214, blurEnd: 234,
  magStart: 248, magEnd: 282,
  bgClick: 306, bgEnd: 346,
  copyClick: 366, toastIn: 370, toastOut: 428,
  outStart: 432, outEnd: 458,
  endIn: 448,
};
export const DURATION = 540;

// ---------- Layout ----------
const EX = 50, EY = 40, EW = 1500, EH = 920;
const CX = 800, CY = 525;
const S1 = Math.min(1420 / APP_W, 690 / APP_H) * 0.96;
const PAD = 60;
const S2 = Math.min(1420 / (APP_W + PAD * 2), 690 / (APP_H + PAD * 2)) * 0.96;
const toScreen = (x: number, y: number, s = S1): [number, number] => [CX + (x - APP_W / 2) * s, CY + (y - APP_H / 2) * s];

const RED = '#ff3b30';
const ease = Easing.bezier(0.45, 0, 0.2, 1);
const clamp = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' } as const;
const ramp = (f: number, a: number, b: number) => interpolate(f, [a, b], [0, 1], { ...clamp, easing: ease });

// Annotation geometry, in app coordinates.
const RECT = { x0: 222, y0: 128, x1: 512, y1: 254 };
const best = barRect(BEST);
const ARROW = { x0: 690, y0: 312, x1: best.x - 4, y1: best.y + 4 };
const LABEL = { x: 470, y: 292, text: 'Best month yet' };
const BLUR = emailCell(1);
const MAG = { tx: 409, ty: 199, lx: 660, ly: 104, r: 72, zoom: 2.6 };

// ---------- Backgrounds ----------
const Wallpaper: React.FC<{ style?: React.CSSProperties }> = ({ style }) => (
  <div
    style={{
      position: 'absolute', inset: 0,
      background:
        'radial-gradient(60% 70% at 18% 20%, #4b3aa8 0%, rgba(75,58,168,0) 60%),' +
        'radial-gradient(55% 60% at 85% 85%, #f07a52 0%, rgba(240,122,82,0) 60%),' +
        'radial-gradient(50% 50% at 75% 15%, #b04f9a 0%, rgba(176,79,154,0) 60%),' +
        'linear-gradient(160deg, #13133a 0%, #1b1b4d 45%, #3a1f4f 100%)',
      ...style,
    }}
  />
);

const FRAME_BG = 'linear-gradient(135deg, #3b2f7a 0%, #8c5aa8 38%, #ef8a63 72%, #f7c37a 100%)';

// ---------- Cursor ----------
type Key = [number, number, number];
const path = (f: number, keys: Key[]): [number, number] => {
  if (f <= keys[0][0]) return [keys[0][1], keys[0][2]];
  for (let i = 1; i < keys.length; i++) {
    const [f1, x1, y1] = keys[i];
    const [f0, x0, y0] = keys[i - 1];
    if (f <= f1) {
      const t = interpolate(f, [f0, f1], [0, 1], { ...clamp, easing: ease });
      return [x0 + (x1 - x0) * t, y0 + (y1 - y0) * t];
    }
  }
  const last = keys[keys.length - 1];
  return [last[1], last[2]];
};

const BG_BTN: [number, number] = [1263, 72];
const COPY_BTN: [number, number] = [1388, 72];

const pointerKeys: Key[] = [
  [T.flyEnd, ...toScreen(620, 560)],
  [T.rectStart, ...toScreen(RECT.x0, RECT.y0)],
  [T.rectEnd, ...toScreen(RECT.x1, RECT.y1)],
  [T.arrowStart - 4, ...toScreen(ARROW.x0, ARROW.y0)],
  [T.arrowStart, ...toScreen(ARROW.x0, ARROW.y0)],
  [T.arrowEnd, ...toScreen(ARROW.x1, ARROW.y1)],
  [T.textStart, ...toScreen(LABEL.x + 20, LABEL.y + 20)],
  [T.blurStart - 4, ...toScreen(BLUR.x, BLUR.y)],
  [T.blurStart, ...toScreen(BLUR.x, BLUR.y)],
  [T.blurEnd, ...toScreen(BLUR.x + BLUR.w, BLUR.y + BLUR.h)],
  [T.magStart - 4, ...toScreen(MAG.tx, MAG.ty)],
  [T.magStart, ...toScreen(MAG.tx, MAG.ty)],
  [T.magEnd, ...toScreen(MAG.lx, MAG.ly)],
  [T.bgClick - 2, ...BG_BTN],
  [T.bgClick + 16, BG_BTN[0] - 20, BG_BTN[1] + 50],
  [T.copyClick - 2, ...COPY_BTN],
  [T.outStart, COPY_BTN[0] + 30, COPY_BTN[1] + 120],
];

const crossKeys: Key[] = [
  [0, 640, 420],
  [T.selStart, 250, 150],
  [T.selEnd, 1350, 850],
];

const clickPulse = (f: number, at: number) => {
  const d = f - at;
  return d >= 0 && d < 8 ? Math.sin((d / 8) * Math.PI) : 0;
};

const Pointer: React.FC<{ x: number; y: number; press: number }> = ({ x, y, press }) => (
  <div style={{ position: 'absolute', left: x - 4, top: y - 2, transform: `scale(${1 - press * 0.15})`, transformOrigin: '4px 2px' }}>
    <svg width="30" height="36" viewBox="0 0 30 36" style={{ filter: 'drop-shadow(0 3px 4px rgba(0,0,0,0.35))' }}>
      <path d="M4 2l20 18-9 1.5 5.5 10.5-4 2-5.5-10.6L4 29z" fill="#111" stroke="#fff" strokeWidth="2" strokeLinejoin="round" />
    </svg>
  </div>
);

const Crosshair: React.FC<{ x: number; y: number; label?: string }> = ({ x, y, label }) => (
  <>
    <svg style={{ position: 'absolute', left: x - 16, top: y - 16 }} width="32" height="32" viewBox="0 0 32 32">
      <path d="M16 2v11M16 19v11M2 16h11M19 16h11" stroke="#000" strokeWidth="4" strokeLinecap="round" />
      <path d="M16 2v11M16 19v11M2 16h11M19 16h11" stroke="#fff" strokeWidth="2" strokeLinecap="round" />
    </svg>
    {label ? (
      <div
        style={{
          position: 'absolute', left: x + 16, top: y + 16, padding: '5px 9px', borderRadius: 7,
          background: 'rgba(20,20,30,0.85)', color: '#fff', fontSize: 15, fontWeight: 600, fontVariantNumeric: 'tabular-nums',
        }}
      >
        {label}
      </div>
    ) : null}
  </>
);

// ---------- Desktop ----------
const MenuBar: React.FC = () => (
  <div
    style={{
      position: 'absolute', left: 0, top: 0, right: 0, height: 30, display: 'flex', alignItems: 'center',
      padding: '0 18px', gap: 22, color: '#fff', fontSize: 14, fontWeight: 500,
      background: 'rgba(15,15,40,0.35)', backdropFilter: 'blur(20px)',
    }}
  >
    <div style={{ fontWeight: 700 }}>Orbit</div>
    <div>File</div>
    <div>Edit</div>
    <div>View</div>
    <div>Window</div>
    <div style={{ flex: 1 }} />
    <div style={{ width: 18, height: 18, borderRadius: 5, background: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div style={{ width: 8, height: 8, borderRadius: 4, background: '#1b1b4d' }} />
    </div>
    <div>Fri 9:41</div>
  </div>
);

// ---------- Editor chrome ----------
type ToolName =
  | 'select' | 'crop' | 'arrow' | 'line' | 'rect' | 'pen' | 'marker'
  | 'text' | 'counter' | 'magnifier' | 'spotlight' | 'blur' | 'drop';
const TOOL_GROUPS: ToolName[][] = [
  ['select', 'crop'],
  ['arrow', 'line', 'rect', 'pen', 'marker'],
  ['text', 'counter', 'magnifier'],
  ['spotlight', 'blur', 'drop'],
];

const activeTool = (f: number): ToolName => {
  if (f < T.rectStart - 6) return 'select';
  if (f < T.c1 - 2) return 'rect';
  if (f < T.arrowStart - 4) return 'counter';
  if (f < T.textStart - 2) return 'arrow';
  if (f < T.c2 - 2) return 'text';
  if (f < T.blurStart - 4) return 'counter';
  if (f < T.magStart - 4) return 'blur';
  if (f < T.bgClick - 10) return 'magnifier';
  return 'select';
};

const Toolbar: React.FC<{ f: number }> = ({ f }) => {
  const active = activeTool(f);
  const bgPress = clickPulse(f, T.bgClick);
  const copyPress = clickPulse(f, T.copyClick);
  const btn = (x: number, w: number, press: number, children: React.ReactNode) => (
    <div
      style={{
        position: 'absolute', left: x - EX, top: 14, width: w, height: 36, borderRadius: 9,
        border: '1px solid rgba(0,0,0,0.1)', background: press ? '#e6e6ec' : '#fff', display: 'flex', alignItems: 'center',
        justifyContent: 'center', gap: 8, fontSize: 17, fontWeight: 500, color: '#2a2a33', boxShadow: '0 1px 1px rgba(0,0,0,0.04)',
        transform: `scale(${1 - press * 0.05})`,
      }}
    >
      {children}
    </div>
  );
  return (
    <div style={{ position: 'absolute', left: 0, top: 0, width: EW, height: 64, background: '#f7f7f9', borderBottom: '1px solid rgba(0,0,0,0.08)' }}>
      {['#ff5f57', '#febc2e', '#28c840'].map((c, i) => (
        <div key={c} style={{ position: 'absolute', left: 20 + i * 22, top: 26, width: 13, height: 13, borderRadius: 7, background: c }} />
      ))}
      <div style={{ position: 'absolute', left: 104, top: 20, display: 'flex', gap: 10, color: '#9a9aa6' }}>
        <Icon name="undo" size={22} />
        <Icon name="redo" size={22} />
      </div>
      <div style={{ position: 'absolute', left: 190, top: 13, display: 'flex', gap: 18 }}>
        {TOOL_GROUPS.map((g, gi) => (
          <div key={gi} style={{ display: 'flex', gap: 4 }}>
            {g.map((t) => (
              <div
                key={t}
                style={{
                  width: 40, height: 38, borderRadius: 9, display: 'flex', alignItems: 'center', justifyContent: 'center',
                  background: t === active ? 'rgba(0,0,0,0.09)' : 'transparent', color: '#3a3a44',
                }}
              >
                <Icon name={t} size={22} />
              </div>
            ))}
          </div>
        ))}
      </div>
      {btn(1188, 150, bgPress, (
        <>
          <div style={{ width: 26, height: 18, borderRadius: 5, background: FRAME_BG }} />
          Background
        </>
      ))}
      {btn(1348, 80, copyPress, 'Copy')}
      {btn(1438, 96, 0, (
        <>
          Save <Icon name="chevron" size={16} />
        </>
      ))}
    </div>
  );
};

const StyleBar: React.FC = () => (
  <div
    style={{
      position: 'absolute', left: EW / 2 - 400, top: 80, width: 800, height: 48, borderRadius: 24,
      background: 'rgba(250,250,252,0.94)', border: '1px solid rgba(0,0,0,0.08)', boxShadow: '0 6px 20px rgba(0,0,0,0.12)',
      display: 'flex', alignItems: 'center', gap: 14, padding: '0 20px', boxSizing: 'border-box',
    }}
  >
    <div style={{ width: 54, height: 28, borderRadius: 7, background: RED, border: '1px solid rgba(0,0,0,0.1)' }} />
    {['#ff9500', '#ffcc00', '#34c759', '#0a84ff', '#af52de', '#111111', '#ffffff', RED].map((c, i) => (
      <div key={i} style={{ width: 20, height: 20, borderRadius: 10, background: c, border: '1px solid rgba(0,0,0,0.15)' }} />
    ))}
    <div style={{ marginLeft: 10, fontSize: 16, color: '#6a6a76' }}>Stroke</div>
    <div style={{ position: 'relative', width: 150, height: 4, borderRadius: 2, background: '#d8d8e0' }}>
      <div style={{ position: 'absolute', left: 0, top: 0, width: 88, height: 4, borderRadius: 2, background: '#0a84ff' }} />
      <div style={{ position: 'absolute', left: 78, top: -9, width: 22, height: 22, borderRadius: 11, background: '#fff', boxShadow: '0 1px 4px rgba(0,0,0,0.3)' }} />
    </div>
    <div style={{ flex: 1 }} />
    <div style={{ display: 'flex', gap: 2, padding: 3, borderRadius: 8, background: '#ececf1' }}>
      {['arrow', 'line', 'expand'].map((n, i) => (
        <div key={n} style={{ width: 40, height: 26, borderRadius: 6, display: 'flex', alignItems: 'center', justifyContent: 'center', background: i === 0 ? '#fff' : 'transparent' }}>
          <Icon name={n} size={16} color="#33333d" />
        </div>
      ))}
    </div>
  </div>
);

const BottomBar: React.FC<{ zoom: number }> = ({ zoom }) => (
  <div
    style={{
      position: 'absolute', left: EW / 2 - 320, top: EH - 70, width: 640, height: 50, borderRadius: 25,
      background: 'rgba(250,250,252,0.94)', border: '1px solid rgba(0,0,0,0.08)', boxShadow: '0 6px 20px rgba(0,0,0,0.12)',
      display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 22, color: '#4a4a55',
    }}
  >
    {['trash', 'rotate', 'flip', 'expand', 'image'].map((n) => (
      <Icon key={n} name={n} size={21} />
    ))}
    <div style={{ width: 1, height: 22, background: 'rgba(0,0,0,0.1)' }} />
    <Icon name="zoomOut" size={21} />
    <div style={{ width: 52, textAlign: 'center', fontSize: 16, fontVariantNumeric: 'tabular-nums' }}>{zoom}%</div>
    <Icon name="zoomIn" size={21} />
  </div>
);

// ---------- Annotations ----------
const Annotations: React.FC<{ f: number; fps: number }> = ({ f, fps }) => {
  const rectP = ramp(f, T.rectStart, T.rectEnd);
  const arrowP = ramp(f, T.arrowStart, T.arrowEnd);
  const c1 = spring({ frame: f - T.c1, fps, config: { damping: 12, stiffness: 180 } });
  const c2 = spring({ frame: f - T.c2, fps, config: { damping: 12, stiffness: 180 } });
  const typed = Math.floor(interpolate(f, [T.textStart, T.textEnd], [0, LABEL.text.length], clamp));
  const labelIn = spring({ frame: f - T.textStart, fps, config: { damping: 16, stiffness: 220 } });
  const blurDrag = ramp(f, T.blurStart, T.blurEnd);
  const blurDone = f >= T.blurEnd;
  const magTarget = spring({ frame: f - T.magStart, fps, config: { damping: 14, stiffness: 200 } });
  const magMove = ramp(f, T.magStart, T.magEnd);

  const rx1 = RECT.x0 + (RECT.x1 - RECT.x0) * rectP;
  const ry1 = RECT.y0 + (RECT.y1 - RECT.y0) * rectP;
  const ax1 = ARROW.x0 + (ARROW.x1 - ARROW.x0) * arrowP;
  const ay1 = ARROW.y0 + (ARROW.y1 - ARROW.y0) * arrowP;
  const ang = Math.atan2(ARROW.y1 - ARROW.y0, ARROW.x1 - ARROW.x0);
  const head = 26;
  const hx = (a: number) => ax1 - head * Math.cos(ang + a);
  const hy = (a: number) => ay1 - head * Math.sin(ang + a);

  // Magnifier: loupe slides from the target to its resting place.
  const lx = MAG.tx + (MAG.lx - MAG.tx) * magMove;
  const ly = MAG.ty + (MAG.ly - MAG.ty) * magMove;
  const tr = 26;
  const dx = lx - MAG.tx, dy = ly - MAG.ty;
  const dist = Math.hypot(dx, dy) || 1;
  const ux = dx / dist, uy = dy / dist;
  const showLine = dist > MAG.r + tr + 4;

  const shadow = 'drop-shadow(0 2px 3px rgba(0,0,0,0.25))';

  return (
    <>
      <svg width={APP_W} height={APP_H} viewBox={`0 0 ${APP_W} ${APP_H}`} style={{ position: 'absolute', left: 0, top: 0, overflow: 'visible', filter: shadow }}>
        {f >= T.rectStart ? (
          <rect x={RECT.x0} y={RECT.y0} width={rx1 - RECT.x0} height={ry1 - RECT.y0} rx={8} fill="none" stroke={RED} strokeWidth={6} />
        ) : null}
        {f >= T.arrowStart ? (
          <>
            <line x1={ARROW.x0} y1={ARROW.y0} x2={ax1 - 14 * Math.cos(ang)} y2={ay1 - 14 * Math.sin(ang)} stroke={RED} strokeWidth={7} strokeLinecap="round" />
            {arrowP > 0.15 ? <polygon points={`${ax1},${ay1} ${hx(0.42)},${hy(0.42)} ${hx(-0.42)},${hy(-0.42)}`} fill={RED} stroke={RED} strokeWidth={3} strokeLinejoin="round" /> : null}
          </>
        ) : null}
        {f >= T.blurStart && !blurDone ? (
          <rect
            x={BLUR.x} y={BLUR.y} width={BLUR.w * blurDrag} height={BLUR.h * Math.min(1, blurDrag * 1.6)}
            fill="rgba(10,132,255,0.08)" stroke="#0a84ff" strokeWidth={2} strokeDasharray="6 5"
          />
        ) : null}
        {f >= T.magStart ? (
          <g opacity={Math.min(1, magTarget * 1.2)}>
            <circle cx={MAG.tx} cy={MAG.ty} r={tr * magTarget} fill="none" stroke={RED} strokeWidth={4} />
            {showLine ? (
              <line x1={MAG.tx + ux * tr} y1={MAG.ty + uy * tr} x2={lx - ux * (MAG.r + 3)} y2={ly - uy * (MAG.r + 3)} stroke={RED} strokeWidth={4} strokeLinecap="round" />
            ) : null}
          </g>
        ) : null}
      </svg>

      {/* Loupe */}
      {f >= T.magStart + 2 ? (
        <div
          style={{
            position: 'absolute', left: lx - MAG.r, top: ly - MAG.r, width: MAG.r * 2, height: MAG.r * 2, borderRadius: '50%',
            overflow: 'hidden', border: `5px solid ${RED}`, boxSizing: 'border-box', background: '#fff',
            boxShadow: '0 10px 24px rgba(0,0,0,0.3)', transform: `scale(${Math.min(1, magTarget)})`,
          }}
        >
          <div style={{ position: 'absolute', left: MAG.r - 5 - MAG.tx * MAG.zoom, top: MAG.r - 5 - MAG.ty * MAG.zoom, transform: `scale(${MAG.zoom})`, transformOrigin: '0 0' }}>
            <FakeApp />
          </div>
        </div>
      ) : null}

      {/* Text callout */}
      {f >= T.textStart ? (
        <div
          style={{
            position: 'absolute', left: LABEL.x, top: LABEL.y, height: 40, padding: '0 16px 0 22px', borderRadius: 10,
            background: RED, color: '#fff', fontSize: 21, fontWeight: 700, display: 'flex', alignItems: 'center', whiteSpace: 'nowrap',
            boxShadow: '0 4px 10px rgba(0,0,0,0.2)', transform: `scale(${0.6 + 0.4 * labelIn})`, transformOrigin: '0 50%', opacity: labelIn,
          }}
        >
          {LABEL.text.slice(0, typed)}
          {f < T.textEnd + 6 ? <span style={{ width: 2, height: 22, marginLeft: 2, background: '#fff', opacity: Math.floor(f / 6) % 2 ? 1 : 0.2 }} /> : null}
        </div>
      ) : null}

      {/* Counters */}
      {[
        { n: 1, x: RECT.x0, y: RECT.y0, s: c1, at: T.c1 },
        { n: 2, x: LABEL.x - 2, y: LABEL.y + 20, s: c2, at: T.c2 },
      ].map((c) =>
        f >= c.at ? (
          <div
            key={c.n}
            style={{
              position: 'absolute', left: c.x - 19, top: c.y - 19, width: 38, height: 38, borderRadius: 19, background: RED,
              border: '3px solid #fff', boxSizing: 'border-box', color: '#fff', fontSize: 19, fontWeight: 800,
              display: 'flex', alignItems: 'center', justifyContent: 'center', transform: `scale(${c.s})`, boxShadow: '0 3px 8px rgba(0,0,0,0.3)',
            }}
          >
            {c.n}
          </div>
        ) : null,
      )}
    </>
  );
};

// ---------- End card ----------
const EndCard: React.FC<{ f: number; fps: number }> = ({ f, fps }) => {
  const d = f - T.endIn;
  const icon = spring({ frame: d, fps, config: { damping: 13, stiffness: 140 } });
  const title = spring({ frame: d - 8, fps, config: { damping: 18, stiffness: 160 } });
  const words = ['Capture.', 'Annotate.', 'Record.', 'Share.'];
  const pill = spring({ frame: d - 40, fps, config: { damping: 18, stiffness: 160 } });
  return (
    <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', flexDirection: 'column' }}>
      <Img
        src={staticFile('icon.png')}
        style={{ width: 190, height: 190, transform: `scale(${icon}) rotate(${(1 - icon) * -12}deg)`, filter: 'drop-shadow(0 24px 40px rgba(0,0,0,0.45))' }}
      />
      <div style={{ marginTop: 26, fontSize: 112, fontWeight: 800, color: '#fff', letterSpacing: -4, opacity: title, transform: `translateY(${(1 - title) * 30}px)` }}>
        Snapper
      </div>
      <div style={{ display: 'flex', gap: 18, marginTop: 6 }}>
        {words.map((w, i) => {
          const s = spring({ frame: d - 18 - i * 5, fps, config: { damping: 18, stiffness: 170 } });
          return (
            <div key={w} style={{ fontSize: 38, fontWeight: 600, color: 'rgba(255,255,255,0.86)', opacity: s, transform: `translateY(${(1 - s) * 24}px)` }}>
              {w}
            </div>
          );
        })}
      </div>
      <div
        style={{
          marginTop: 38, padding: '10px 22px', borderRadius: 999, border: '1px solid rgba(255,255,255,0.3)', background: 'rgba(255,255,255,0.08)',
          color: '#fff', fontSize: 20, fontWeight: 600, letterSpacing: 0.3, opacity: pill, transform: `scale(${0.9 + 0.1 * pill})`,
        }}
      >
        Invite only. For macOS 14 and later
      </div>
    </AbsoluteFill>
  );
};

// ---------- Composition ----------
export const Promo: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();

  const fly = ramp(f, T.flyStart, T.flyEnd);
  const bg = spring({ frame: f - T.bgClick - 2, fps, config: { damping: 20, stiffness: 120 } });
  const out = ramp(f, T.outStart, T.outEnd);
  const flash = interpolate(f, [T.flash - 2, T.flash, T.flash + 8], [0, 0.7, 0], clamp);

  // Captured image: flies from its place on the desktop into the editor, then shrinks as the background frame grows.
  const sEditor = S1 + (S2 - S1) * bg;
  const s = 1 + (sEditor - 1) * fly;
  const cy = 500 + (CY - 500) * fly;
  const imgL = CX - (APP_W * s) / 2;
  const imgT = cy - (APP_H * s) / 2;
  const pad = PAD * bg * s;

  const sel = ramp(f, T.selStart, T.selEnd);
  const [cxh, cyh] = path(f, crossKeys);
  const selecting = f >= T.selStart && f < T.flash;
  const selW = Math.round(1100 * sel), selH = Math.round(700 * sel);

  const [px, py] = path(f, pointerKeys);
  const press = Math.max(
    clickPulse(f, T.rectStart), clickPulse(f, T.arrowStart), clickPulse(f, T.c1), clickPulse(f, T.textStart),
    clickPulse(f, T.c2), clickPulse(f, T.blurStart), clickPulse(f, T.magStart), clickPulse(f, T.bgClick), clickPulse(f, T.copyClick),
  );

  const toast = spring({ frame: f - T.toastIn, fps, config: { damping: 16, stiffness: 180 } }) - ramp(f, T.toastOut, T.toastOut + 8);

  const editorOpacity = fly * (1 - out);
  const sceneScale = 1 - out * 0.08;
  const blurAmount = f >= T.blurEnd ? 7 * spring({ frame: f - T.blurEnd, fps, config: { damping: 20 } }) : 0;

  return (
    <AbsoluteFill style={{ fontFamily: 'Inter, sans-serif', overflow: 'hidden', background: '#13133a' }}>
      <Wallpaper />
      <div style={{ opacity: 1 - fly }}>
        <MenuBar />
      </div>
      <AbsoluteFill style={{ background: 'rgba(8,8,24,0.45)', opacity: fly * (1 - out) }} />

      {f < T.endIn + 30 ? (
        <AbsoluteFill style={{ transform: `scale(${sceneScale})`, opacity: f < T.flyStart ? 1 : 1 - out, filter: out > 0 ? `blur(${out * 10}px)` : undefined }}>
          {/* Editor window */}
          <div
            style={{
              position: 'absolute', left: EX, top: EY, width: EW, height: EH, borderRadius: 16, overflow: 'hidden',
              background: '#dcdce2', boxShadow: '0 40px 80px rgba(0,0,0,0.45), 0 0 0 1px rgba(0,0,0,0.25)',
              opacity: editorOpacity > 0 ? fly : 0, transform: `scale(${0.97 + 0.03 * fly})`,
            }}
          >
            <div style={{ opacity: fly }}>
              <Toolbar f={f} />
            </div>
          </div>

          {/* Background frame behind the image */}
          {bg > 0.001 ? (
            <div
              style={{
                position: 'absolute', left: imgL - pad, top: imgT - pad, width: APP_W * s + pad * 2, height: APP_H * s + pad * 2,
                background: FRAME_BG, opacity: Math.min(1, bg * 1.5),
              }}
            />
          ) : null}

          {/* The captured image and its annotations */}
          <div
            style={{
              position: 'absolute', left: imgL, top: imgT, width: APP_W, height: APP_H, transform: `scale(${s})`, transformOrigin: '0 0',
              borderRadius: 12 * bg, boxShadow: f < T.flyStart ? '0 30px 60px rgba(0,0,0,0.5)' : `0 ${24 * bg}px ${50 * bg}px rgba(0,0,0,${0.35 * bg})`,
            }}
          >
            <div style={{ position: 'absolute', inset: 0, overflow: 'hidden', borderRadius: f < T.flyStart ? 12 : 12 * bg }}>
              <FakeApp blurRow={1} blurAmount={blurAmount} />
            </div>
            <Annotations f={f} fps={fps} />
          </div>

          {/* Floating bars */}
          <div style={{ position: 'absolute', left: EX, top: EY, width: EW, height: EH, opacity: fly, pointerEvents: 'none' }}>
            <StyleBar />
            <BottomBar zoom={Math.round(sEditor * 100)} />
            {toast > 0.001 ? (
              <div
                style={{
                  position: 'absolute', left: EW / 2 - 210, top: EH - 150, width: 420, height: 56, borderRadius: 16,
                  background: 'rgba(24,24,32,0.92)', color: '#fff', display: 'flex', alignItems: 'center', gap: 12, padding: '0 18px',
                  boxSizing: 'border-box', fontSize: 18, fontWeight: 600, boxShadow: '0 12px 30px rgba(0,0,0,0.35)',
                  opacity: toast, transform: `translateY(${(1 - toast) * 24}px)`,
                }}
              >
                <div style={{ width: 28, height: 28, borderRadius: 14, background: '#34c759', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                  <Icon name="check" size={18} color="#fff" width={2.6} />
                </div>
                Copied. Link ready
                <div style={{ flex: 1 }} />
                <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 15, fontWeight: 500, color: 'rgba(255,255,255,0.7)' }}>
                  <Icon name="link" size={16} color="rgba(255,255,255,0.7)" />
                  snapper.link/k7Qm
                </div>
              </div>
            ) : null}
          </div>

          {/* Selection overlay */}
          {selecting ? (
            <>
              <div
                style={{
                  position: 'absolute', left: 250, top: 150, width: selW, height: selH,
                  boxShadow: '0 0 0 4000px rgba(0,0,0,0.38)', outline: '1px solid rgba(255,255,255,0.9)',
                }}
              />
            </>
          ) : null}
          {f < T.selStart ? <AbsoluteFill style={{ background: 'rgba(0,0,0,0.38)', opacity: interpolate(f, [4, T.selStart], [0, 1], clamp) }} /> : null}

          {f < T.flash + 2 ? <Crosshair x={cxh} y={cyh} label={selecting ? `${selW} × ${selH}` : undefined} /> : null}
          {f >= T.flyEnd && f < T.outEnd ? <Pointer x={px} y={py} press={press} /> : null}
        </AbsoluteFill>
      ) : null}

      <AbsoluteFill style={{ background: '#fff', opacity: flash }} />
      {f >= T.endIn ? <EndCard f={f} fps={fps} /> : null}
      {/* Fade from and to the same navy so the loop is seamless */}
      <AbsoluteFill style={{ background: '#13133a', opacity: interpolate(f, [0, 10], [1, 0], clamp) }} />
      <AbsoluteFill style={{ background: '#13133a', opacity: interpolate(f, [DURATION - 14, DURATION - 1], [0, 1], clamp) }} />
    </AbsoluteFill>
  );
};
