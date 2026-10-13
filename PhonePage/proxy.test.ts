import { describe, expect, test } from "bun:test";
import type { Device, WhoisNode } from "./checks";
import {
  aimOf, aimsOf, buildStatus, checkProxyFetch, checkProxyHost, decideProxyCaller, downstreamHeaders, notes, parseSelfAddresses, parseServePorts,
  certificateFailure, operatorCommand, planPorts, proxiedAddress, rewriteLocation, upstreamHeaders, type PortFacts,
} from "./proxy";

const ID = "5f0f3a4e-2b6e-4c0a-9d58-0a2f6f8d1c11";
const ORIGIN = "https://mac-mini.example.ts.net:5173";

describe("the ports a tabs answer names", () => {
  test("an app names its port, and the path of its address when that is the port's", () => {
    expect(aimOf({ id: ID, kind: "app", port: 5197, url: "http://127.0.0.1:5197/board?x=1" })).toEqual({ pane: ID, port: 5197, path: "/board?x=1" });
    expect(aimOf({ id: ID, kind: "app", port: 5197, url: "http://127.0.0.1:9999/other" })).toEqual({ pane: ID, port: 5197, path: "/" });
    expect(aimOf({ id: ID, kind: "app", port: 5197 })).toEqual({ pane: ID, port: 5197, path: "/" });
  });

  test("an app with no usable port has a note instead", () => {
    expect(aimOf({ id: ID, kind: "app", url: "http://127.0.0.1:5197/" })).toEqual({ pane: ID, port: null, note: notes.noPort });
    expect(aimOf({ id: ID, kind: "app", port: 70000 })).toEqual({ pane: ID, port: null, note: notes.noPort });
  });

  test("a web pane on localhost, 127.0.0.1 or ::1 names its port", () => {
    for (const url of ["http://localhost:3000/", "http://127.0.0.1:3000/", "http://[::1]:3000/", "http://127.0.0.2:3000/", "http://app.localhost:3000/", "http://0.0.0.0:3000/", "http://[::]:3000/"]) {
      expect(aimOf({ id: ID, kind: "web", url })).toEqual({ pane: ID, port: 3000, path: "/" });
    }
    expect(aimOf({ id: ID, kind: "web", url: "http://LOCALHOST:3000/a/b?c=d#e" })).toEqual({ pane: ID, port: 3000, path: "/a/b?c=d#e" });
  });

  test("a web pane with no port names the scheme's, which is below 1024", () => {
    expect(aimOf({ id: ID, kind: "web", url: "http://localhost/" })).toEqual({ pane: ID, port: 80, path: "/" });
  });

  test("an HTTPS server on localhost is not proxied, and says so", () => {
    expect(aimOf({ id: ID, kind: "web", url: "https://localhost:8443/" })).toEqual({ pane: ID, port: null, note: notes.secure });
  });

  test("a page at an outside address, and every other kind, name nothing", () => {
    expect(aimOf({ id: ID, kind: "web", url: "https://example.com/" })).toBeNull();
    expect(aimOf({ id: ID, kind: "web", url: "http://192.168.1.5:3000/" })).toBeNull();
    expect(aimOf({ id: ID, kind: "web", url: "http://localhost.example.com:3000/" })).toBeNull();
    expect(aimOf({ id: ID, kind: "web", url: "" })).toBeNull();
    expect(aimOf({ id: ID, kind: "terminal" })).toBeNull();
    expect(aimOf({ id: ID, kind: "file", file: "/x" })).toBeNull();
    expect(aimOf({ kind: "app", port: 5000 })).toBeNull();
  });

  test("every tab's panes are read, and an odd answer names nothing", () => {
    const tabs = [{ panes: [{ id: "a", kind: "app", port: 5000 }, { id: "b", kind: "claude" }] }, { panes: [{ id: "c", kind: "web", url: "http://localhost:3000/" }] }];
    expect(aimsOf(tabs).map((aim) => aim.pane)).toEqual(["a", "c"]);
    expect(aimsOf(undefined)).toEqual([]);
    expect(aimsOf([{ panes: "x" }, 3])).toEqual([]);
  });
});

