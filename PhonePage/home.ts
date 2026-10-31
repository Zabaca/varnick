// What the home page is told: the relay's `tabs` and `recent` replies, and the other hosts' links (hosts.ts), cut down to what the
// page draws. No I/O.

import type { Device } from "./checks";
import type { HostLink } from "./hosts";
import { isObject, objects, uuidPattern } from "./json";
import { hasSession } from "./page/tabrules.js";

export type RelayResult = { ok: true; reply: Record<string, unknown> } | { ok: false; error: string };

/** What the page may show of a pane: its kind decides which of the fields are set. */
export interface HomePane {
  /** The pane's id, a lowercase uuid. */
  id: string;
  /** `claude`, `terminal`, `web`, `app`, `file`, `transcript`, or what a newer host sends. */
  kind: string;
  title: string;
  folder: string;
  agent: string | null;
  /** The zmx session name, `varnick-<uuid>`: what opening a Claude or terminal pane names. Null for the other kinds. */
  session: string | null;
  /** Claude and terminal: whether its zmx session runs. */
  running: boolean;
  /** True when this device is the one in control of it. */
  mine: boolean;
  /** "Controlled on Mac mini", "Last controlled on this phone": the one wording, from `controlledText`. Empty for a pane that isn't running. */
  text: string;
  /** Why a Claude or terminal pane doesn't run, when the host says. */
  note: string | null;
  /** Web: its address. App: its address on the host, and its name and port. File: its path. */
  url: string | null;
  app: string | null;
  port: number | null;
  file: string | null;
  /** Web at a local address, and app: the address the tab view frames it at, through the host's port proxy (an https address), when it has one. */
  proxy: string | null;
  /** Why it has none, in the host's words. */
  proxyNote: string | null;
  /** A Claude pane's standing message (option 04), for the push worker's notification. The page shows nothing of it: a tap lands on the terminal. */
  message: HomeMessage | null;
}

/** A message's words as the worker shows them: the title one line of at most 80 characters, the body at most 300 (`PaneMessage` cuts the same). */
export interface HomeMessage {
  title: string;
  body: string | null;
}

/** Control characters and the bidi overrides out of a host's words, then cut: what the host sent is the host's, but it goes on to a lock screen. */
const cleaned = (value: unknown, limit: number, lines: boolean): string | null => {
  if (typeof value !== "string") return null;
  const line = (text: string): string => text.replace(/[\t\r]/g, " ").replace(/[\p{Cc}\p{Cf}]/gu, "").replace(/\s+/g, " ").trim();
  const kept = lines ? value.split("\n").map(line).join("\n").replace(/\n{2,}/g, "\n\n").trim() : line(value);
  if (kept === "") return null;
  return kept.length > limit ? `${kept.slice(0, limit - 1)}…` : kept;
};

export function shapeMessage(value: unknown): HomeMessage | null {
  if (!isObject(value)) return null;
  const title = cleaned(value.title, 80, false);
  return title === null ? null : { title, body: cleaned(value.body, 300, true) };
}

/** An open tab of the host with its panes in the host's layout order. `name` is the tab's own (⌘⇧R), when it has one. */
export interface HomeTab {
  tab: string;
  name: string | null;
  /** True when this device is in control of the tab, and who is, in the one wording; empty when nothing in it can be taken. */
  mine: boolean;
  text: string;
  /** A run nobody opened: the id of the automation that made it, when the host says (`PeerRunMark.automation`), for the link to it. */
  automation: string | null;
  /** The host's Voice session (`PeerTab.voice`): it runs with permissions skipped, and Voice mode and Hey Varnick type into it until Take over makes it the user's. */
  voice: boolean;
  panes: HomePane[];
}

export interface HomeRecentSession {
  conversation: string;
  title: string;
  folder: string;
  agent: string | null;
}

/** A closed tab in the host's Recent: what resuming names is its id, and the host's own Recent says its sessions. */
export interface HomeRecent {
  tab: string;
  /** Its name, else its first session's title. */
  title: string;
  sessions: HomeRecentSession[];
  /** Unix seconds when it closed. */
  last: number;
}

export type Part<Row> = { rows: Row[] } | { error: string };

