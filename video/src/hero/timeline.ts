// The hero script from site/src/page.html ("Animated hero"), replayed on a virtual clock.
// The page awaits timers; here every wait just advances `clock`, and every change to the panel is
// recorded as a snapshot. A frame then reads the snapshot at its time, so renders are frame-exact.
import {
  AGENTS, commands, dur, FIND_MSG, lead, MESSAGE, PEERS, PROJECTS, RES_FIND, RES_FIND_PARTIAL, RES_FINAL,
  RES_PARTIAL, suggestions, TAB_AUTH, TAB_NEW, TAB_RENAME, type Result, type Tab,
} from "./data";

export type View = "prompt" | "claude" | "board";
export type ColKey = "run" | "stop" | "done";

// One row of the prompt-mode list. `k` is the page's patch key; the rest is what the row shows.
export type PItem = { k: string } & (
  | { type: "hr"; sp4?: boolean }
  | { type: "lab"; text: string }
  | { type: "sp8" }
  | { type: "tab"; t: string; p: string[]; s: string; sel: boolean }
  | { type: "cmd"; id: string; sym: string; title: string; detail: string; sel: boolean; press: boolean }
  | { type: "prow"; peer?: string; proj?: string; agent?: string; sub: string; sel: boolean; press: boolean }
  | { type: "srow"; tok: string; icon: string; detail: string; tag: string; sel: boolean; press: boolean }
  | { type: "sess"; t: string; p: string[]; detail: string; open: boolean; hint: null | { label: string; press: boolean }; sel: boolean }
);

// A row as it sits in the page's DOM: `at` is when its element was created, `anim` whether it got the
// "new" class (rows replaced in place don't animate).
export interface DomItem { item: PItem; at: number; anim: boolean }

export interface Fade { on: boolean; at: number; from: number }
export interface BCard {
  id: string; t: string; p: string[]; verb: string; since: number; done: boolean; shownAt: number;
  inBoard: boolean; landAt: number | null; glow: Fade; mkAt: number | null; flyAt: number | null;
}
export interface BoardS {
  cards: Record<string, BCard>;
  cols: Record<ColKey, string[]>;
  hit: Fade;
  flip: { at: number; before: Record<string, { col: ColKey; idx: number }> } | null;
}
export interface CapKey { icon?: string; text?: string }
export interface CapS { key: CapKey | null; text: string; on: boolean; from: number; at: number }
export interface ClaudeS { name: string; pills: string[]; lines: { html: string; at: number }[] }

export interface Snap {
  t: number;
  q: string;
  barAt: number;
  view: View;
  viewAt: number;
  dom: DomItem[];
  claude: ClaudeS | null;
  board: BoardS;
  cap: CapS;
  seg: number;
  h: number;
}
export interface HSeg { at: number; from: number; to: number }
export interface Timeline { snaps: Snap[]; hsegs: HSeg[]; end: number }

// ---------- layout constants (px at 1x, the app's own sizes) ----------
export const L = {
  bar: 56, hr: 1, hrSp4: 4, lab: 30, row: 44, srow: 40, prow: 76, sp8: 8,
  claude: 36 + 1 + 200,
  boardHead: 56 + 1, bcolsPad: 12, bch: 30, bcardsPadTop: 4, bcardsPadBot: 8, gap: 6,
  cardH: 75, emptyH: 61, border: 2,
  bcolsGutter: 8, bcolsPadX: 6, appW: 760,
};

export const FADE_MS = 280;
export const ease = (x: number) => { // CSS "ease"
  x = Math.min(1, Math.max(0, x));
  return cubic(0.25, 0.1, 0.25, 1, x);
};
export function cubic(x1: number, y1: number, x2: number, y2: number, x: number): number {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  const sampleX = (t: number) => 3 * x1 * t * (1 - t) ** 2 + 3 * x2 * t * t * (1 - t) + t ** 3;
  const sampleY = (t: number) => 3 * y1 * t * (1 - t) ** 2 + 3 * y2 * t * t * (1 - t) + t ** 3;
  let lo = 0, hi = 1, t = x;
  for (let i = 0; i < 40; i++) {
    const v = sampleX(t);
    if (Math.abs(v - x) < 1e-6) break;
    if (v < x) lo = t; else hi = t;
    t = (lo + hi) / 2;
  }
  return sampleY(t);
}
export const fadeVal = (f: Fade, t: number, ms = FADE_MS) => f.from + ((f.on ? 1 : 0) - f.from) * ease((t - f.at) / ms);