describe("which ports open", () => {
  const none: PortFacts = { reserved: new Set([8444, 18444]), serve: new Set(), localUp: new Set(), tailnetUp: new Set(), held: new Set(), certificate: null };
  const facts = (change: Partial<PortFacts>): PortFacts => ({ ...none, ...change });

  test("a port whose server answers on localhost and nothing else does opens", () => {
    const plan = planPorts([5173], facts({ localUp: new Set([5173]) }));
    expect(plan).toEqual({ open: [5173], keep: [], close: [], notes: new Map() });
  });

  test("a port below 1024 never does", () => {
    const plan = planPorts([80, 1023], facts({ localUp: new Set([80, 1023]) }));
    expect(plan.open).toEqual([]);
    expect(plan.notes.get(80)).toBe(notes.low);
    expect(plan.notes.get(1023)).toBe(notes.low);
    expect(planPorts([1024], facts({ localUp: new Set([1024]) })).open).toEqual([1024]);
  });

  test("a port tailscale serve publishes never does, and 8444 is the page's", () => {
    const plan = planPorts([8443, 8444, 18444], facts({ localUp: new Set([8443, 8444, 18444]), serve: new Set([8443]) }));
    expect(plan.open).toEqual([]);
    expect(plan.notes.get(8443)).toBe(notes.serve);
    expect(plan.notes.get(8444)).toBe(notes.reserved);
    expect(plan.notes.get(18444)).toBe(notes.reserved);
  });

  test("a port whose server isn't answering on localhost waits", () => {
    const plan = planPorts([5173], none);
    expect(plan.open).toEqual([]);
    expect(plan.notes.get(5173)).toBe(notes.down);
  });

  test("a port where something already answers on the tailnet address is left alone", () => {
    const plan = planPorts([3000], facts({ localUp: new Set([3000]), tailnetUp: new Set([3000]) }));
    expect(plan.open).toEqual([]);
    expect(plan.notes.get(3000)).toBe(notes.taken);
  });

  test("a port held stays while its server answers, though the tailnet address answers (the proxy's own)", () => {
    const plan = planPorts([5173], facts({ localUp: new Set([5173]), tailnetUp: new Set([5173]), held: new Set([5173]) }));
    expect(plan).toEqual({ open: [], keep: [5173], close: [], notes: new Map() });
  });

  test("a held port closes when its server stops answering, when serve takes it, and when no tab names it", () => {
    const stopped = planPorts([5173], facts({ held: new Set([5173]) }));
    expect(stopped.close).toEqual([5173]);
    expect(stopped.notes.get(5173)).toBe(notes.down);
    const served = planPorts([5173], facts({ held: new Set([5173]), localUp: new Set([5173]), serve: new Set([5173]) }));
    expect(served.close).toEqual([5173]);
    expect(served.notes.get(5173)).toBe(notes.serve);
    const unnamed = planPorts([], facts({ held: new Set([5173, 4000]), localUp: new Set([5173, 4000]) }));
    expect(unnamed.close).toEqual([4000, 5173]);
    expect(unnamed.notes.size).toBe(0);
  });

  test("without a certificate nothing opens, but a port held keeps the one it serves with", () => {
    const missing = "No certificate.";
    const plan = planPorts([5173, 5174], facts({ localUp: new Set([5173, 5174]), held: new Set([5174]), certificate: missing }));
    expect(plan.open).toEqual([]);
    expect(plan.keep).toEqual([5174]);
    expect(plan.notes.get(5173)).toBe(missing);
  });

  test("two panes of one port are one port", () => {
    expect(planPorts([5173, 5173], facts({ localUp: new Set([5173]) })).open).toEqual([5173]);
  });
});

describe("what the listing is told", () => {
  const aims = aimsOf([{ panes: [
    { id: "a", kind: "app", port: 5173, url: "http://127.0.0.1:5173/deep" },
    { id: "b", kind: "web", url: "http://localhost:3000/" },
    { id: "c", kind: "web", url: "https://localhost:8443/" },
  ] }]);

  test("a held port gives its panes' proxied addresses, the others the reason", () => {
    const held = new Set([5173]);
    const plan = planPorts([5173, 3000], { reserved: new Set(), serve: new Set(), localUp: new Set([5173]), tailnetUp: new Set(), held, certificate: null });
    const status = buildStatus({ now: 1_760_000_123_456, dnsName: "mac-mini.example.ts.net", certificate: null, command: null, aims, plan, held });
    expect(status).toEqual({
      at: 1_760_000_123, name: "mac-mini.example.ts.net", note: null, command: null, ports: [5173],
      panes: { a: { url: "https://mac-mini.example.ts.net:5173/deep" }, b: { note: notes.down }, c: { note: notes.secure } },
    });
  });

  test("a port closing this look is not given as an address", () => {
    const held = new Set([5173]);
    const plan = planPorts([5173], { reserved: new Set(), serve: new Set(), localUp: new Set(), tailnetUp: new Set(), held, certificate: null });
    const status = buildStatus({ now: 0, dnsName: "mac-mini.example.ts.net", certificate: null, command: null, aims, plan, held });
    expect(status.panes.a).toEqual({ note: notes.down });
  });

  test("the address keeps a path that has a slash and adds one that hasn't", () => {
    expect(proxiedAddress("h.example.ts.net", 3000, "/a?b=c")).toBe("https://h.example.ts.net:3000/a?b=c");
    expect(proxiedAddress("h.example.ts.net", 3000, "")).toBe("https://h.example.ts.net:3000/");
  });
});

