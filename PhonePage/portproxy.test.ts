import { afterEach, describe, expect, test } from "bun:test";
import { X509Certificate } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { connect } from "node:tls";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Device, WhoisNode } from "./checks";
import { notes, type ProxyStatus } from "./proxy";
import { answers, PortProxy, type CertificateResult, type ProxyWorld } from "./portproxy";

// The proxy on throwaway ports and a copy of its code, never the running page. The "tailnet address" is ::1 and the server is on 127.0.0.1,
// the same port on two addresses as on a real host. Nothing here listens on a tailnet address. It passes with
// HTTP_PROXY and HTTPS_PROXY set or not, because constructing a `PortProxy` exempts localhost (proxyenv.test.ts runs it with them set).

const NAME = "test.example.ts.net";
const DEVICE: Device = { id: "5f0f3a4e-2b6e-4c0a-9d58-0a2f6f8d1c11", node: "nPHONE", name: "Phone" };
const PHONE: WhoisNode = { stableID: "nPHONE", label: "phone-1", dnsName: "phone-1.example.ts.net", tagged: false, sharee: false, userID: "1" };
const SAME_ORIGIN = { "sec-fetch-site": "same-origin", "sec-fetch-mode": "no-cors", "sec-fetch-dest": "empty" };

const ipv6 = await (async () => {
  try { const probe = Bun.serve({ hostname: "::1", port: 0, fetch: () => new Response("") }); await probe.stop(true); return true; } catch { return false; }
})();
const openssl = Bun.spawnSync(["openssl", "version"]).exitCode === 0;

const cleanups: (() => Promise<void> | void)[] = [];
afterEach(async () => { for (const clean of cleanups.splice(0).reverse()) await clean(); });

interface Rig { dir: string; port: number; proxy: PortProxy; status: () => ProxyStatus; tabs: { value: Record<string, unknown> }; backend: Bun.Server<unknown>; logs: string[]; world: ProxyWorld; url: (path: string) => string; host: string }

/** A server on 127.0.0.1 that echoes what it was asked, a proxy on ::1 in front of it, and a tabs answer naming its port. */
async function rig(change: {
  certificate?: () => Promise<CertificateResult>; tls?: boolean; serve?: number[]; whois?: WhoisNode | null; peers?: string[]; relayGraceMs?: number; stamp?: () => string;
} = {}): Promise<Rig> {
  const folder = mkdtempSync(join(tmpdir(), "portproxy-"));
  cleanups.push(() => rmSync(folder, { recursive: true, force: true }));
  const backend = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request, server) {
      const url = new URL(request.url);
      if (url.pathname === "/ws") {
        const wanted = (request.headers.get("sec-websocket-protocol") ?? "").split(",")[0].trim();
        return server.upgrade(request, wanted ? { headers: { "sec-websocket-protocol": wanted } } : undefined) ? undefined : new Response("no", { status: 400 });
      }
      if (url.pathname === "/redirect") return new Response(null, { status: 302, headers: { location: `http://localhost:${backend.port}/landing?x=1` } });
      if (url.pathname === "/forever") return new Response(new ReadableStream({ start(c) { const tick = setInterval(() => { try { c.enqueue(new TextEncoder().encode("tick\n")); } catch { clearInterval(tick); } }, 30); } }), { headers: { "content-type": "text/event-stream" } });
      if (url.pathname === "/stream") return new Response(new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode("a")); setTimeout(() => { c.enqueue(new TextEncoder().encode("b")); c.close(); }, 50); } }));
      return Response.json({ host: request.headers.get("host"), origin: request.headers.get("origin"), method: request.method, path: url.pathname + url.search, body: await request.text() });
    },
    websocket: {
      open(ws) { ws.send("connected"); },
      message(ws, message) { ws.send(typeof message === "string" ? `echo:${message}` : message); },
    },
  });
  cleanups.push(() => { void backend.stop(true); });
  const port = backend.port!;
  const tabs = { value: { tabs: [{ panes: [{ id: "a", kind: "app", port, url: `http://127.0.0.1:${port}/start` }] }] } as Record<string, unknown> };
  const logs: string[] = [];
  const world: ProxyWorld = {
    tabs: async () => ({ ok: true, reply: tabs.value }),
    servePorts: async () => new Set(change.serve ?? []),
    addresses: async () => ["::1"],
    certificate: change.certificate ?? (async () => ({ ok: false, note: "none" })),
    whois: async () => (change.whois === undefined ? PHONE : change.whois),
    devices: () => [DEVICE],
    peers: async () => new Set(change.peers ?? []),
    log: (line) => logs.push(line),
    ...(change.stamp ? { tabsStamp: change.stamp } : {}),
  };
  const statusPath = join(folder, "status.json");
  const proxy = new PortProxy(world, { dnsName: NAME, userID: "1", reserved: [], statusPath, tls: change.tls ?? false, upstreams: ["127.0.0.1"], relayGraceMs: change.relayGraceMs });
  cleanups.push(() => proxy.stop());
  const host = `${NAME}:${port}`;
  return { dir: folder, port, proxy, tabs, backend, logs, world, host, status: () => JSON.parse(readFileSync(statusPath, "utf8")), url: (path) => `http://[::1]:${port}${path}` };
}

