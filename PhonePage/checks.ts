// The Phone page's decisions, with no I/O: who is calling, whether a request is for this page, and what the
// environment says. server.ts does the reading and spawning; everything it decides by is here, so `bun test` can
// check it (ADR 0011).

import { isObject, type Json } from "./json";

export type Mode = "socket" | "loopback";

interface CommonConfig {
  /** The HTTPS port `tailscale serve` publishes. The Host and Origin checks expect it. */
  port: number;
  relay: string;
  devices: string;
  tailscale: string;
  /** Passed on to the relay when set, for checks. */
  zmxDir?: string;
  userHome?: string;
  /** The port proxy (proxy.ts): an owner-only folder for its certificate, and the file it writes its status to. Both set, or no proxy. */
  proxy?: { folder: string; status: string };
}

/** Socket mode (an owner-only Unix socket) or loopback (a port on 127.0.0.1): exactly one. */
export type Config =
  | (CommonConfig & { mode: "socket"; socketPath: string })
  | (CommonConfig & { mode: "loopback"; loopbackPort: number });

/** The server's configuration from its environment only. The names are the check kit's. */
export function readConfig(env: Record<string, string | undefined>): { config: Config } | { error: string } {
  const socketPath = env.VARNICK_PAGE_SOCKET || undefined;
  const loopback = env.VARNICK_PAGE_LOOPBACK || undefined;
  if (socketPath && loopback) return { error: "Set VARNICK_PAGE_SOCKET or VARNICK_PAGE_LOOPBACK, not both" };
  if (!socketPath && !loopback) return { error: "Set VARNICK_PAGE_SOCKET (a socket path) or VARNICK_PAGE_LOOPBACK (a port on 127.0.0.1)" };
  const port = parsePort(env.VARNICK_PAGE_PORT ?? "8444");
  if (port === null) return { error: "VARNICK_PAGE_PORT isn't a port number" };
  const relay = env.VARNICK_RELAY;
  if (!relay || !relay.startsWith("/")) return { error: "VARNICK_RELAY must be the absolute path of the relay" };
  const devices = env.VARNICK_DEVICES;
  if (!devices || !devices.startsWith("/")) return { error: "VARNICK_DEVICES must be the absolute path of devices.json" };
  const tailscale = env.VARNICK_TAILSCALE || "tailscale";
  const folder = env.VARNICK_PROXY_FOLDER || undefined, status = env.VARNICK_PROXY_STATUS || undefined;
  if ((folder === undefined) !== (status === undefined)) return { error: "Set VARNICK_PROXY_FOLDER and VARNICK_PROXY_STATUS together, or neither" };
  if ((folder && !folder.startsWith("/")) || (status && !status.startsWith("/"))) return { error: "VARNICK_PROXY_FOLDER and VARNICK_PROXY_STATUS must be absolute paths" };
  const shared = {
    port, relay, devices, tailscale, zmxDir: env.VARNICK_ZMX_DIR || undefined, userHome: env.CFFIXED_USER_HOME || undefined,
    proxy: folder && status ? { folder, status } : undefined,
  };
  if (socketPath) {
    if (!socketPath.startsWith("/")) return { error: "VARNICK_PAGE_SOCKET must be an absolute path" };
    return { config: { mode: "socket", socketPath, ...shared } };
  }
  const loopbackPort = parsePort(loopback!);
  if (loopbackPort === null) return { error: "VARNICK_PAGE_LOOPBACK isn't a port number" };
  return { config: { mode: "loopback", loopbackPort, ...shared } };
}

function parsePort(text: string): number | null {
  if (!/^[0-9]{1,5}$/.test(text)) return null;
  const port = Number(text);
  return port >= 1 && port <= 65535 ? port : null;
}

// ---------------------------------------------------------------------------------------------------------------
// JSON from Tailscale

/**
 * Parses what `tailscale status --json` and `whois --json` print. A user id is a 17-digit number, more than a
 * double holds, and two different users' ids could parse equal: so an integer too big to be exact is kept as the
 * text it was written as.
 */
export function parseTailnetJSON(text: string): unknown {
  return JSON.parse(text, (_key, value, context?: { source?: string }) =>
    typeof value === "number" && Number.isInteger(value) && !Number.isSafeInteger(value) && context?.source && /^-?[0-9]+$/.test(context.source)
      ? context.source
      : value);
}

