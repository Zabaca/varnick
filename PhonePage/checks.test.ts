import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  callerAddress, checkFetchSite, checkHost, checkOrigin, decideCaller, expectedHost, expectedOrigin, gateMutation, mayBeListed, parseSelf, parseTailnetJSON,
  parseWhois, readConfig, readDevices, type Device,
} from "./checks";

const ME = "10000000000000001";
// A user whose id differs from ME in the last digit only (and parses to the same double): a double can't tell the two apart.
const OTHER = "10000000000000000";
// The user id in fixtures/whois-own-node.json.
const FIXTURE_USER = "70000000000000001";
const SECOND_MAC = "nEXAMPLE2CNTRL";
const PHONE = "nEXAMPLE4CNTRL";
const devices: Device[] = [{ id: "5f0f3a4e-2b6e-4c0a-9d58-0a2f6f8d1c11", node: PHONE, name: "Phone" }];

function whoisText(node: Record<string, unknown>): string {
  return `{"Node":${JSON.stringify({ StableID: PHONE, Name: "phone-1.example.ts.net.", Tags: null, ...node })},"UserProfile":{"ID":${ME}}}`
    .replace(/"User":"([0-9]+)"/, '"User":$1');
}
const whoisOf = (node: Record<string, unknown> = {}, user = ME) => parseWhois(whoisText({ User: user, ...node }));

describe("the caller decision", () => {
  test("a listed node of the user's own is the device", () => {
    const caller = decideCaller(whoisOf(), ME, devices);
    expect(caller.kind).toBe("device");
    if (caller.kind === "device") {
      expect(caller.device.id).toBe(devices[0].id);
      expect(caller.label).toBe("phone-1");
    }
  });

  test("a node that isn't in the file is unlisted, with its name", () => {
    const caller = decideCaller(whoisOf({ StableID: SECOND_MAC, Name: "alexs-macbook-pro.example.ts.net." }), ME, devices);
    expect(caller).toEqual({ kind: "unlisted", reason: "not-listed", label: "alexs-macbook-pro" });
  });

  test("a tagged node is refused even when its entry is in the file", () => {
    const caller = decideCaller(whoisOf({ Tags: ["tag:vps"] }), ME, devices);
    expect(caller).toEqual({ kind: "unlisted", reason: "not-own", label: "phone-1" });
  });

  test("a node shared in is refused even when its entry is in the file", () => {
    // whois's Node has no ShareeNode of its own: tailcfg.Node's Sharer, and Hostinfo's ShareeNode, say shared in.
    expect(decideCaller(whoisOf({ Hostinfo: { ShareeNode: true } }), ME, devices).kind).toBe("unlisted");
    expect(decideCaller(whoisOf({ Sharer: 7 }), ME, devices).kind).toBe("unlisted");
    expect(decideCaller(whoisOf({ Sharer: "10000000000000002" }), ME, devices).kind).toBe("unlisted");
    expect(decideCaller(whoisOf({ Sharer: 0 }), ME, devices).kind).toBe("device");
    expect(decideCaller(whoisOf({ Hostinfo: { OS: "android" } }), ME, devices).kind).toBe("device");
  });

  test("a real whois answer (redacted), as the user's own untagged node", () => {
    const text = readFileSync(new URL("./fixtures/whois-own-node.json", import.meta.url), "utf8");
    const node = parseWhois(text)!;
    expect(node).toEqual({ stableID: "nEXAMPLE1CNTRL", label: "mac-mini", dnsName: "mac-mini.example.ts.net", tagged: false, sharee: false, userID: FIXTURE_USER });
    expect(decideCaller(node, FIXTURE_USER, [{ id: devices[0].id, node: node.stableID, name: "Mac mini" }]).kind).toBe("device");
    expect(decideCaller(node, OTHER, [{ id: devices[0].id, node: node.stableID, name: "Mac mini" }]).kind).toBe("unlisted");
    // The same answer with the fields that mark it as not the user's own.
    const tagged = JSON.parse(text); tagged.Node.Tags = ["tag:vps"];
    expect(parseWhois(JSON.stringify(tagged))!.tagged).toBe(true);
    const shared = JSON.parse(text); shared.Node.Sharer = 12345;
    expect(parseWhois(JSON.stringify(shared))!.sharee).toBe(true);
    const sharee = JSON.parse(text); sharee.Node.Hostinfo.ShareeNode = true;
    expect(parseWhois(JSON.stringify(sharee))!.sharee).toBe(true);
    expect(Object.keys(JSON.parse(text).Node)).not.toContain("ShareeNode");
  });

  test("another user's node is refused even when its entry is in the file", () => {
    expect(decideCaller(whoisOf({}, OTHER), ME, devices)).toEqual({ kind: "unlisted", reason: "not-own", label: "phone-1" });
  });

  test("a failed whois is unlisted and names nobody", () => {
    expect(decideCaller(null, ME, devices)).toEqual({ kind: "unlisted", reason: "unknown", label: null });
    expect(parseWhois("not json")).toBeNull();
    expect(parseWhois('{"Node":{}}')).toBeNull();
    expect(parseWhois("{}")).toBeNull();
  });

  test("a node with no owner, or a host with no user, is refused", () => {
    expect(decideCaller(whoisOf({ User: null }), ME, devices).kind).toBe("unlisted");
    expect(decideCaller(whoisOf(), null, devices).kind).toBe("unlisted");
  });

  test("tags in a shape that isn't a list count as tagged", () => {
    expect(whoisOf({ Tags: "tag:vps" })!.tagged).toBe(true);
    expect(whoisOf({ Tags: [] })!.tagged).toBe(false);
  });

  test("an empty device list lists nobody", () => {
    expect(decideCaller(whoisOf(), ME, []).kind).toBe("unlisted");
  });

  test("the same rule as PeerDevice.mayBeListed", () => {
    const own = { tagged: false, sharee: false, userID: ME };
    expect(mayBeListed(own, ME)).toBe(true);
    expect(mayBeListed({ ...own, tagged: true }, ME)).toBe(false);
    expect(mayBeListed({ ...own, sharee: true }, ME)).toBe(false);
    expect(mayBeListed({ ...own, userID: OTHER }, ME)).toBe(false);
    expect(mayBeListed({ ...own, userID: null }, ME)).toBe(false);
    expect(mayBeListed(own, null)).toBe(false);
  });
});

