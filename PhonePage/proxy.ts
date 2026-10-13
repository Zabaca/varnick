// The port proxy's decisions, with no I/O (ADR 0035): which ports a host's open tabs name, which of them are opened and why a
// port isn't, who may connect, which requests a browser may make, and what is rewritten on the way through. portproxy.ts does the
// listening and the spawning; everything it decides by is here, so `bun test` can check it.

import { readFileSync } from "node:fs";
import { isIP } from "node:net";
import { decideCaller, mayBeListed, parseTailnetJSON, type Device, type WhoisNode } from "./checks";
import { isObject, objects, type Json } from "./json";
import { isLocalAddress } from "./page/tabrules.js";

// ---------------------------------------------------------------------------------------------------------------
// Which ports

/** What a web or app pane of a listed tab asks of the proxy: its port on the host's localhost, and the path it is at. */
export type PaneAim = { pane: string; port: number; path: string } | { pane: string; port: null; note: string };

/** Why a port isn't open, in the words the pane's card gives. All of the proxy's reasons are in this file, and the relay and the viewers only pass them on. */
export const notes = {
  reserved: "That is the Phone page's own port.",
  low: "Ports below 1024 can't be opened without root.",
  serve: "tailscale serve already publishes this port.",
  down: "Its server isn't answering on that machine yet.",
  taken: "A server on that machine already answers on every address at this port, so the proxy leaves it alone.",
  secure: "An HTTPS server isn't proxied: it speaks TLS, which the proxy doesn't.",
  noPort: "This page names no port.",
  noCertificate: "No certificate yet.",
  noAddress: "Tailscale gave no address for this machine.",
} as const;

/** The one fix for a refused certificate, which takes root once. It is written in `operator-command.txt`, which the installer reads too; Settings shows it from the status file. */
export const operatorCommand = readFileSync(new URL("./operator-command.txt", import.meta.url), "utf8").trim();

/** Why the proxy couldn't open a port, by the error's code. */
export const openFailure = (code: string): string => `The proxy couldn't open this port (${code || "error"}).`;

/** How `tailscale cert`'s refusal is told: the operator is the usual cause, and the fix has a command. */
export function certificateFailure(stderr: string): { note: string; command: string | null } {
  const line = stderr.split("\n").map((text) => text.trim()).find((text) => text !== "") ?? "";
  if (/access denied/i.test(line)) return { note: `No certificate: Tailscale gives one only to its operator. Run ${operatorCommand} once.`, command: operatorCommand };
  return { note: line === "" ? "No certificate: Tailscale didn't answer." : `No certificate: Tailscale said ${line.slice(0, 160)}`, command: null };
}

/** The port and path an address names when it is on the host's own localhost, else null. A scheme other than http or https is not one. */
function localAddress(text: string): { port: number; path: string; secure: boolean } | null {
  let url: URL;
  try { url = new URL(text); } catch { return null; }
  if ((url.protocol !== "http:" && url.protocol !== "https:") || !isLocalAddress(text)) return null;
  const secure = url.protocol === "https:";
  return { port: url.port !== "" ? Number(url.port) : secure ? 443 : 80, path: `${url.pathname}${url.search}${url.hash}`, secure };
}

/** The pane's aim: null for a pane that isn't a web or app pane, or a web pane at an outside address (it loads from where it is). */
export function aimOf(pane: Json): PaneAim | null {
  if (typeof pane.id !== "string") return null;
  const id = pane.id.toLowerCase();
  const url = typeof pane.url === "string" ? localAddress(pane.url) : null;
  if (pane.kind === "app") {
    const port = typeof pane.port === "number" && Number.isInteger(pane.port) && pane.port > 0 && pane.port < 65536 ? pane.port : null;
    if (port === null) return { pane: id, port: null, note: notes.noPort };
    return { pane: id, port, path: url && url.port === port ? url.path : "/" };
  }
  if (pane.kind === "web" && url) {
    if (url.secure) return { pane: id, port: null, note: notes.secure };
    return { pane: id, port: url.port, path: url.path };
  }
  return null;
}

export const aimsOf = (tabs: unknown): PaneAim[] => objects(tabs).flatMap((tab) => objects(tab.panes).flatMap((pane) => aimOf(pane) ?? []));

/** What the proxy looked at to decide a port. */
export interface PortFacts {
  /** The ports it never opens: the page's own. */
  reserved: ReadonlySet<number>;
  /** The ports `tailscale serve` publishes. */
  serve: ReadonlySet<number>;
  /** The ports whose server answers on this host's localhost. */
  localUp: ReadonlySet<number>;
  /** Of the ports not held, those where something answers on the tailnet address. */
  tailnetUp: ReadonlySet<number>;
  /** The ports it holds now. */
  held: ReadonlySet<number>;
  /** Why it has no certificate to serve with, or null when it has one. */
  certificate: string | null;
}

