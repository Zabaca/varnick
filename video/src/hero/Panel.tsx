// The Varnick panel, drawn from one timeline snapshot. Markup and classes follow the page's hero script.
// The page's CSS animations are kept and seeked: paused, with a negative delay equal to the time since they began.
import React from "react";
import { Ic } from "../Icons";
import {
  type BCard, type BoardS, type ColKey, type DomItem, type PItem, type Snap, cardText, cubic, fadeVal, L, panelHeight, snapAt,
  timeline,
} from "./timeline";

const seek = (elapsedMs: number, durs: number[] = [0]): React.CSSProperties => ({
  animationPlayState: durs.map(() => "paused").join(", "),
  animationDelay: durs.map((d) => `${d - elapsedMs}ms`).join(", "),
});

const Pill: React.FC<{ t: string }> = ({ t }) => <span className="pill">{t}</span>;
const Tile: React.FC<{ id: string; cls?: string }> = ({ id, cls = "claude" }) => <span className={`tile ${cls}`}><Ic id={id} /></span>;
const Kh: React.FC<{ label: string; k: string; press?: boolean; ms: number; at: number }> = ({ label, k, press, ms, at }) => (
  <span className="kh"><span className="kl">{label}</span> <kbd className={press ? "press" : undefined} style={press ? seek(ms - at) : undefined}>{k}</kbd></span>
);

const Row: React.FC<{ d: DomItem; ms: number }> = ({ d, ms }) => {
  const it = d.item;
  const style: React.CSSProperties | undefined = d.anim && ms - d.at < 220 ? { animationName: "ha-in", animationDuration: "220ms", animationTimingFunction: "ease", animationFillMode: "both", ...seek(ms - d.at) } : undefined;
  const kh = (label: string, k: string, press = false) => <Kh label={label} k={k} press={press} ms={ms} at={d.at} />;
  switch (it.type) {
    case "hr": return <hr className={`hr${it.sp4 ? " sp4" : ""}`} style={style} />;
    case "sp8": return <div className="sp8" style={style} />;
    case "lab": return <div className="lab" style={style}>{it.text}</div>;
    case "tab":
      return (
        <div className={`row${it.sel ? " sel" : ""}`} style={style}><Tile id="i-sparkle" />
          <div className="stack"><div className="t1">{it.t}</div><div className="t2">{it.p.map((p) => <Pill key={p} t={p} />)}{it.s}</div></div>
          {it.sel && kh("Open", "↩")}</div>
      );
    case "cmd":
      return (
        <div className={`row${it.sel ? " sel" : ""}`} style={style}><Tile id={it.sym} cls="transcript" />
          <div className="stack"><div className="t1">{it.title}</div><div className="t2">{it.detail}</div></div>
          <span className="stag">!{it.id}</span>{it.sel && kh("Run", "↩", it.press)}</div>
      );
    case "prow":
      return (
        <div className={`prow${it.sel ? " sel" : ""}`} style={style}><Tile id="i-sparkle" />
          <div className="stack"><div className="t1b">Ask Claude Code {it.peer && <Pill t={it.peer} />}{it.proj && <Pill t={it.proj} />}{it.agent && <Pill t={it.agent} />}</div>
            <div className="t2">{it.sub}</div></div>
          {it.sel && kh("Start", "↩", it.press)}</div>
      );
    case "srow":
      return (
        <div className={`srow${it.sel ? " sel" : ""}`} style={style}><Ic id={it.icon} /><span className="stk">{it.tok}</span>
          <span className="sdet">{it.detail}</span><span className="stag">{it.tag}</span>{it.sel && kh("Use", "⇥", it.press)}</div>
      );
    case "sess":
      return (
        <div className={`row${it.hint ? " sel" : ""}`} style={style}><Tile id="i-sparkle" />
          <div className="stack"><div className="t1">{it.t}</div><div className="t2">{it.p.map((p) => <Pill key={p} t={p} />)}{it.detail}</div></div>
          {it.open && <span className="pill">open</span>}{it.hint && kh(it.hint.label, "↩", it.hint.press)}</div>
      );
  }
};

// Where a card sits inside the board, for the page's FLIP move.
const colW = (L.appW - 2 - 2 * L.bcolsPadX - 2 * L.bcolsGutter) / 3;
const COLS: [ColKey, string][] = [["run", "Running"], ["stop", "Stopped"], ["done", "Completed"]];
const colIdx = (c: ColKey) => COLS.findIndex(([k]) => k === c);

