import { afterEach, describe, expect, test } from "bun:test";
import { X509Certificate } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { connect } from "node:tls";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Device, WhoisNode } from "./checks";
import { notes, type ProxyStatus } from "./proxy";
import { answers, certificateNote, PortProxy, type CertificateResult, type ProxyWorld } from "./portproxy";

// The proxy on throwaway ports and a copy of its code, never the running page. The "tailnet address" is ::1 and the server is on 127.0.0.1,
// the same port on two addresses as on a real host. Nothing here listens on a tailnet address. Run it from a shell with no HTTP_PROXY or
// HTTPS_PROXY: Bun sends even a request to ::1 through one, and a request would then arrive from the proxy's node, not from here.

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

interface Rig { port: number; proxy: PortProxy; status: () => ProxyStatus; tabs: { value: Record<string, unknown> }; backend: Bun.Server<unknown>; logs: string[]; world: ProxyWorld; url: (path: string) => string; host: string }

/** A server on 127.0.0.1 that echoes what it was asked, a proxy on ::1 in front of it, and a tabs answer naming its port. */
async function rig(change: { certificate?: () => Promise<CertificateResult>; tls?: boolean; serve?: number[]; whois?: WhoisNode | null; peers?: string[] } = {}): Promise<Rig> {
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
  };
  const statusPath = join(folder, "status.json");
  const proxy = new PortProxy(world, { dnsName: NAME, userID: "1", reserved: [], statusPath, tls: change.tls ?? false, upstreams: ["127.0.0.1"] });
  cleanups.push(() => proxy.stop());
  const host = `${NAME}:${port}`;
  return { port, proxy, tabs, backend, logs, world, host, status: () => JSON.parse(readFileSync(statusPath, "utf8")), url: (path) => `http://[::1]:${port}${path}` };
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

  test("a failed whois gets nothing", async () => {
    const r = await rig({ whois: null });
    await r.proxy.look();
    expect((await ask(r, "/")).status).toBe(403);
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

  test("with no certificate nothing opens, and the status says why", async () => {
    const r = await rig({ tls: true, certificate: async () => ({ ok: false, note: "No certificate: because." }) });
    await r.proxy.look();
    expect(r.proxy.heldPorts()).toEqual([]);
    expect(r.status().note).toBe("No certificate: because.");
    expect(r.status().panes.a).toEqual({ note: "No certificate: because." });
  });
});

describe("what Tailscale's refusal of a certificate says", () => {
  test("the operator is named, with the one fix", () => {
    expect(certificateNote("Access denied: cert access denied\n")).toContain("sudo tailscale set --operator=$USER");
  });

  test("anything else is Tailscale's first line, cut", () => {
    expect(certificateNote("\nHTTPS isn't enabled on this tailnet.\nmore")).toBe("No certificate: Tailscale said HTTPS isn't enabled on this tailnet.");
    expect(certificateNote("x".repeat(500)).length).toBeLessThan(200);
    expect(certificateNote("")).toBe("No certificate: Tailscale didn't answer.");
  });
});
