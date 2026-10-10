import React from "react";
import { AbsoluteFill, interpolate, Sequence, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { Fold, Ic, Sprite } from "./Icons";
import { Panel } from "./hero/Panel";
import { fadeVal, L, snapAt, timeline } from "./hero/timeline";
import "./hero/hero.css";
import "./video.css";

export const FPS = 30;
const TITLE = 78;   // frames of title card before the hero starts
const END = 96;     // frames of end card
const XFADE = 12;   // frames of cross-fade between cards

export const heroFrames = () => Math.ceil((timeline().end / 1000) * FPS);
export const totalFrames = () => TITLE + heroFrames() + END;

export type Theme = "light" | "dark";
export type Shape = "landscape" | "square";

interface Layout {
  w: number; h: number;
  scale: number;       // panel scale (the panel is 760 px wide at 1x)
  panelTop: number;
  capTop: number; capH: number; capSize: number;
  segY: number; seg: { w: number; h: number; gap: number };
  brandY: number; brandSize: number;
  title: { mark: number; name: number; line: number; lead: number; gap: number };
  end: { mark: number; url: number; btn: number; note: number; gap: number };
}
const LAYOUTS: Record<Shape, Layout> = {
  landscape: {
    w: 1920, h: 1080, scale: 2.1, panelTop: 104, capTop: 790, capH: 150, capSize: 64,
    segY: 1012, seg: { w: 52, h: 7, gap: 10 }, brandY: 40, brandSize: 40,
    title: { mark: 170, name: 120, line: 64, lead: 34, gap: 28 },
    end: { mark: 150, url: 112, btn: 40, note: 30, gap: 34 },
  },
  square: {
    w: 1080, h: 1080, scale: 1.3, panelTop: 262, capTop: 700, capH: 210, capSize: 54,
    segY: 972, seg: { w: 40, h: 6, gap: 9 }, brandY: 96, brandSize: 50,
    title: { mark: 150, name: 104, line: 62, lead: 32, gap: 26 },
    end: { mark: 140, url: 96, btn: 38, note: 28, gap: 30 },
  },
};

const rise = (frame: number, delay: number, fps: number) => {
  const s = spring({ frame: frame - delay, fps, config: { damping: 200 }, durationInFrames: 22 });
  return { opacity: s, transform: `translateY(${(1 - s) * 22}px)` };
};

const TitleCard: React.FC<{ lay: Layout }> = ({ lay }) => {
  const frame = useCurrentFrame(), { fps } = useVideoConfig(), t = lay.title;
  const mark = spring({ frame, fps, config: { damping: 14, stiffness: 120 }, durationInFrames: 30 });
  return (
    <div className="vc-card" style={{ gap: t.gap }}>
      <div style={{ opacity: Math.min(1, mark * 1.4), transform: `scale(${0.7 + 0.3 * mark})` }}><Fold size={t.mark} /></div>
      <h2 style={{ fontSize: t.name, fontWeight: 600, letterSpacing: "-.02em", lineHeight: 1, ...rise(frame, 8, fps) }}>Varnick</h2>
      <h1 style={{ fontSize: t.line, fontWeight: 600, letterSpacing: "-.015em", lineHeight: 1.12, maxWidth: "15em", ...rise(frame, 16, fps) }}>
        Your Claude sessions, one keystroke away
      </h1>
      <p style={{ fontSize: t.lead, lineHeight: 1.45, color: "var(--muted)", maxWidth: "22em", ...rise(frame, 26, fps) }}>
        A floating panel for Claude Code, terminals and every page you’ve visited.
      </p>
    </div>
  );
};

const EndCard: React.FC<{ lay: Layout }> = ({ lay }) => {
  const frame = useCurrentFrame(), { fps } = useVideoConfig(), e = lay.end;
  const mark = spring({ frame, fps, config: { damping: 14, stiffness: 120 }, durationInFrames: 30 });
  return (
    <div className="vc-card" style={{ gap: e.gap }}>
      <div style={{ opacity: Math.min(1, mark * 1.4), transform: `scale(${0.7 + 0.3 * mark})` }}><Fold size={e.mark} /></div>
      <h2 style={{ fontSize: e.url, fontWeight: 600, letterSpacing: "-.02em", lineHeight: 1, ...rise(frame, 6, fps) }}>varnick.com</h2>
      <div className="vc-btn" style={{ fontSize: e.btn, gap: ".55em", padding: ".62em 1.4em", ...rise(frame, 14, fps) }}>
        <Ic id="i-down" />Free download for Mac
      </div>
      <p style={{ fontSize: e.note, color: "var(--muted)", ...rise(frame, 22, fps) }}>macOS 14+, Apple Silicon</p>
    </div>
  );
};

const Caption: React.FC<{ ms: number; lay: Layout }> = ({ ms, lay }) => {
  const s = snapAt(timeline(), ms), c = s.cap;
  if (!c.key && !c.text) return null;
  const v = fadeVal(c, ms);
  const pop = c.on ? ms - c.at : 1e9;
  return (
    <div className="vc-cap" style={{ top: lay.capTop, height: lay.capH, fontSize: lay.capSize, opacity: v, transform: `translateY(${(1 - v) * 10 * (lay.capSize / 20)}px)` }}>
      <span className="ha-k" style={{ animationName: "ha-key", animationDuration: "500ms", animationTimingFunction: "cubic-bezier(.2,1.3,.4,1)", animationPlayState: "paused", animationDelay: `-${pop}ms` }}>
        {c.key?.icon ? <Ic id={c.key.icon} /> : c.key?.text}
      </span>
      <span className="vc-txt">{c.text}</span>
    </div>
  );
};

const Segs: React.FC<{ ms: number; lay: Layout }> = ({ ms, lay }) => {
  const cur = snapAt(timeline(), ms).seg, g = lay.seg;
  return (
    <div className="vc-segs" style={{ top: lay.segY, gap: g.gap }}>
      {Array.from({ length: 7 }, (_, i) => (
        <i key={i} className={i < cur ? "done" : i === cur ? "cur" : ""} style={{ width: g.w, height: g.h }} />
      ))}
    </div>
  );
};

const Demo: React.FC<{ lay: Layout; shape: Shape }> = ({ lay, shape }) => {
  const frame = useCurrentFrame();
  const ms = (frame / FPS) * 1000;
  const left = (lay.w - L.appW * lay.scale) / 2;
  return (
    <div className="vc-stage">
      {shape === "square" && (
        <div className="vc-brand" style={{ top: lay.brandY, left: 0, right: 0, justifyContent: "center", gap: lay.brandSize * 0.35, fontSize: lay.brandSize }}>
          <Fold size={lay.brandSize * 1.05} />Varnick
        </div>
      )}
      <div className="vc-panel" style={{ left, top: lay.panelTop, transform: `scale(${lay.scale})` }}><Panel ms={ms} /></div>
      <Caption ms={ms} lay={lay} />
      <Segs ms={ms} lay={lay} />
    </div>
  );
};

const fadeWindow = (frame: number, from: number, to: number, fadeIn: boolean, fadeOut: boolean) =>
  Math.min(
    fadeIn ? interpolate(frame, [from, from + XFADE], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }) : 1,
    fadeOut ? interpolate(frame, [to - XFADE, to], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }) : 1,
  );