const Card: React.FC<{ c: BCard; board: BoardS; pos: { col: ColKey; idx: number }; ms: number }> = ({ c, board, pos, ms }) => {
  let dx = 0, dy = 0;
  const f = board.flip, was = f?.before[c.id];
  if (f && was) {
    const e = cubic(0.25, 0.8, 0.25, 1, (ms - f.at) / 750);
    dx = (colIdx(was.col) - colIdx(pos.col)) * (colW + L.bcolsGutter) * (1 - e);
    dy = (was.idx - pos.idx) * (L.cardH + L.gap) * (1 - e);
  }
  const fly = c.flyAt != null && ms - c.flyAt < 800;
  const g = fadeVal(c.glow, ms, 500);
  const style: React.CSSProperties = {
    background: `color-mix(in srgb, var(--m-sel) ${g * 100}%, var(--m-tile))`,
    borderColor: `color-mix(in srgb, color-mix(in srgb, var(--c-claude) 60%, transparent) ${g * 100}%, var(--m-hair))`,
    ...(c.landAt != null ? seek(ms - c.landAt) : null),
  };
  return (
    <div style={{ transform: dx || dy ? `translate(${dx}px, ${dy}px)` : undefined, position: "relative", zIndex: fly ? 2 : undefined }}>
      <div className={`bcard${c.landAt != null ? " landing" : ""}${fly ? " fly" : ""}`} style={style}>
        <div className="t1">{c.t}</div>
        <div className="bpills">{c.p.map((p) => <Pill key={p} t={p} />)}</div>
        <div className="bmeta"><span className="bt">{cardText(c, ms)}</span>
          {c.mkAt != null && <span className="mk pop" style={seek(ms - c.mkAt, [0, 450])}>Needs permission</span>}</div>
      </div>
    </div>
  );
};

const Board: React.FC<{ b: BoardS; ms: number }> = ({ b, ms }) => (
  <>
    <div className="bh"><Ic id="i-split3" /><b>Sessions</b><span className="t">Problems</span><span className="sp" />
      <span className="hint">
        <span className="kh"><span className="kl">Open</span> <kbd>↩</kbd></span>
        <span className="kh"><span className="kl">Switch</span> <kbd>⇥</kbd></span>
        <span className="kh"><span className="kl">Close</span> <kbd>esc</kbd></span>
      </span></div>
    <hr className="hr" />
    <div className="bcols">
      {COLS.map(([k, name]) => {
        const ids = b.cols[k];
        const need = ids.filter((id) => b.cards[id].mkAt != null).length;
        const hit = k === "done" ? fadeVal(b.hit, ms, 300) : 0;
        return (
          <div className="bcol" data-col={k} key={k} style={hit > 0 ? {
            background: `color-mix(in srgb, var(--c-claude) ${10 * hit}%, transparent)`,
            boxShadow: `inset 0 0 0 1.5px color-mix(in srgb, var(--c-claude) ${60 * hit}%, transparent)`,
          } : undefined}>
            <div className="bch"><i className={`cd ${k}`} />{name}<span className="cnt">{ids.length}</span>
              <span className="need">{k === "stop" && need ? `${need} need${need === 1 ? "s" : ""} permission` : ""}</span></div>
            <div className="bcards">
              {ids.length
                ? ids.map((id, idx) => <Card key={id} c={b.cards[id]} board={b} pos={{ col: k, idx }} ms={ms} />)
                : <div className="bempty">{k === "done" ? "Nothing marked done" : "No sessions"}</div>}
            </div>
          </div>
        );
      })}
    </div>
  </>
);

const Bar: React.FC<{ s: Snap; ms: number }> = ({ s, ms }) => {
  const mag = s.q[0] === "!";
  return (
    <div className="bar ha-bar"><Ic id={mag ? "i-search" : "i-sparkle"} className={mag ? "" : "claude"} />
      <span className="q">{s.q}<span className="caret" style={seek(ms - s.barAt)} />{!s.q && <span className="ph">{"Ask Claude Code…   ! commands"}</span>}</span></div>
  );
};

export const Panel: React.FC<{ ms: number }> = ({ ms }) => {
  const tl = timeline();
  const s = snapAt(tl, ms);
  const view = seek(ms - s.viewAt);
  return (
    <div className="mock" style={{ width: L.appW }}>
      <div className="app hero-app ha-app" data-view={s.view} style={{ width: L.appW, height: panelHeight(tl, ms) }}>
        <div className="ha-in">
          <Bar s={s} ms={ms} />
          <div className="hav hav-prompt" style={view}>
            {s.dom.map((d) => <Row key={d.item.k} d={d} ms={ms} />)}
          </div>
          <div className="hav hav-claude" style={view}>
            {s.claude && (
              <>
                <div className="hdr"><div className="tabs"><span className="tabx on">{s.claude.name}</span><span className="tabx">+</span></div>
                  {s.claude.pills.map((p) => <Pill key={p} t={p} />)}</div>
                <hr className="hr" />
                <div className="cpane">
                  {s.claude.lines.map((l, i) => <div key={i} style={seek(ms - l.at)} dangerouslySetInnerHTML={{ __html: l.html }} />)}
                </div>
              </>
            )}
          </div>
          <div className="hav hav-board" style={view}><Board b={s.board} ms={ms} /></div>
        </div>
      </div>
    </div>
  );
};

export type { PItem };
