// The port proxy (ADR 0035): one TLS listener per port that the host's open tabs' web and app panes use, on the host's tailnet addresses
// only, forwarding to the same port on localhost so another machine's pane can load what runs here. proxy.ts holds every decision;
// this file holds the listeners, the certificate and the status file, with the world it asks about passed in (`ProxyWorld`), so
// portproxy.test.ts drives it on throwaway ports.
//
// A port opens only while its server answers on localhost and nothing else answers on the tailnet address at it (see `planPorts`), and
// closes when that stops. Logs hold the port, the code and the time: never a path, a query or a body.

import { renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Device, WhoisNode } from "./checks";
import {
  aimsOf, buildStatus, checkProxyFetch, checkProxyHost, decideProxyCaller, downstreamHeaders, notes, planPorts, proxiedOrigin, upstreamHeaders,
  type Admission, type PaneAim, type PortFacts, type PortPlan,
} from "./proxy";
import { Slots } from "./relay";

/** The certificate and key as PEM text, or why there is none. */
export type CertificateResult = { ok: true; cert: string; key: string } | { ok: false; note: string };

/** What the proxy asks of the world. server.ts gives the real ones; a check gives fakes. */
export interface ProxyWorld {
  /** The host's own `tabs` reply, as the relay printed it. */
  tabs(): Promise<{ ok: true; reply: Record<string, unknown> } | { ok: false; error: string }>;
  /** The ports `tailscale serve` publishes. */
  servePorts(): Promise<ReadonlySet<number>>;
  /** The host's tailnet addresses. */
  addresses(): Promise<string[]>;
  certificate(): Promise<CertificateResult>;
  whois(address: string): Promise<WhoisNode | null>;
  /** The devices the host lists, read when asked. */
  devices(): Device[];
  /** The tailnet names of the Macs the host lists as peers. */
  peers(): Promise<ReadonlySet<string>>;
  log(line: string): void;
}

export interface ProxyOptions {
  dnsName: string;
  /** The host's own user, for the own-node rule. */
  userID: string;
  /** Ports never opened: the page's own. */
  reserved: number[];
  /** The owner-only folder where the status file is written. */
  statusPath: string;
  /** TLS, always, except in a check that has no certificate to give. */
  tls?: boolean;
  /** Where a forward goes, in order; a check has no use for the second. */
  upstreams?: string[];
  /** How long between looks. */
  intervalMs?: number;
}

const websocketsInAll = 32;
const websocketsPerCaller = 8;
const requestsInAll = 512;
const requestsPerCaller = 256;
const noCertificateYet = "No certificate yet.";
const certificateRetryMs = 60_000;
const certificateRefreshMs = 24 * 3600_000;

/** Whether something accepts a TCP connection at `hostname:port`. */
export function answers(hostname: string, port: number, timeoutMs = 1000): Promise<boolean> {
  return new Promise((resolve) => {
    let settled = false;
    const done = (value: boolean) => { if (!settled) { settled = true; clearTimeout(timer); resolve(value); } };
    const timer = setTimeout(() => done(false), timeoutMs);
    Bun.connect({ hostname, port, socket: { open(socket) { socket.end(); done(true); }, data() {}, error() { done(false); }, connectError() { done(false); } } })
      .catch(() => done(false));
  });
}

interface Listener {
  port: number;
  servers: Bun.Server<ProxiedSocket>[];
  sockets: Slots;
  requests: Slots;
}

interface ProxiedSocket {
  upstream: WebSocket;
  release: () => void;
  /** What the server sent between its socket opening and the browser's upgrade being answered. */
  queued: (string | ArrayBuffer)[];
  closed: boolean;
}

/** A close code a socket may send: 1005, 1006 and 1015 are only ever reported, never sent. */
const sendableCode = (code: number): number => (code === 1000 || (code >= 3000 && code <= 4999) ? code : 1000);

export class PortProxy {
  private listeners = new Map<number, Listener>();
  private certificate: { cert: string; key: string } | null = null;
  private certificateNote: string | null = null;
  private certificateAskedAt = 0;
  private certificateOKAt = 0;
  private aims: PaneAim[] = [];
  private looking: Promise<void> | null = null;
  private lookAgain = false;
  private lookedAt = 0;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private stopped = false;
  private readonly upstreams: string[];
  private readonly tls: boolean;