export const Video: React.FC<{ shape: Shape; theme: Theme }> = ({ shape, theme }) => {
  const frame = useCurrentFrame();
  const lay = LAYOUTS[shape], H = heroFrames();
  const heroFrom = TITLE, heroTo = TITLE + H, endFrom = heroTo - XFADE;
  return (
    <AbsoluteFill className="vc" style={{ colorScheme: theme }}>
      <Sprite />
      {frame < TITLE + XFADE && (
        <AbsoluteFill style={{ opacity: fadeWindow(frame, 0, TITLE + XFADE, false, true) }}><TitleCard lay={lay} /></AbsoluteFill>
      )}
      {frame >= heroFrom && frame < heroTo + XFADE && (
        <AbsoluteFill style={{ opacity: fadeWindow(frame, heroFrom, heroTo + XFADE, true, true) }}>
          <ShiftedFrame by={heroFrom}><Demo lay={lay} shape={shape} /></ShiftedFrame>
        </AbsoluteFill>
      )}
      {frame >= endFrom && (
        <AbsoluteFill style={{ opacity: fadeWindow(frame, endFrom, 1e9, true, false) }}>
          <ShiftedFrame by={endFrom}><EndCard lay={lay} /></ShiftedFrame>
        </AbsoluteFill>
      )}
    </AbsoluteFill>
  );
};

// A layer's own clock starts at its first frame; the layers overlap and share one opacity ramp, so <Sequence> only shifts time.
const ShiftedFrame: React.FC<{ by: number; children: React.ReactNode }> = ({ by, children }) => (
  <Sequence from={by} layout="none">{children}</Sequence>
);