interface Answer { status: number; location: string | undefined; text: string; json: () => Record<string, string> }

/** One request to the proxy as a browser on the tailnet would make it. node:http, since fetch follows HTTP_PROXY, which a shell may set. */
const ask = (r: Rig, path: string, init: { method?: string; body?: string; headers?: Record<string, string> } = {}) =>
  new Promise<Answer>((resolve, reject) => {
    const sent = httpRequest({ host: "::1", port: r.port, path, method: init.method ?? "GET", headers: { host: r.host, ...SAME_ORIGIN, ...init.headers } }, (response) => {
      const chunks: Buffer[] = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        resolve({ status: response.statusCode!, location: response.headers.location, text, json: () => JSON.parse(text) });
      });
    });
    sent.on("error", reject);
    sent.end(init.body);
  });

describe.skipIf(!ipv6)("a port opens and forwards", () => {
  test("it opens once its server answers, and the pane's status gives the proxied address with its path", async () => {
    const r = await rig();
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([r.port]);
    const status = r.status();
    expect(status.name).toBe(NAME);
    expect(status.ports).toEqual([r.port]);
    expect(status.panes.a).toEqual({ url: `https://${NAME}:${r.port}/start` });
    expect(Date.now() / 1000 - status.at).toBeLessThan(5);
  });

  test("a request goes to the server with Host as localhost, the method, the query and the body untouched", async () => {
    const r = await rig();
    await r.proxy.look();
    const reply = (await ask(r, "/a/b?c=d", { method: "POST", body: "payload", headers: { origin: `https://${NAME}:${r.port}` } })).json();
    expect(reply).toEqual({ host: `localhost:${r.port}`, origin: `http://localhost:${r.port}`, method: "POST", path: "/a/b?c=d", body: "payload" });
  });

  test("a redirect to localhost goes back to the proxied address, and isn't followed", async () => {
    const r = await rig();
    await r.proxy.look();
    const response = await ask(r, "/redirect");
    expect(response.status).toBe(302);
    expect(response.location).toBe(`https://${NAME}:${r.port}/landing?x=1`);
  });

  test("a streamed body arrives whole", async () => {
    const r = await rig();
    await r.proxy.look();
    expect((await ask(r, "/stream")).text).toBe("ab");
  });

  test("a socket is opened to the server first, and its subprotocol and first message reach the browser", async () => {
    const r = await rig();
    await r.proxy.look();
    const received: string[] = [];
    const socket = new WebSocket(`ws://[::1]:${r.port}/ws`, { protocols: ["vite-hmr"], headers: { host: r.host, origin: `https://${NAME}:${r.port}`, ...SAME_ORIGIN } } as unknown as string[]);
    await new Promise<void>((resolve, reject) => {
      socket.onmessage = (event) => {
        received.push(String(event.data));
        if (received.length === 1) socket.send("ping");
        if (received.length === 2) resolve();
      };
      socket.onerror = () => reject(new Error("socket error"));
      setTimeout(() => reject(new Error("no messages")), 3000);
    });
    expect(socket.protocol).toBe("vite-hmr");
    expect(received).toEqual(["connected", "echo:ping"]);
    socket.close();
  });

});

