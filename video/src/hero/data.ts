// Ported from the "Animated hero" script in site/src/page.html: made-up data, the prompt grammar and the ranking.

export interface Project { n: string; d: string; t: string }
export interface Agent { n: string; d: string; t: string }
export interface Peer { h: string; n: string; t: string }
export interface Command { id: string; names: string[]; sym: string; title: string; detail: string }
export interface Result { t: string; p: string[]; ago: string; open?: boolean }
export interface Tab { t: string; p: string[]; s: string }

export const PROJECTS: Project[] = [
  { n: "shop-api", d: "~/Projects/acme", t: "2 hours ago" },
  { n: "shop-admin", d: "~/Projects/acme", t: "last week" },
  { n: "notes-app", d: "~/Projects/personal", t: "yesterday" },
  { n: "dashboard", d: "~/Projects/acme", t: "3 weeks ago" },
];
export const AGENTS: Agent[] = [
  { n: "reviewer", d: "Reviews a change for bugs and style", t: "user" },
  { n: "planner", d: "Turns a goal into small steps", t: "project" },
  { n: "researcher", d: "Reads docs and code, reports what it finds", t: "user" },
  { n: "refactorer", d: "Restructures code without changing behaviour", t: "user" },
];
export const PEERS: Peer[] = [
  { h: "studio", n: "Studio", t: "studio.local" },
  { h: "laptop", n: "Laptop", t: "laptop.local" },
  { h: "mini", n: "Mac mini", t: "mini.local" },
  { h: "staging", n: "Staging", t: "Keep sessions running is off" },
];
export const COMMANDS: Command[] = [
  { id: "listen", names: ["listen"], sym: "i-wave", title: "Start listening", detail: "Transcribe the mic and the Mac's audio into today's transcript" },
  { id: "transcript", names: ["transcript"], sym: "i-align", title: "Show transcript", detail: "Today's transcript in a tab, following new lines" },
  { id: "kanban", names: ["kanban", "tabs"], sym: "i-split3", title: "Show session board", detail: "Claude sessions by turn: Running, Stopped, Completed (also !tabs)" },
];

export const MESSAGE = "why is the upload test flaky";
export const RES_PARTIAL: Result[] = [
  { t: "Why is the cache cold after a deploy", p: ["#shop-api"], ago: "3 days ago" },
  { t: "Explain the retry backoff in uploads", p: ["#shop-api"], ago: "last week" },
  { t: "Why is the build slow on CI", p: ["#infra"], ago: "2 weeks ago" },
];
export const RES_FINAL: Result[] = [
  { t: "Fix flaky upload test", p: ["#shop-api", "@reviewer"], ago: "2 hours ago", open: true },
  { t: "Stabilise the retry logic in uploads", p: ["#shop-api"], ago: "yesterday" },
  { t: "Upload test times out on CI", p: ["#shop-api", "@planner"], ago: "4 days ago" },
];
export const FIND_MSG = "where we fixed the login redirect loop";
export const RES_FIND_PARTIAL: Result[] = [
  { t: "Where the config loader looks for files", p: ["#shop-api"], ago: "2 weeks ago" },
  { t: "Release checklist for the web app", p: ["#site"], ago: "last month" },
  { t: "Notes on the redirect middleware", p: ["#shop-api"], ago: "2 months ago" },
];
export const RES_FIND: Result[] = [
  { t: "Auth callback keeps bouncing back to sign-in", p: ["#shop-api"], ago: "5 weeks ago" },
  { t: "Add rate limiting to the sign-in route", p: ["#shop-api"], ago: "2 months ago" },
  { t: "Fix the OAuth scopes for the admin app", p: ["#shop-admin"], ago: "3 months ago" },
];
export const TAB_RENAME: Tab = { t: "Rename the billing module", p: ["#shop-api"], s: "Started 40 minutes ago" };
export const TAB_AUTH: Tab = { t: "Auth callback keeps bouncing back to sign-in", p: ["#shop-api"], s: "Started 5 weeks ago" };
export const TAB_NEW: Tab = { t: MESSAGE, p: ["^studio", "#shop-api", "@reviewer"], s: "Started just now" };

// ---------- the real prompt grammar: leadingWords, ranking, suggestions ----------
export function lead(q: string): { words: string[]; rest: string; typing: boolean } {
  let t = q.replace(/^ +/, "");
  const words: string[] = [];
  while (t && "#@^".includes(t[0])) {
    const w = t.match(/^\S+/)![0];
    words.push(w);
    t = t.slice(w.length);
    if (!t) return { words, rest: "", typing: true };
    t = t.replace(/^\s+/, "");
  }
  return { words, rest: t, typing: false };
}

function ranked<T>(items: T[], names: (it: T) => string[], typed: string): T[] {
  return items
    .map((it, i) => {
      const l = names(it).map((x) => x.toLowerCase());
      let r: number | null = null;
      if (l.includes(typed)) r = 0;
      else if (l.some((x) => x.startsWith(typed))) r = 1;
      else if (typed && l.some((x) => x.includes(typed))) r = 2;
      return r == null ? null : { r, i, it };
    })
    .filter((x): x is { r: number; i: number; it: T } => x !== null)
    .sort((a, b) => a.r - b.r || a.i - b.i)
    .map((x) => x.it);
}

export interface Suggestion { tok: string; icon: string; detail: string; tag: string }
export function suggestions(q: string): Suggestion[] {
  const { words, typing } = lead(q);
  const w = words[words.length - 1];
  if (!typing || !w) return [];
  const typed = w.slice(1).toLowerCase();
  let found: Suggestion[];
  if (w[0] === "^") found = ranked(PEERS, (p) => [p.h], typed).map((p) => ({ tok: "^" + p.h, icon: "i-desktop", detail: p.n, tag: p.t }));
  else if (w[0] === "#") found = ranked(PROJECTS, (p) => [p.n], typed).map((p) => ({ tok: "#" + p.n, icon: "i-folder", detail: p.d, tag: p.t }));
  else found = ranked(AGENTS, (a) => [a.n], typed).map((a) => ({ tok: "@" + a.n, icon: "i-person", detail: a.d, tag: a.t }));
  return found.slice(0, 6);
}

export function commands(q: string): Command[] {
  const typed = q.slice(1).trim().toLowerCase();
  return COMMANDS.map((c, i) => {
    const r = Math.min(...c.names.map((n) => (n === typed ? 0 : n.startsWith(typed) ? 1 : n.includes(typed) ? 2 : 9)));
    return { c, i, r };
  })
    .filter((x) => x.r < 9)
    .sort((a, b) => a.r - b.r || a.i - b.i)
    .map((x) => x.c);
}

export function dur(s: number): string {
  s = Math.max(0, Math.round(s));
  return s < 60 ? s + "s" : s < 3600 ? Math.floor(s / 60) + "m" : Math.floor(s / 3600) + "h";
}