  constructor(private world: ProxyWorld, private options: ProxyOptions) {
    this.upstreams = options.upstreams ?? ["127.0.0.1", "[::1]"];
    this.tls = options.tls !== false;
  }

  /** The ports held now. */
  heldPorts(): number[] {
    return [...this.listeners.keys()].sort((a, b) => a - b);
  }

  /** Starts looking every few seconds. The first look is now. */
  start(): void {
    const again = () => {
      if (this.stopped) return;
      this.timer = setTimeout(() => { void this.look().finally(again); }, this.options.intervalMs ?? 5000);
    };
    void this.look().finally(again);
  }

  /** A page asked about a tab: look again soon, unless a look has just run. */
  touch(): void {
    if (!this.stopped && Date.now() - this.lookedAt > 2000) void this.look();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    clearTimeout(this.timer);
    for (const port of this.heldPorts()) this.close(port, "stopped");
    rmSync(this.options.statusPath, { force: true });
  }

  /** One look, at most one at a time: a look asked for while one runs is run once more when it ends. */
  look(): Promise<void> {
    if (this.looking) {
      this.lookAgain = true;
      return this.looking;
    }
    this.looking = (async () => {
      try {
        do {
          this.lookAgain = false;
          await this.lookOnce();
        } while (this.lookAgain && !this.stopped);
      } catch (error) {
        this.world.log(`proxy look failed: ${(error as Error)?.name ?? "unknown"}`);
      } finally {
        this.looking = null;
      }
    })();
    return this.looking;
  }

  private async lookOnce(): Promise<void> {
    if (this.stopped) return;
    this.lookedAt = Date.now();
    const tabs = await this.world.tabs();
    // A relay that didn't answer changes nothing this time: the ports stay as they were.
    if (tabs.ok) this.aims = aimsOf(tabs.reply.tabs);
    await this.ensureCertificate();

    const wanted = new Set(this.aims.flatMap((aim) => (aim.port === null ? [] : [aim.port])));
    const held = new Set(this.listeners.keys());
    const candidates = new Set([...wanted, ...held]);
    let serve: ReadonlySet<number> = new Set();
    let addresses: string[] = [];
    const localUp = new Set<number>(), tailnetUp = new Set<number>();
    if (candidates.size > 0) {
      [serve, addresses] = await Promise.all([this.world.servePorts(), this.world.addresses()]);
      await Promise.all([...candidates].map(async (port) => { if (await this.answersOnLocalhost(port)) localUp.add(port); }));
      // A held port answers on the tailnet address itself, so only the others are looked at there.
      await Promise.all([...wanted].filter((port) => !held.has(port) && localUp.has(port)).map(async (port) => {
        if ((await Promise.all(addresses.map((address) => answers(address, port)))).some(Boolean)) tailnetUp.add(port);
      }));
    }
    const facts: PortFacts = {
      reserved: new Set(this.options.reserved), serve, localUp, tailnetUp, held,
      certificate: this.certificate === null && this.tls ? this.certificateNote ?? noCertificateYet : null,
    };
    const plan = planPorts(wanted, facts);
    for (const port of plan.close) this.close(port, plan.notes.get(port) ?? "no tab names it");
    for (const port of plan.open) {
      const failure = this.open(port, addresses);
      if (failure) plan.notes.set(port, failure);
    }
    this.writeStatus(plan);
  }

  // -------------------------------------------------------------------------------------------------------------
  // The certificate

  private async ensureCertificate(): Promise<void> {
    if (!this.tls) return;
    const now = Date.now();
    const due = this.certificate === null ? now - this.certificateAskedAt >= certificateRetryMs : now - this.certificateOKAt >= certificateRefreshMs;
    if (due || this.certificateAskedAt === 0) await this.renewCertificate();
  }

