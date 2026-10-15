import React from 'react';

// An invented analytics app. This is what gets "captured" in the promo.
export const APP_W = 1100;
export const APP_H = 700;

export const BARS = [38, 46, 41, 55, 50, 62, 58, 66, 61, 92, 70, 74];
export const BEST = 9;

// Chart geometry, shared with the annotation layer so the arrow lands on the tallest bar.
export const CHART = { x: 232, y: 262, w: 836, h: 218 };
const plotX = CHART.x + 28;
const plotW = CHART.w - 56;
const plotBottom = CHART.y + CHART.h - 26;
const plotH = 140;
const slot = plotW / BARS.length;
export const barRect = (i: number) => {
  const h = (BARS[i] / 100) * plotH;
  return { x: plotX + i * slot + slot * 0.22, y: plotBottom - h, w: slot * 0.56, h };
};

const ink = '#16163a';
const muted = '#6b6f86';
const line = '#ececf3';

const Card: React.FC<{ x: number; label: string; value: string; delta: string; up: boolean }> = ({ x, label, value, delta, up }) => (
  <div
    style={{
      position: 'absolute', left: x, top: 140, width: 268, height: 104,
      border: `1px solid ${line}`, borderRadius: 14, padding: '16px 18px', boxSizing: 'border-box', background: '#fff',
    }}
  >
    <div style={{ fontSize: 13, color: muted, fontWeight: 500 }}>{label}</div>
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 8 }}>
      <div style={{ fontSize: 30, fontWeight: 700, color: ink, letterSpacing: -0.6 }}>{value}</div>
      <div
        style={{
          fontSize: 12, fontWeight: 600, padding: '3px 8px', borderRadius: 999,
          color: up ? '#13804a' : '#b4372c', background: up ? '#e3f6eb' : '#fbe6e3',
        }}
      >
        {delta}
      </div>
    </div>
  </div>
);

const rows = [
  { name: 'Maya Lindqvist', email: 'maya@northpeak.io', plan: 'Team', amount: '$1,240' },
  { name: 'Tomas Okafor', email: 'tomas.okafor@fieldnote.co', plan: 'Business', amount: '$3,980' },
  { name: 'Lena Varga', email: 'lena@brightloom.app', plan: 'Team', amount: '$860' },
];