export interface PortPlan {
  open: number[];
  keep: number[];
  close: number[];
  /** Why each wanted port is not open or kept. */
  notes: Map<number, string>;
}

/**
 * The ports to open, keep and close. A port opens only while its server answers on localhost and nothing else answers on the tailnet
 * address at it: on Linux a listener opened first would keep a server bound to every address from starting, and on a Mac it would take
 * the traffic of one already there. A held port is judged again each look, except for the tailnet address, which it holds itself.
 */
export function planPorts(wanted: Iterable<number>, facts: PortFacts): PortPlan {
  const plan: PortPlan = { open: [], keep: [], close: [], notes: new Map() };
  const named = new Set(wanted);
  for (const port of [...named].sort((a, b) => a - b)) {
    const held = facts.held.has(port);
    const why = facts.reserved.has(port) ? notes.reserved
      : port < 1024 ? notes.low
      : facts.serve.has(port) ? notes.serve
      : !held && facts.certificate !== null ? facts.certificate
      : !facts.localUp.has(port) ? notes.down
      : !held && facts.tailnetUp.has(port) ? notes.taken
      : null;
    if (why !== null) {
      plan.notes.set(port, why);
      if (held) plan.close.push(port);
    } else {
      (held ? plan.keep : plan.open).push(port);
    }
  }
  for (const port of [...facts.held].sort((a, b) => a - b)) if (!named.has(port)) plan.close.push(port);
  return plan;
}

// ---------------------------------------------------------------------------------------------------------------
// What the listing is told

export const proxiedOrigin = (dnsName: string, port: number): string => `https://${dnsName}:${port}`;
export const proxiedAddress = (dnsName: string, port: number, path: string): string => `${proxiedOrigin(dnsName, port)}${path.startsWith("/") ? path : `/${path}`}`;

/** What the page server writes for the relay to read into `tabs` (`PeerProxyStatus` in the Swift package). */
export interface ProxyStatus {
  /** Unix seconds when it was written: a file older than a minute means the server is not running. */
  at: number;
  /** The host's tailnet name. */
  name: string;
  /** Why the proxy opens nothing at all (no certificate), or null. */
  note: string | null;
  /** The command that would fix it, when there is one (the operator): Settings shows it from here. */
  command: string | null;
  /** The ports held now, for Settings. */
  ports: number[];
  /** Each web or app pane's proxied address, or why it has none. */
  panes: Record<string, { url: string } | { note: string }>;
}

export function buildStatus(input: {
  now: number; dnsName: string; certificate: string | null; command: string | null; aims: PaneAim[]; plan: PortPlan; held: ReadonlySet<number>;
}): ProxyStatus {
  const panes: ProxyStatus["panes"] = {};
  for (const aim of input.aims) {
    if (aim.port === null) panes[aim.pane] = { note: aim.note };
    else if (input.held.has(aim.port) && !input.plan.close.includes(aim.port)) panes[aim.pane] = { url: proxiedAddress(input.dnsName, aim.port, aim.path) };
    else panes[aim.pane] = { note: input.plan.notes.get(aim.port) ?? notes.down };
  }
  return { at: Math.floor(input.now / 1000), name: input.dnsName, note: input.certificate, command: input.command, ports: [...input.held].sort((a, b) => a - b), panes };
}

// ---------------------------------------------------------------------------------------------------------------
// What Tailscale says

const portOf = (text: string): number | null => (/^[0-9]{1,5}$/.test(text) && Number(text) >= 1 && Number(text) <= 65535 ? Number(text) : null);

/** The ports `tailscale serve status --json` publishes: TCP forwards, web handlers and Funnel's. Empty when it can't be read. */
export function parseServePorts(text: string): Set<number> {
  const ports = new Set<number>();
  let json: unknown;
  try { json = JSON.parse(text); } catch { return ports; }
  if (!isObject(json)) return ports;
  const add = (port: number | null) => { if (port !== null) ports.add(port); };
  if (isObject(json.TCP)) for (const key of Object.keys(json.TCP)) add(portOf(key));
  for (const section of [json.Web, json.AllowFunnel]) {
    if (isObject(section)) for (const key of Object.keys(section)) add(portOf(key.slice(key.lastIndexOf(":") + 1)));
  }
  return ports;
}

/** This host's tailnet addresses from `tailscale status --json`: IPv4 and IPv6, nothing else. */
export function parseSelfAddresses(text: string): string[] {
  let json: unknown;
  try { json = parseTailnetJSON(text); } catch { return []; }
  const self = isObject(json) ? json.Self : null;
  const ips = isObject(self) && Array.isArray(self.TailscaleIPs) ? self.TailscaleIPs : [];
  return ips.filter((ip): ip is string => typeof ip === "string" && isIP(ip) !== 0);
}

// ---------------------------------------------------------------------------------------------------------------
// Who gets in

export type Admission =
  | { admitted: true; label: string | null; key: string }
  | { admitted: false; reason: "unknown" | "not-own" | "not-listed" };