export interface Home {
  host: { name: string; headless: boolean };
  /** Loopback mode: any program on the host can reach the page. */
  loopback: boolean;
  device: { name: string };
  /** The host's open tabs, less the runs nobody opened. */
  tabs: Part<HomeTab>;
  /** The runs of the host's automations that nobody has opened (the tabs the host marks with `run`, protocol 29): listed here and not under Tabs. */
  runs: Part<HomeTab>;
  recent: Part<HomeRecent>;
  /** The other hosts' pages, by name: where each would be, since this host can't know that it serves one. */
  hosts: HostLink[];
}

/** Whether a reply's id is `b`: ids compare case-insensitively, as `Zmx.sameID` does. */
export const same = (a: unknown, b: string): boolean => typeof a === "string" && a.toLowerCase() === b.toLowerCase();
const text = (value: unknown): string => (typeof value === "string" ? value : "");
export const optional = (value: unknown): string | null => (typeof value === "string" && value !== "" ? value : null);

/** An address the page may frame: https, and nothing else. The host's relay sent it, and the page's content rules name the host's own name too. */
function httpsAddress(value: unknown): string | null {
  if (typeof value !== "string") return null;
  try { return new URL(value).protocol === "https:" ? value : null; } catch { return null; }
}

/** The Mac app's wording (`Peer.controlledText`): with no client attached the controller only last had control. */
export function controlledText(controller: string, attached: boolean): string {
  return (attached ? "Controlled on " : "Last controlled on ") + controller;
}

const sessionNameOf = (id: string): string => `varnick-${id.toLowerCase()}`;

/**
 * One pane of a listed tab. The relay leaves out a controller's id unless it names the asking device, so `control` being present (and
 * equal to the device's id) is what "this phone" rests on; the id itself goes no further. The name of anyone else comes from `controlName`.
 * Null for a pane with no id.
 */
export function shapePane(pane: Record<string, unknown>, device: Device): HomePane | null {
  if (typeof pane.id !== "string" || !uuidPattern.test(pane.id)) return null;
  const kind = text(pane.kind);
  const zmx = hasSession(kind);
  const running = zmx && pane.running === true;
  const mine = running && same(pane.control, device.id);
  const controller = mine ? "this phone" : optional(pane.controlName) ?? "another device";
  const clients = typeof pane.clients === "number" ? pane.clients : 0;
  return {
    id: pane.id.toLowerCase(),
    kind,
    title: text(pane.title),
    folder: text(pane.folder),
    agent: optional(pane.agent),
    session: zmx ? sessionNameOf(pane.id) : null,
    running,
    mine,
    text: running ? controlledText(controller, clients > 0) : "",
    note: zmx ? optional(pane.note) : null,
    url: optional(pane.url),
    app: optional(pane.app),
    port: typeof pane.port === "number" && Number.isInteger(pane.port) ? pane.port : null,
    file: optional(pane.file),
    proxy: httpsAddress(pane.proxy),
    proxyNote: optional(pane.proxyNote),
    message: kind === "claude" ? shapeMessage(pane.message) : null,
  };
}

/**
 * One listed tab. None when it has no id of a tab or no pane the page can show, and none when it is only Claude and terminal panes that
 * aren't running, which a phone can't open. The tab's control is the host's word (`PeerTab.control`): this phone, or somebody else, or no
 * one when nothing in it runs.
 */
export function shapeTab(tab: Record<string, unknown>, device: Device): HomeTab | null {
  if (typeof tab.tab !== "string" || !uuidPattern.test(tab.tab)) return null;
  const panes = objects(tab.panes).flatMap((pane) => shapePane(pane, device) ?? []);
  if (panes.length === 0) return null;
  const live = panes.filter((pane) => pane.running);
  if (live.length === 0 && panes.every((pane) => hasSession(pane.kind))) return null;
  const mine = live.length > 0 && same(tab.control, device.id);
  const controller = mine ? "this phone" : optional(tab.controlName) ?? "another device";
  const clients = typeof tab.clients === "number" ? tab.clients : 0;
  const automation = isObject(tab.run) && typeof tab.run.automation === "string" && uuidPattern.test(tab.run.automation) ? tab.run.automation.toLowerCase() : null;
  return { tab: tab.tab.toLowerCase(), name: optional(tab.name), mine, text: live.length > 0 ? controlledText(controller, clients > 0) : "", automation, voice: tab.voice === true, panes };
}

export const shapeTabs = (tabs: Record<string, unknown>[], device: Device): HomeTab[] => tabs.flatMap((tab) => shapeTab(tab, device) ?? []);

/** A tab the host marks as a run nobody opened (`PeerTab.run`, protocol 29). A host before protocol 29 marks none. */
export const isRun = (tab: Record<string, unknown>): boolean => isObject(tab.run);

