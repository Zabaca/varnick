// The Phone page's server (ADR 0011): a Bun server beside a host's relay, behind `tailscale serve`, answering the user's own
// listed devices. It decides nothing about sessions: every list is a request to the host's relay with the device's id as `by`.
// Bun is for the page only, never the relay. Configuration is from the environment alone (checks.ts `readConfig`).
//
// Who is calling is never taken from the client. The server alone sets `by`: whois on the address serve puts in
// X-Forwarded-For, then the node, then devices.json. Logs hold the method, the path, the status, the device's name and the time.

import { chmodSync, lstatSync, readFileSync, rmSync } from "node:fs";
import { dirname } from "node:path";
import { homedir } from "node:os";
import { isIP } from "node:net";
import {
  callerAddress, checkFetchSite, checkHost, decideCaller, expectedHost, expectedOrigin, gateMutation, gateUpgrade, parseSelf, parseWhois, readConfig, readDevices,
  type Caller, type Config, type Device, type WhoisNode,
} from "./checks";
import { inputLimitBytes, Terminals, type TerminalData } from "./bridge";
import { Watches, type WatchData } from "./watcher";
import { loopbackNote, shapeHome, unlistedPage } from "./home";
import { hostLinks, parseNodeNames, type HostLink } from "./hosts";
import { agentsOf, parseAgentsFolder, parseResumeBody, parseStartBody, resumeConversation, shapeProjects, startSession } from "./launch";
import { clean, Relay, Slots } from "./relay";
import { decideOpen, endText, isSessionName } from "./terminal";

/** The relay protocol this server speaks (`PeerProtocol.version` in Packages/LaunchyPeer). Every protocol bump changes this too. */
export const PROTOCOL_VERSION = 16;

const whoisLifetime = 60_000;
/** How long the other hosts' links are kept, and how long a failure to read them is. */
const linksLifetime = 60_000;
const linksFailureLifetime = 10_000;
const whoisCacheLimit = 256;

function fail(message: string): never {
  console.error(`phone page: ${message}`);
  process.exit(1);
}