  /** Asks for the certificate. A new one replaces the old on every port held: Bun's reload of TLS options keeps serving the old one, so each listener is stopped and served again. */
  async renewCertificate(): Promise<void> {
    this.certificateAskedAt = Date.now();
    const result = await this.world.certificate();
    if (!result.ok) {
      this.certificateNote = result.note;
      this.world.log("proxy certificate: none");
      return;
    }
    this.certificateNote = null;
    this.certificateOKAt = Date.now();
    const changed = this.certificate === null || this.certificate.cert !== result.cert || this.certificate.key !== result.key;
    this.certificate = { cert: result.cert, key: result.key };
    if (!changed) return;
    for (const listener of [...this.listeners.values()]) {
      const hostnames = listener.servers.map((server) => server.hostname).filter((name): name is string => typeof name === "string");
      for (const server of listener.servers) void server.stop(false);
      try {
        listener.servers = this.serve(listener, hostnames);
      } catch {
        // The port couldn't be served again: it is not held, and the next look opens it.
        this.listeners.delete(listener.port);
        this.world.log(`proxy close :${listener.port} (certificate swap failed)`);
      }
    }
    if (this.listeners.size > 0) this.world.log(`proxy certificate renewed for ${this.listeners.size} ports`);
  }

  // -------------------------------------------------------------------------------------------------------------
  // The listeners

  /** Opens `port` on every tailnet address that takes it. Returns why it couldn't, or null. */
  private open(port: number, addresses: string[]): string | null {
    if (addresses.length === 0) return "Tailscale gave no address for this machine.";
    const listener: Listener = { port, servers: [], sockets: new Slots(websocketsInAll, websocketsPerCaller), requests: new Slots(requestsInAll, requestsPerCaller) };
    let code = "";
    const bound: string[] = [];
    for (const address of addresses) {
      try {
        listener.servers.push(...this.serve(listener, [address]));
        bound.push(address);
      } catch (error) {
        code = (error as NodeJS.ErrnoException)?.code ?? (error as Error)?.name ?? "error";
      }
    }
    if (listener.servers.length === 0) {
      this.world.log(`proxy open :${port} failed ${code}`);
      return `The proxy couldn't open this port (${code}).`;
    }
    this.listeners.set(port, listener);
    this.world.log(`proxy open :${port} on ${bound.length} address${bound.length === 1 ? "" : "es"}`);
    return null;
  }

  private serve(listener: Listener, hostnames: string[]): Bun.Server<ProxiedSocket>[] {
    const servers: Bun.Server<ProxiedSocket>[] = [];
    for (const hostname of hostnames) {
      try {
        servers.push(Bun.serve<ProxiedSocket>({
          hostname,
          port: listener.port,
          ...(this.tls && this.certificate ? { tls: { cert: this.certificate.cert, key: this.certificate.key } } : {}),
          idleTimeout: 120,
          websocket: socketHandlers,
          fetch: (request, server) => this.handle(listener, request, server),
          error: () => new Response("Bad gateway\n", { status: 502 }),
        }));
      } catch (error) {
        // One address of two may not bind (no IPv6 on the tailnet, say): the port is held if any does.
        if (hostnames.length === 1 && servers.length === 0) throw error;
        this.world.log(`proxy open :${listener.port} failed ${(error as NodeJS.ErrnoException)?.code ?? "error"}`);
      }
    }
    return servers;
  }

  private close(port: number, why: string): void {
    const listener = this.listeners.get(port);
    if (!listener) return;
    this.listeners.delete(port);
    for (const server of listener.servers) void server.stop(false);
    this.world.log(`proxy close :${port} (${why.length > 60 ? "see status" : why})`);
  }

  // -------------------------------------------------------------------------------------------------------------
  // A request

