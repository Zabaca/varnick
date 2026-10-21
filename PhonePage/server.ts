// The Phone page's server (ADR 0011): a Bun server beside a host's relay, behind `tailscale serve`, answering the user's own
// listed devices. It decides nothing about sessions: every list is a request to the host's relay with the device's id as `by`.
// Bun is for the page only, never the relay. Configuration is from the environment alone (checks.ts `readConfig`).
//
// Who is calling is never taken from the client. The server alone sets `by`: whois on the address serve puts in
// X-Forwarded-For, then the node, then devices.json. Logs hold the method, the path, the status, the device's name and the time.

import { chmodSync, lstatSync, readFileSync, rmSync, statSync } from "node:fs";
import { dirname } from "node:path";
import { homedir } from "node:os";
import { isIP } from "node:net";
import {
  callerAddress, checkFetchSite, checkHost, decideCaller, expectedHost, expectedOrigin, gateMutation, gateUpgrade, parseSelf, parseWhois, readConfig, readDevices,
  type Caller, type Config, type Device, type WhoisNode,
} from "./checks";
import { inputLimitBytes, Terminals, type TerminalData } from "./bridge";
import { Watches, type WatchData } from "./watcher";
import { loopbackNote, shapeHome, shapeTab, unlistedPage } from "./home";
import { hostLinks, hostNodes, parseNodeNames, type HostLink } from "./hosts";
import { agentsOf, closePane, doneTab, parseAgentsFolder, parseCloseBody, parseDoneBody, parseRestartBody, parseResumeBody, parseSplitBody, parseSplitDir, parseStartBody, reopenTab, restartPane, shapeProjects, splitFiles, splitOffer, splitTab, startSession } from "./launch";
import { clean, Relay, Slots } from "./relay";
import { uuidPattern } from "./json";
import { decideOpen, endText, isSessionName, parseEndBody, parseTabBody } from "./terminal";
import { certificateFiles, PortProxy, type CertificateResult, type ProxyWorld } from "./portproxy";
import { certificateFailure, parseSelfAddresses, parseServePorts } from "./proxy";
import { appTitleTag, appTitleToken, iconFiles, isWorkerFetch, manifestFor, pageContentPolicy, workerSource } from "./webapp";
import { presenceMarker, pushPaths, pushRoute, pushStatus, setupPush, takeKeyFile, type Push } from "./pushserver";
import { Shared } from "./pushwatch";
import { askFields, audioFields, parseAskBody, parseAudioBody, parseStatusQuery, shapeStatus, shapeTaken, statusFields, type AudioChunk, type TextAsk } from "./voice";

/** The relay protocol this server speaks (`PeerProtocol.version` in Packages/VarnickPeer). Every protocol bump changes this too. */
export const PROTOCOL_VERSION = 33;

const whoisLifetime = 60_000;
/** How long the other hosts' links are kept, and how long a failure to read them is. */
const linksLifetime = 60_000;
const linksFailureLifetime = 10_000;
const whoisCacheLimit = 256;

function fail(message: string): never {
  console.error(`phone page: ${message}`);
  process.exit(1);
}

/** Runs a command with a plain environment and a deadline: whether it succeeded, and both its streams (`tailscale cert` says why it refuses on stderr). */
async function run(argv: string[], timeout: number): Promise<{ ok: boolean; out: string; err: string }> {
  try {
    const process = Bun.spawn(argv, { env: { HOME: homedir(), PATH: "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", TERM: "dumb" }, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    const timer = setTimeout(() => process.kill(), timeout);
    try {
      const [out, err] = await Promise.all([new Response(process.stdout).text(), new Response(process.stderr).text()]);
      return { ok: (await process.exited) === 0, out, err };
    } finally {
      clearTimeout(timer);
    }
  } catch {
    return { ok: false, out: "", err: "" };
  }
}

/** A command's output, or null when it failed. */
async function capture(argv: string[], timeout: number): Promise<string | null> {
  const done = await run(argv, timeout);
  return done.ok ? done.out : null;
}

/** The socket's folder must be the user's own and closed to everyone else: Bun binds the socket before it can be chmodded. */
async function checkSocketFolder(socketPath: string): Promise<void> {
  const folder = dirname(socketPath);
  let info;
  try { info = lstatSync(folder); } catch { fail(`the socket's folder ${folder} doesn't exist: make it with mode 0700`); }
  if (!info.isDirectory()) fail(`${folder} isn't a folder`);
  if (info.uid !== process.getuid!()) fail(`${folder} isn't owned by this user`);
  if ((info.mode & 0o777) !== 0o700) fail(`${folder} must be mode 0700, not ${(info.mode & 0o777).toString(8).padStart(4, "0")}`);
  let existing;
  try { existing = lstatSync(socketPath); } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
    throw error;
  }
  // A socket left by an earlier run goes; anything else there is not ours to remove, and neither is one a server still answers on.
  if (!existing.isSocket()) fail(`${socketPath} exists and isn't a socket`);
  if (await socketAnswers(socketPath)) fail(`another server already answers on ${socketPath}`);
  rmSync(socketPath);
}

/** Whether something accepts a connection on the socket. */
function socketAnswers(path: string): Promise<boolean> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), 2000);
    const done = (answered: boolean) => { clearTimeout(timer); resolve(answered); };
    Bun.connect({
      unix: path,
      socket: { open(socket) { socket.end(); done(true); }, data() {}, error() { done(false); }, connectError() { done(false); } },
    }).catch(() => done(false));
  });
}