export const FakeApp: React.FC<{ blurRow?: number; blurAmount?: number }> = ({ blurRow = -1, blurAmount = 0 }) => (
  <div
    style={{
      position: 'relative', width: APP_W, height: APP_H, background: '#fff', overflow: 'hidden',
      fontFamily: 'Inter, sans-serif', color: ink,
    }}
  >
    {/* Title bar */}
    <div style={{ position: 'absolute', left: 0, top: 0, width: APP_W, height: 44, background: '#f6f6f9', borderBottom: `1px solid ${line}` }}>
      {['#ff5f57', '#febc2e', '#28c840'].map((c, i) => (
        <div key={c} style={{ position: 'absolute', left: 16 + i * 20, top: 16, width: 12, height: 12, borderRadius: 6, background: c }} />
      ))}
      <div
        style={{
          position: 'absolute', left: 400, top: 9, width: 300, height: 26, borderRadius: 8, background: '#fff',
          border: `1px solid ${line}`, fontSize: 12, color: muted, display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}
      >
        orbit.app/revenue
      </div>
    </div>

    {/* Sidebar */}
    <div style={{ position: 'absolute', left: 0, top: 44, width: 200, height: APP_H - 44, background: '#fafafc', borderRight: `1px solid ${line}` }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '22px 22px 18px' }}>
        <div style={{ width: 26, height: 26, borderRadius: 8, background: 'linear-gradient(135deg,#5b5bf0,#9b6bff)' }} />
        <div style={{ fontSize: 18, fontWeight: 700 }}>Orbit</div>
      </div>
      {['Overview', 'Revenue', 'Customers', 'Reports', 'Settings'].map((t) => (
        <div
          key={t}
          style={{
            margin: '2px 12px', padding: '9px 12px', borderRadius: 8, fontSize: 14, fontWeight: t === 'Revenue' ? 600 : 500,
            color: t === 'Revenue' ? ink : muted, background: t === 'Revenue' ? '#ececf6' : 'transparent',
          }}
        >
          {t}
        </div>
      ))}
    </div>

    {/* Header */}
    <div style={{ position: 'absolute', left: 232, top: 70 }}>
      <div style={{ fontSize: 26, fontWeight: 700, letterSpacing: -0.5 }}>Revenue</div>
      <div style={{ fontSize: 13, color: muted, marginTop: 2 }}>Last 12 months</div>
    </div>
    <div
      style={{
        position: 'absolute', right: 32, top: 78, padding: '8px 14px', borderRadius: 9, background: ink, color: '#fff', fontSize: 13, fontWeight: 600,
      }}
    >
      Export
    </div>

    <Card x={232} label="Monthly revenue" value="$48,210" delta="+18.2%" up />
    <Card x={516} label="Active customers" value="1,284" delta="+6.1%" up />
    <Card x={800} label="Churn" value="3.6%" delta="+0.4%" up={false} />

    {/* Chart */}
    <div style={{ position: 'absolute', left: CHART.x, top: CHART.y, width: CHART.w, height: CHART.h, border: `1px solid ${line}`, borderRadius: 14, boxSizing: 'border-box' }}>
      <div style={{ position: 'absolute', left: 18, top: 14, fontSize: 13, fontWeight: 600 }}>Revenue by month</div>
    </div>
    {[0, 1, 2, 3].map((g) => (
      <div key={g} style={{ position: 'absolute', left: plotX, top: plotBottom - g * 46, width: plotW, height: 1, background: line }} />
    ))}
    {BARS.map((_, i) => {
      const r = barRect(i);
      return (
        <div
          key={i}
          style={{
            position: 'absolute', left: r.x, top: r.y, width: r.w, height: r.h, borderRadius: '6px 6px 2px 2px',
            background: i === BEST ? '#5b5bf0' : '#d9d9f6',
          }}
        />
      );
    })}
    {['J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D'].map((m, i) => (
      <div key={i} style={{ position: 'absolute', left: plotX + i * slot, width: slot, top: plotBottom + 6, textAlign: 'center', fontSize: 11, color: muted }}>
        {m}
      </div>
    ))}

    {/* Table */}
    <div style={{ position: 'absolute', left: 232, top: 500, width: 836 }}>
      <div style={{ display: 'flex', fontSize: 12, color: muted, fontWeight: 600, padding: '0 18px 10px', borderBottom: `1px solid ${line}` }}>
        <div style={{ width: 230 }}>Customer</div>
        <div style={{ width: 320 }}>Email</div>
        <div style={{ width: 140 }}>Plan</div>
        <div style={{ flex: 1, textAlign: 'right' }}>Amount</div>
      </div>
      {rows.map((r, i) => (
        <div key={r.name} style={{ display: 'flex', alignItems: 'center', fontSize: 14, height: 48, padding: '0 18px', borderBottom: `1px solid ${line}` }}>
          <div style={{ width: 230, fontWeight: 600 }}>{r.name}</div>
          <div style={{ width: 320, color: muted, filter: i === blurRow && blurAmount > 0 ? `blur(${blurAmount}px)` : undefined }}>{r.email}</div>
          <div style={{ width: 140 }}>
            <span style={{ fontSize: 12, fontWeight: 600, padding: '3px 9px', borderRadius: 999, background: '#f0f0f7' }}>{r.plan}</span>
          </div>
          <div style={{ flex: 1, textAlign: 'right', fontWeight: 600 }}>{r.amount}</div>
        </div>
      ))}
    </div>
  </div>
);

// Email cell of a table row, in app coordinates.
export const emailCell = (row: number) => ({ x: 232 + 18 + 230 - 8, y: 500 + 31 + row * 48 + 6, w: 236, h: 36 });
