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
  aimsOf, buildStatus, checkProxyFetch, checkProxyHost, decideProxyCaller, downstreamHeaders, notes, openFailure, planPorts, proxiedOrigin, upstreamHeaders,
  type Admission, type PaneAim, type PortFacts, type PortPlan,
} from "./proxy";
import { Slots } from "./relay";

/** The certificate and key as PEM text, or why there is none (and the command that would give one, when there is one). */
export type CertificateResult = { ok: true; cert: string; key: string } | { ok: false; note: string; command?: string | null };

/** What the proxy asks of the world. server.ts gives the real ones; a check gives fakes. */
export interface ProxyWorld {
  /** The host's own `tabs` reply, as the relay printed it. */
  tabs(): Promise<{ ok: true; reply: Record<string, unknown> } | { ok: false; error: string }>;
  /** A stamp of the saved tabs that changes when they do, so a look with the same stamp as the last doesn't run the relay. Absent: the relay is run each look. */
  tabsStamp?(): string | null;
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
  /** How long between looks while a port is wanted or held; with none, three times as long. */
  intervalMs?: number;
  /** How long a relay may fail before every port closes (a minute). */
  relayGraceMs?: number;
}

const websocketsInAll = 32;
const websocketsPerCaller = 8;
const requestsInAll = 512;
const requestsPerCaller = 256;
/** The most a socket may have waiting to go to the server before it is closed. */
const upstreamBacklog = 8 << 20;
const certificateRetryMs = 60_000;
/** With no port wanted there is no hurry to find the operator set, but Settings shows it, so it is asked now and then. */
const certificateIdleRetryMs = 3600_000;
const certificateRefreshMs = 24 * 3600_000;
/** The saved tabs are read by the relay at least this often, whatever their stamp says. */
const relayRefreshMs = 300_000;
/** A relay that keeps failing for this long no longer vouches for the ports it once named: they close. */
const relayFailureMs = 60_000;
const addressesLifetimeMs = 60_000;

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

type ProxiedWebSocket = Bun.ServerWebSocket<ProxiedSocket>;

interface Listener {
  port: number;
  /** The tailnet addresses it is bound to. */
  addresses: string[];
  servers: Bun.Server<ProxiedSocket>[];
  sockets: Slots;
  requests: Slots;
  /** The sockets open now, so a caller no longer admitted is cut off. */
  open: Set<ProxiedWebSocket>;
}

interface ProxiedSocket {
  upstream: WebSocket;
  release: () => void;
  /** What the server sent between its socket opening and the browser's upgrade being answered. */
  queued: (string | ArrayBuffer)[];
  closed: boolean;
  /** The caller's address, asked about again at each look. */
  address: string;
  open: Set<ProxiedWebSocket>;
}

/** A close code a socket may send: 1005, 1006 and 1015 are only ever reported, never sent. */
const sendableCode = (code: number): number => (code === 1000 || (code >= 3000 && code <= 4999) ? code : 1000);