const idText = (value: unknown): string | null => (typeof value === "number" || typeof value === "string") && String(value) !== "" ? String(value) : null;

/** What the page needs of `tailscale status --json`: this host's MagicDNS name (lowercase, no final dot) and its user. */
export function parseSelf(text: string): { dnsName: string; userID: string } | null {
  let json: unknown;
  try { json = parseTailnetJSON(text); } catch { return null; }
  const self = isObject(json) ? json.Self : null;
  if (!isObject(self)) return null;
  const dnsName = typeof self.DNSName === "string" ? self.DNSName.replace(/\.$/, "").toLowerCase() : "";
  const userID = idText(self.UserID);
  return dnsName && userID ? { dnsName, userID } : null;
}

/** The node `tailscale whois --json <address>` found, with what decides whether it may be listed. */
export interface WhoisNode {
  stableID: string;
  /** The node's MagicDNS label ("phone-1"). Null when it has none that is safe to show. */
  label: string | null;
  /** The node's full MagicDNS name, lowercase with no final dot. Null when it has none. */
  dnsName: string | null;
  tagged: boolean;
  sharee: boolean;
  /** The owning user's id, as text. */
  userID: string | null;
}

export function parseWhois(text: string): WhoisNode | null {
  let json: unknown;
  try { json = parseTailnetJSON(text); } catch { return null; }
  const node = isObject(json) ? json.Node : null;
  if (!isObject(node) || typeof node.StableID !== "string" || node.StableID === "") return null;
  const full = typeof node.Name === "string" ? node.Name.replace(/\.$/, "").toLowerCase() : "";
  const name = full.split(".")[0];
  const tags = node.Tags;
  return {
    stableID: node.StableID,
    label: /^[A-Za-z0-9-]{1,63}$/.test(name) ? name : null,
    dnsName: full !== "" ? full : null,
    // Anything but an empty list of tags counts as tagged: a shape this code doesn't know is not the user's own node.
    tagged: !(tags === null || tags === undefined || (Array.isArray(tags) && tags.length === 0)),
    sharee: sharedIn(node),
    userID: idText(node.User),
  };
}

/**
 * Whether a whois node was shared in. `whois --json`'s Node has no `ShareeNode` of its own (`status --json`'s peers do):
 * tailcfg.Node has `Sharer`, the user who shared the node when non-zero, and the node's Hostinfo has `ShareeNode`, set
 * for a node owned by a shared-to user. Either says shared in, and a value this code can't read counts as shared.
 */
function sharedIn(node: Json): boolean {
  const sharer = node.Sharer;
  const sharerSet = !(sharer === undefined || sharer === null || sharer === 0 || sharer === "0" || sharer === "");
  const hostinfo = node.Hostinfo;
  return sharerSet || (isObject(hostinfo) && !!hostinfo.ShareeNode);
}

/** `PeerDevice.mayBeListed` in the Swift package: only the user's own untagged nodes. Keep the two the same. */
export function mayBeListed(node: { tagged: boolean; sharee: boolean; userID: string | null }, selfUserID: string | null): boolean {
  if (node.tagged || node.sharee || node.userID === null || selfUserID === null) return false;
  return node.userID === selfUserID;
}

// ---------------------------------------------------------------------------------------------------------------
// Devices and who is calling