type SocketData = TerminalData | WatchData;

/**
 * Bun.serve takes one set of websocket options for every socket, so both channels live under these, and each kind's own limits sit
 * below them: a terminal message is at most `inputLimitBytes`, a watch's first message at most 1 KB, and a watch's messages to the page
 * at most `longestMessage` plus what `sendHighWater` lets wait, which is under `backpressureLimit` (a socket whose unsent bytes pass
 * it is closed). Keep that true when changing any of them: `watch.test.ts` checks it against a real server.
 */
export const socketOptions = {
  maxPayloadLength: inputLimitBytes,
  idleTimeout: 120,
  backpressureLimit: 4 << 20,
  closeOnBackpressureLimit: true,
};

/** Each socket's data says which channel it is; its handlers are that kind's. */
export function socketHandlers(terminals: Terminals, watches: Watches): Bun.WebSocketHandler<SocketData> {
  const kinds = { terminal: terminals.handlers(), watch: watches.handlers() };
  // One handler is looked up by the socket's kind, so a third channel adds one entry above.
  const of = (ws: Bun.ServerWebSocket<SocketData>) => kinds[ws.data.kind] as Record<string, (...args: unknown[]) => void>;
  return {
    ...socketOptions,
    open: (ws) => of(ws).open?.(ws),
    message: (ws, message) => of(ws).message?.(ws, message),
    close: (ws, code, reason) => of(ws).close?.(ws, code, reason),
    drain: (ws) => of(ws).drain?.(ws),
  };
}

/** The `tab` and `pane` of a GET route's query when both are ids, lowercase as the host writes them. */
function tabAndPane(request: Request): { tab: string; pane: string } | null {
  const query = new URL(request.url).searchParams;
  const tab = query.get("tab"), pane = query.get("pane");
  return tab !== null && uuidPattern.test(tab) && pane !== null && uuidPattern.test(pane) ? { tab: tab.toLowerCase(), pane: pane.toLowerCase() } : null;
}