const emptyPlan = (): PortPlan => ({ open: [], keep: [], close: [], notes: new Map() });
const plain = { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" };

export class PortProxy {
  private listeners = new Map<number, Listener>();
  private certificate: { cert: string; key: string } | null = null;
  private certificateNote: { note: string; command: string | null } | null = null;
  private certificateAskedAt = 0;
  private certificateOKAt = 0;
  private aims: PaneAim[] = [];
  private plan: PortPlan = emptyPlan();
  private stamp: string | null = null;
  private relayAt = 0;
  private relayWasOK = false;
  private relayOKAt = Date.now();
  private addressList: { at: number; list: string[] } = { at: 0, list: [] };
  /** The reason last logged for each port that isn't open, so a look every few seconds doesn't repeat it. */
  private logged = new Map<number, string>();
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
      const active = this.options.intervalMs ?? 5000;
      const idle = this.aims.length === 0 && this.listeners.size === 0;
      this.timer = setTimeout(() => { void this.look().finally(again); }, idle ? active * 3 : active);
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
    await this.readTabs();
    const wanted = new Set(this.aims.flatMap((aim) => (aim.port === null ? [] : [aim.port])));
    const held = new Set(this.listeners.keys());
    if (this.certificateDue(wanted.size > 0 || held.size > 0)) {
      // The status is written before and after the slow call, so a certificate that takes a while never makes the file look stale.
      this.writeStatus(this.plan);
      await this.renewCertificate();
      this.writeStatus(this.plan);
    }

    const candidates = new Set([...wanted, ...held]);
    let serve: ReadonlySet<number> = new Set();
    let addresses: string[] = [];
    const localUp = new Set<number>(), tailnetUp = new Set<number>();
    if (candidates.size > 0) {
      [serve, addresses] = await Promise.all([this.world.servePorts(), this.tailnetAddresses()]);
      await Promise.all([...candidates].map(async (port) => { if (await this.answersOnLocalhost(port)) localUp.add(port); }));
      // A held port answers on the tailnet address itself, so only the others are looked at there.
      await Promise.all([...wanted].filter((port) => !held.has(port) && localUp.has(port)).map(async (port) => {
        if ((await Promise.all(addresses.map((address) => answers(address, port)))).some(Boolean)) tailnetUp.add(port);
      }));
    }
    const facts: PortFacts = {
      reserved: new Set(this.options.reserved), serve, localUp, tailnetUp, held,
      certificate: this.missingCertificate()?.note ?? null,
    };
    const plan = planPorts(wanted, facts);
    for (const port of plan.close) this.close(port, plan.notes.get(port) ?? "no tab names it");
    for (const port of plan.open) {
      const failure = this.open(port, addresses);
      if (failure) plan.notes.set(port, failure);
    }
    this.logRefusals(plan, wanted);
    this.plan = plan;
    this.writeStatus(plan);
    await this.cutOffRemoved();
  }

  /** The tabs the relay lists, unless the saved tabs have not changed since it was last asked; a relay failing for a minute closes every port. */
  private async readTabs(): Promise<void> {
    const now = Date.now();
    const stamp = this.world.tabsStamp ? this.world.tabsStamp() : null;
    if (stamp !== null && stamp === this.stamp && this.relayWasOK && now - this.relayAt < relayRefreshMs) {
      this.relayOKAt = now;
      return;
    }
    const tabs = await this.world.tabs();
    this.relayAt = Date.now();
    this.relayWasOK = tabs.ok;
    if (tabs.ok) {
      this.aims = aimsOf(tabs.reply.tabs);
      this.stamp = stamp;
      this.relayOKAt = now;
    } else if (now - this.relayOKAt > (this.options.relayGraceMs ?? relayFailureMs)) {
      // Nothing vouches for the ports any more: a pane closed meanwhile would keep its port open for good.
      if (this.aims.length > 0) this.world.log("proxy: the relay has not answered for a minute, so every port closes");
      this.aims = [];
      this.stamp = null;
    }
  }

  private async tailnetAddresses(): Promise<string[]> {
    if (this.addressList.list.length === 0 || Date.now() - this.addressList.at > addressesLifetimeMs) {
      this.addressList = { at: Date.now(), list: await this.world.addresses() };
    }
    return this.addressList.list;
  }

  /** A port that isn't open is logged with its reason, once for as long as the reason stands. */
  private logRefusals(plan: PortPlan, wanted: Set<number>): void {
    for (const port of [...this.logged.keys()]) if (!wanted.has(port) || !plan.notes.has(port)) this.logged.delete(port);
    for (const [port, note] of plan.notes) {
      if (this.logged.get(port) === note) continue;
      this.logged.set(port, note);
      this.world.log(`proxy :${port} not opened: ${note}`);
    }
  }

  // -------------------------------------------------------------------------------------------------------------
  // The certificate

  private certificateDue(wanted: boolean): boolean {
    if (!this.tls) return false;
    if (this.certificateAskedAt === 0) return true;
    const now = Date.now();
    if (this.certificate === null) return now - this.certificateAskedAt >= (wanted ? certificateRetryMs : certificateIdleRetryMs);
    return now - this.certificateOKAt >= certificateRefreshMs;
  }

  /** Asks for the certificate. A new one replaces the old on every port held: Bun's reload of TLS options keeps serving the old one, so each listener is stopped and served again. */
  async renewCertificate(): Promise<void> {
    this.certificateAskedAt = Date.now();
    const result = await this.world.certificate();
    if (!result.ok) {
      this.certificateNote = { note: result.note, command: result.command ?? null };
      this.world.log("proxy certificate: none");
      return;
    }
    this.certificateNote = null;
    this.certificateOKAt = Date.now();
    const changed = this.certificate === null || this.certificate.cert !== result.cert || this.certificate.key !== result.key;
    this.certificate = { cert: result.cert, key: result.key };
    if (!changed) return;
    for (const listener of [...this.listeners.values()]) {
      // Connections open now finish on the old certificate; new ones get the new.
      for (const server of listener.servers) void server.stop(false);
      try {
        listener.servers = this.serve(listener, listener.addresses);
      } catch {
        listener.servers = [];
      }
      if (listener.servers.length === 0) {
        // Nothing is serving it: not held, and the next look opens it.
        this.listeners.delete(listener.port);
        this.world.log(`proxy close :${listener.port} (certificate swap failed)`);
      }
    }
    if (this.listeners.size > 0) this.world.log(`proxy certificate renewed for ${this.listeners.size} ports`);
  }

  /** Why there is no certificate to serve with, or null when there is one (a renewal that failed leaves the old one serving). */
  private missingCertificate(): { note: string; command: string | null } | null {
    if (this.certificate !== null || !this.tls || this.certificateAskedAt === 0) return null;
    return this.certificateNote ?? { note: notes.noCertificate, command: null };
  }

  // -------------------------------------------------------------------------------------------------------------
  // The listeners

  /** Opens `port` on every tailnet address that takes it. Returns why it couldn't, or null. */
  private open(port: number, addresses: string[]): string | null {
    if (addresses.length === 0) return notes.noAddress;
    const listener: Listener = {
      port, addresses: [], servers: [], sockets: new Slots(websocketsInAll, websocketsPerCaller), requests: new Slots(requestsInAll, requestsPerCaller), open: new Set(),
    };
    let code = "";
    for (const address of addresses) {
      try {
        listener.servers.push(...this.serve(listener, [address]));
        listener.addresses.push(address);
      } catch (error) {
        code = (error as NodeJS.ErrnoException)?.code ?? (error as Error)?.name ?? "error";
      }
    }
    if (listener.servers.length === 0) return openFailure(code);
    this.listeners.set(port, listener);
    this.world.log(`proxy open :${port} on ${listener.addresses.length} address${listener.addresses.length === 1 ? "" : "es"}`);
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
        if (hostnames.length === 1) throw error;
      }
    }
    return servers;
  }

  /**
   * Closes the port and everything open on it, websockets too: a tunnel left open would go on serving a port no tab names. A forward that
   * found the server gone closes it `gently`, so the answer it is giving still goes out.
   */
  private close(port: number, why: string, gently = false): void {
    const listener = this.listeners.get(port);
    if (!listener) return;
    this.listeners.delete(port);
    for (const server of listener.servers) void server.stop(!gently);
    this.world.log(`proxy close :${port} (${why.length > 60 ? "see status" : why})`);
  }

  /** Sockets of a caller the host no longer admits (a device removed, a Mac unpaired) are closed. A caller whose whois failed this time stays. */
  private async cutOffRemoved(): Promise<void> {
    const verdicts = new Map<string, Admission>();
    for (const listener of this.listeners.values()) {
      for (const ws of [...listener.open]) {
        const address = ws.data.address;
        let verdict = verdicts.get(address);
        if (!verdict) {
          verdict = await this.admit(address);
          verdicts.set(address, verdict);
        }
        if (!verdict.admitted && verdict.reason !== "unknown") ws.close(1008, "not admitted");
      }
    }
  }

  // -------------------------------------------------------------------------------------------------------------
  // A request

  private refusal(port: number, status: number, text: string): Response {
    this.world.log(`proxy :${port} ${status}`);
    return new Response(`${text}\n`, { status, headers: plain });
  }

  private async handle(listener: Listener, request: Request, server: Bun.Server<ProxiedSocket>): Promise<Response | undefined> {
    const { port } = listener;
    if (!checkProxyHost(request.headers.get("host"), this.options.dnsName, port)) return this.refusal(port, 421, "Misdirected request");
    const address = server.requestIP(request)?.address;
    if (!address) return this.refusal(port, 403, "Not admitted");
    const admission = await this.admit(address);
    if (!admission.admitted) return this.refusal(port, 403, "Not admitted");
    const origin = proxiedOrigin(this.options.dnsName, port);
    if (!checkProxyFetch(request.method, request.headers, origin)) return this.refusal(port, 403, "cross-site");

    const url = new URL(request.url);
    const target = `${url.pathname}${url.search}`;
    if ((request.headers.get("upgrade") ?? "").toLowerCase() === "websocket") return this.upgrade(listener, request, server, admission.key, address, target, origin);

    if (!listener.requests.acquire(admission.key)) return this.refusal(port, 429, "Too many requests");
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
    if (!(await this.answersOnLocalhost(port))) this.close(port, notes.down, true);
    return this.refusal(port, 502, notes.down);
  }

  private async answersOnLocalhost(port: number): Promise<boolean> {
    return (await Promise.all(this.upstreams.map((host) => answers(host.replace(/^\[|\]$/g, ""), port)))).some(Boolean);
  }

  /** The upstream socket is opened before the browser's upgrade is answered, so the subprotocol the server picked can go back in the answer. */
  private async upgrade(listener: Listener, request: Request, server: Bun.Server<ProxiedSocket>, key: string, address: string, target: string, origin: string): Promise<Response | undefined> {
    const { port } = listener;
    if (request.method !== "GET") return this.refusal(port, 405, "Method not allowed");
    if (!listener.sockets.acquire(key)) return this.refusal(port, 429, "Too many sockets");
    let released = false;
    const release = () => { if (!released) { released = true; listener.sockets.release(key); } };
    const protocols = (request.headers.get("sec-websocket-protocol") ?? "").split(",").map((word) => word.trim()).filter(Boolean);
    const headers = Object.fromEntries(upstreamHeaders(request.headers, port, origin, true));
    for (const host of this.upstreams) {
      const upstream = await openUpstream(`ws://${host}:${port}${target}`, protocols, headers);
      if (!upstream) continue;
      const data: ProxiedSocket = { upstream, release, queued: [], closed: false, address, open: listener.open };
      upstream.onmessage = (event) => { data.queued.push(event.data as string | ArrayBuffer); };
      const picked = upstream.protocol;
      if (server.upgrade(request, { data, headers: picked ? { "sec-websocket-protocol": picked } : undefined })) return undefined;
      upstream.close();
      release();
      return this.refusal(port, 400, "Upgrade failed");
    }
    release();
    if (!(await this.answersOnLocalhost(port))) this.close(port, notes.down, true);
    return this.refusal(port, 502, notes.down);
  }

  // -------------------------------------------------------------------------------------------------------------
  // The status file

  /** What the relay reads into `tabs`: written each look, so a file older than a minute means this server is not running. */
  private writeStatus(plan: PortPlan): void {
    const missing = this.missingCertificate();
    const status = buildStatus({
      now: Date.now(), dnsName: this.options.dnsName, certificate: missing?.note ?? null, command: missing?.command ?? null, aims: this.aims, plan,
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
    ws.data.open.add(ws);
    for (const message of queued.splice(0)) ws.send(message);
    upstream.onmessage = (event) => { if (!ws.data.closed) ws.send(event.data as string | ArrayBuffer); };
    upstream.onclose = (event) => { ws.data.closed = true; ws.data.release(); ws.close(sendableCode(event.code), event.reason.slice(0, 100)); };
    upstream.onerror = () => { ws.data.closed = true; ws.data.release(); ws.close(1011, "upstream error"); };
  },
  message(ws, message) {
    const { upstream } = ws.data;
    if (upstream.readyState !== WebSocket.OPEN) return;
    // A server that reads slower than the browser sends is not allowed to hold the rest in memory.
    if (upstream.bufferedAmount > upstreamBacklog) return ws.close(1013, "too much waiting");
    upstream.send(message);
  },
  close(ws, code, reason) {
    ws.data.closed = true;
    ws.data.open.delete(ws);
    ws.data.release();
    try { ws.data.upstream.close(sendableCode(code), reason.slice(0, 100)); } catch { /* already closing */ }
  },
};

/** The folder's files `tailscale cert` writes to. */
export const certificateFiles = (folder: string) => ({ cert: join(folder, "proxy.crt"), key: join(folder, "proxy.key") });
