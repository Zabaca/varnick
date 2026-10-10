// The page's icon sprite (site/src/page.html), rendered once per composition and referenced with <use>.
import React from "react";

const SYMBOLS = `
  <symbol id="i-sparkle" viewBox="0 0 24 24"><path d="M12 3l2 6.5L20.5 12 14 14.5 12 21l-2-6.5L3.5 12 10 9.5z" style="fill:currentColor;stroke:none"/></symbol>
  <symbol id="i-search" viewBox="0 0 24 24"><circle cx="11" cy="11" r="6.5"/><path d="M16 16l5 5"/></symbol>
  <symbol id="i-wave" viewBox="0 0 24 24"><path d="M4 10v4M8 7v10M12 4v16M16 8v8M20 11v2"/></symbol>
  <symbol id="i-align" viewBox="0 0 24 24"><path d="M4 6h16M4 10.7h10M4 15.3h16M4 20h10"/></symbol>
  <symbol id="i-split3" viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="14" rx="3"/><path d="M9 5v14M15 5v14"/></symbol>
  <symbol id="i-tray" viewBox="0 0 24 24"><path d="M3 13l2.6-7h12.8L21 13v5a1.6 1.6 0 0 1-1.6 1.6H4.6A1.6 1.6 0 0 1 3 18z"/><path d="M3 13h5l1 2.2h6L16 13h5M9 9.5h6"/></symbol>
  <symbol id="i-desktop" viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M9 20h6M12 16v4"/></symbol>
  <symbol id="i-folder" viewBox="0 0 24 24"><path d="M3.5 7a2 2 0 0 1 2-2H10l2 2.5h6.5a2 2 0 0 1 2 2V17.5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"/></symbol>
  <symbol id="i-person" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="10" r="3"/><path d="M6.4 18.2c1.3-2.3 3.2-3.4 5.6-3.4s4.300 1.100 5.600 3.400"/></symbol>
  <symbol id="i-down" viewBox="0 0 24 24"><path d="M12 4v11m0 0l-4.5-4.5M12 15l4.5-4.5M5 20h14"/></symbol>
`;

export const Sprite: React.FC = () => (
  <svg width="0" height="0" style={{ position: "absolute" }} aria-hidden="true" focusable="false"
    dangerouslySetInnerHTML={{ __html: SYMBOLS }} />
);

export const Ic: React.FC<{ id: string; className?: string }> = ({ id, className = "" }) => (
  <svg className={`ic ${className}`} aria-hidden="true"><use href={`#${id}`} /></svg>
);

// The Fold mark, from the page's header.
export const Fold: React.FC<{ size: number; color?: string }> = ({ size, color = "var(--accent)" }) => (
  <svg viewBox="0 0 64 64" width={size} height={size} aria-hidden="true" style={{ display: "block", color }}>
    <path d="M6 4.5L24 4.5L30.25 27.94L30.25 51.13ZM58 11.5L40 11.5L33.75 34.94L33.75 58.13Z" fill="currentColor" />
  </svg>
);