describe.skipIf(!ipv6)("who and what is refused", () => {
  test("a Host that isn't the proxied name and port is 421", async () => {
    const r = await rig();
    await r.proxy.look();
    expect((await ask(r, "/", { headers: { host: `${NAME}:1` } })).status).toBe(421);
    expect((await ask(r, "/", { headers: { host: "100.64.0.1:1" } })).status).toBe(421);
  });

  test("a node that is neither a listed device nor a listed peer gets nothing, and never reaches the server", async () => {
    const r = await rig({ whois: { ...PHONE, stableID: "nOTHER", dnsName: "stranger.example.ts.net" } });
    await r.proxy.look();
    expect((await ask(r, "/")).status).toBe(403);
  });

  test("a failed whois is asked to come back, not refused", async () => {
    const r = await rig({ whois: null });
    await r.proxy.look();
    expect((await ask(r, "/")).status).toBe(503);
  });

  test("with the paired Macs never read, a Mac that isn't a device is asked to come back, and one whose socket is open stays", async () => {
    const r = await rig({ whois: { ...PHONE, stableID: "nMAC", dnsName: "other-mac.example.ts.net" } });
    r.world.peers = async () => null;
    await r.proxy.look();
    expect((await ask(r, "/")).status).toBe(503);
  });

  test("a Mac the host lists as a peer is let in", async () => {
    const r = await rig({ whois: { ...PHONE, stableID: "nMAC", dnsName: "other-mac.example.ts.net" }, peers: ["other-mac.example.ts.net"] });
    await r.proxy.look();
    expect((await ask(r, "/")).status).toBe(200);
  });

  test("another port's fetch and another site's request are refused, a page load is not", async () => {
    const r = await rig();
    await r.proxy.look();
    const sameSite = { "sec-fetch-site": "same-site", "sec-fetch-mode": "cors", "sec-fetch-dest": "empty" };
    expect((await ask(r, "/", { headers: sameSite })).status).toBe(403);
    expect((await ask(r, "/", { headers: { "sec-fetch-site": "cross-site", "sec-fetch-mode": "no-cors", "sec-fetch-dest": "empty" } })).status).toBe(403);
    expect((await ask(r, "/", { headers: { "sec-fetch-site": "none", "sec-fetch-mode": "navigate", "sec-fetch-dest": "document" } })).status).toBe(200);
    expect((await ask(r, "/", { headers: { "sec-fetch-site": "same-site", "sec-fetch-mode": "navigate", "sec-fetch-dest": "iframe" } })).status).toBe(200);
  });

  test("a refusal is logged by its port and code, never its path", async () => {
    const r = await rig();
    await r.proxy.look();
    await ask(r, "/secret-path?token=1", { headers: { host: "wrong:1" } });
    expect(r.logs.some((line) => line === `proxy :${r.port} 421`)).toBe(true);
    expect(r.logs.join("\n")).not.toContain("secret");
  });
});

