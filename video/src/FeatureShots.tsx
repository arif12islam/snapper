import React from 'react';
import { AbsoluteFill, Img, staticFile } from 'remotion';
import { APP_H, APP_W, BEST, FakeApp, barRect } from './FakeApp';
import { FinalShot } from './Product';
import { Icon } from './Icons';
import { C } from './palette';

// Still images for the website's feature cards. Each one is a realistic Snapper scene:
// the editor with a tool in use, or a macOS desktop moment. Rendered by features.mjs.

const RED = '#ff3b30';
const font: React.CSSProperties = { fontFamily: 'Inter, -apple-system, sans-serif' };

export const WASH: Record<string, string> = {
  peach: 'linear-gradient(160deg, #fff1ea 0%, #ffd9c9 100%)',
  sky: 'linear-gradient(160deg, #eef4ff 0%, #c4d9ff 100%)',
  lilac: 'linear-gradient(160deg, #f4f0ff 0%, #d9cdfd 100%)',
  mint: 'linear-gradient(160deg, #ecfbf4 0%, #bdeed9 100%)',
  sun: 'linear-gradient(160deg, #fff8e2 0%, #ffe39a 100%)',
  night: 'linear-gradient(160deg, #2a2a6e 0%, #15153d 100%)',
};

const windowShadow = '0 50px 100px rgba(27,27,77,0.28), 0 12px 30px rgba(27,27,77,0.14), 0 0 0 1px rgba(0,0,0,0.12)';

const Lights: React.FC<{ x?: number; y?: number }> = ({ x = 20, y = 26 }) => (
  <>
    {['#ff5f57', '#febc2e', '#28c840'].map((c, i) => (
      <div key={c} style={{ position: 'absolute', left: x + i * 22, top: y, width: 13, height: 13, borderRadius: 7, background: c }} />
    ))}
  </>
);

// ---------------------------------------------------------------- the editor window
type Tool = 'select' | 'crop' | 'arrow' | 'line' | 'rect' | 'pen' | 'marker' | 'text' | 'counter' | 'magnifier' | 'spotlight' | 'blur' | 'drop';
const GROUPS: Tool[][] = [['select', 'crop'], ['arrow', 'line', 'rect', 'pen', 'marker'], ['text', 'counter', 'magnifier'], ['spotlight', 'blur', 'drop']];

const Toolbar: React.FC<{ active: Tool; width: number; bgActive?: boolean }> = ({ active, width, bgActive }) => (
  <div style={{ position: 'absolute', left: 0, top: 0, width, height: 64, background: '#f7f7f9', borderBottom: '1px solid rgba(0,0,0,0.08)' }}>
    <Lights />
    <div style={{ position: 'absolute', left: 104, top: 20, display: 'flex', gap: 10, color: '#9a9aa6' }}>
      <Icon name="undo" size={22} />
      <Icon name="redo" size={22} />
    </div>
    <div style={{ position: 'absolute', left: 190, top: 13, display: 'flex', gap: 18 }}>
      {GROUPS.map((g, gi) => (
        <div key={gi} style={{ display: 'flex', gap: 4 }}>
          {g.map((t) => (
            <div key={t} style={{ width: 40, height: 38, borderRadius: 9, display: 'flex', alignItems: 'center', justifyContent: 'center', background: t === active ? 'rgba(0,0,0,0.09)' : 'transparent', color: '#3a3a44' }}>
              <Icon name={t} size={22} />
            </div>
          ))}
        </div>
      ))}
    </div>
    {[
      { x: width - 362, w: 150, label: 'Background', swatch: true },
      { x: width - 202, w: 80, label: 'Copy' },
      { x: width - 112, w: 96, label: 'Save', chev: true },
    ].map((b) => (
      <div
        key={b.label}
        style={{
          position: 'absolute', left: b.x, top: 14, width: b.w, height: 36, borderRadius: 9, border: '1px solid rgba(0,0,0,0.1)',
          background: b.swatch && bgActive ? '#e8e8ee' : '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
          fontSize: 17, fontWeight: 500, color: '#2a2a33',
        }}
      >
        {b.swatch ? <div style={{ width: 26, height: 18, borderRadius: 5, background: 'linear-gradient(135deg,#ff8a7c,#b9a2ff)' }} /> : null}
        {b.label}
        {b.chev ? <Icon name="chevron" size={16} /> : null}
      </div>
    ))}
  </div>
);

