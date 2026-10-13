// The links on Home to the other hosts' Phone pages: the hosts this one lists as peers (the relay's `hosts`, names and
// addresses and never ids), each turned into the page that host would serve at its own tailnet name. No I/O.
//
// The page can't know whether a host has published its page, so a link only says where it would be: opening one
// shows the browser's own error when that host serves none.

import { parseTailnetJSON } from "./checks";
import { isObject, objects } from "./json";

export interface HostLink {
  name: string;
  /** `https://<tailnet name>:<port>/`. */
  url: string;
}

/** A name a person types after `ssh`, once `user@` is off: dot-separated DNS labels, so never a port, an IPv6 address or a `%` zone. */
const hostName = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/;

/** The host part of an address ("alex@linux-box" is "linux-box"), lowercase; null for anything that isn't a plain name. */
export function addressHost(address: string): string | null {
  const host = address.slice(address.lastIndexOf("@") + 1).toLowerCase();
  return hostName.test(host) && host.length <= 253 ? host : null;
}

/** The MagicDNS names of this node and its peers from `tailscale status --json` (lowercase, no final dot). Empty when it can't be read. */
export function parseNodeNames(text: string): Set<string> {
  let json: unknown;
  try { json = parseTailnetJSON(text); } catch { return new Set(); }
  if (!isObject(json)) return new Set();
  const names = new Set<string>();
  const add = (node: unknown) => {
    if (isObject(node) && typeof node.DNSName === "string" && node.DNSName !== "") names.add(node.DNSName.replace(/\.$/, "").toLowerCase());
  };
  add(json.Self);
  if (isObject(json.Peer)) for (const node of Object.values(json.Peer)) add(node);
  return names;
}

/**
 * The nodes of a relay's `hosts` reply. An address names a node only if it is one of this tailnet: a name with no dot
 * is read under this host's own tailnet suffix ("linux-box" is "linux-box.example.ts.net", as a Mac saves a headless host), a dotted
 * one must be a node as it stands, and `nodes` (the tailnet's own list) is what says so, so an address such as
 * `alex@check`, or one outside the tailnet, names none. This host itself is left out, and a host listed twice shows once.
 */
export function hostNodes(reply: Record<string, unknown>, own: string, nodes: Set<string>): { name: string; dns: string }[] {
  const suffix = own.includes(".") ? own.slice(own.indexOf(".") + 1) : "";
  const found: { name: string; dns: string }[] = [];
  const seen = new Set<string>([own.toLowerCase()]);
  for (const entry of objects(reply.hosts)) {
    const host = typeof entry.address === "string" ? addressHost(entry.address) : null;
    if (host === null) continue;
    const dns = host.includes(".") ? host : suffix ? `${host}.${suffix}` : null;
    if (dns === null || !nodes.has(dns) || seen.has(dns)) continue;
    seen.add(dns);
    const named = typeof entry.name === "string" ? entry.name.replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, 80) : "";
    found.push({ name: named || dns.split(".")[0], dns });
  }
  return found;
}

/** The links to the other hosts' pages: each node `hostNodes` finds, at the page's port. */
export function hostLinks(reply: Record<string, unknown>, own: string, nodes: Set<string>, port: number): HostLink[] {
  return hostNodes(reply, own, nodes).map(({ name, dns }) => ({ name, url: `https://${dns}:${port}/` }));
}