async function main(): Promise<void> {
  const read = readConfig(process.env);
  if ("error" in read) fail(read.error);
  const config: Config = read.config;
  // The push key a Mac's Varnick left in a file, read and deleted before anything slow (pushserver.ts `takeKeyFile`).
  const handedKey = takeKeyFile(config.push?.keyFile);

  // Who this host is on the tailnet, and its user: the Host and Origin checks and the own-node rule rest on them.
  const statusText = await capture([config.tailscale, "status", "--json"], 15_000);
  const self = statusText ? parseSelf(statusText) : null;
  if (!self) fail(`tailscale status --json (${config.tailscale}) didn't give this host's MagicDNS name and user`);

  const relay = new Relay(config, PROTOCOL_VERSION, homedir());
  // Voice mode's own, so a poll and a chunk never wait on the sessions and Recent, and it never takes more than two relays of a device (a chunk and a poll)
  // or four in all.
  const voiceRelay = new Relay(config, PROTOCOL_VERSION, homedir(), { total: 4, perKey: 2 });
  // The anonymous hello Find Macs sends: no from, by or pair, so it pairs nothing.
  const hello = await relay.ask("hello", null);
  if (!hello.ok) fail(`the relay (${config.relay}) didn't answer a hello: ${hello.error}`);
  const identity = hello.reply.hello as { name?: unknown; headless?: unknown } | undefined;
  if (!identity || typeof identity.name !== "string" || identity.name === "") fail("the relay's hello didn't say the host's name");
  const host = { name: identity.name, headless: identity.headless === true };
  // The host's own id is how this server asks `tabs` and `hosts` for the proxy: it is no device's, and a peer's request for them is refused unlisted.
  const ownID = typeof (identity as { id?: unknown }).id === "string" ? String((identity as { id: string }).id) : null;

  const wantHost = expectedHost(self.dnsName, config.port);
  const wantOrigin = expectedOrigin(self.dnsName, config.port);
  const loopback = config.mode === "loopback";

  // whois answers, failures included, for a minute per address.
  const whoisCache = new Map<string, { at: number; node: Promise<WhoisNode | null> }>();
  const whoisSlots = new Slots(4, 1);
  function whois(address: string): Promise<WhoisNode | null> {
    const now = Date.now();
    const cached = whoisCache.get(address);
    if (cached && now - cached.at < whoisLifetime) return cached.node;
    if (whoisCache.size >= whoisCacheLimit) {
      for (const [key, entry] of whoisCache) if (now - entry.at >= whoisLifetime) whoisCache.delete(key);
      if (whoisCache.size >= whoisCacheLimit) whoisCache.delete(whoisCache.keys().next().value!);
    }
    // Only a few whois processes at once: with every slot taken the caller is unknown for now, and that isn't cached.
    if (!whoisSlots.acquire(address)) return Promise.resolve(null);
    const node = capture([config.tailscale, "whois", "--json", address], 10_000)
      .then((text) => (text ? parseWhois(text) : null))
      .finally(() => whoisSlots.release(address));
    whoisCache.set(address, { at: now, node });
    return node;
  }

  // The links to the other hosts' pages: the hosts this one lists (the relay's `hosts`, names and addresses) read against the
  // tailnet's own nodes. The list is the host's, not the device's, so it is kept for `linksLifetime`, and loads that arrive
  // while it is being fetched share that one fetch: a home never runs a relay and `tailscale status` of its own. A failure
  // is kept for `linksFailureLifetime` and shows no links, never an error: they are only a convenience. The relay run has its
  // own slot key, so it doesn't take one of a device's slots from its sessions and Recent.
  let linksCache: { at: number; ttl: number; links: HostLink[] } | null = null;
  let linksFetch: Promise<HostLink[]> | null = null;
  function otherHosts(device: Device): Promise<HostLink[]> {
    if (linksCache && Date.now() - linksCache.at < linksCache.ttl) return Promise.resolve(linksCache.links);
    linksFetch ??= (async () => {
      try {
        const [listed, statusNow] = await Promise.all([relay.ask("hosts", device.id, {}, undefined, "hosts"), capture([config.tailscale, "status", "--json"], 10_000)]);
        const nodes = statusNow ? parseNodeNames(statusNow) : new Set<string>();
        const ok = listed.ok && nodes.size > 0;
        linksCache = { at: Date.now(), ttl: ok ? linksLifetime : linksFailureLifetime, links: ok ? hostLinks(listed.reply, self!.dnsName, nodes, config.port) : [] };
        return linksCache.links;
      } finally {
        linksFetch = null;
      }
    })();
    return linksFetch;
  }

  async function identify(request: Request): Promise<Caller> {
    const address = callerAddress(request.headers.get("x-forwarded-for"), (text) => isIP(text) !== 0);
    const node = address ? await whois(address) : null;
    // The device file is read on every request, so adding a device needs no restart.
    let file: string | null = null;
    try { file = readFileSync(config.devices, "utf8"); } catch { file = null; }
    return decideCaller(node, self!.userID, readDevices(file));
  }

  const security = {
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
    // No other site may load a reply of the page as a script, image or frame's resource (a `no-cors` request still runs the caller's check).
    "cross-origin-resource-policy": "same-origin",
  };
  const pageSecurity = {
    ...security,
    "content-security-policy": pageContentPolicy(self.dnsName, wantHost),
  };

  function respond(body: BodyInit | null, status: number, type: string, extra: Record<string, string> = {}): Response {
    return new Response(body, { status, headers: { ...pageSecurity, "content-type": type, ...extra } });
  }
  const plain = (status: number, text: string) => respond(`${text}\n`, status, "text/plain; charset=utf-8");

  // The page's own files, and xterm.js as vendored (vendor/VERSIONS), never from node_modules.
  const js = "text/javascript; charset=utf-8";
  const files: Record<string, { file: string; type: string }> = {
    "/": { file: "page/index.html", type: "text/html; charset=utf-8" },
    "/app.js": { file: "page/app.js", type: js },
    "/session.js": { file: "page/session.js", type: js },
    "/tab.js": { file: "page/tab.js", type: js },
    "/tabrules.js": { file: "page/tabrules.js", type: js },
    "/rules.js": { file: "page/rules.js", type: js },
    "/dom.js": { file: "page/dom.js", type: js },
    "/menu.js": { file: "page/menu.js", type: js },
    "/live.js": { file: "page/live.js", type: js },
    "/liverules.js": { file: "page/liverules.js", type: js },
    "/new.js": { file: "page/new.js", type: js },
    "/add.js": { file: "page/add.js", type: js },
    "/addrules.js": { file: "page/addrules.js", type: js },
    "/newrules.js": { file: "page/newrules.js", type: js },
    "/app.css": { file: "page/app.css", type: "text/css; charset=utf-8" },
    "/vendor/xterm.mjs": { file: "vendor/xterm.mjs", type: js },
    "/vendor/addon-fit.mjs": { file: "vendor/addon-fit.mjs", type: js },
    "/vendor/xterm.css": { file: "vendor/xterm.css", type: "text/css; charset=utf-8" },
    "/install.js": { file: "page/install.js", type: js },
    "/installrules.js": { file: "page/installrules.js", type: js },
    "/push.js": { file: "page/push.js", type: js },
    "/pushrules.js": { file: "page/pushrules.js", type: js },
    "/voice.js": { file: "page/voice.js", type: js },
    "/voicerules.js": { file: "page/voicerules.js", type: js },
    "/voice-worklet.js": { file: "page/voice-worklet.js", type: js },
  };

  const log = (line: string) => console.log(`${new Date().toISOString()} ${line}`);

  // The host's own `tabs`, asked as the host itself: one ask serves the port proxy and the push watcher when both want one.
  const hostTabs = ownID ? new Shared(() => relay.ask("tabs", ownID, {}, undefined, "proxy"), Date.now, 1500) : null;
  /** The saved tabs' date and size: a look that finds them as they were doesn't run the relay. A host that gives no file is asked only every few minutes. */
  const tabsStamp = (): string => {
    const tabsFile = config.proxy?.tabs;
    if (!tabsFile) return "none";
    try { const info = statSync(tabsFile); return `${info.mtimeMs}:${info.size}`; } catch { return "missing"; }
  };

  // The port proxy (portproxy.ts), only where the environment gives it a folder and a status file, and the relay gave this host's id.
  let proxy: PortProxy | null = null;
  if (config.proxy && ownID && hostTabs) {
    const { folder, status } = config.proxy;
    const certFiles = certificateFiles(folder);
    // The Macs this host lists, by tailnet name: asked of the relay as the host itself. One ask is shared by every request that comes while it runs,
    // and its answer is kept for a minute, a failure for ten seconds, like the other hosts' links.
    // A fetch that fails keeps the last good set, and with none yet the answer is null: a paired Mac is asked to come back, not cut off.
    let peersCache: { at: number; ttl: number; names: Set<string> | null } | null = null;
    let peersFetch: Promise<Set<string> | null> | null = null;
    const world: ProxyWorld = {
      tabs: () => hostTabs.get(),
      tabsStamp,
      servePorts: async () => {
        const text = await capture([config.tailscale, "serve", "status", "--json"], 8000);
        return text ? parseServePorts(text) : new Set<number>();
      },
      addresses: async () => {
        const text = await capture([config.tailscale, "status", "--json"], 10_000);
        return text ? parseSelfAddresses(text) : [];
      },
      certificate: async (): Promise<CertificateResult> => {
        // Under the status file's minute, with the status written before and after: a first issuance takes seconds, not minutes.
        const asked = await run([config.tailscale, "cert", "--cert-file", certFiles.cert, "--key-file", certFiles.key, "--min-validity", "720h", self.dnsName], 50_000);
        if (!asked.ok) return { ok: false, ...certificateFailure(asked.err) };
        try {
          return { ok: true, cert: readFileSync(certFiles.cert, "utf8"), key: readFileSync(certFiles.key, "utf8") };
        } catch {
          const failure = certificateFailure("");
          return { ok: false, note: failure.note };
        }
      },
      whois,
      devices: () => {
        try { return readDevices(readFileSync(config.devices, "utf8")); } catch { return []; }
      },
      peers: () => {
        if (peersCache && Date.now() - peersCache.at < peersCache.ttl) return Promise.resolve(peersCache.names);
        peersFetch ??= (async () => {
          try {
            const [listed, statusNow] = await Promise.all([relay.ask("hosts", ownID, {}, undefined, "proxy-hosts"), capture([config.tailscale, "status", "--json"], 10_000)]);
            const nodes = statusNow ? parseNodeNames(statusNow) : new Set<string>();
            const ok = listed.ok && nodes.size > 0;
            const names = ok ? new Set(hostNodes(listed.reply, self!.dnsName, nodes).map((node) => node.dns)) : (peersCache?.names ?? null);
            peersCache = { at: Date.now(), ttl: ok ? linksLifetime : linksFailureLifetime, names };
            return names;
          } finally {
            peersFetch = null;
          }
        })();
        return peersFetch;
      },
      log,
    };
    proxy = new PortProxy(world, { dnsName: self.dnsName, userID: self.userID, reserved: [config.port, ...(config.mode === "loopback" ? [config.loopbackPort] : [])], statusPath: status });
  }
  // Push notifications, where the environment gives the folders and the host has a key (pushserver.ts).
  const push: Push | null = config.push && ownID && hostTabs
    ? await setupPush({
      push: config.push, headless: host.headless, ownID, hostTabs, handedKey, tabsStamp,
      devices: () => { try { return readDevices(readFileSync(config.devices, "utf8")); } catch { return []; } }, log,
    })
    : null;
  // No push set up (no host id, or setupPush said off): a marker a server left would silence Claude Code's own pushes for nothing.
  if (!push && config.push) presenceMarker(config.push.folder)(false);
  const terminals = new Terminals(config, relay, PROTOCOL_VERSION, homedir(), log, push?.openPanes);
  const watches = new Watches(config, PROTOCOL_VERSION, homedir(), log, push?.openPanes);
  const json = (value: unknown, status = 200) => respond(JSON.stringify(value), status, "application/json; charset=utf-8");

  /** Null when the request was upgraded to a terminal websocket. */
  async function handle(request: Request, name: { value: string }, server: Bun.Server<SocketData>): Promise<Response | null> {
    const path = new URL(request.url).pathname;
    // The Host check comes first, on every request and path.
    if (!checkHost(config.mode, request.headers, wantHost)) return plain(421, "Misdirected request");

    const caller = await identify(request);
    if (caller.kind === "unlisted") {
      name.value = `unlisted(${caller.label ?? "unknown"})`;
      // No session data, whatever was asked.
      return new Response(request.method === "HEAD" ? null : unlistedPage(caller, host, loopback), {
        status: 403,
        headers: { ...security, "content-type": "text/html; charset=utf-8", "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'" },
      });
    }
    const { device } = caller;
    name.value = device.name;

    // Another site open on the phone can send a request that carries the phone's identity: a read from it (`no-cors`)
    // would still run a relay, so `/api/*` answers only the page itself.
    if (path.startsWith("/api/") && !checkFetchSite(request.headers, wantOrigin)) return plain(403, "cross-site");
    // The two websockets, the terminal's and the live screen's, pass the caller, Host and Origin checks as a mutation does,
    // before anything is spawned.
    if (path === "/ws/terminal" || path === "/ws/watch") {
      const refusedUpgrade = gateUpgrade(request.method, request.headers, wantOrigin);
      if (refusedUpgrade) return plain(refusedUpgrade.status, refusedUpgrade.reason);
      const terminal = path === "/ws/terminal";
      const data: SocketData | null = terminal ? terminals.admit(device) : watches.admit(device);
      if (!data) return plain(429, terminal ? "Too many terminals open" : "Too many screens open");
      if (server.upgrade(request, { data })) return null;
      data.admission.giveBack();
      return plain(400, "Upgrade failed");
    }

    const refused = gateMutation(request.method, request.headers, wantOrigin);
    if (refused) return plain(refused.status, refused.reason);
    if (request.method === "POST") {
      if (path !== "/api/end" && path !== "/api/start" && path !== "/api/split" && path !== "/api/close" && path !== "/api/restart" && path !== "/api/done" && path !== "/api/resume" && path !== "/api/take" && !pushPaths.includes(path)
        && path !== "/api/voice/audio" && path !== "/api/voice/ask") return plain(404, "Not found");
      let body: unknown;
      try { body = await request.json(); } catch { return plain(400, "Not JSON"); }
      if (pushPaths.includes(path)) {
        const answered = await pushRoute(push, device, path, body, { now: Date.now, log });
        return json(answered.body, answered.status);
      }
      // Voice mode (voice.ts): one chunk of an utterance, or a typed ask. The host takes it and answers at once; what comes of it is polled.
      if (path === "/api/voice/audio" || path === "/api/voice/ask") {
        const audio = path === "/api/voice/audio";
        const parsed = audio ? parseAudioBody(body) : parseAskBody(body);
        if (!parsed.ok) return json({ ok: false, error: parsed.error }, 400);
        const fields = audio ? audioFields(parsed.value as AudioChunk) : askFields(parsed.value as TextAsk);
        const taken = shapeTaken(await voiceRelay.ask(audio ? "voiceAudio" : "voiceAsk", device.id, fields));
        return json(taken.body, taken.status);
      }
      if (path === "/api/end") {
        const target = parseEndBody(body);
        if (!target.ok) return plain(400, target.error);
        // The host decides: a tab (or session) this device started ends, any other is released to its host.
        const ended = await relay.ask("end", device.id, target.fields);
        if (!ended.ok) return json({ ok: false, error: ended.error }, 502);
        return json({ ok: true, released: ended.reply.released === true, text: endText(ended.reply, host.name) });
      }
      if (path === "/api/take") {
        // Take over takes the whole tab (ADR 0034): the relay relabels every Claude and terminal pane of it for this device, then detaches
        // their clients. The page then attaches the pane it shows, without take.
        const target = parseTabBody(body);
        if (!target.ok) return plain(400, target.error);
        const taken = await relay.ask("take", device.id, { tab: target.tab });
        return taken.ok ? json({ ok: true }) : json({ ok: false, error: taken.error }, 502);
      }
      // A start waits for the host (`launchTimeoutMs`), then asks it again before it fails: past the 30 s Bun waits on an idle connection.
      server.timeout(request, 120);
      // Checked here (launch.ts), then sent to the relay as JSON fields only. The session id is the server's own, and so is `by`.
      if (path === "/api/start") {
        const ask = parseStartBody(body);
        if (!ask.ok) return json({ ok: false, error: ask.error }, 400);
        const launched = await startSession(relay, device, host.name, ask.value, () => crypto.randomUUID());
        return json(launched.body, launched.status);
      }
      // Add pane (options 03 and 05 of panes-open-only-by-hand-at-a-mac): a Claude session, a terminal, an app, a page or a file beside a pane of a tab this phone controls.
      if (path === "/api/split") {
        const ask = parseSplitBody(body);
        if (!ask.ok) return json({ ok: false, error: ask.error }, 400);
        const launched = await splitTab(relay, device, host.name, ask.value, () => crypto.randomUUID(), host.headless);
        return json(launched.body, launched.status);
      }
      // Close one pane (where-it-breaks, The tab view on the phone), under the timeout above: the host's `end`, which may wait on zmx.
      if (path === "/api/close") {
        const ask = parseCloseBody(body);
        if (!ask.ok) return json({ ok: false, error: ask.error }, 400);
        const closed = await closePane(relay, device, host.name, ask.value);
        return json(closed.body, closed.status);
      }
      // Restart (protocol 32; where-it-breaks, The tab view on the phone), under the timeout above.
      if (path === "/api/restart") {
        const ask = parseRestartBody(body);
        if (!ask.ok) return json({ ok: false, error: ask.error }, 400);
        const restarted = await restartPane(relay, device, host.name, ask.value);
        return json(restarted.body, restarted.status);
      }
      // Done (protocol 33, ADR 0045), from the tab view's menu: the host closes the tab, whoever controls or started it.
      if (path === "/api/done") {
        const ask = parseDoneBody(body);
        if (!ask.ok) return json({ ok: false, error: ask.error }, 400);
        const done = await doneTab(relay, device, ask.value);
        return json(done.body, done.status);
      }
      const tab = parseResumeBody(body);
      if (!tab.ok) return json({ ok: false, error: tab.error }, 400);
      const launched = await reopenTab(relay, device, host.name, tab.value);
      return json(launched.body, launched.status);
    }

    // The app's own files (webapp.ts): the manifest and the worker are written per request with the host's name, the icons are served as
    // they are. They pass the same Host and caller checks as every file, so an unlisted device gets none of them.
    const head = request.method === "HEAD";
    if (path === "/manifest.webmanifest") return respond(head ? null : manifestFor(host.name), 200, "application/manifest+json; charset=utf-8");
    if (path === "/sw.js") {
      // The script holds the host's name, so another site's `<script src>` gets nothing.
      if (!isWorkerFetch(request.headers)) return plain(404, "Not found");
      const template = await Bun.file(new URL("page/sw.js", import.meta.url)).text();
      return respond(head ? null : workerSource(template, host.name), 200, js);
    }
    // The icons hold nothing private, and a browser may fetch one outside the page's own context (a Home Screen icon).
    if (Object.hasOwn(iconFiles, path)) return respond(head ? null : await Bun.file(new URL(iconFiles[path].file, import.meta.url)).bytes(), 200, "image/png", { "cross-origin-resource-policy": "cross-origin" });

    const served = files[path];
    if (served) {
      let body = await Bun.file(new URL(served.file, import.meta.url)).text();
      if (path === "/") {
        body = body.replace("<!--LOOPBACK-->", loopback ? `<p class="banner" role="note">${loopbackNote}</p>` : "");
        body = body.replace(appTitleToken, () => appTitleTag(host.name));
      }
      return respond(head ? null : body, 200, served.type);
    }
    if (path === "/api/push" && request.method === "GET") {
      const answered = pushStatus(push, host.name);
      return json(answered.body, answered.status);
    }
    if (path === "/api/session" && request.method === "GET") {
      const session = new URL(request.url).searchParams.get("name");
      if (!isSessionName(session)) return plain(400, "Not a Varnick session name");
      // Every open and every reconnect asks first: the label says whether to attach, show who has it, or say it ended.
      return json({ ...decideOpen(await relay.ask("status", device.id, { sessions: [session] }), session, device), host: host.name });
    }
    if (path === "/api/tab" && request.method === "GET") {
      proxy?.touch();
      const tab = new URL(request.url).searchParams.get("tab");
      if (tab === null || !uuidPattern.test(tab)) return plain(400, "Not a Varnick tab id");
      const listed = await relay.ask("tabs", device.id);
      if (!listed.ok) return json({ ok: false, error: listed.error }, 502);
      const found = (Array.isArray(listed.reply.tabs) ? listed.reply.tabs : []).find((candidate: any) => String(candidate?.tab).toLowerCase() === tab.toLowerCase());
      const shaped = found && typeof found === "object" ? shapeTab(found as Record<string, unknown>, device) : null;
      return shaped ? json({ ok: true, host: host.name, tab: shaped }) : json({ ok: false, error: `That tab isn't open on ${host.name} any more` }, 404);
    }
    if (path === "/api/file" && request.method === "GET") {
      const ids = tabAndPane(request);
      if (ids === null) return plain(400, "Not a Varnick tab or pane id");
      // The host reads the file the pane has, inside the tab's folders, and caps its size: the path is never the page's.
      const read = await relay.ask("file", device.id, ids);
      return read.ok && typeof read.reply.text === "string" ? json({ ok: true, text: read.reply.text }) : json({ ok: false, error: read.ok ? "The host sent no text" : read.error }, 502);
    }
    if (path === "/api/projects" && request.method === "GET") {
      const projects = shapeProjects(await relay.ask("projects", device.id));
      return "error" in projects ? json({ ok: false, error: projects.error }, 502) : json({ ok: true, host: host.name, projects: projects.rows });
    }
    if (path === "/api/split-offer" && request.method === "GET") {
      const ids = tabAndPane(request);
      if (ids === null) return plain(400, "Not a Varnick tab or pane id");
      // The folder is the pane's own as the host lists it, never the page's.
      const offer = await splitOffer(relay, device, host.name, ids.tab, ids.pane, host.headless);
      return json(offer.body, offer.status);
    }
    if (path === "/api/split-files" && request.method === "GET") {
      const ids = tabAndPane(request);
      if (ids === null) return plain(400, "Not a Varnick tab or pane id");
      const dir = parseSplitDir(new URL(request.url).searchParams.get("dir"));
      if (!dir.ok) return json({ ok: false, error: dir.error }, 400);
      // The root is the pane's own folder as the host lists it; the folder asked for has to be inside it, and the host keeps the tab's folders besides.
      const listing = await splitFiles(relay, device, host.name, ids.tab, ids.pane, dir.value, host.headless);
      return json(listing.body, listing.status);
    }
    if (path === "/api/agents" && request.method === "GET") {
      const folder = parseAgentsFolder(new URL(request.url).searchParams.get("folder"));
      if (!folder.ok) return json({ ok: false, error: folder.error }, 400);
      const agents = await agentsOf(relay, device, host.name, folder.value);
      return json(agents.body, agents.status);
    }
    if (path === "/api/voice/status" && request.method === "GET") {
      const query = parseStatusQuery(new URL(request.url).searchParams);
      if (!query.ok) return json({ ok: false, error: query.error }, 400);
      const answered = shapeStatus(await voiceRelay.ask("voiceStatus", device.id, statusFields(query.value)));
      return json(answered.body, answered.status);
    }
    if (path === "/api/home" && request.method === "GET") {
      proxy?.touch();
      // The tabs and Recent run at once, each its own relay as the device the server found; the other hosts' links come
      // from the cache or the one shared fetch (`otherHosts`), which has a slot key of its own.
      const [tabs, recent, hosts] = await Promise.all([relay.ask("tabs", device.id), relay.ask("recent", device.id), otherHosts(device)]);
      return respond(JSON.stringify(shapeHome({ host, loopback, device, tabs, recent, hosts })), 200, "application/json; charset=utf-8");
    }
    return plain(404, "Not found");
  }

  if (config.mode === "socket") await checkSocketFolder(config.socketPath);

  const server = Bun.serve<SocketData>({
    ...(config.mode === "socket" ? { unix: config.socketPath } : { hostname: "127.0.0.1", port: config.loopbackPort }),
    idleTimeout: 30,
    // A prompt may be up to 60,000 bytes (launch.ts), and JSON escaping can double that.
    maxRequestBodySize: 256 << 10,
    websocket: socketHandlers(terminals, watches),
    async fetch(request, server) {
      const started = Date.now();
      const name = { value: "-" };
      let response: Response | null;
      try {
        response = await handle(request, name, server);
      } catch (error) {
        console.error(`${new Date().toISOString()} error ${(error as Error)?.name ?? "unknown"}`);
        response = plain(500, "Something went wrong");
      }
      // The method, the path, the status, the device and the time: never a prompt, a title, a screen or what was typed.
      console.log(`${new Date().toISOString()} ${clean(request.method)} ${clean(new URL(request.url).pathname)} ${response ? response.status : "upgrade"} ${clean(name.value)} ${Date.now() - started}ms`);
      return response ?? undefined;
    },
  });
  // Bun has no mode for the socket, so it is set once the socket is bound.
  if (config.mode === "socket") chmodSync(config.socketPath, 0o600);

  const stop = () => {
    push?.stop();
    server.stop(true);
    if (config.mode === "socket") rmSync(config.socketPath, { force: true });
    // Its status file goes first, so the relay stops listing proxied addresses at once.
    void (proxy ? proxy.stop() : Promise.resolve()).finally(() => process.exit(0));
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
  // `zmx kill` (how Varnick ends the page) sends the child SIGHUP, then SIGKILL: without this the marker would outlive the server.
  process.on("SIGHUP", stop);

  proxy?.start();
  push?.start();
  console.log(`${new Date().toISOString()} listening ${config.mode === "socket" ? config.socketPath : `127.0.0.1:${config.loopbackPort}`} as ${self.dnsName}:${config.port} for ${host.name}${host.headless ? " (headless)" : ""}, protocol ${PROTOCOL_VERSION}`);
}

if (import.meta.main) await main();