describe("what Tailscale says", () => {
  test("serve ports come from the TCP forwards, the web handlers and Funnel's", () => {
    const text = JSON.stringify({
      TCP: { "443": { HTTPS: true }, "8444": { HTTPS: true }, "22": { TCPForward: "127.0.0.1:22" } },
      Web: { "mac-mini.example.ts.net:8444": {}, "mac-mini.example.ts.net:8443": {} },
      AllowFunnel: { "mac-mini.example.ts.net:9443": true },
    });
    expect([...parseServePorts(text)].sort((a, b) => a - b)).toEqual([22, 443, 8443, 8444, 9443]);
  });

  test("a serve status that can't be read has no ports", () => {
    expect(parseServePorts("nope").size).toBe(0);
    expect(parseServePorts("{}").size).toBe(0);
    expect(parseServePorts('{"TCP":{"x":1,"0":1,"70000":1}}').size).toBe(0);
  });

  test("the host's tailnet addresses are its IPv4 and IPv6 ones", () => {
    const text = '{"Self":{"TailscaleIPs":["100.64.0.7","fd7a:115c:a1e0::7","junk",5]}}';
    expect(parseSelfAddresses(text)).toEqual(["100.64.0.7", "fd7a:115c:a1e0::7"]);
    expect(parseSelfAddresses("nope")).toEqual([]);
    expect(parseSelfAddresses('{"Self":{}}')).toEqual([]);
  });
});

describe("who gets in", () => {
  const ME = "10000000000000001";
  const node = (change: Partial<WhoisNode> = {}): WhoisNode => ({ stableID: "nPHONE", label: "phone-1", dnsName: "phone-1.example.ts.net", tagged: false, sharee: false, userID: ME, ...change });
  const devices: Device[] = [{ id: ID, node: "nPHONE", name: "Phone" }];
  const peers = new Set(["other-mac.example.ts.net"]);

  test("a device the host lists is admitted, and is counted by its id", () => {
    expect(decideProxyCaller(node(), ME, devices, peers)).toEqual({ admitted: true, label: "phone-1", key: ID });
  });

  test("a Mac the host lists as a peer is admitted, found by its tailnet name", () => {
    expect(decideProxyCaller(node({ stableID: "nMAC", label: "other-mac", dnsName: "other-mac.example.ts.net" }), ME, devices, peers))
      .toEqual({ admitted: true, label: "other-mac", key: "nMAC" });
  });

  test("a node that is neither is refused", () => {
    expect(decideProxyCaller(node({ stableID: "nOTHER", dnsName: "stranger.example.ts.net" }), ME, devices, peers)).toEqual({ admitted: false, reason: "not-listed" });
  });

  test("a whois that failed is refused", () => {
    expect(decideProxyCaller(null, ME, devices, peers)).toEqual({ admitted: false, reason: "unknown" });
  });

  test("a peer's name on a tagged, shared-in or another user's node is refused", () => {
    const named = { stableID: "nMAC", dnsName: "other-mac.example.ts.net" };
    expect(decideProxyCaller(node({ ...named, tagged: true }), ME, devices, peers)).toEqual({ admitted: false, reason: "not-own" });
    expect(decideProxyCaller(node({ ...named, sharee: true }), ME, devices, peers)).toEqual({ admitted: false, reason: "not-own" });
    expect(decideProxyCaller(node({ ...named, userID: "20000000000000002" }), ME, devices, peers)).toEqual({ admitted: false, reason: "not-own" });
  });

  test("a node with no name is not a peer", () => {
    expect(decideProxyCaller(node({ stableID: "nMAC", dnsName: null }), ME, devices, peers)).toEqual({ admitted: false, reason: "not-listed" });
  });
});

