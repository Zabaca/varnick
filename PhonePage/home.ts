// What the home page is told: the relay's `sessions` and `recent` replies, and the other hosts' links (hosts.ts), cut down to what the
// page draws. No I/O.

import type { Device } from "./checks";
import type { HostLink } from "./hosts";
import { objects } from "./json";

export type RelayResult = { ok: true; reply: Record<string, unknown> } | { ok: false; error: string };

export interface HomeSession {
  /** The zmx session name, `varnick-<uuid>`: what opening a row will name. */
  session: string;
  title: string;
  folder: string;
  agent: string | null;
  /** True when this device is the one in control. */
  mine: boolean;
  /** "Controlled on Mac mini", "Last controlled on this phone": the one wording, from `controlledText`. */
  text: string;
}

export interface HomeRecent {
  conversation: string;
  title: string;
  folder: string;
  agent: string | null;
  /** Unix seconds. */
  last: number;
}

export type Part<Row> = { rows: Row[] } | { error: string };

export interface Home {
  host: { name: string; headless: boolean };
  /** Loopback mode: any program on the host can reach the page. */
  loopback: boolean;
  device: { name: string };
  sessions: Part<HomeSession>;
  recent: Part<HomeRecent>;
  /** The other hosts' pages, by name: where each would be, since this host can't know that it serves one. */
  hosts: HostLink[];
}

/** Whether a reply's id is `b`: ids compare case-insensitively, as `Zmx.sameID` does. */
export const same = (a: unknown, b: string): boolean => typeof a === "string" && a.toLowerCase() === b.toLowerCase();
const text = (value: unknown): string => (typeof value === "string" ? value : "");
export const optional = (value: unknown): string | null => (typeof value === "string" && value !== "" ? value : null);

/** The Mac app's wording (`Peer.controlledText`): with no client attached the controller only last had control. */
export function controlledText(controller: string, attached: boolean): string {
  return (attached ? "Controlled on " : "Last controlled on ") + controller;
}

/**
 * One session row. The relay leaves out a controller's id unless it names the asking device, so `control` being
 * present (and equal to the device's id) is what "this phone" rests on; the id itself goes no further. The name
 * of anyone else comes from `controlName`.
 */
export function shapeSession(open: Record<string, unknown>, device: Device): HomeSession {
  const mine = same(open.control, device.id);
  const controller = mine ? "this phone" : optional(open.controlName) ?? "another device";
  const clients = typeof open.clients === "number" ? open.clients : 0;
  return {
    session: text(open.session),
    title: text(open.title),
    folder: text(open.folder),
    agent: optional(open.agent),
    mine,
    text: controlledText(controller, clients > 0),
  };
}

export function shapeHome(input: {
  host: { name: string; headless: boolean };
  loopback: boolean;
  device: Device;
  sessions: RelayResult;
  recent: RelayResult;
  hosts: HostLink[];
}): Home {
  const { device } = input;
  return {
    host: input.host,
    loopback: input.loopback,
    device: { name: device.name },
    hosts: input.hosts,
    sessions: input.sessions.ok ? { rows: objects(input.sessions.reply.open).map((open) => shapeSession(open, device)) } : { error: input.sessions.error },
    recent: input.recent.ok
      ? {
          rows: objects(input.recent.reply.recent).map((row) => ({
            conversation: text(row.conversation),
            title: text(row.title),
            folder: text(row.folder),
            agent: optional(row.agent),
            last: typeof row.last === "number" ? row.last : 0,
          })),
        }
      : { error: input.recent.error },
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