describe("user ids", () => {
  test("two ids a double can't tell apart stay different", () => {
    expect(Number(ME) === Number(OTHER)).toBe(true);
    const self = parseSelf(`{"Self":{"DNSName":"Mac-Mini.example.ts.net.","UserID":${ME}}}`);
    expect(self).toEqual({ dnsName: "mac-mini.example.ts.net", userID: ME });
    expect(whoisOf({}, OTHER)!.userID).toBe(OTHER);
    expect(whoisOf({}, OTHER)!.userID).not.toBe(self!.userID);
  });

  test("a small number stays a number", () => {
    expect(parseTailnetJSON('{"a":12,"b":1.5}')).toEqual({ a: 12, b: 1.5 });
  });

  test("status without a name or a user is nothing", () => {
    expect(parseSelf('{"Self":{"DNSName":"","UserID":1}}')).toBeNull();
    expect(parseSelf('{"Self":{"DNSName":"a.b.","UserID":0}}')).toEqual({ dnsName: "a.b", userID: "0" });
    expect(parseSelf('{"Self":{"DNSName":"a.b."}}')).toBeNull();
    expect(parseSelf("nope")).toBeNull();
  });
});

describe("the device file", () => {
  const id = "5F0F3A4E-2B6E-4C0A-9D58-0A2F6F8D1C11";

  test("ids are lowercased, so an uppercase hand-written id makes the label the relay compares", () => {
    expect(readDevices(JSON.stringify([{ id, node: PHONE, name: "Phone" }]))).toEqual([{ id: id.toLowerCase(), node: PHONE, name: "Phone" }]);
  });

  test("a bad entry is skipped and the good ones stay", () => {
    const text = JSON.stringify([{ bogus: 1 }, { id: "not-a-uuid", node: PHONE, name: "x" }, { id, node: "", name: "x" }, { id, node: PHONE, name: "ok" }]);
    expect(readDevices(text).map((device) => device.name)).toEqual(["ok"]);
  });

  test("a missing file, junk or a file that isn't a list lists nobody", () => {
    expect(readDevices(null)).toEqual([]);
    expect(readDevices("junk")).toEqual([]);
    expect(readDevices('{"not":"a list"}')).toEqual([]);
  });
});

describe("the address", () => {
  const isIP = (text: string) => /^[0-9.]+$/.test(text);
  test("the first address of the header, only when it is an address", () => {
    expect(callerAddress("100.64.0.4", isIP)).toBe("100.64.0.4");
    expect(callerAddress("100.64.0.4, 1.2.3.4", isIP)).toBe("100.64.0.4");
    expect(callerAddress("--help", isIP)).toBeNull();
    expect(callerAddress("", isIP)).toBeNull();
    expect(callerAddress(null, isIP)).toBeNull();
  });
});