describe.skipIf(!ipv6)("what stays open", () => {
  const openSocket = async (r: Rig) => {
    const socket = new WebSocket(`ws://[::1]:${r.port}/ws`, { headers: { host: r.host, origin: `https://${NAME}:${r.port}`, ...SAME_ORIGIN } } as unknown as string[]);
    await new Promise<void>((resolve, reject) => { socket.onmessage = () => resolve(); socket.onerror = () => reject(new Error("socket error")); setTimeout(() => reject(new Error("no message")), 3000); });
    return socket;
  };
  const closed = (socket: WebSocket) => new Promise<number>((resolve) => { socket.onclose = (event) => resolve(event.code); setTimeout(() => resolve(-1), 3000); });

  test("closing a port closes the sockets open on it", async () => {
    const r = await rig();
    await r.proxy.look();
    const socket = await openSocket(r);
    const ended = closed(socket);
    r.tabs.value = { tabs: [] };
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([]);
    expect(await ended).not.toBe(-1);
  });

  test("a socket of a caller no longer admitted is closed at the next look", async () => {
    const r = await rig();
    await r.proxy.look();
    const socket = await openSocket(r);
    const ended = closed(socket);
    r.world.devices = () => [];
    // The page's whois answer is kept for a minute in the real server; here it is fresh each time.
    await r.proxy.look();
    expect(await ended).toBe(1008);
    expect(r.proxy.heldPorts()).toEqual([r.port]);
  });

  test("a response being streamed to a caller no longer admitted is cut off", async () => {
    const r = await rig();
    await r.proxy.look();
    const ended = new Promise<string>((resolve) => {
      const sent = httpRequest({ host: "::1", port: r.port, path: "/forever", headers: { host: r.host, ...SAME_ORIGIN } }, (response) => {
        response.once("data", () => { r.world.devices = () => []; void r.proxy.look(); });
        response.on("error", () => resolve("error"));
        response.on("aborted", () => resolve("aborted"));
        response.on("close", () => resolve("close"));
      });
      sent.on("error", () => resolve("error"));
      sent.end();
      setTimeout(() => resolve("still open"), 3000);
    });
    expect(await ended).not.toBe("still open");
  });

  test("a caller whose whois fails for a moment is not cut off", async () => {
    const r = await rig();
    await r.proxy.look();
    const socket = await openSocket(r);
    let ended = false;
    socket.onclose = () => { ended = true; };
    r.world.whois = async () => null;
    await r.proxy.look();
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(ended).toBe(false);
    socket.close();
  });

  test("a relay that keeps failing closes every port, after its grace", async () => {
    const r = await rig({ relayGraceMs: 50 });
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([r.port]);
    r.world.tabs = async () => ({ ok: false, error: "busy" });
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([r.port]);
    await new Promise((resolve) => setTimeout(resolve, 80));
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([]);
  });

  test("the relay is not asked again while the saved tabs are as they were", async () => {
    let stamp = "a";
    let asked = 0;
    const r = await rig({ stamp: () => stamp });
    const real = r.world.tabs;
    r.world.tabs = async () => { asked += 1; return real(); };
    await r.proxy.look();
    await r.proxy.look();
    await r.proxy.look();
    expect(asked).toBe(1);
    expect(r.proxy.heldPorts()).toEqual([r.port]);
    stamp = "b";
    r.tabs.value = { tabs: [] };
    await r.proxy.look();
    expect(asked).toBe(2);
    expect(r.proxy.heldPorts()).toEqual([]);
  });

  test("a port that is not opened is logged once with its reason", async () => {
    const r = await rig({ serve: [] });
    r.world.servePorts = async () => new Set([r.port]);
    await r.proxy.look();
    await r.proxy.look();
    expect(r.logs.filter((line) => line.startsWith(`proxy :${r.port} not opened`))).toEqual([`proxy :${r.port} not opened: ${notes.serve}`]);
  });
});