function promptHeight(items: PItem[]): number {
  let h = L.bar;
  for (const it of items) {
    h += it.type === "hr" ? (it.sp4 ? L.hrSp4 : L.hr) : it.type === "lab" ? L.lab : it.type === "sp8" ? L.sp8
      : it.type === "prow" ? L.prow : it.type === "srow" ? L.srow : L.row;
  }
  // A last prow's bottom margin collapses out of the panel.
  if (items[items.length - 1]?.type === "prow") h -= 6;
  return h;
}
function boardHeight(b: BoardS): number {
  const col = (k: ColKey) => {
    const n = b.cols[k].length;
    return L.bch + L.bcardsPadTop + L.bcardsPadBot + (n ? n * L.cardH + (n - 1) * L.gap : L.emptyH);
  };
  return L.boardHead + L.bcolsPad + Math.max(col("run"), col("stop"), col("done"));
}

interface PState { q: string; over: null | "claude" | "board"; press: string | null; starting: boolean; settled: boolean; sel: number | null; tabs: Tab[] }

function promptItems(S: PState): PItem[] {
  const q = S.q, items: PItem[] = [];
  const hr = (k: string): PItem => ({ k, type: "hr" });
  const sp4 = (k: string): PItem => ({ k, type: "hr", sp4: true });
  if (!q) {
    if (S.tabs.length) {
      items.push(hr("h0"), { k: "labT", type: "lab", text: "Tabs" });
      S.tabs.forEach((t, i) => items.push({ k: "tab" + t.t, type: "tab", t: t.t, p: t.p, s: t.s, sel: i === 0 }));
      items.push({ k: "pb", type: "sp8" });
    }
  } else if (q[0] === "!") {
    const cs = commands(q);
    items.push(hr("h0"), sp4("sp0"));
    cs.forEach((c, i) => items.push({ k: "c" + c.id, type: "cmd", id: c.id, sym: c.sym, title: c.title, detail: c.detail, sel: i === 0, press: i === 0 && S.press === "cmd" }));
    items.push(sp4("sp1"));
  } else {
    const { words, rest } = lead(q);
    const peer = words.map((w) => w[0] === "^" && PEERS.find((p) => p.h === w.slice(1).toLowerCase())).find(Boolean) || undefined;
    const proj = words.map((w) => w[0] === "#" && PROJECTS.find((p) => p.n === w.slice(1).toLowerCase())).find(Boolean) || undefined;
    const agent = words.map((w) => w[0] === "@" && AGENTS.find((a) => a.n === w.slice(1).toLowerCase())).find(Boolean) || undefined;
    const sub = S.starting && peer ? `Starting on ${peer.n}…` : rest || "Start an interactive session";
    items.push(hr("h0"), {
      k: "pl", type: "prow", peer: peer && "^" + peer.h, proj: proj && "#" + proj.n, agent: agent && "@" + agent.n,
      sub, sel: S.sel == null, press: S.sel == null && S.press === "start",
    });
    const sg = suggestions(q);
    if (sg.length) {
      items.push(hr("h1"), sp4("sp0"));
      sg.forEach((s, i) => items.push({ k: "s" + s.tok, type: "srow", tok: s.tok, icon: s.icon, detail: s.detail, tag: s.tag, sel: i === 0, press: i === 0 && S.press === "use" }));
      items.push(sp4("sp1"));
    } else if (rest.length >= 6) {
      const res: Result[] = rest === FIND_MSG ? (S.settled ? RES_FIND : RES_FIND_PARTIAL) : FIND_MSG.startsWith(rest) ? RES_FIND_PARTIAL : rest === MESSAGE && S.settled ? RES_FINAL : RES_PARTIAL;
      items.push(hr("h1"), { k: "lab", type: "lab", text: "Sessions" });
      res.forEach((r, i) => items.push({
        k: "r" + r.t, type: "sess", t: r.t, p: r.p, detail: "Last used " + r.ago, open: !!r.open, sel: S.sel === i,
        hint: S.sel === i ? { label: r.open ? "Open" : "Resume", press: S.press === "resume" } : null,
      }));
      items.push({ k: "pb", type: "sp8" });
    }
  }
  return items;
}