describe("the Host check", () => {
  const expected = expectedHost("linux-box.example.ts.net", 8444);
  const headers = (init: Record<string, string>) => new Headers(init);

  test("on a socket it reads X-Forwarded-Host, and serve's own Host (localhost) doesn't count", () => {
    expect(checkHost("socket", headers({ host: "localhost", "x-forwarded-host": expected }), expected)).toBe(true);
    expect(checkHost("socket", headers({ host: expected }), expected)).toBe(false);
    expect(checkHost("socket", headers({ host: expected, "x-forwarded-host": "evil.example:8444" }), expected)).toBe(false);
  });

  test("on loopback it reads Host", () => {
    expect(checkHost("loopback", headers({ host: expected }), expected)).toBe(true);
    expect(checkHost("loopback", headers({ host: "evil.example:8444", "x-forwarded-host": expected }), expected)).toBe(false);
    expect(checkHost("loopback", headers({ host: "127.0.0.1:18449" }), expected)).toBe(false);
  });

  test("a wrong host, a wrong port and no header are refused", () => {
    expect(checkHost("socket", headers({ "x-forwarded-host": "linux-box.example.ts.net:8443" }), expected)).toBe(false);
    expect(checkHost("socket", headers({ "x-forwarded-host": "linux-box.example.ts.net" }), expected)).toBe(false);
    expect(checkHost("socket", headers({}), expected)).toBe(false);
    expect(checkHost("loopback", headers({}), expected)).toBe(false);
  });

  test("two values of the header don't pass as one", () => {
    expect(checkHost("socket", headers({ "x-forwarded-host": `${expected}, evil.example` }), expected)).toBe(false);
  });

  test("the case of a name doesn't matter", () => {
    expect(checkHost("socket", headers({ "x-forwarded-host": expected.toUpperCase() }), expected)).toBe(true);
  });
});

describe("the Origin check", () => {
  const expected = expectedOrigin("linux-box.example.ts.net", 8444);
  const post = (init: Record<string, string>) => gateMutation("POST", new Headers(init), expected);

  test("the page's own origin passes, anything else or nothing is refused", () => {
    expect(checkOrigin(expected, expected)).toBe(true);
    expect(checkOrigin("https://evil.example", expected)).toBe(false);
    expect(checkOrigin("https://linux-box.example.ts.net:8443", expected)).toBe(false);
    expect(checkOrigin("http://linux-box.example.ts.net:8444", expected)).toBe(false);
    expect(checkOrigin("null", expected)).toBe(false);
    expect(checkOrigin(null, expected)).toBe(false);
  });

  test("a POST needs the origin and a JSON body", () => {
    expect(post({ origin: expected, "content-type": "application/json" })).toBeNull();
    expect(post({ origin: expected, "content-type": "application/json; charset=utf-8" })).toBeNull();
    expect(post({ origin: "https://evil.example", "content-type": "application/json" })?.status).toBe(403);
    expect(post({ "content-type": "application/json" })?.status).toBe(403);
    expect(post({ origin: expected, "content-type": "application/x-www-form-urlencoded" })?.status).toBe(415);
    expect(post({ origin: expected })?.status).toBe(415);
  });

  test("a form POST from another site is refused, whatever its type", () => {
    expect(post({ origin: "https://evil.example", "content-type": "application/x-www-form-urlencoded" })?.status).toBe(403);
  });

  test("reads go through, other methods don't", () => {
    expect(gateMutation("GET", new Headers(), expected)).toBeNull();
    expect(gateMutation("HEAD", new Headers(), expected)).toBeNull();
    for (const method of ["PUT", "DELETE", "PATCH", "OPTIONS"]) expect(gateMutation(method, new Headers({ origin: expected }), expected)?.status).toBe(405);
  });
});

describe("requests from another site", () => {
  const expected = expectedOrigin("linux-box.example.ts.net", 8444);
  const ok = (init: Record<string, string>) => checkFetchSite(new Headers(init), expected);

  test("the page's own requests say same-origin", () => {
    expect(ok({ "sec-fetch-site": "same-origin" })).toBe(true);
    expect(ok({ "sec-fetch-site": "same-origin", origin: expected })).toBe(true);
  });

  test("a no-cors fetch from another site says cross-site and is refused", () => {
    expect(ok({ "sec-fetch-site": "cross-site" })).toBe(false);
    expect(ok({ "sec-fetch-site": "same-site" })).toBe(false);
    expect(ok({ "sec-fetch-site": "none" })).toBe(false);
    // The header decides: a forged-looking Origin doesn't rescue it.
    expect(ok({ "sec-fetch-site": "cross-site", origin: expected })).toBe(false);
  });

  test("without that header an Origin, when sent, must be the page's", () => {
    expect(ok({ origin: expected })).toBe(true);
    expect(ok({ origin: "https://evil.example" })).toBe(false);
    expect(ok({ origin: "null" })).toBe(false);
  });

  test("a client that sends neither (curl) goes through", () => {
    expect(ok({})).toBe(true);
  });
});