/** The tabs split in two: the ordinary ones, and the runs. A run is opened from Runs like any tab, and the host takes its mark off when it is. */
export function splitRuns(tabs: Record<string, unknown>[]): { tabs: Record<string, unknown>[]; runs: Record<string, unknown>[] } {
  return { tabs: tabs.filter((tab) => !isRun(tab)), runs: tabs.filter(isRun) };
}

/** One closed tab of a `recent` reply; none when it has no id of a tab or no session to resume. */
export function shapeRecent(row: Record<string, unknown>): HomeRecent[] {
  const sessions = objects(row.sessions).flatMap((session): HomeRecentSession[] =>
    typeof session.conversation === "string" && uuidPattern.test(session.conversation)
      ? [{ conversation: session.conversation.toLowerCase(), title: text(session.title), folder: text(session.folder), agent: optional(session.agent) }]
      : [],
  );
  if (typeof row.tab !== "string" || !uuidPattern.test(row.tab) || sessions.length === 0) return [];
  return [{ tab: row.tab.toLowerCase(), title: optional(row.name) ?? sessions[0].title, sessions, last: typeof row.last === "number" ? row.last : 0 }];
}

export function shapeHome(input: {
  host: { name: string; headless: boolean };
  loopback: boolean;
  device: Device;
  tabs: RelayResult;
  recent: RelayResult;
  hosts: HostLink[];
}): Home {
  const { device } = input;
  const { tabs, runs } = input.tabs.ok ? splitRuns(objects(input.tabs.reply.tabs)) : { tabs: [], runs: [] };
  // A Mac's page links a run to its automation (ADR 0040's amendment of 2026-10-29); a headless host's automations are not on the phone, so its ids go no further.
  const part = (rows: Record<string, unknown>[]): Part<HomeTab> =>
    input.tabs.ok ? { rows: shapeTabs(rows, device).map((tab) => (input.host.headless ? { ...tab, automation: null } : tab)) } : { error: input.tabs.error };
  return {
    host: input.host,
    loopback: input.loopback,
    device: { name: device.name },
    hosts: input.hosts,
    tabs: part(tabs),
    runs: part(runs),
    recent: input.recent.ok ? { rows: objects(input.recent.reply.recent).flatMap(shapeRecent) } : { error: input.recent.error },
  };
}

// ---------------------------------------------------------------------------------------------------------------
// The page an unlisted caller gets

/** Said on every view in loopback mode, where the Host and Origin checks are all that stand between a local program and the page. */
export const loopbackNote = "Loopback mode: any program on this host can reach this page.";

export const escapeHTML = (value: string): string =>
  value.replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]!);

/** What an unlisted caller is told, as HTML-safe pieces. It names the caller and where to add it, and holds nothing of the host's sessions. */
export function unlistedLines(caller: { reason: "unknown" | "not-own" | "not-listed"; label: string | null }, host: { name: string; headless: boolean }): string[] {
  const hostName = escapeHTML(host.name);
  const device = escapeHTML(caller.label ?? "This device");
  switch (caller.reason) {
    case "unknown":
      return [`${hostName}'s phone page couldn't tell which device is asking, so it shows nothing.`];
    case "not-own":
      return [`${device} isn't one of your own devices, so it can't use ${hostName}'s phone page.`];
    case "not-listed":
      return [
        `${device} can't use ${hostName}'s phone page.`,
        host.headless
          ? `Add it on ${hostName} with <code>varnick-peer device add ${escapeHTML(caller.label ?? "<its name>")}</code>.`
          : `Add it in Varnick › Settings › Peers › Devices on ${hostName}.`,
      ];
  }
}

export function unlistedPage(caller: { reason: "unknown" | "not-own" | "not-listed"; label: string | null }, host: { name: string; headless: boolean }, loopback: boolean): string {
  const lines = unlistedLines(caller, host).map((line) => `<p>${line}</p>`).join("\n");
  const note = loopback ? `<p class="note">${escapeHTML(loopbackNote)}</p>` : "";
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>Phone page</title>
<style>
  body { font: 16px/1.45 system-ui, sans-serif; margin: 0 auto; padding: 24px 16px; max-width: 34rem; }
  code { font: 14px ui-monospace, monospace; overflow-wrap: anywhere; }
  .note { font-size: 14px; opacity: .75; }
</style>
</head><body>
<h1>Not added yet</h1>
${lines}
${note}
</body></html>
`;
}