describe.skipIf(!ipv6)("when a port is open", () => {
  test("a port no tab names isn't opened, and one that stops being named closes", async () => {
    const r = await rig();
    r.tabs.value = { tabs: [{ panes: [{ id: "t", kind: "terminal" }] }] };
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([]);
    expect(await answers("::1", r.port)).toBe(false);
    r.tabs.value = { tabs: [{ panes: [{ id: "a", kind: "app", port: r.port }] }] };
    await r.proxy.look();
    expect(await answers("::1", r.port)).toBe(true);
    r.tabs.value = { tabs: [] };
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([]);
    expect(await answers("::1", r.port)).toBe(false);
  });

  test("a port whose server isn't answering waits, and opens when it does; it closes when the server stops", async () => {
    const r = await rig();
    const port = r.port;
    await r.backend.stop(true);
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([]);
    expect(r.status().panes.a).toEqual({ note: notes.down });
    const again = Bun.serve({ hostname: "127.0.0.1", port, fetch: () => new Response("back") });
    cleanups.push(() => { void again.stop(true); });
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([port]);
    await again.stop(true);
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([]);
    expect(await answers("::1", port)).toBe(false);
  });

  test("a forward that finds the server gone closes the port at once", async () => {
    const r = await rig();
    await r.proxy.look();
    await r.backend.stop(true);
    expect((await ask(r, "/")).status).toBe(502);
    expect(r.proxy.heldPorts()).toEqual([]);
  });

  test("a port where something already answers on the tailnet address is left alone, and says why", async () => {
    const r = await rig();
    const squatter = Bun.serve({ hostname: "::1", port: r.port, fetch: () => new Response("someone else") });
    cleanups.push(() => { void squatter.stop(true); });
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([]);
    expect(r.status().panes.a).toEqual({ note: notes.taken });
    expect((await ask(r, "/", { headers: { host: `localhost:${r.port}` } })).text).toBe("someone else");
  });

  test("a port tailscale serve publishes, or below 1024, is not opened", async () => {
    const served = await rig({ serve: [] });
    served.world.servePorts = async () => new Set([served.port]);
    await served.proxy.look();
    expect(served.proxy.heldPorts()).toEqual([]);
    expect(served.status().panes.a).toEqual({ note: notes.serve });
    const low = await rig();
    low.tabs.value = { tabs: [{ panes: [{ id: "w", kind: "web", url: "http://localhost/" }] }] };
    await low.proxy.look();
    expect(low.status().panes.w).toEqual({ note: notes.low });
  });

  test("a port that would not bind says so and is not held", async () => {
    const r = await rig();
    r.world.addresses = async () => ["203.0.113.9"];
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([]);
    expect(String((r.status().panes.a as { note: string }).note)).toContain("couldn't open this port");
  });

  test("with a relay that didn't answer, the ports stay as they were", async () => {
    const r = await rig();
    await r.proxy.look();
    r.world.tabs = async () => ({ ok: false, error: "busy" });
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([r.port]);
  });

  test("stopping closes every port and removes the status file", async () => {
    const r = await rig();
    await r.proxy.look();
    await r.proxy.stop();
    expect(await answers("::1", r.port)).toBe(false);
    expect(() => r.status()).toThrow();
  });
});