describe("the configuration", () => {
  const base = { VARNICK_RELAY: "/opt/varnick-peer", VARNICK_DEVICES: "/opt/devices.json" };

  test("a socket or a loopback port, one of them", () => {
    expect("config" in readConfig({ ...base, VARNICK_PAGE_SOCKET: "/tmp/x/page.sock" })).toBe(true);
    expect("config" in readConfig({ ...base, VARNICK_PAGE_LOOPBACK: "18449" })).toBe(true);
    expect("error" in readConfig(base)).toBe(true);
    expect("error" in readConfig({ ...base, VARNICK_PAGE_SOCKET: "/tmp/x/page.sock", VARNICK_PAGE_LOOPBACK: "18449" })).toBe(true);
  });

  test("the published port is 8444 unless set, and must be a port", () => {
    const read = (extra: Record<string, string>) => readConfig({ ...base, VARNICK_PAGE_LOOPBACK: "18449", ...extra });
    expect((read({}) as any).config.port).toBe(8444);
    expect((read({ VARNICK_PAGE_PORT: "8449" }) as any).config.port).toBe(8449);
    expect("error" in read({ VARNICK_PAGE_PORT: "0" })).toBe(true);
    expect("error" in read({ VARNICK_PAGE_PORT: "99999" })).toBe(true);
    expect("error" in read({ VARNICK_PAGE_PORT: "8444x" })).toBe(true);
    expect("error" in readConfig({ ...base, VARNICK_PAGE_LOOPBACK: "nope" })).toBe(true);
  });

  test("the port proxy has a folder and a status file together, or is off", () => {
    const read = (extra: Record<string, string>) => readConfig({ ...base, VARNICK_PAGE_LOOPBACK: "18449", ...extra });
    expect((read({}) as any).config.proxy).toBeUndefined();
    expect((read({ VARNICK_PROXY_FOLDER: "/p", VARNICK_PROXY_STATUS: "/s.json" }) as any).config.proxy).toEqual({ folder: "/p", status: "/s.json", tabs: undefined });
    expect((read({ VARNICK_PROXY_FOLDER: "/p", VARNICK_PROXY_STATUS: "/s.json", VARNICK_PROXY_TABS: "/t.json" }) as any).config.proxy.tabs).toBe("/t.json");
    expect("error" in read({ VARNICK_PROXY_FOLDER: "/p", VARNICK_PROXY_STATUS: "/s.json", VARNICK_PROXY_TABS: "t.json" })).toBe(true);
    expect("error" in read({ VARNICK_PROXY_FOLDER: "/p" })).toBe(true);
    expect("error" in read({ VARNICK_PROXY_STATUS: "/s.json" })).toBe(true);
    expect("error" in read({ VARNICK_PROXY_FOLDER: "p", VARNICK_PROXY_STATUS: "/s.json" })).toBe(true);
  });

  test("push has its three folders together, or is off, and a Mac's key comes in the environment", () => {
    const read = (extra: Record<string, string>) => readConfig({ ...base, VARNICK_PAGE_LOOPBACK: "18449", ...extra });
    const three = { VARNICK_PUSH_FOLDER: "/p", VARNICK_PANES_FOLDER: "/panes", VARNICK_PRESENCE_FOLDER: "/presence" };
    expect((read({}) as any).config.push).toBeUndefined();
    expect((read(three) as any).config.push).toEqual({ folder: "/p", panes: "/panes", presence: "/presence", key: undefined });
    expect((read({ ...three, VARNICK_PUSH_KEY: "{}" }) as any).config.push.key).toBe("{}");
    expect("error" in read({ VARNICK_PUSH_FOLDER: "/p" })).toBe(true);
    expect("error" in read({ VARNICK_PUSH_FOLDER: "/p", VARNICK_PANES_FOLDER: "/panes" })).toBe(true);
    expect("error" in read({ ...three, VARNICK_PANES_FOLDER: "panes" })).toBe(true);
  });

  test("the relay and the device file are absolute paths", () => {
    expect("error" in readConfig({ VARNICK_PAGE_LOOPBACK: "18449", VARNICK_DEVICES: "/d" })).toBe(true);
    expect("error" in readConfig({ VARNICK_PAGE_LOOPBACK: "18449", VARNICK_RELAY: "relay", VARNICK_DEVICES: "/d" })).toBe(true);
    expect("error" in readConfig({ VARNICK_PAGE_LOOPBACK: "18449", VARNICK_RELAY: "/r" })).toBe(true);
  });

  test("the zmx folder and the home are passed on when set", () => {
    const read = readConfig({ ...base, VARNICK_PAGE_LOOPBACK: "18449", VARNICK_ZMX_DIR: "/tmp/zmx-check", CFFIXED_USER_HOME: "/tmp/home" }) as any;
    expect(read.config.zmxDir).toBe("/tmp/zmx-check");
    expect(read.config.userHome).toBe("/tmp/home");
    expect(read.config.tailscale).toBe("tailscale");
  });
});