const StyleBar: React.FC<{ x: number }> = ({ x }) => (
  <div
    style={{
      position: 'absolute', left: x, top: 80, width: 800, height: 48, borderRadius: 24, background: 'rgba(250,250,252,0.96)',
      border: '1px solid rgba(0,0,0,0.08)', boxShadow: '0 6px 20px rgba(0,0,0,0.12)', display: 'flex', alignItems: 'center', gap: 14, padding: '0 20px', boxSizing: 'border-box',
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
  </div>
);

/** The Snapper editor, zoomed into a spot of the captured image. */
const Editor: React.FC<{
  active: Tool; left?: number; top?: number; width?: number; height?: number; zoom: number; focus: [number, number]; at?: [number, number];
  bgActive?: boolean; styleBar?: boolean; children?: React.ReactNode; image?: React.ReactNode; overlay?: React.ReactNode;
}> = ({ active, left = 70, top = 70, width = 1500, height = 1100, zoom, focus, at = [560, 470], bgActive, styleBar = true, children, image, overlay }) => {
  const imgL = at[0] - focus[0] * zoom;
  const imgT = at[1] - focus[1] * zoom;
  return (
    <div style={{ position: 'absolute', left, top, width, height, borderRadius: 16, overflow: 'hidden', background: '#dcdce2', boxShadow: windowShadow }}>
      <div style={{ position: 'absolute', left: imgL, top: imgT, width: APP_W, height: APP_H, transform: `scale(${zoom})`, transformOrigin: '0 0', boxShadow: '0 2px 10px rgba(0,0,0,0.12)' }}>
        {image ?? <FakeApp />}
        {overlay}
      </div>
      {children}
      <Toolbar active={active} width={width} bgActive={bgActive} />
      {styleBar ? <StyleBar x={120} /> : null}
    </div>
  );
};

const Counter: React.FC<{ n: number; x: number; y: number; size?: number }> = ({ n, x, y, size = 40 }) => (
  <div
    style={{
      position: 'absolute', left: x - size / 2, top: y - size / 2, width: size, height: size, borderRadius: size / 2, background: RED, border: '3px solid #fff', boxSizing: 'border-box',
      color: '#fff', fontSize: size * 0.48, fontWeight: 800, display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: '0 3px 8px rgba(0,0,0,0.3)', ...font,
    }}
  >
    {n}
  </div>
);

const Handles: React.FC<{ x: number; y: number; w: number; h: number; color?: string }> = ({ x, y, w, h, color = '#0a84ff' }) => (
  <>
    {[[x, y], [x + w / 2, y], [x + w, y], [x, y + h / 2], [x + w, y + h / 2], [x, y + h], [x + w / 2, y + h], [x + w, y + h]].map(([hx, hy], i) => (
      <div key={i} style={{ position: 'absolute', left: hx - 6, top: hy - 6, width: 12, height: 12, borderRadius: 6, background: '#fff', border: `2.5px solid ${color}`, boxSizing: 'border-box' }} />
    ))}
  </>
);

const Pointer: React.FC<{ x: number; y: number; scale?: number }> = ({ x, y, scale = 1 }) => (
  <svg width={30 * scale} height={36 * scale} viewBox="0 0 30 36" style={{ position: 'absolute', left: x - 4 * scale, top: y - 2 * scale, filter: 'drop-shadow(0 3px 4px rgba(0,0,0,0.35))' }}>
    <path d="M4 2l20 18-9 1.5 5.5 10.5-4 2-5.5-10.6L4 29z" fill="#111" stroke="#fff" strokeWidth="2" strokeLinejoin="round" />
  </svg>
);

// ---------------------------------------------------------------- desktop pieces
const Wallpaper: React.FC = () => (
  <div style={{ position: 'absolute', inset: 0, background: C.sky, overflow: 'hidden' }}>
    <div style={{ position: 'absolute', width: 700, height: 700, borderRadius: '50%', background: C.sun, left: -260, top: -300 }} />
    <div style={{ position: 'absolute', width: 380, height: 380, borderRadius: '50%', background: C.mint, right: 180, top: -170 }} />
    <div style={{ position: 'absolute', width: 620, height: 620, borderRadius: '50%', background: C.lilac, left: 140, bottom: -420 }} />
    <div style={{ position: 'absolute', width: 1000, height: 1000, borderRadius: '50%', background: C.coral, right: -360, bottom: -560 }} />
  </div>
);

const MenuBar: React.FC<{ width: number; snapperOpen?: boolean; recording?: boolean }> = ({ width, snapperOpen, recording }) => (
  <div style={{ position: 'absolute', left: 0, top: 0, width, height: 34, background: 'rgba(240,240,248,0.72)', backdropFilter: 'blur(30px)', display: 'flex', alignItems: 'center', padding: '0 20px', gap: 24, fontSize: 15, color: '#1d1d24', ...font }}>
    <div style={{ fontWeight: 700 }}>Finder</div>
    <div>File</div><div>Edit</div><div>View</div><div>Go</div><div>Window</div><div>Help</div>
    <div style={{ flex: 1 }} />
    {recording ? (
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontWeight: 600, fontVariantNumeric: 'tabular-nums' }}>
        <div style={{ width: 16, height: 16, borderRadius: 4, background: RED }} />00:12
      </div>
    ) : null}
    <div style={{ padding: '3px 8px', borderRadius: 6, background: snapperOpen ? 'rgba(0,0,0,0.12)' : 'transparent', display: 'flex' }}>
      <Img src={staticFile('icon-4k.png')} style={{ width: 22, height: 22 }} />
    </div>
    <svg width="20" height="14" viewBox="0 0 20 14"><path d="M10 13L1 4a13 13 0 0 1 18 0z" fill="#1d1d24" /></svg>
    <svg width="28" height="14" viewBox="0 0 28 14"><rect x="0.5" y="0.5" width="24" height="13" rx="3.5" fill="none" stroke="#1d1d24" /><rect x="2.5" y="2.5" width="17" height="9" rx="2" fill="#1d1d24" /><rect x="25.5" y="4.5" width="2" height="5" rx="1" fill="#1d1d24" /></svg>
    <div style={{ fontWeight: 500 }}>Fri 9:41 AM</div>
  </div>
);

