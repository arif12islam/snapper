import React from 'react';

// Simple stroked toolbar glyphs drawn on a 24 unit grid.
const paths: Record<string, React.ReactNode> = {
  undo: <path d="M9 14L4 9l5-5M4 9h10a6 6 0 0 1 0 12h-3" />,
  redo: <path d="M15 14l5-5-5-5M20 9H10a6 6 0 0 0 0 12h3" />,
  select: <path d="M6 3l12 9-5.5 1.2L15 19l-2.4 1-2.6-5.6L6 18z" fill="currentColor" stroke="none" />,
  crop: <path d="M7 2v15h15M2 7h15v15" />,
  arrow: <path d="M5 19L19 5M10 5h9v9" />,
  line: <path d="M5 19L19 5" />,
  rect: <rect x="4.5" y="4.5" width="15" height="15" rx="1.5" />,
  pen: <path d="M5 20L12 4l7 16M8.5 13h7" />,
  marker: <path d="M14 4l6 6-9 9H5v-6zM4 21h16" />,
  text: (
    <text x="12" y="17" textAnchor="middle" fontSize="14" fontWeight="500" fill="currentColor" stroke="none" fontFamily="Inter, sans-serif">
      Aa
    </text>
  ),
  counter: (
    <g>
      <circle cx="12" cy="12" r="9" />
      <path d="M10 8l-1.2 8M15.2 8L14 16M8 10.5h8.5M7.5 13.5h8.5" strokeWidth="1.4" />
    </g>
  ),
  magnifier: <path d="M10.5 3a7.5 7.5 0 1 1 0 15 7.5 7.5 0 0 1 0-15zM16 16l5 5M10.5 7.5v6M7.5 10.5h6" />,
  spotlight: <path d="M9 3h6l-1 6h-4zM10 9h4v12h-4z" />,
  blur: (
    <g fill="currentColor" stroke="none">
      {[5, 10, 15].flatMap((y) => [5, 10, 15].map((x) => <rect key={`${x}${y}`} x={x} y={y} width="4" height="4" rx="1" />))}
    </g>
  ),
  drop: <path d="M12 3s6 7 6 11a6 6 0 0 1-12 0c0-4 6-11 6-11z" />,
  trash: <path d="M5 7h14M10 7V4h4v3M7 7l1 13h8l1-13" />,
  rotate: <path d="M5 9h10v10H5zM14 4a5 5 0 0 1 5 5M17 7l2 2 2-2" />,
  flip: <path d="M12 3v18M9 6L4 18h5zM15 6l5 12h-5z" />,
  zoomOut: <path d="M10.5 3a7.5 7.5 0 1 1 0 15 7.5 7.5 0 0 1 0-15zM16 16l5 5M7.5 10.5h6" />,
  zoomIn: <path d="M10.5 3a7.5 7.5 0 1 1 0 15 7.5 7.5 0 0 1 0-15zM16 16l5 5M10.5 7.5v6M7.5 10.5h6" />,
  expand: <path d="M14 4h6v6M10 20H4v-6M20 4l-7 7M4 20l7-7" />,
  image: <path d="M3 5h18v14H3zM3 16l5-5 4 4 3-3 6 6" />,
  chevron: <path d="M7 10l5 5 5-5" />,
  link: <path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1" />,
  check: <path d="M5 12.5l4.5 4.5L19 7" />,
};

export const Icon: React.FC<{ name: string; size?: number; color?: string; width?: number }> = ({ name, size = 22, color = 'currentColor', width = 1.8 }) => (
  <svg
    width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={width}
    strokeLinecap="round" strokeLinejoin="round" style={{ color, display: 'block' }}
  >
    {paths[name]}
  </svg>
);