  private async handle(listener: Listener, request: Request, server: Bun.Server<ProxiedSocket>): Promise<Response | undefined> {
    const { port } = listener;
    const refuse = (status: number, text: string) => {
      this.world.log(`proxy :${port} ${status}`);
      return new Response(`${text}\n`, { status, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });
    };
    if (!checkProxyHost(request.headers.get("host"), this.options.dnsName, port)) return refuse(421, "Misdirected request");
    const address = server.requestIP(request)?.address;
    if (!address) return refuse(403, "Not admitted");
    const admission = await this.admit(address);
    if (!admission.admitted) return refuse(403, "Not admitted");
    const origin = proxiedOrigin(this.options.dnsName, port);
    if (!checkProxyFetch(request.method, request.headers, origin)) return refuse(403, "cross-site");

    const url = new URL(request.url);
    const target = `${url.pathname}${url.search}`;
    if ((request.headers.get("upgrade") ?? "").toLowerCase() === "websocket") return this.upgrade(listener, request, server, admission.key, target, origin);

    if (!listener.requests.acquire(admission.key)) return refuse(429, "Too many requests");
    try {
      return await this.forward(listener, request, target, origin);
    } finally {
      listener.requests.release(admission.key);
    }
  }

  /** The whois node against the devices the host lists, then, for a node that isn't one, against the Macs it lists as peers. */
  private async admit(address: string): Promise<Admission> {
    const node = await this.world.whois(address);
    const devices = this.world.devices();
    const first = decideProxyCaller(node, this.options.userID, devices, new Set());
    if (first.admitted || first.reason !== "not-listed") return first;
    return decideProxyCaller(node, this.options.userID, devices, await this.world.peers());
  }

  private async forward(listener: Listener, request: Request, target: string, origin: string): Promise<Response> {
    const { port } = listener;
    const headers = upstreamHeaders(request.headers, port, origin);
    const hasBody = request.method !== "GET" && request.method !== "HEAD" && request.body !== null;
    // A body can be sent once: a request that has one tries the first address only.
    for (const host of hasBody ? this.upstreams.slice(0, 1) : this.upstreams) {
      try {
        const upstream = await fetch(`http://${host}:${port}${target}`, {
          method: request.method, headers, body: hasBody ? request.body : undefined, redirect: "manual", decompress: false, signal: request.signal,
        } as RequestInit);
        const body = request.method === "HEAD" || upstream.status === 204 || upstream.status === 304 ? null : upstream.body;
        return new Response(body, { status: upstream.status, statusText: upstream.statusText, headers: downstreamHeaders(upstream.headers, port, origin) });
      } catch {
        if (request.signal.aborted) return new Response(null, { status: 499 });
      }
    }
    // Nothing answered: if the server has gone, the port goes with it at once, so a restart doesn't find it held.
    if (!(await this.answersOnLocalhost(port))) this.close(port, notes.down);
    this.world.log(`proxy :${port} 502`);
    return new Response(`${notes.down}\n`, { status: 502, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });
  }

  private async answersOnLocalhost(port: number): Promise<boolean> {
    return (await Promise.all(this.upstreams.map((host) => answers(host.replace(/^\[|\]$/g, ""), port)))).some(Boolean);
  }

  /** The upstream socket is opened before the browser's upgrade is answered, so the subprotocol the server picked can go back in the answer. */
  private async upgrade(listener: Listener, request: Request, server: Bun.Server<ProxiedSocket>, key: string, target: string, origin: string): Promise<Response | undefined> {
    const { port } = listener;
    const refuse = (status: number, text: string) => {
      this.world.log(`proxy :${port} ${status}`);
      return new Response(`${text}\n`, { status, headers: { "content-type": "text/plain; charset=utf-8" } });
    };
    if (request.method !== "GET") return refuse(405, "Method not allowed");
    if (!listener.sockets.acquire(key)) return refuse(429, "Too many sockets");
    let released = false;
    const release = () => { if (!released) { released = true; listener.sockets.release(key); } };
    const protocols = (request.headers.get("sec-websocket-protocol") ?? "").split(",").map((word) => word.trim()).filter(Boolean);
    const headers = Object.fromEntries(upstreamHeaders(request.headers, port, origin, true));
    for (const host of this.upstreams) {
      const upstream = await openUpstream(`ws://${host}:${port}${target}`, protocols, headers);
      if (!upstream) continue;
      const data: ProxiedSocket = { upstream, release, queued: [], closed: false };
      upstream.onmessage = (event) => { data.queued.push(event.data as string | ArrayBuffer); };
      const picked = upstream.protocol;
      if (server.upgrade(request, { data, headers: picked ? { "sec-websocket-protocol": picked } : undefined })) return undefined;
      upstream.close();
      release();
      return refuse(400, "Upgrade failed");
    }
    release();
    if (!(await this.answersOnLocalhost(port))) this.close(port, notes.down);
    return refuse(502, notes.down);
  }