const AppWindow: React.FC<{ x: number; y: number; scale: number; blurRow?: number; blurAmount?: number }> = ({ x, y, scale, blurRow, blurAmount }) => (
  <div style={{ position: 'absolute', left: x, top: y, width: APP_W * scale, height: APP_H * scale, borderRadius: 12, overflow: 'hidden', boxShadow: windowShadow }}>
    <div style={{ transform: `scale(${scale})`, transformOrigin: '0 0' }}>
      <FakeApp blurRow={blurRow} blurAmount={blurAmount} />
    </div>
  </div>
);

const Toast: React.FC<{ x: number; y: number; title: string; detail?: string; w?: number }> = ({ x, y, title, detail, w = 460 }) => (
  <div
    style={{
      position: 'absolute', left: x, top: y, width: w, height: 60, borderRadius: 18, background: 'rgba(24,24,32,0.92)', color: '#fff', display: 'flex', alignItems: 'center', gap: 12,
      padding: '0 20px', boxSizing: 'border-box', fontSize: 19, fontWeight: 600, boxShadow: '0 16px 36px rgba(0,0,0,0.35)', ...font,
    }}
  >
    <div style={{ width: 30, height: 30, borderRadius: 15, background: '#34c759', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <Icon name="check" size={18} color="#fff" width={2.6} />
    </div>
    {title}
    <div style={{ flex: 1 }} />
    {detail ? <div style={{ fontSize: 16, fontWeight: 500, color: 'rgba(255,255,255,0.7)' }}>{detail}</div> : null}
  </div>
);

// ---------------------------------------------------------------- the shots
const best = barRect(BEST);

const shots: Record<string, { w: number; h: number; render: () => React.ReactNode }> = {
  // The full editor with every mark, for the "one shortcut away" row.
  editor: {
    w: 1400, h: 1000,
    render: () => (
      <AbsoluteFill style={{ background: WASH.sky }}>
        <Editor active="select" left={90} top={90} width={1500} height={1000} zoom={0.92} focus={[550, 330]} at={[640, 520]} image={<FinalShot />} />
      </AbsoluteFill>
    ),
  },
  arrows: {
    w: 1200, h: 900,
    render: () => (
      <AbsoluteFill style={{ background: WASH.peach }}>
        <Editor
          active="arrow" zoom={1.2} focus={[560, 270]}
          overlay={
            <svg width={APP_W} height={APP_H} style={{ position: 'absolute', inset: 0, overflow: 'visible', filter: 'drop-shadow(0 2px 3px rgba(0,0,0,0.25))' }}>
              <rect x={222} y={128} width={290} height={126} rx={10} fill="none" stroke={RED} strokeWidth={6} />
              <line x1={690} y1={312} x2={842} y2={325} stroke={RED} strokeWidth={7} strokeLinecap="round" />
              <path d="M 862 328 L 832 342 L 836 312 Z" fill={RED} stroke={RED} strokeWidth={3} strokeLinejoin="round" />
            </svg>
          }
        >
          <Pointer x={560 + (858 - 560) * 1.2} y={470 + (329 - 270) * 1.2} />
        </Editor>
      </AbsoluteFill>
    ),
  },
  numbers: {
    w: 1200, h: 900,
    render: () => (
      <AbsoluteFill style={{ background: WASH.sun }}>
        <Editor
          active="counter" zoom={1.25} focus={[420, 250]}
          overlay={
            <>
              <Counter n={1} x={200} y={127} size={38} />
              <Counter n={2} x={232} y={146} size={38} />
              <Counter n={3} x={516} y={146} size={38} />
              <Counter n={4} x={800} y={146} size={38} />
            </>
          }
        />
      </AbsoluteFill>
    ),
  },
  blur: {
    w: 1200, h: 900,
    render: () => (
      <AbsoluteFill style={{ background: WASH.lilac }}>
        <Editor
          active="blur" zoom={1.45} focus={[560, 600]} at={[560, 520]} image={<FakeApp blurRow={1} blurAmount={3.2} />}
          overlay={
            <div style={{ position: 'absolute', left: 472, top: 581, width: 244, height: 40, border: '2px dashed #0a84ff', borderRadius: 6, background: 'rgba(10,132,255,0.06)' }} />
          }
        />
      </AbsoluteFill>
    ),
  },
  magnifier: {
    w: 1200, h: 900,
    render: () => {
      const T = { x: 409, y: 199 }, L = { x: 660, y: 150, r: 92 }, Z = 2.6;
      const dx = L.x - T.x, dy = L.y - T.y, d = Math.hypot(dx, dy), ux = dx / d, uy = dy / d;
      return (
        <AbsoluteFill style={{ background: WASH.mint }}>
          <Editor
            active="magnifier" zoom={1.3} focus={[530, 230]}
            overlay={
              <>
                <svg width={APP_W} height={APP_H} style={{ position: 'absolute', inset: 0, overflow: 'visible' }}>
                  <circle cx={T.x} cy={T.y} r={26} fill="none" stroke={RED} strokeWidth={4} />
                  <line x1={T.x + ux * 26} y1={T.y + uy * 26} x2={L.x - ux * (L.r + 3)} y2={L.y - uy * (L.r + 3)} stroke={RED} strokeWidth={4} strokeLinecap="round" />
                </svg>
                <div style={{ position: 'absolute', left: L.x - L.r, top: L.y - L.r, width: L.r * 2, height: L.r * 2, borderRadius: '50%', overflow: 'hidden', border: `5px solid ${RED}`, boxSizing: 'border-box', background: '#fff', boxShadow: '0 10px 24px rgba(0,0,0,0.3)' }}>
                  <div style={{ position: 'absolute', left: L.r - 5 - T.x * Z, top: L.r - 5 - T.y * Z, transform: `scale(${Z})`, transformOrigin: '0 0' }}>
                    <FakeApp />
                  </div>
                </div>
              </>
            }
          />
        </AbsoluteFill>
      );
    },
  },
  backgrounds: {
    w: 1200, h: 900,
    render: () => {
      const z = 0.62, pad = 70;
      return (
        <AbsoluteFill style={{ background: WASH.sky }}>
          <Editor
            active="select" left={-330} bgActive styleBar={false} zoom={z} focus={[550, 350]} at={[1040, 520]}
            image={
              <div style={{ position: 'relative', width: APP_W, height: APP_H }}>
                <div style={{ position: 'absolute', left: -pad, top: -pad, width: APP_W + pad * 2, height: APP_H + pad * 2, background: 'linear-gradient(135deg, #ff8a7c 0%, #b9a2ff 100%)' }} />
                <div style={{ position: 'absolute', inset: 0, borderRadius: 18, overflow: 'hidden', boxShadow: '0 30px 60px rgba(0,0,0,0.35)' }}><FinalShot /></div>
              </div>
            }
          >
            {/* Background popover under the toolbar button */}
            <div style={{ position: 'absolute', left: 1500 - 400, top: 62, width: 300, padding: 18, borderRadius: 16, background: 'rgba(252,252,254,0.97)', boxShadow: '0 20px 50px rgba(0,0,0,0.25), 0 0 0 1px rgba(0,0,0,0.08)', ...font }}>
              <div style={{ fontSize: 14, fontWeight: 650, color: '#55586f', marginBottom: 12 }}>Background</div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10 }}>
                {['linear-gradient(135deg,#ff8a7c,#b9a2ff)', 'linear-gradient(135deg,#8cb8ff,#6fd9b0)', 'linear-gradient(135deg,#ffc83d,#ff6b5b)', '#1b1b4d', '#ff6b5b', '#6fd9b0', '#f4efe6', 'transparent'].map((bg, i) => (
                  <div key={i} style={{ height: 48, borderRadius: 10, background: bg === 'transparent' ? 'repeating-conic-gradient(#ddd 0 25%, #fff 0 50%) 0 0 / 14px 14px' : bg, boxShadow: i === 0 ? '0 0 0 3px #fff, 0 0 0 5px #0a84ff' : 'inset 0 0 0 1px rgba(0,0,0,0.08)' }} />
                ))}
              </div>
              {[['Padding', 0.55], ['Corners', 0.4], ['Shadow', 0.7]].map(([label, v]) => (
                <div key={label as string} style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 16, fontSize: 14, color: '#33354d' }}>
                  <div style={{ width: 70 }}>{label}</div>
                  <div style={{ position: 'relative', flex: 1, height: 4, borderRadius: 2, background: '#d8d8e0' }}>
                    <div style={{ position: 'absolute', left: 0, top: 0, width: `${(v as number) * 100}%`, height: 4, borderRadius: 2, background: '#0a84ff' }} />
                    <div style={{ position: 'absolute', left: `calc(${(v as number) * 100}% - 9px)`, top: -7, width: 18, height: 18, borderRadius: 9, background: '#fff', boxShadow: '0 1px 4px rgba(0,0,0,0.3)' }} />
                  </div>
                </div>
              ))}
            </div>
          </Editor>
        </AbsoluteFill>
      );
    },
  },
  crop: {
    w: 1200, h: 900,
    render: () => {
      const r = { x: 232, y: 262, w: 836, h: 220 };
      return (
        <AbsoluteFill style={{ background: WASH.peach }}>
          <Editor
            active="crop" zoom={1.05} focus={[600, 370]}
            overlay={
              <>
                <svg width={APP_W} height={APP_H} style={{ position: 'absolute', inset: 0 }}>
                  <path d={`M0 0H${APP_W}V${APP_H}H0Z M${r.x} ${r.y}V${r.y + r.h}H${r.x + r.w}V${r.y}Z`} fill="rgba(20,20,40,0.55)" fillRule="evenodd" />
                  <rect x={r.x} y={r.y} width={r.w} height={r.h} fill="none" stroke="#fff" strokeWidth={2} />
                  {[1, 2].map((k) => <line key={'v' + k} x1={r.x + (r.w * k) / 3} y1={r.y} x2={r.x + (r.w * k) / 3} y2={r.y + r.h} stroke="rgba(255,255,255,0.45)" strokeWidth={1} />)}
                  {[1, 2].map((k) => <line key={'h' + k} x1={r.x} y1={r.y + (r.h * k) / 3} x2={r.x + r.w} y2={r.y + (r.h * k) / 3} stroke="rgba(255,255,255,0.45)" strokeWidth={1} />)}
                  {[[r.x, r.y, 1, 1], [r.x + r.w, r.y, -1, 1], [r.x, r.y + r.h, 1, -1], [r.x + r.w, r.y + r.h, -1, -1]].map(([x, y, sx, sy], i) => (
                    <path key={i} d={`M ${x} ${y + sy * 30} V ${y} H ${x + sx * 30}`} fill="none" stroke="#fff" strokeWidth={7} strokeLinecap="round" />
                  ))}
                </svg>
                <div style={{ position: 'absolute', left: r.x + r.w / 2 - 70, top: r.y + r.h + 14, width: 140, height: 34, borderRadius: 9, background: 'rgba(20,20,30,0.85)', color: '#fff', fontSize: 16, fontWeight: 600, display: 'flex', alignItems: 'center', justifyContent: 'center', ...font }}>
                  836 × 220
                </div>
              </>
            }
          />
        </AbsoluteFill>
      );
    },
  },
  text: {
    w: 1200, h: 900,
    render: () => {
      const s = 1.05, ax = 60, ay = 120;
      const sel = { x: ax + 222 * s, y: ay + 128 * s, w: 290 * s, h: 126 * s };
      return (
        <AbsoluteFill style={{ background: WASH.lilac, ...font }}>
          <AppWindow x={ax} y={ay} scale={s} />
          <div style={{ position: 'absolute', inset: 0, boxShadow: 'none' }}>
            <div style={{ position: 'absolute', left: sel.x, top: sel.y, width: sel.w, height: sel.h, boxShadow: '0 0 0 4000px rgba(20,20,40,0.42)', outline: '2px solid #fff' }} />
          </div>
          <div style={{ position: 'absolute', left: sel.x + sel.w + 16, top: sel.y + 10, padding: '10px 16px', borderRadius: 12, background: '#fff', boxShadow: '0 16px 36px rgba(0,0,0,0.3)', fontSize: 17, color: '#33354d', lineHeight: 1.5 }}>
            <div style={{ fontSize: 13, fontWeight: 650, color: '#8a8ca6', marginBottom: 4 }}>Recognized text</div>
            <div><span style={{ background: 'rgba(10,132,255,0.2)', borderRadius: 4, padding: '0 3px' }}>Monthly revenue</span></div>
            <div style={{ fontSize: 26, fontWeight: 750, color: '#16163a' }}><span style={{ background: 'rgba(10,132,255,0.2)', borderRadius: 4, padding: '0 3px' }}>$48,210 +18.2%</span></div>
          </div>
          <Toast x={360} y={760} title="Text copied" detail="Paste anywhere" />
        </AbsoluteFill>
      );
    },
  },

  // ---- Recording
  recording: {
    w: 1400, h: 820,
    render: () => {
      const area = { x: 330, y: 150, w: 760, h: 470 };
      return (
        <AbsoluteFill style={font}>
          <Wallpaper />
          <AppWindow x={250} y={90} scale={0.84} />
          <MenuBar width={1400} recording />
          <div style={{ position: 'absolute', left: area.x, top: area.y, width: area.w, height: area.h, boxShadow: '0 0 0 4000px rgba(20,20,40,0.35)', outline: `3px solid ${RED}`, borderRadius: 2 }} />
          <div style={{ position: 'absolute', left: area.x + area.w / 2 - 170, top: area.y + area.h + 26, height: 60, padding: '0 10px 0 22px', borderRadius: 30, background: 'rgba(24,24,32,0.94)', color: '#fff', display: 'flex', alignItems: 'center', gap: 18, boxShadow: '0 18px 40px rgba(0,0,0,0.4)', fontSize: 19, fontWeight: 650, fontVariantNumeric: 'tabular-nums' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}><div style={{ width: 14, height: 14, borderRadius: 7, background: RED }} />00:12</div>
            <div style={{ width: 1, height: 26, background: 'rgba(255,255,255,0.2)' }} />
            <svg width="22" height="22" viewBox="0 0 24 24" fill="#fff"><rect x="6" y="5" width="4" height="14" rx="1" /><rect x="14" y="5" width="4" height="14" rx="1" /></svg>
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2" strokeLinecap="round"><rect x="9" y="3" width="6" height="11" rx="3" /><path d="M5 11a7 7 0 0 0 14 0M12 18v3" /></svg>
            <div style={{ height: 42, padding: '0 18px', borderRadius: 21, background: RED, display: 'flex', alignItems: 'center', gap: 8 }}>
              <div style={{ width: 12, height: 12, borderRadius: 2, background: '#fff' }} />Stop
            </div>
          </div>
        </AbsoluteFill>
      );
    },
  },
  gif: {
    w: 1400, h: 820,
    render: () => (
      <AbsoluteFill style={{ background: WASH.lilac, ...font }}>
        <div style={{ position: 'absolute', left: 260, top: 90, width: 880, height: 700, borderRadius: 22, background: '#fff', boxShadow: windowShadow, overflow: 'hidden' }}>
          <div style={{ height: 64, borderBottom: '1px solid rgba(27,27,77,0.1)', display: 'flex', alignItems: 'center', padding: '0 26px', gap: 10 }}>
            <div style={{ fontSize: 21, fontWeight: 800, color: C.ink }}># bug-reports</div>
          </div>
          <div style={{ position: 'absolute', left: 26, top: 92, display: 'flex', gap: 16 }}>
            <div style={{ width: 46, height: 46, borderRadius: 13, background: C.ink, color: '#fff', fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>A</div>
            <div>
              <div style={{ display: 'flex', gap: 10, alignItems: 'baseline' }}><div style={{ fontSize: 19, fontWeight: 700, color: C.ink }}>You</div><div style={{ fontSize: 15, color: '#8a8ca0' }}>10:02</div></div>
              <div style={{ fontSize: 19, color: '#33354d', marginTop: 2 }}>Export button does nothing on the Revenue page:</div>
              <div style={{ position: 'relative', marginTop: 12, width: 620, height: 395, borderRadius: 14, overflow: 'hidden', boxShadow: '0 0 0 1px rgba(27,27,77,0.12)' }}>
                <div style={{ transform: 'scale(0.5636)', transformOrigin: '0 0' }}><FakeApp /></div>
                <svg style={{ position: 'absolute', inset: 0 }} width="620" height="395"><circle cx={(1068 - 32 - 30) * 0.5636} cy={93 * 0.5636} r="26" fill="rgba(255,59,48,0.25)" stroke={RED} strokeWidth="3" /></svg>
                <Pointer x={(1068 - 32 - 36) * 0.5636} y={92 * 0.5636} scale={0.9} />
                <div style={{ position: 'absolute', left: 14, bottom: 14, padding: '6px 12px', borderRadius: 8, background: 'rgba(20,20,30,0.82)', color: '#fff', fontSize: 15, fontWeight: 800, letterSpacing: 1 }}>GIF</div>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 12, fontSize: 15, color: '#55586f' }}>
                <Icon name="image" size={18} color="#55586f" />revenue-export.gif<span style={{ color: '#9a9cb2' }}>1.8 MB</span>
              </div>
            </div>
          </div>
        </div>
      </AbsoluteFill>
    ),
  },
  trim: {
    w: 1600, h: 760,
    render: () => {
      const L = 0.2, R = 0.76, P = 0.47;
      const tlX = 40, tlW = 1160;
      return (
        <AbsoluteFill style={{ background: WASH.peach, ...font }}>
          <div style={{ position: 'absolute', left: 70, top: 70, width: 1460, height: 760, borderRadius: 16, background: '#ececf1', overflow: 'hidden', boxShadow: windowShadow }}>
            <div style={{ height: 52, background: '#f7f7f9', borderBottom: '1px solid rgba(0,0,0,0.08)', position: 'relative' }}>
              <Lights y={20} />
              <div style={{ position: 'absolute', left: 0, right: 0, top: 15, textAlign: 'center', fontSize: 16, fontWeight: 600, color: '#3a3a44' }}>Recording 10:02.mov</div>
            </div>
            {/* Player */}
            <div style={{ position: 'absolute', left: 40, top: 80, width: 1160, height: 420, background: '#15153d', borderRadius: 10, overflow: 'hidden' }}>
              <div style={{ position: 'absolute', left: (1160 - 660) / 2, top: 0, width: 660, height: 420 }}>
                <div style={{ transform: 'scale(0.6)', transformOrigin: '0 0' }}><FakeApp /></div>
              </div>
            </div>
            {/* Sidebar */}
            <div style={{ position: 'absolute', left: 1226, top: 80, width: 206, color: '#33354d', fontSize: 16 }}>
              <div style={{ fontSize: 14, fontWeight: 650, color: '#8a8ca6', marginBottom: 12 }}>Trim</div>
              {[['Start', '00:03.2'], ['End', '00:11.8'], ['Length', '00:08.6']].map(([k, v]) => (
                <div key={k} style={{ display: 'flex', justifyContent: 'space-between', padding: '12px 14px', borderRadius: 10, background: '#fff', marginBottom: 8, boxShadow: 'inset 0 0 0 1px rgba(0,0,0,0.06)' }}>
                  <span>{k}</span><span style={{ fontWeight: 650, fontVariantNumeric: 'tabular-nums', color: C.ink }}>{v}</span>
                </div>
              ))}
              <div style={{ marginTop: 18, height: 46, borderRadius: 12, background: C.ink, color: '#fff', fontWeight: 650, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>Export</div>
            </div>
            {/* Timeline */}
            <div style={{ position: 'absolute', left: tlX, top: 530, width: tlW, height: 96, display: 'flex', gap: 3, borderRadius: 10, overflow: 'hidden' }}>
              {Array.from({ length: 10 }).map((_, i) => (
                <div key={i} style={{ flex: 1, position: 'relative', overflow: 'hidden', background: '#fff' }}>
                  <div style={{ transform: 'scale(0.105)', transformOrigin: '0 0' }}><FakeApp /></div>
                </div>
              ))}
            </div>
            <div style={{ position: 'absolute', left: tlX, top: 530, width: tlW * L, height: 96, background: 'rgba(236,236,241,0.78)' }} />
            <div style={{ position: 'absolute', left: tlX + tlW * R, top: 530, width: tlW * (1 - R), height: 96, background: 'rgba(236,236,241,0.78)' }} />
            <div style={{ position: 'absolute', left: tlX + tlW * L - 14, top: 524, width: tlW * (R - L) + 28, height: 108, border: `7px solid ${C.sun}`, borderLeftWidth: 14, borderRightWidth: 14, borderRadius: 10, boxSizing: 'border-box' }} />
            <div style={{ position: 'absolute', left: tlX + tlW * P - 2, top: 512, width: 4, height: 132, borderRadius: 2, background: RED }} />
            <div style={{ position: 'absolute', left: tlX + tlW * P - 9, top: 504, width: 18, height: 18, borderRadius: 9, background: RED }} />
            <div style={{ position: 'absolute', left: tlX, top: 650, width: tlW, display: 'flex', justifyContent: 'space-between', fontSize: 14, color: '#8a8ca6', fontVariantNumeric: 'tabular-nums' }}>
              {['00:00', '00:03', '00:06', '00:09', '00:12', '00:15'].map((t) => <span key={t}>{t}</span>)}
            </div>
          </div>
        </AbsoluteFill>
      );
    },
  },

  // ---- Mac
  menubar: {
    w: 1200, h: 900,
    render: () => {
      const items: (string | [string, string?, string?])[] = [
        ['All-In-One', '⌃⇧X', 'select'], '-',
        ['Capture Screen', '⌃⇧F', 'image'], ['Capture Area', '⌃⇧A', 'crop'], ['Capture Window', '⌃⇧W', 'rect'], ['Capture Previous Area'],
        ['Scrolling Capture', '›'], '-',
        ['Recognize Text/QR', '⌃⇧T', 'text'], ['Pin Area to Screen'], '-',
        ['Record Screen', '⌃⇧R', 'spotlight'], ['Record Area'], ['Record GIF'],
      ];
      return (
        <AbsoluteFill style={font}>
          <Wallpaper />
          <MenuBar width={1200} snapperOpen />
          <div style={{ position: 'absolute', left: 470, top: 40, width: 400, padding: 6, borderRadius: 12, background: 'rgba(246,246,250,0.94)', backdropFilter: 'blur(30px)', boxShadow: '0 24px 60px rgba(0,0,0,0.3), 0 0 0 1px rgba(0,0,0,0.12)', fontSize: 17, color: '#1d1d24' }}>
            {items.map((it, i) =>
              it === '-' ? (
                <div key={i} style={{ height: 1, background: 'rgba(0,0,0,0.1)', margin: '5px 10px' }} />
              ) : (
                <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 12, height: 38, padding: '0 12px', borderRadius: 7, background: i === 3 ? '#0a84ff' : 'transparent', color: i === 3 ? '#fff' : '#1d1d24' }}>
                  <div style={{ width: 20, display: 'flex', justifyContent: 'center' }}>{(it as string[])[2] ? <Icon name={(it as string[])[2]!} size={18} color={i === 3 ? '#fff' : '#3a3a44'} /> : null}</div>
                  <div style={{ flex: 1 }}>{(it as string[])[0]}</div>
                  <div style={{ color: i === 3 ? '#fff' : '#8a8a96', letterSpacing: 1 }}>{(it as string[])[1] ?? ''}</div>
                </div>
              ),
            )}
          </div>
        </AbsoluteFill>
      );
    },
  },
  pin: {
    w: 1200, h: 900,
    render: () => (
      <AbsoluteFill style={font}>
        <Wallpaper />
        {/* A notes window you are writing in */}
        <div style={{ position: 'absolute', left: 70, top: 120, width: 760, height: 720, borderRadius: 14, background: '#fff', boxShadow: windowShadow, overflow: 'hidden' }}>
          <div style={{ height: 50, background: '#f6f6f8', borderBottom: '1px solid rgba(0,0,0,0.07)', position: 'relative' }}><Lights y={18} /></div>
          <div style={{ padding: '30px 40px', color: '#2a2a33' }}>
            <div style={{ fontSize: 30, fontWeight: 750, letterSpacing: -0.5 }}>Q4 board update</div>
            <div style={{ fontSize: 15, color: '#8a8ca0', marginTop: 4 }}>Draft</div>
            {[0.95, 0.88, 0.92, 0.6, 0, 0.9, 0.84, 0.7].map((w, i) =>
              w ? <div key={i} style={{ height: 13, width: `${w * 100}%`, borderRadius: 7, background: '#e9e9f1', marginTop: 18 }} /> : <div key={i} style={{ height: 20 }} />,
            )}
            <div style={{ marginTop: 26, fontSize: 18, color: '#33354d' }}>Revenue hit <b>$48,210</b> in October, up 18.2%.<span style={{ display: 'inline-block', width: 2, height: 22, background: '#0a84ff', marginLeft: 3, verticalAlign: 'middle' }} /></div>
          </div>
        </div>
        {/* The pinned screenshot, floating above everything */}
        <div style={{ position: 'absolute', left: 600, top: 70, width: 560, transform: 'rotate(0deg)' }}>
          <div style={{ position: 'relative', width: 560, height: 356, borderRadius: 12, overflow: 'hidden', boxShadow: '0 40px 80px rgba(0,0,0,0.35), 0 0 0 1px rgba(0,0,0,0.15)' }}>
            <div style={{ transform: 'scale(0.509)', transformOrigin: '0 0' }}><FinalShot /></div>
          </div>
          <div style={{ position: 'absolute', right: 12, top: 12, display: 'flex', gap: 6 }}>
            {['spotlight', 'drop'].map((n) => (
              <div key={n} style={{ width: 34, height: 34, borderRadius: 17, background: 'rgba(20,20,30,0.75)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Icon name={n} size={18} color="#fff" /></div>
            ))}
            <div style={{ width: 34, height: 34, borderRadius: 17, background: 'rgba(20,20,30,0.75)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff', fontSize: 20 }}>×</div>
          </div>
        </div>
      </AbsoluteFill>
    ),
  },
  scrolling: {
    w: 1200, h: 900,
    render: () => {
      // A long article page, captured top to bottom. The part above the fold is the screen; the rest was stitched in.
      const Lines: React.FC<{ n: number; last?: number }> = ({ n, last = 0.6 }) => (
        <>{Array.from({ length: n }).map((_, i) => <div key={i} style={{ height: 11, width: i === n - 1 ? `${last * 100}%` : `${92 - (i % 3) * 4}%`, borderRadius: 6, background: '#e6e6ef', marginTop: 12 }} />)}</>
      );
      const block = (bg: string, h: number, children?: React.ReactNode) => <div style={{ height: h, borderRadius: 14, background: bg, marginTop: 22, position: 'relative', overflow: 'hidden' }}>{children}</div>;
      return (
        <AbsoluteFill style={{ background: WASH.sun, ...font }}>
          <div style={{ position: 'absolute', left: 120, top: 50, width: 600, height: 1500, borderRadius: 14, background: '#fff', boxShadow: windowShadow, overflow: 'hidden' }}>
            <div style={{ height: 44, background: '#f6f6f8', borderBottom: '1px solid rgba(0,0,0,0.07)', position: 'relative' }}>
              <Lights y={16} />
              <div style={{ position: 'absolute', left: 150, right: 150, top: 10, height: 24, borderRadius: 7, background: '#fff', border: '1px solid #ececf3', fontSize: 12, color: '#8a8ca0', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>orbit.app/blog/q3-review</div>
            </div>
            <div style={{ padding: '26px 34px' }}>
              <div style={{ fontSize: 13, fontWeight: 700, color: '#5b5bf0' }}>Orbit Journal</div>
              <div style={{ fontSize: 32, fontWeight: 800, letterSpacing: -0.8, color: '#16163a', marginTop: 6, lineHeight: 1.1 }}>What we learned from a record October</div>
              <Lines n={3} />
              {block('linear-gradient(135deg,#d9d9f6,#b9a2ff)', 170, <div style={{ position: 'absolute', left: 30, bottom: 26, display: 'flex', gap: 10, alignItems: 'end' }}>{[50, 70, 60, 110, 80].map((h, i) => <div key={i} style={{ width: 34, height: h, borderRadius: 6, background: i === 3 ? '#5b5bf0' : 'rgba(255,255,255,0.7)' }} />)}</div>)}
              <Lines n={4} last={0.4} />
              <div style={{ fontSize: 20, fontWeight: 750, color: '#16163a', marginTop: 28 }}>Customers who stayed</div>
              <Lines n={4} />
              {block('#eef4ff', 150)}
              <Lines n={5} last={0.5} />
              <div style={{ fontSize: 20, fontWeight: 750, color: '#16163a', marginTop: 28 }}>What comes next</div>
              <Lines n={4} />
              {block('#ffe9df', 140)}
            </div>
          </div>
          {/* The visible screen and the stitched part below it */}
          <div style={{ position: 'absolute', left: 112, top: 42, width: 616, height: 420, border: '3px solid #fff', borderRadius: 16, boxShadow: '0 0 0 2px rgba(10,132,255,0.9)' }} />
          <div style={{ position: 'absolute', left: 112, top: 462, width: 616, height: 600, borderLeft: '3px dashed rgba(10,132,255,0.9)', borderRight: '3px dashed rgba(10,132,255,0.9)' }} />
          {/* Progress HUD */}
          <div style={{ position: 'absolute', left: 790, top: 330, width: 320, padding: 22, borderRadius: 18, background: 'rgba(24,24,32,0.94)', color: '#fff', boxShadow: '0 20px 44px rgba(0,0,0,0.35)' }}>
            <div style={{ fontSize: 14, fontWeight: 650, color: 'rgba(255,255,255,0.6)' }}>Scrolling capture</div>
            <div style={{ fontSize: 30, fontWeight: 800, marginTop: 6, fontVariantNumeric: 'tabular-nums' }}>1100 × 3240</div>
            <div style={{ height: 6, borderRadius: 3, background: 'rgba(255,255,255,0.15)', marginTop: 16 }}><div style={{ width: '64%', height: 6, borderRadius: 3, background: '#34c759' }} /></div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 16 }}>
              <div style={{ fontSize: 15, color: 'rgba(255,255,255,0.7)' }}>Keep scrolling</div>
              <div style={{ padding: '6px 14px', borderRadius: 10, background: '#fff', color: C.ink, fontSize: 15, fontWeight: 700 }}>Done</div>
            </div>
          </div>
        </AbsoluteFill>
      );
    },
  },
};

export const SHOT_NAMES = Object.keys(shots);
export const shotSize = (name: string) => ({ w: shots[name].w, h: shots[name].h });

export const FeatureShot: React.FC<{ name: string }> = ({ name }) => <AbsoluteFill style={font}>{shots[name].render()}</AbsoluteFill>;