/**
 * A device the host lists, or the node of a Mac it lists as a peer (found by its tailnet name, from `hosts`), and only a node of the
 * user's own: tagged and shared-in nodes never. `key` is what the caps count by.
 */
export function decideProxyCaller(node: WhoisNode | null, selfUserID: string | null, devices: Device[], peers: ReadonlySet<string>): Admission {
  const caller = decideCaller(node, selfUserID, devices);
  if (caller.kind === "device") return { admitted: true, label: caller.label, key: caller.device.id };
  if (caller.reason !== "not-listed" || !node) return { admitted: false, reason: caller.reason };
  if (mayBeListed(node, selfUserID) && node.dnsName !== null && peers.has(node.dnsName)) return { admitted: true, label: node.label, key: node.stableID };
  return { admitted: false, reason: "not-listed" };
}

interface HeaderReader {
  get(name: string): string | null;
}

/**
 * Whether a browser's request may go through, by what it says of itself. Another port of the same name is `same-site`, not `cross-site`,
 * and so is every host of the tailnet, so "not cross-site" would let any app on any port reach every other with the viewer's identity.
 * Let through only:
 * - `same-origin`: the proxied page's own requests, and its hot-reload socket;
 * - a page loaded whole (`Sec-Fetch-Dest: document`), whatever started it, as a typed address or an Open alone link;
 * - a page loaded into a frame by a page of the same site, as the phone's tab view does.
 * A navigation is a GET: a form posted from another page is not one. Without the header, an Origin when sent must be the proxied
 * address itself, and a client that sends neither (curl) goes through, as on the page.
 */
export function checkProxyFetch(method: string, headers: HeaderReader, origin: string): boolean {
  const site = headers.get("sec-fetch-site");
  if (site === null) {
    const sent = headers.get("origin");
    return sent === null || sent === origin;
  }
  if (site === "same-origin") return true;
  if (headers.get("sec-fetch-mode") !== "navigate" || (method !== "GET" && method !== "HEAD")) return false;
  const dest = headers.get("sec-fetch-dest");
  if (dest === "document") return true;
  return (dest === "iframe" || dest === "frame") && site === "same-site";
}

// ---------------------------------------------------------------------------------------------------------------
// Rewriting

const hopByHop = new Set(["connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade", "host"]);

/** The headers a `Connection` header names are the connection's own too (`Connection: close, X-Foo` drops X-Foo). */
function connectionNames(headers: [string, string][]): Set<string> {
  const names = new Set<string>();
  for (const [name, value] of headers) {
    if (name.toLowerCase() === "connection") for (const token of value.split(",")) names.add(token.trim().toLowerCase());
  }
  return names;
}

/**
 * The headers a request goes to the server with: Host as the server's own (dev servers refuse any other), Origin as the server's own
 * when it is the proxied address, nothing else changed. Websocket handshake headers are the client's own to make, so they go too.
 */
export function upstreamHeaders(headers: Iterable<[string, string]>, port: number, origin: string, websocket = false): Headers {
  const out = new Headers();
  const listed = [...headers];
  const named = connectionNames(listed);
  for (const [name, value] of listed) {
    const lower = name.toLowerCase();
    if (hopByHop.has(lower) || named.has(lower) || (websocket && (lower.startsWith("sec-websocket-")))) continue;
    out.set(name, lower === "origin" && value === origin ? `http://localhost:${port}` : value);
  }
  out.set("host", `localhost:${port}`);
  return out;
}

/** The headers of a response: the connection's own are the proxy's. */
export function downstreamHeaders(headers: Iterable<[string, string]>, port: number, origin: string): Headers {
  const out = new Headers();
  const listed = [...headers];
  const named = connectionNames(listed);
  for (const [name, value] of listed) {
    const lower = name.toLowerCase();
    if (hopByHop.has(lower) || named.has(lower)) continue;
    out.set(name, lower === "location" ? rewriteLocation(value, port, origin) : value);
  }
  return out;
}

/** A redirect to the server's own localhost address goes back to the proxied one; any other Location is untouched. */
export function rewriteLocation(location: string, port: number, origin: string): string {
  const match = /^(https?):\/\/(?:localhost|127\.0\.0\.1|\[::1\])(?::([0-9]+))?(?=[/?#]|$)/i.exec(location);
  if (!match) return location;
  const named = match[2] !== undefined ? Number(match[2]) : match[1].toLowerCase() === "https" ? 443 : 80;
  return named === port ? origin + location.slice(match[0].length) : location;
}

// ---------------------------------------------------------------------------------------------------------------
// Host

/** Whether a request's Host is the proxied name and port: anything else is a name that isn't ours (DNS rebinding) or no name at all. */
export function checkProxyHost(host: string | null, dnsName: string, port: number): boolean {
  return host !== null && host.toLowerCase() === `${dnsName}:${port}`;
}
