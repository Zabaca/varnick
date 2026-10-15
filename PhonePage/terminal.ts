// The terminal's decisions, with no I/O: what a websocket's first message may ask, what a reconnect does for a session's
// status, which code closes a socket when the zmx client exits, and how a refused attach is told from a screen. bridge.ts
// does the spawning; everything it decides by is here, so `bun test` can check it (ADR 0011).

import type { Device } from "./checks";
import type { RelayResult } from "./home";
import { controlledText, optional, same } from "./home";
import { uuidPattern, type Json } from "./json";
import { parseReply } from "./relay";

/** The one kind of name the page may open: a pane's zmx session, `varnick-<uuid>` with a lowercase uuid (`Zmx.paneID`). */
export const sessionPattern = /^varnick-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const isSessionName = (value: unknown): value is string => typeof value === "string" && sessionPattern.test(value);

export interface Grid {
  cols: number;
  rows: number;
}

export const gridLimits = { minCols: 20, maxCols: 400, minRows: 5, maxRows: 200 };

const clamp = (value: unknown, low: number, high: number, fallback: number): number => {
  const number = typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : fallback;
  return Math.max(low, Math.min(high, number));
};

/** A grid the pseudo-terminal may have, whatever the page sent. */
export const clampGrid = (cols: unknown, rows: unknown): Grid => ({
  cols: clamp(cols, gridLimits.minCols, gridLimits.maxCols, 80),
  rows: clamp(rows, gridLimits.minRows, gridLimits.maxRows, 24),
});

/** A websocket's first message: the session, the grid, and whether to take. */
export interface OpenRequest extends Grid {
  session: string;
  take: boolean;
}

/** `take` is only ever the literal `true`; anything else is no take. Null for a message that isn't a valid first message. */
export function parseOpen(text: string): OpenRequest | null {
  let json: unknown;
  try { json = JSON.parse(text); } catch { return null; }
  if (typeof json !== "object" || json === null || Array.isArray(json)) return null;
  const message = json as Record<string, unknown>;
  if (!isSessionName(message.session)) return null;
  return { session: message.session, take: message.take === true, ...clampGrid(message.cols, message.rows) };
}

/** What the page sends after the first message: typed bytes, legacy binary reports, and a new grid. */
export type ClientMessage =
  | { t: "in"; data: string }
  | { t: "bin"; data: Uint8Array }
  | { t: "resize"; cols: number; rows: number }
  /** The page was hidden or shown: a hidden page has no pane open, whatever its socket still holds. */
  | { t: "visibility"; visible: boolean };

/** The most one message may type: a paste, not a flood. */
export const inputLimit = 256 << 10;

export function parseClient(text: string): ClientMessage | null {
  let json: unknown;
  try { json = JSON.parse(text); } catch { return null; }
  if (typeof json !== "object" || json === null || Array.isArray(json)) return null;
  const message = json as Record<string, unknown>;
  if (message.t === "in" && typeof message.d === "string" && message.d.length > 0 && message.d.length <= inputLimit) return { t: "in", data: message.d };
  // xterm's `onBinary` is a string of characters 0 to 255, one byte each.
  if (message.t === "bin" && typeof message.d === "string" && message.d.length > 0 && message.d.length <= inputLimit && /^[\x00-\xff]*$/.test(message.d)) {
    return { t: "bin", data: Buffer.from(message.d, "latin1") };
  }
  if (message.t === "resize") return { t: "resize", ...clampGrid(message.cols, message.rows) };
  if (message.t === "visibility" && typeof message.visible === "boolean") return { t: "visibility", visible: message.visible };
  return null;
}

// ---------------------------------------------------------------------------------------------------------------
// What a session's status says

/** What `status` said of one session, for this device. `control` is present only when the relay found it to be the device. */
export type SessionLook =
  | { kind: "error"; error: string }
  | { kind: "gone" }
  | { kind: "mine"; title: string | null }
  | { kind: "other"; controller: string; attached: boolean; title: string | null };

export function lookAtSession(result: RelayResult, name: string, device: Device): SessionLook {
  if (!result.ok) return { kind: "error", error: result.error };
  const sessions = result.reply.sessions;
  const entry = typeof sessions === "object" && sessions !== null ? (sessions as Json)[name] : undefined;
  if (typeof entry !== "object" || entry === null || (entry as Json).running !== true) return { kind: "gone" };
  const status = entry as Json;
  const title = optional(status.title);
  if (same(status.control, device.id)) return { kind: "mine", title };
  const clients = typeof status.clients === "number" ? status.clients : 0;
  return { kind: "other", controller: optional(status.controlName) ?? "another device", attached: clients > 0, title };
}

/**
 * What a reconnect does, a pure function of `status` and the device's id:
 * - labelled for this device: attach, without take;
 * - labelled for anyone else, the host included: the session view ("Controlled on X", or "Taken over on X" once);
 * - gone: "Session ended";
 * - the host couldn't say: try again.
 */
export type Opening =
  | { state: "mine"; title: string | null }
  | { state: "other"; controller: string; text: string; title: string | null }
  | { state: "gone"; text: string }
  | { state: "error"; error: string };