async function capture(argv: string[], timeout: number): Promise<string | null> {
  try {
    const process = Bun.spawn(argv, { env: { HOME: homedir(), PATH: "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", TERM: "dumb" }, stdin: "ignore", stdout: "pipe", stderr: "ignore" });
    const timer = setTimeout(() => process.kill(), timeout);
    try {
      const output = await new Response(process.stdout).text();
      return (await process.exited) === 0 ? output : null;
    } finally {
      clearTimeout(timer);
    }
  } catch {
    return null;
  }
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

async function main(): Promise<void> {
  const read = readConfig(process.env);
  if ("error" in read) fail(read.error);
  const config: Config = read.config;

  // Who this host is on the tailnet, and its user: the Host and Origin checks and the own-node rule rest on them.
  const statusText = await capture([config.tailscale, "status", "--json"], 15_000);
  const self = statusText ? parseSelf(statusText) : null;
  if (!self) fail(`tailscale status --json (${config.tailscale}) didn't give this host's MagicDNS name and user`);

  const relay = new Relay(config, PROTOCOL_VERSION, homedir());
  // The anonymous hello Find Macs sends: no from, by or pair, so it pairs nothing.
  const hello = await relay.ask("hello", null);
  if (!hello.ok) fail(`the relay (${config.relay}) didn't answer a hello: ${hello.error}`);
  const identity = hello.reply.hello as { name?: unknown; headless?: unknown } | undefined;
  if (!identity || typeof identity.name !== "string" || identity.name === "") fail("the relay's hello didn't say the host's name");
  const host = { name: identity.name, headless: identity.headless === true };

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
  };
  const pageSecurity = {
    ...security,
    // xterm.js's renderer writes <style> elements, which `style-src 'self'` would refuse: styles may be inline, scripts may not.
    // The terminal's websocket is named outright: not every browser takes 'self' to cover wss.
    "content-security-policy": `default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self' wss://${wantHost}; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
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
    "/rules.js": { file: "page/rules.js", type: js },
    "/dom.js": { file: "page/dom.js", type: js },
    "/live.js": { file: "page/live.js", type: js },
    "/liverules.js": { file: "page/liverules.js", type: js },
    "/new.js": { file: "page/new.js", type: js },
    "/newrules.js": { file: "page/newrules.js", type: js },
    "/app.css": { file: "page/app.css", type: "text/css; charset=utf-8" },
    "/vendor/xterm.mjs": { file: "vendor/xterm.mjs", type: js },
    "/vendor/addon-fit.mjs": { file: "vendor/addon-fit.mjs", type: js },
    "/vendor/xterm.css": { file: "vendor/xterm.css", type: "text/css; charset=utf-8" },
  };

  const log = (line: string) => console.log(`${new Date().toISOString()} ${line}`);
  const terminals = new Terminals(config, relay, PROTOCOL_VERSION, homedir(), log);
  const watches = new Watches(config, PROTOCOL_VERSION, homedir(), log);
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
      if (path !== "/api/end" && path !== "/api/start" && path !== "/api/resume") return plain(404, "Not found");
      let body: unknown;
      try { body = await request.json(); } catch { return plain(400, "Not JSON"); }
      if (path === "/api/end") {
        const session = typeof body === "object" && body !== null ? (body as Record<string, unknown>).session : undefined;
        if (!isSessionName(session)) return plain(400, "Not a Launchy session name");
        // The host decides: a session this device started ends, any other is released to its host.
        const ended = await relay.ask("end", device.id, { session });
        if (!ended.ok) return json({ ok: false, error: ended.error }, 502);
        return json({ ok: true, released: ended.reply.released === true, text: endText(ended.reply, host.name) });
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
      const conversation = parseResumeBody(body);
      if (!conversation.ok) return json({ ok: false, error: conversation.error }, 400);
      const launched = await resumeConversation(relay, device, host.name, conversation.value, () => crypto.randomUUID());
      return json(launched.body, launched.status);
    }

    const served = files[path];
    if (served) {
      let body = await Bun.file(new URL(served.file, import.meta.url)).text();
      if (path === "/") body = body.replace("<!--LOOPBACK-->", loopback ? `<p class="banner" role="note">${loopbackNote}</p>` : "");
      return respond(request.method === "HEAD" ? null : body, 200, served.type);
    }
    if (path === "/api/session" && request.method === "GET") {
      const session = new URL(request.url).searchParams.get("name");
      if (!isSessionName(session)) return plain(400, "Not a Launchy session name");
      // Every open and every reconnect asks first: the label says whether to attach, show who has it, or say it ended.
      return json({ ...decideOpen(await relay.ask("status", device.id, { sessions: [session] }), session, device), host: host.name });
    }
    if (path === "/api/projects" && request.method === "GET") {
      const projects = shapeProjects(await relay.ask("projects", device.id));
      return "error" in projects ? json({ ok: false, error: projects.error }, 502) : json({ ok: true, host: host.name, projects: projects.rows });
    }
    if (path === "/api/agents" && request.method === "GET") {
      const folder = parseAgentsFolder(new URL(request.url).searchParams.get("folder"));
      if (!folder.ok) return json({ ok: false, error: folder.error }, 400);
      const agents = await agentsOf(relay, device, host.name, folder.value);
      return json(agents.body, agents.status);
    }
    if (path === "/api/home" && request.method === "GET") {
      // The sessions and Recent run at once, each its own relay as the device the server found; the other hosts' links come
      // from the cache or the one shared fetch (`otherHosts`), which has a slot key of its own.
      const [sessions, recent, hosts] = await Promise.all([relay.ask("sessions", device.id), relay.ask("recent", device.id), otherHosts(device)]);
      return respond(JSON.stringify(shapeHome({ host, loopback, device, sessions, recent, hosts })), 200, "application/json; charset=utf-8");
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
    server.stop(true);
    if (config.mode === "socket") rmSync(config.socketPath, { force: true });
    process.exit(0);
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);

  console.log(`${new Date().toISOString()} listening ${config.mode === "socket" ? config.socketPath : `127.0.0.1:${config.loopbackPort}`} as ${self.dnsName}:${config.port} for ${host.name}${host.headless ? " (headless)" : ""}, protocol ${PROTOCOL_VERSION}`);
}

if (import.meta.main) await main();