describe("what a browser may ask", () => {
  const headers = (fields: Record<string, string>) => new Headers(fields);
  const allowed = (method: string, fields: Record<string, string>) => checkProxyFetch(method, headers(fields), ORIGIN);

  test("a page loaded by its address is let through, as the web view sends it (none)", () => {
    expect(allowed("GET", { "sec-fetch-site": "none", "sec-fetch-mode": "navigate", "sec-fetch-dest": "document" })).toBe(true);
  });

  test("the page's own requests and hot-reload socket are let through (same-origin)", () => {
    expect(allowed("GET", { "sec-fetch-site": "same-origin", "sec-fetch-mode": "no-cors", "sec-fetch-dest": "script" })).toBe(true);
    expect(allowed("GET", { "sec-fetch-site": "same-origin", "sec-fetch-mode": "websocket", "sec-fetch-dest": "websocket" })).toBe(true);
    expect(allowed("POST", { "sec-fetch-site": "same-origin", "sec-fetch-mode": "cors", "sec-fetch-dest": "empty" })).toBe(true);
  });

  test("the phone's frame is let through: same-site, a navigation, into an iframe", () => {
    expect(allowed("GET", { "sec-fetch-site": "same-site", "sec-fetch-mode": "navigate", "sec-fetch-dest": "iframe" })).toBe(true);
  });

  test("another port's fetch is refused, though it is only same-site", () => {
    expect(allowed("GET", { "sec-fetch-site": "same-site", "sec-fetch-mode": "cors", "sec-fetch-dest": "empty" })).toBe(false);
    expect(allowed("GET", { "sec-fetch-site": "same-site", "sec-fetch-mode": "no-cors", "sec-fetch-dest": "image" })).toBe(false);
  });

  test("another site's request is refused, a subresource or a frame", () => {
    expect(allowed("GET", { "sec-fetch-site": "cross-site", "sec-fetch-mode": "no-cors", "sec-fetch-dest": "empty" })).toBe(false);
    expect(allowed("GET", { "sec-fetch-site": "cross-site", "sec-fetch-mode": "navigate", "sec-fetch-dest": "iframe" })).toBe(false);
  });

  test("a link followed from another site is a page loaded whole, and goes through", () => {
    expect(allowed("GET", { "sec-fetch-site": "cross-site", "sec-fetch-mode": "navigate", "sec-fetch-dest": "document" })).toBe(true);
  });

  test("a form posted from another page is not a navigation that goes through", () => {
    expect(allowed("POST", { "sec-fetch-site": "cross-site", "sec-fetch-mode": "navigate", "sec-fetch-dest": "document" })).toBe(false);
    expect(allowed("POST", { "sec-fetch-site": "same-site", "sec-fetch-mode": "navigate", "sec-fetch-dest": "iframe" })).toBe(false);
  });

  test("a page loaded into an object or embed, or by a worker, is refused unless it is the page's own", () => {
    expect(allowed("GET", { "sec-fetch-site": "same-site", "sec-fetch-mode": "navigate", "sec-fetch-dest": "object" })).toBe(false);
    expect(allowed("GET", { "sec-fetch-site": "same-site", "sec-fetch-mode": "same-origin", "sec-fetch-dest": "worker" })).toBe(false);
  });

  test("without the header, an Origin must be the proxied address, and no Origin goes through", () => {
    expect(allowed("GET", {})).toBe(true);
    expect(allowed("GET", { origin: ORIGIN })).toBe(true);
    expect(allowed("GET", { origin: "https://evil.example" })).toBe(false);
    expect(allowed("GET", { origin: "https://mac-mini.example.ts.net:5174" })).toBe(false);
  });
});