describe.skipIf(!ipv6 || !openssl)("the certificate", () => {
  /** A self-signed certificate for the proxy's name. */
  function selfSigned(): { cert: string; key: string; fingerprint: string } {
    const folder = mkdtempSync(join(tmpdir(), "portproxy-cert-"));
    cleanups.push(() => rmSync(folder, { recursive: true, force: true }));
    const made = Bun.spawnSync(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", join(folder, "k"), "-out", join(folder, "c"), "-days", "1", "-subj", `/CN=${NAME}`]);
    if (made.exitCode !== 0) throw new Error("openssl couldn't make a certificate");
    const cert = readFileSync(join(folder, "c"), "utf8");
    return { cert, key: readFileSync(join(folder, "k"), "utf8"), fingerprint: new X509Certificate(cert).fingerprint256 };
  }

  const served = (port: number) => new Promise<string>((resolve, reject) => {
    const socket = connect({ host: "::1", port, servername: NAME, rejectUnauthorized: false }, () => {
      const fingerprint = socket.getPeerCertificate().fingerprint256;
      socket.end();
      resolve(fingerprint);
    });
    socket.on("error", reject);
  });

  test("a new certificate is served on every port, and a socket open across the swap keeps working", async () => {
    const first = selfSigned(), second = selfSigned();
    expect(first.fingerprint).not.toBe(second.fingerprint);
    let next = first;
    const r = await rig({ tls: true, certificate: async () => ({ ok: true, cert: next.cert, key: next.key }) });
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([r.port]);
    expect(await served(r.port)).toBe(first.fingerprint);

    const socket = new WebSocket(`wss://[::1]:${r.port}/ws`, { tls: { rejectUnauthorized: false }, headers: { host: r.host, origin: `https://${NAME}:${r.port}`, ...SAME_ORIGIN } } as unknown as string[]);
    const messages: string[] = [];
    await new Promise<void>((resolve, reject) => {
      socket.onmessage = (event) => { messages.push(String(event.data)); resolve(); };
      socket.onerror = () => reject(new Error("socket error"));
      setTimeout(() => reject(new Error("no message")), 3000);
    });

    next = second;
    await r.proxy.renewCertificate();
    expect(await served(r.port)).toBe(second.fingerprint);
    expect(r.proxy.heldPorts()).toEqual([r.port]);

    const echoed = new Promise<string>((resolve) => { socket.onmessage = (event) => resolve(String(event.data)); });
    socket.send("after the swap");
    expect(await echoed).toBe("echo:after the swap");
    socket.close();
  });

  test("a host with no web or app pane asks once, so the operator shows before the first pane, and not again for an hour", async () => {
    let asked = 0;
    const r = await rig({ tls: true, certificate: async () => { asked += 1; return { ok: false, note: "No certificate: x.", command: "do it" }; } });
    r.tabs.value = { tabs: [{ panes: [{ id: "t", kind: "terminal" }] }] };
    await r.proxy.look();
    await r.proxy.look();
    expect(asked).toBe(1);
    expect(r.status().note).toBe("No certificate: x.");
    expect(r.status().command).toBe("do it");
  });

  test("the status is written while a slow certificate is awaited, so it never looks stale", async () => {
    let release = () => {};
    const r = await rig({ tls: true, certificate: () => new Promise((resolve) => { release = () => resolve({ ok: false, note: "late" }); }) });
    const looking = r.proxy.look();
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(Math.abs(Date.now() / 1000 - r.status().at)).toBeLessThan(5);
    release();
    await looking;
  });

  test("a socket opened before a certificate swap ends with its port", async () => {
    const first = selfSigned(), second = selfSigned();
    let next = first;
    const r = await rig({ tls: true, certificate: async () => ({ ok: true, cert: next.cert, key: next.key }) });
    await r.proxy.look();
    const socket = new WebSocket(`wss://[::1]:${r.port}/ws`, { tls: { rejectUnauthorized: false }, headers: { host: r.host, origin: `https://${NAME}:${r.port}`, ...SAME_ORIGIN } } as unknown as string[]);
    await new Promise<void>((resolve, reject) => { socket.onmessage = () => resolve(); socket.onerror = () => reject(new Error("socket error")); setTimeout(() => reject(new Error("no message")), 3000); });
    next = second;
    await r.proxy.renewCertificate();
    const ended = new Promise<number>((resolve) => { socket.onclose = (event) => resolve(event.code); setTimeout(() => resolve(-1), 3000); });
    r.tabs.value = { tabs: [] };
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([]);
    expect(await ended).not.toBe(-1);
  });

  test("with no certificate nothing opens, and the status says why", async () => {
    const r = await rig({ tls: true, certificate: async () => ({ ok: false, note: "No certificate: because." }) });
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([]);
    expect(r.status().note).toBe("No certificate: because.");
    expect(r.status().panes.a).toEqual({ note: "No certificate: because." });
  });
});