  // -------------------------------------------------------------------------------------------------------------
  // The status file

  /** What the relay reads into `tabs`: written each look, so a file older than a minute means this server is not running. */
  private writeStatus(plan: PortPlan): void {
    const status = buildStatus({
      now: Date.now(), dnsName: this.options.dnsName, certificate: this.tls ? this.certificateNote : null, aims: this.aims, plan,
      held: new Set(this.listeners.keys()),
    });
    const temp = `${this.options.statusPath}.${process.pid}.tmp`;
    try {
      writeFileSync(temp, JSON.stringify(status), { mode: 0o600 });
      renameSync(temp, this.options.statusPath);
    } catch {
      rmSync(temp, { force: true });
      this.world.log("proxy status: couldn't be written");
    }
  }
}

/** Opens a socket to the server, or null when it doesn't open in time. */
function openUpstream(url: string, protocols: string[], headers: Record<string, string>): Promise<WebSocket | null> {
  return new Promise((resolve) => {
    let socket: WebSocket;
    try {
      socket = new WebSocket(url, (protocols.length > 0 ? { protocols, headers } : { headers }) as unknown as string[]);
    } catch {
      return resolve(null);
    }
    socket.binaryType = "arraybuffer";
    const timer = setTimeout(() => { socket.close(); resolve(null); }, 10_000);
    socket.onopen = () => { clearTimeout(timer); resolve(socket); };
    socket.onerror = () => { clearTimeout(timer); resolve(null); };
    socket.onclose = () => { clearTimeout(timer); resolve(null); };
  });
}

/** Both directions of a proxied socket: what either end sends goes to the other, and either end closing closes both. */
const socketHandlers: Bun.WebSocketHandler<ProxiedSocket> = {
  maxPayloadLength: 64 << 20,
  idleTimeout: 120,
  backpressureLimit: 8 << 20,
  closeOnBackpressureLimit: true,
  open(ws) {
    const { upstream, queued } = ws.data;
    if (upstream.readyState !== WebSocket.OPEN) {
      ws.data.closed = true;
      ws.data.release();
      return ws.close(1011, "upstream closed");
    }
    for (const message of queued.splice(0)) ws.send(message);
    upstream.onmessage = (event) => { if (!ws.data.closed) ws.send(event.data as string | ArrayBuffer); };
    upstream.onclose = (event) => { ws.data.closed = true; ws.data.release(); ws.close(sendableCode(event.code), event.reason.slice(0, 100)); };
    upstream.onerror = () => { ws.data.closed = true; ws.data.release(); ws.close(1011, "upstream error"); };
  },
  message(ws, message) {
    if (ws.data.upstream.readyState === WebSocket.OPEN) ws.data.upstream.send(message);
  },
  close(ws, code, reason) {
    ws.data.closed = true;
    ws.data.release();
    try { ws.data.upstream.close(sendableCode(code), reason.slice(0, 100)); } catch { /* already closing */ }
  },
};

// ---------------------------------------------------------------------------------------------------------------
// The real world

/** The folder's files `tailscale cert` writes to and the certificate read back from them. */
export const certificateFiles = (folder: string) => ({ cert: join(folder, "proxy.crt"), key: join(folder, "proxy.key") });

/** How `tailscale cert`'s refusal is told: the operator is the usual cause, and the fix takes root once. */
export function certificateNote(stderr: string): string {
  const line = stderr.split("\n").map((text) => text.trim()).find((text) => text !== "") ?? "";
  if (/access denied|cert access denied/i.test(line)) return 'No certificate: Tailscale gives one only to its operator. Run "sudo tailscale set --operator=$USER" once.';
  return line === "" ? "No certificate: Tailscale didn't answer." : `No certificate: Tailscale said ${line.slice(0, 160)}`;
}