describe("what is rewritten", () => {
  test("Host becomes localhost and the port, and nothing else of the request changes", () => {
    const out = upstreamHeaders([["Host", "mac-mini.example.ts.net:5173"], ["Accept", "text/html"], ["Cookie", "a=b"], ["Connection", "keep-alive"], ["Sec-Fetch-Site", "none"]], 5173, ORIGIN);
    expect(out.get("host")).toBe("localhost:5173");
    expect(out.get("accept")).toBe("text/html");
    expect(out.get("cookie")).toBe("a=b");
    expect(out.get("sec-fetch-site")).toBe("none");
    expect(out.has("connection")).toBe(false);
  });

  test("Origin is rewritten only when it is the proxied address itself", () => {
    expect(upstreamHeaders([["Origin", ORIGIN]], 5173, ORIGIN).get("origin")).toBe("http://localhost:5173");
    expect(upstreamHeaders([["Origin", "https://elsewhere.example"]], 5173, ORIGIN).get("origin")).toBe("https://elsewhere.example");
  });

  test("a websocket's handshake headers are left to the client that opens the upstream", () => {
    const out = upstreamHeaders([["Upgrade", "websocket"], ["Sec-WebSocket-Key", "k"], ["Sec-WebSocket-Version", "13"], ["Sec-WebSocket-Protocol", "vite-hmr"], ["Origin", ORIGIN]], 5173, ORIGIN, true);
    expect([...out.keys()].sort()).toEqual(["host", "origin"]);
  });

  test("a redirect to the server's own localhost goes back to the proxied address", () => {
    for (const from of ["http://localhost:5173/login", "http://127.0.0.1:5173/login", "http://[::1]:5173/login", "HTTP://LOCALHOST:5173/login"]) {
      expect(rewriteLocation(from, 5173, ORIGIN)).toBe(`${ORIGIN}/login`);
    }
    expect(rewriteLocation("http://localhost:5173", 5173, ORIGIN)).toBe(ORIGIN);
    expect(rewriteLocation("http://localhost:5173?x=1", 5173, ORIGIN)).toBe(`${ORIGIN}?x=1`);
  });

  test("any other Location is left as it is", () => {
    for (const from of ["/login", "http://localhost:5174/login", "http://localhost/login", "https://example.com/", "http://localhost:51730/", "http://localhost.evil.example:5173/"]) {
      expect(rewriteLocation(from, 5173, ORIGIN)).toBe(from);
    }
  });

  test("a header the Connection header names goes too, with the connection's own", () => {
    const out = upstreamHeaders([["Connection", "close, X-Hop"], ["X-Hop", "1"], ["X-Keep", "2"]], 5173, ORIGIN);
    expect([...out.keys()].sort()).toEqual(["host", "x-keep"]);
    const back = downstreamHeaders([["Connection", "X-Hop"], ["X-Hop", "1"], ["X-Keep", "2"]], 5173, ORIGIN);
    expect([...back.keys()]).toEqual(["x-keep"]);
  });

  test("a response keeps its headers but loses the connection's own, and its Location is rewritten", () => {
    const out = downstreamHeaders([["Content-Type", "text/html"], ["Transfer-Encoding", "chunked"], ["Location", "http://localhost:5173/x"], ["Set-Cookie", "a=b"]], 5173, ORIGIN);
    expect(out.get("content-type")).toBe("text/html");
    expect(out.get("set-cookie")).toBe("a=b");
    expect(out.get("location")).toBe(`${ORIGIN}/x`);
    expect(out.has("transfer-encoding")).toBe(false);
  });
});

describe("what Tailscale's refusal of a certificate says", () => {
  test("the operator is named, with the one command", () => {
    const failure = certificateFailure("Access denied: cert access denied\n");
    expect(failure.command).toBe(operatorCommand);
    expect(failure.note).toContain(operatorCommand);
  });

  test("anything else is Tailscale's first line, cut, with no command", () => {
    expect(certificateFailure("\nHTTPS isn't enabled on this tailnet.\nmore")).toEqual({ note: "No certificate: Tailscale said HTTPS isn't enabled on this tailnet.", command: null });
    expect(certificateFailure("x".repeat(500)).note.length).toBeLessThan(200);
    expect(certificateFailure("")).toEqual({ note: "No certificate: Tailscale didn't answer.", command: null });
  });
});

describe("the Host", () => {
  test("must be the proxied name and port", () => {
    expect(checkProxyHost("mac-mini.example.ts.net:5173", "mac-mini.example.ts.net", 5173)).toBe(true);
    expect(checkProxyHost("MAC-MINI.example.ts.net:5173", "mac-mini.example.ts.net", 5173)).toBe(true);
    expect(checkProxyHost("mac-mini.example.ts.net:5174", "mac-mini.example.ts.net", 5173)).toBe(false);
    expect(checkProxyHost("100.64.0.7:5173", "mac-mini.example.ts.net", 5173)).toBe(false);
    expect(checkProxyHost("mac-mini.example.ts.net", "mac-mini.example.ts.net", 5173)).toBe(false);
    expect(checkProxyHost(null, "mac-mini.example.ts.net", 5173)).toBe(false);
  });
});