export interface Device {
  /** A lowercase UUID: the `by` of every request, and the label that marks the device as in control. */
  id: string;
  /** The tailnet node's StableID. */
  node: string;
  name: string;
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * `devices.json`: a list, one bad entry skipped, ids lowercased as `DeviceList.read` does (so a hand-written
 * uppercase id can't make a label that differs from the one the relay compares). Only a UUID is an id: it goes
 * into zmx labels. Anything that isn't a list lists nobody.
 */
export function readDevices(text: string | null): Device[] {
  if (text === null) return [];
  let json: unknown;
  try { json = JSON.parse(text); } catch { return []; }
  if (!Array.isArray(json)) return [];
  const devices: Device[] = [];
  for (const entry of json) {
    if (!isObject(entry) || typeof entry.id !== "string" || typeof entry.node !== "string" || typeof entry.name !== "string") continue;
    const id = entry.id.toLowerCase();
    if (!uuid.test(id) || entry.node === "") continue;
    devices.push({ id, node: entry.node, name: entry.name });
  }
  return devices;
}

export type Caller =
  | { kind: "device"; device: Device; label: string | null }
  /** `unknown`: nothing said who this is. `not-own`: a tagged node, one shared in, or another user's, which can't be listed. */
  | { kind: "unlisted"; reason: "unknown" | "not-own" | "not-listed"; label: string | null };

/** The one decision: the whois node, the host's own user and the device list say who is calling. */
export function decideCaller(node: WhoisNode | null, selfUserID: string | null, devices: Device[]): Caller {
  if (!node) return { kind: "unlisted", reason: "unknown", label: null };
  if (!mayBeListed(node, selfUserID)) return { kind: "unlisted", reason: "not-own", label: node.label };
  const device = devices.find((candidate) => candidate.node === node.stableID);
  return device ? { kind: "device", device, label: node.label } : { kind: "unlisted", reason: "not-listed", label: node.label };
}

/** The first address of `X-Forwarded-For`, if it is an IP address (it goes into a command line). */
export function callerAddress(header: string | null, isIP: (text: string) => boolean): string | null {
  const first = (header ?? "").split(",")[0].trim();
  return first !== "" && isIP(first) ? first : null;
}

// ---------------------------------------------------------------------------------------------------------------
// Host and Origin

interface Headers {
  get(name: string): string | null;
}

/** What the browser's address bar says: the host's MagicDNS name and the port serve publishes. */
export const expectedHost = (dnsName: string, port: number): string => `${dnsName}:${port}`;
export const expectedOrigin = (dnsName: string, port: number): string => `https://${dnsName}:${port}`;

/**
 * The Host check, on every request. Behind a socket serve sends `Host: localhost` and the browser's host only in
 * `X-Forwarded-Host`, which it replaces if the browser sent one; on loopback `Host` is the browser's. Anything
 * else, or no header, is refused (DNS rebinding, a program on the host, a proxy).
 */
export function checkHost(mode: Mode, headers: Headers, expected: string): boolean {
  const value = headers.get(mode === "socket" ? "x-forwarded-host" : "host");
  return value !== null && value.toLowerCase() === expected.toLowerCase();
}

export function checkOrigin(origin: string | null, expected: string): boolean {
  return origin !== null && origin === expected;
}

/**
 * Whether an `/api/*` request comes from the page itself. The phone's tailnet identity goes with every request its
 * browser makes, and another site can send `fetch(url, { mode: "no-cors" })` (a read nobody sees, but one that runs a
 * relay): the browser says `Sec-Fetch-Site: cross-site` and the page's own requests say `same-origin`. Without that
 * header an `Origin`, when one is sent, must be the page's. A client that sends neither (curl) goes through.
 */
export function checkFetchSite(headers: Headers, expected: string): boolean {
  const site = headers.get("sec-fetch-site");
  if (site !== null) return site === "same-origin";
  const origin = headers.get("origin");
  return origin === null || origin === expected;
}

/**
 * What a request that changes something needs: a POST with a JSON body whose `Origin` is the page's own. The
 * phone's tailnet identity goes with every request its browser makes, so another site open on the phone would
 * otherwise drive the page. Null lets the request go on; a websocket upgrade is checked by `gateUpgrade`.
 */
export function gateMutation(method: string, headers: Headers, expected: string): { status: number; reason: string } | null {
  if (method === "GET" || method === "HEAD") return null;
  if (method !== "POST") return { status: 405, reason: "method" };
  if (!checkOrigin(headers.get("origin"), expected)) return { status: 403, reason: "origin" };
  if (!/^application\/json\s*(;|$)/i.test(headers.get("content-type") ?? "")) return { status: 415, reason: "content-type" };
  return null;
}

/**
 * What a websocket upgrade needs, as a mutation does, since it decides who is typing: a GET that asks to upgrade, from the
 * page itself. `Origin` must be the page's, and `Sec-Fetch-Site`, when the browser sends it, `same-origin`: the phone's
 * tailnet identity goes with every request another site open on the phone can start, and a websocket isn't bound by
 * CORS. Null lets the upgrade go on.
 */
export function gateUpgrade(method: string, headers: Headers, expected: string): { status: number; reason: string } | null {
  if (method !== "GET") return { status: 405, reason: "method" };
  if (!/^websocket$/i.test((headers.get("upgrade") ?? "").trim())) return { status: 400, reason: "not an upgrade" };
  if (!checkOrigin(headers.get("origin"), expected)) return { status: 403, reason: "origin" };
  if (!checkFetchSite(headers, expected)) return { status: 403, reason: "cross-site" };
  return null;
}