export function buildTimeline(tail = 1800): Timeline {
  let clock = 0;
  const snaps: Snap[] = [];
  const W = (ms: number) => { clock += ms; };

  let S: PState = { q: "", over: null, press: null, starting: false, settled: false, sel: null, tabs: [TAB_RENAME] };
  let dom = new Map<string, DomItem>();
  let view: View = "prompt", viewAt = -1e9, barAt = 0, seg = -1;
  let claude: ClaudeS | null = null;
  let cap: CapS = { key: null, text: "", on: false, from: 0, at: -1e9 };

  const mkCard = (id: string, t: string, p: string[], verb: string, base: number, col: ColKey): BCard & { col: ColKey } => ({
    id, t, p, verb, since: -base * 1000, done: false, shownAt: 0, inBoard: false, landAt: null,
    glow: { on: false, at: -1e9, from: 0 }, mkAt: null, flyAt: null, col,
  });
  const cards = {
    rename: mkCard("rename", "Rename the billing module", ["#shop-api"], "Working", 128, "run"),
    auth: mkCard("auth", "Auth callback keeps bouncing back to sign-in", ["#shop-api"], "Waiting", 48, "stop"),
    fresh: mkCard("fresh", MESSAGE, ["^studio", "#shop-api", "@reviewer"], "Working", 0, "run"),
  };
  const board: BoardS = { cards: {}, cols: { run: [], stop: [], done: [] }, hit: { on: false, at: -1e9, from: 0 }, flip: null };
  const colOf: Record<string, ColKey> = { rename: "run", auth: "stop", fresh: "run" };

  const positions = () => {
    const out: Record<string, { col: ColKey; idx: number }> = {};
    (["run", "stop", "done"] as ColKey[]).forEach((c) => board.cols[c].forEach((id, idx) => { out[id] = { col: c, idx }; }));
    return out;
  };
  const addCard = (id: keyof typeof cards, landing = false) => {
    const { col, ...c } = cards[id];
    board.cards[id] = { ...c, inBoard: true, shownAt: clock };
    board.cols[col].push(id);
    colOf[id] = col;
    if (landing) { board.cards[id].landAt = clock; board.cards[id].glow = { on: true, at: -1e9, from: 1 }; }
  };
  const turnText = (id: string) => { board.cards[id].shownAt = clock; };
  const moveCard = (id: string, col: ColKey) => {
    const before = positions();
    board.cols[colOf[id]] = board.cols[colOf[id]].filter((x) => x !== id);
    board.cols[col].push(id);
    colOf[id] = col;
    board.cards[id].flyAt = clock;
    board.flip = { at: clock, before };
  };
  const setFade = (f: Fade, on: boolean): Fade => ({ on, at: clock, from: fadeVal(f, clock) });

  function commit() {
    const items = [...dom.values()];
    const h = (view === "prompt" ? promptHeight(items.map((d) => d.item)) : view === "claude" ? L.claude : boardHeight(board)) + L.border;
    snaps.push(structuredClone({ t: clock, q: S.q, barAt, view, viewAt, dom: items, claude, board, cap, seg, h }) as Snap);
  }
  function patchDom(items: PItem[]) {
    const next = new Map<string, DomItem>();
    for (const it of items) {
      const e = dom.get(it.k), h = JSON.stringify(it);
      if (e && JSON.stringify(e.item) === h) next.set(it.k, e);
      else if (e) next.set(it.k, { item: it, at: clock, anim: false });
      else next.set(it.k, { item: it, at: clock, anim: true });
    }
    dom = next;
  }
  function render() {
    barAt = clock;
    if (S.over) { if (view !== S.over) { view = S.over; viewAt = clock; } } else {
      if (view !== "prompt") { view = "prompt"; viewAt = clock; }
      patchDom(promptItems(S));
    }
    commit();
  }
  const setSeg = (i: number) => { seg = i; commit(); };
  function doCap(key: CapKey, text: string) {
    if (cap.on) { cap = { ...cap, ...setFade({ on: cap.on, at: cap.at, from: cap.from }, false) }; commit(); W(180); }
    cap = { key, text, ...setFade({ on: cap.on, at: cap.at, from: cap.from }, true) };
    commit();
  }
  function type(str: string, base = 62) {
    for (const ch of str) { S.q += ch; render(); W(base + ((ch.charCodeAt(0) * 13) % 34) - 10); }
  }
  function press(kind: string, ms = 380) { S.press = kind; render(); W(ms); S.press = null; }
  function complete() {
    const { words } = lead(S.q), w = words[words.length - 1], s = suggestions(S.q)[0];
    S.q = S.q.slice(0, S.q.length - w.length) + s.tok + " "; render();
  }
  function suggestScene(i: number, key: CapKey, text: string, typed: string) {
    setSeg(i);
    doCap(key, text);
    W(220);
    type(typed[0], 0); W(i === 1 ? 800 : 650);
    type(typed.slice(1), 250); W(480);
    press("use", 330); complete(); W(300);
  }
  function showClaude(name: string, pills: string[]) {
    claude = { name, pills, lines: [] };
    S.over = "claude"; render();
  }
  function line(html: string, ms = 260) { claude!.lines.push({ html, at: clock }); commit(); W(ms); }

  // ---------- the timeline (loopOnce) ----------
  addCard("rename"); addCard("auth");
  render();

  W(800);

  // A: find a session by describing it
  setSeg(0);
  doCap({ icon: "i-sparkle" }, "Find any session by describing it");
  W(250);
  S.settled = false;
  type(FIND_MSG, 46);
  W(420); S.settled = true; render(); W(1700);
  S.sel = 0; render();
  doCap({ text: "↓ ↩" }, "picks a session and resumes it");
  W(500);
  press("resume", 480);
  showClaude(TAB_AUTH.t, ["#shop-api"]);
  line('<span class="o">· resumed</span>', 120);
  line("The cookie was dropped on the redirect from the sign-in provider.", 300);
  line('<span class="o">· edit auth/session.ts</span>   SameSite: Strict to Lax', 300);
  line('<span class="g">✓</span> 12 tests pass', 500);
  S.tabs = [TAB_RENAME, TAB_AUTH]; S.over = null; S.q = ""; S.sel = null; S.settled = false; render(); W(550);

  // B, C, D: the three words
  suggestScene(1, { text: "#" }, "picks the project", "#sh");
  suggestScene(2, { text: "@" }, "picks the agent", "@re");
  suggestScene(3, { text: "^" }, "picks the Mac it runs on", "^st");

  // E: the message, the matching sessions, Return
  setSeg(4);
  doCap({ text: "↩" }, "starts Claude there");
  W(150);
  S.settled = false;
  type(MESSAGE, 52);
  W(380); S.settled = true; render(); W(800);
  press("start", 420);
  S.starting = true; render(); W(750);
  showClaude(MESSAGE, ["^studio", "#shop-api", "@reviewer"]);
  line(`<span class="you">› ${MESSAGE}</span>`, 260);
  line('<span class="o">· read uploads/retry.test.ts</span>', 240);
  line('<span class="o">· read uploads/retry.ts</span>', 300);
  line("The two cases share one timer. The second starts before the first has cleared it.", 420);
  S.tabs = [TAB_RENAME, TAB_AUTH, TAB_NEW]; S.over = null; S.q = ""; S.starting = false; S.settled = false; render(); W(600);

  // F: a command
  setSeg(5);
  doCap({ text: "!" }, "runs a command");
  W(150);
  type("!", 0); W(1200);
  type("kanban", 105); W(380);
  press("cmd", 380);

  // G: the board
  setSeg(6);
  S.over = "board"; render();
  doCap({ icon: "i-split3" }, "Sessions by what Claude is doing");
  W(900);
  cards.fresh.since = clock; addCard("fresh", true); commit(); W(1300);
  board.cards.fresh.glow = setFade(board.cards.fresh.glow, false); commit();
  W(400);
  const rn = board.cards.rename; rn.verb = "Waiting"; rn.since = clock; turnText("rename"); rn.mkAt = clock;
  moveCard("rename", "stop"); commit(); W(1500);
  board.hit = setFade(board.hit, true); commit(); W(450);
  const au = board.cards.auth; au.done = true; au.since = clock; turnText("auth"); au.glow = setFade(au.glow, true);
  moveCard("auth", "done"); commit(); W(700);
  board.hit = setFade(board.hit, false); commit();
  W(tail);
  cap = { ...cap, ...setFade({ on: cap.on, at: cap.at, from: cap.from }, false) }; commit();
  const end = clock;

  // The panel's height follows its content with a .4s ease; a change mid-ease restarts from where it is.
  const hsegs: HSeg[] = [];
  let cur: HSeg = { at: -1e9, from: snaps[0].h, to: snaps[0].h };
  hsegs.push(cur);
  for (let i = 0; i < snaps.length; i++) {
    if (i + 1 < snaps.length && snaps[i + 1].t === snaps[i].t) continue;
    if (snaps[i].h !== cur.to) {
      cur = { at: snaps[i].t, from: heightAt(cur, snaps[i].t), to: snaps[i].h };
      hsegs.push(cur);
    }
  }
  return { snaps, hsegs, end };
}

const HEIGHT_MS = 400;
function heightAt(s: HSeg, t: number): number {
  return s.from + (s.to - s.from) * cubic(0.3, 0.7, 0.2, 1, (t - s.at) / HEIGHT_MS);
}

let memo: Timeline | null = null;
export function timeline(): Timeline { return (memo ??= buildTimeline()); }

export function snapAt(tl: Timeline, ms: number): Snap {
  let lo = 0, hi = tl.snaps.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (tl.snaps[mid].t <= ms) lo = mid; else hi = mid - 1;
  }
  return tl.snaps[lo];
}
export function panelHeight(tl: Timeline, ms: number): number {
  let lo = 0, hi = tl.hsegs.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (tl.hsegs[mid].at <= ms) lo = mid; else hi = mid - 1;
  }
  return heightAt(tl.hsegs[lo], ms);
}
export function cardText(c: BCard, ms: number): string {
  const u = Math.max(c.shownAt, Math.floor(ms / 1000) * 1000);
  const s = (u - c.since) / 1000;
  return c.done ? `Done ${dur(s)} ago` : `${c.verb} ${dur(s)}`;
}
export { PEERS };