export function decideOpen(result: RelayResult, name: string, device: Device): Opening {
  const look = lookAtSession(result, name, device);
  switch (look.kind) {
    case "mine": return { state: "mine", title: look.title };
    case "other": return { state: "other", controller: look.controller, text: controlledText(look.controller, look.attached), title: look.title };
    case "gone": return { state: "gone", text: "Session ended" };
    case "error": return { state: "error", error: look.error };
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Closing a websocket

/** The private close codes the page reads (4000 to 4999). */
export const closeCode = {
  /** Another Mac or device took the session: the reason is "Taken over on X". */
  taken: 4001,
  ended: 4002,
  /** The zmx client went but the session is still this device's (a dropped client): the page reconnects. */
  dropped: 4003,
  /** The relay refused the attach: the reason is its error. */
  refused: 4004,
  badRequest: 4400,
  busy: 4429,
  failed: 4500,
} as const;

export interface Closing {
  code: number;
  reason: string;
}

/** A close reason is at most 123 bytes of UTF-8, and holds printable text only. */
export function fitReason(text: string): string {
  let result = "";
  let bytes = 0;
  for (const character of text.replace(/[\x00-\x1f\x7f]/g, " ")) {
    const size = Buffer.byteLength(character, "utf8");
    if (bytes + size > 120) break;
    result += character;
    bytes += size;
  }
  return result;
}

/**
 * The reason of a 4001: the controller as a JSON field, which the page words itself ("Taken over on X"), cut so the whole
 * fits a close frame. The page never has to take the name out of a sentence.
 */
export function takenReason(controller: string): string {
  let name = controller.replace(/[\x00-\x1f\x7f]/g, " ");
  while (Buffer.byteLength(JSON.stringify({ controller: name }), "utf8") > 120) name = [...name].slice(0, -1).join("");
  return JSON.stringify({ controller: name });
}

/** What closes the websocket when the zmx client exited by itself: the label decides, never the exit. */
export function decideExit(result: RelayResult, name: string, device: Device): Closing {
  const look = lookAtSession(result, name, device);
  switch (look.kind) {
    case "gone": return { code: closeCode.ended, reason: "Session ended" };
    case "mine": return { code: closeCode.dropped, reason: "Disconnected" };
    case "other": return { code: closeCode.taken, reason: takenReason(look.controller) };
    // The host couldn't say: the page asks again before it attaches, and learns then.
    case "error": return { code: closeCode.dropped, reason: "Disconnected" };
  }
}

/**
 * The check a second after a client attaches. The relay checked the label before it became zmx, and another Mac may have
 * taken the session between that check and the attach, so two keyboards would be live: if the label isn't this device's,
 * let go (as the Mac clients do). Null when it is, or when the host couldn't say: the next reconnect asks again.
 */
export function recheckControl(result: RelayResult, name: string, device: Device): Closing | null {
  const look = lookAtSession(result, name, device);
  if (look.kind === "mine" || look.kind === "error") return null;
  return decideExit(result, name, device);
}

// ---------------------------------------------------------------------------------------------------------------
// A refused attach

/**
 * A refused attach prints one reply line and exits, instead of becoming zmx. Whether the first output could be that
 * line: it starts with `{`, which a zmx screen's first bytes (escape sequences) don't. "undecided" while nothing but
 * whitespace has come.
 */
export function firstOutput(bytes: Uint8Array): "reply" | "screen" | "undecided" {
  for (const byte of bytes) {
    if (byte === 0x20 || byte === 0x09 || byte === 0x0a || byte === 0x0d) continue;
    return byte === 0x7b ? "reply" : "screen";
  }
  return "undecided";
}

/** The error of a refusal held back from the terminal, or null when what was held isn't the relay's refusal. */
export function refusal(held: string): string | null {
  const reply = parseReply(held);
  if (!reply || reply.ok !== false) return null;
  return typeof reply.error === "string" && reply.error !== "" ? reply.error : "The relay refused the attach";
}

// ---------------------------------------------------------------------------------------------------------------
// End and take over

/** A body that names a tab by its id, lowercased, and nothing else. */
export function parseTabBody(body: unknown): { ok: true; tab: string } | { ok: false; error: string } {
  const tab = typeof body === "object" && body !== null ? (body as Record<string, unknown>).tab : undefined;
  return typeof tab === "string" && uuidPattern.test(tab) ? { ok: true, tab: tab.toLowerCase() } : { ok: false, error: "Not a Varnick tab id" };
}

/** `POST /api/end`: a tab (the page's End) or a session by its name; only the one it names reaches the relay. */
export function parseEndBody(body: unknown): { ok: true; fields: Record<string, string> } | { ok: false; error: string } {
  const object = typeof body === "object" && body !== null ? (body as Record<string, unknown>) : {};
  if (object.tab !== undefined) {
    const tab = parseTabBody(body);
    return tab.ok ? { ok: true, fields: { tab: tab.tab } } : tab;
  }
  return isSessionName(object.session) ? { ok: true, fields: { session: object.session } } : { ok: false, error: "Not a Varnick session name or tab id" };
}

/** What End says the host did: "Ended", or "Handed back to Mac mini, still running" when the reply has `released`. */
export function endText(reply: Record<string, unknown>, hostName: string): string {
  return reply.released === true ? `Handed back to ${hostName}, still running` : "Ended";
}

/**
 * The terminal's environment: the relay's (a home and a plain PATH, and the check folders), `TERM`, and `LANG`
 * so zmx draws UTF-8. Nothing else of the server's reaches the zmx client.
 */
export function attachEnvironment(base: Record<string, string>, lang: string | undefined, platform: string): Record<string, string> {
  return { ...base, TERM: "xterm-256color", LANG: lang && /^[A-Za-z0-9_.@-]+$/.test(lang) ? lang : platform === "darwin" ? "en_US.UTF-8" : "C.UTF-8" };
}
