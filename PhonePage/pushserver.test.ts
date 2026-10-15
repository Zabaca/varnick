import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Device } from "./checks";
import { folderWatch, keyFileName, loadKey, pushRoute, pushStatus, readPresence, readTurnDates, setupPush, subscriptionsFileName, testEveryMs, writePrivate } from "./pushserver";
import { Shared } from "./pushwatch";
import { b64u, fingerprint, generatePushKey, parsePushKey } from "./webpush";

const root = mkdtempSync(join(tmpdir(), "push-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
let counter = 0;
const folder = () => { const path = join(root, `f${(counter += 1)}`); mkdirSync(path, { recursive: true, mode: 0o700 }); return path; };
const mode = (path: string) => statSync(path).mode & 0o777;

const point = b64u.encode(new Uint8Array([4, ...Array.from({ length: 64 }, (_, index) => index)]));
const auth = b64u.encode(new Uint8Array(16));
const device: Device = { id: "11111111-1111-4111-8111-111111111111", node: "n", name: "Phone" };
// A real browser key, so a push to it can be encrypted.
const browser = await generatePushKey();
const realPoint = b64u.encode(new Uint8Array([4, ...b64u.decode(browser.x), ...b64u.decode(browser.y)]));
const subscription = (n = 1) => ({ endpoint: `https://fcm.googleapis.com/fcm/send/${n}`, keys: { p256dh: realPoint, auth } });

describe("the key", () => {
  test("a Mac's comes from its Varnick; a Mac without one sends no push", async () => {
    const key = await generatePushKey();
    const given = await loadKey({ folder: folder(), panes: "/p", presence: "/q", key: JSON.stringify(key) }, false);
    expect(given).toEqual({ key });
    expect("off" in (await loadKey({ folder: folder(), panes: "/p", presence: "/q" }, false))).toBe(true);
    expect("off" in (await loadKey({ folder: folder(), panes: "/p", presence: "/q", key: "nonsense" }, false))).toBe(true);
    // A Mac never writes a key file of its own: the Keychain holds it.
  });

  test("a headless host makes its key at the first start, owner-only, and keeps it", async () => {
    const dir = folder();
    const first = await loadKey({ folder: dir, panes: "/p", presence: "/q" }, true);
    expect("key" in first).toBe(true);
    expect(mode(join(dir, keyFileName))).toBe(0o600);
    const again = await loadKey({ folder: dir, panes: "/p", presence: "/q" }, true);
    expect(again).toEqual(first);
    expect(parsePushKey(readFileSync(join(dir, keyFileName), "utf8"))).toEqual((first as { key: object }).key as never);
  });

  test("a lost or unreadable key file is made again", async () => {
    const dir = folder();
    writeFileSync(join(dir, keyFileName), "garbage");
    const made = await loadKey({ folder: dir, panes: "/p", presence: "/q" }, true);
    expect("key" in made).toBe(true);
    expect(parsePushKey(readFileSync(join(dir, keyFileName), "utf8"))).not.toBeNull();
  });

  test("a private file is replaced whole and closed to others", () => {
    const dir = folder();
    const file = join(dir, "x.json");
    writePrivate(file, "one");
    writePrivate(file, "two");
    expect(readFileSync(file, "utf8")).toBe("two");
    expect(mode(file)).toBe(0o600);
  });
});

describe("the files it reads", () => {
  test("a presence file is a report, and nothing else is", () => {
    const dir = folder();
    const id = "22222222-2222-4222-8222-222222222222";
    writeFileSync(join(dir, `${id}.json`), JSON.stringify({ idle: 4, away: false, at: 1000 }));
    expect(readPresence(dir, id)).toEqual({ idle: 4, away: false, at: 1000 });
    expect(readPresence(dir, id.toUpperCase())).toEqual({ idle: 4, away: false, at: 1000 });
    expect(readPresence(dir, "33333333-3333-4333-8333-333333333333")).toBeNull();
    expect(readPresence(dir, "../etc/passwd")).toBeNull();
    writeFileSync(join(dir, `${id}.json`), JSON.stringify({ idle: "4", away: false, at: 1000 }));
    expect(readPresence(dir, id)).toBeNull();
    writeFileSync(join(dir, `${id}.json`), "not json");
    expect(readPresence(dir, id)).toBeNull();
  });

  test("a turn file's date, 0 for a pane without one", () => {
    const dir = folder();
    const pane = "44444444-4444-4444-8444-444444444444";
    mkdirSync(join(dir, pane));
    writeFileSync(join(dir, pane, ".varnick-turn"), "working");
    utimesSync(join(dir, pane, ".varnick-turn"), 1000, 2000);
    const dates = readTurnDates(dir, [pane, "55555555-5555-4555-8555-555555555555"]);
    expect(dates.get(pane)).toBe(2_000_000);
    expect(dates.get("55555555-5555-4555-8555-555555555555")).toBe(0);
  });

  test("a new pane folder is seen once, the first look only learning what is there", () => {
    const dir = folder();
    mkdirSync(join(dir, "a"));
    const watch = folderWatch(dir);
    expect(watch()).toBe(false);
    expect(watch()).toBe(false);
    mkdirSync(join(dir, "b"));
    expect(watch()).toBe(true);
    expect(watch()).toBe(false);
    expect(folderWatch(join(dir, "missing"))()).toBe(false);
  });
});

async function pushIn(options: { headless?: boolean; devices?: Device[] } = {}) {
  const dir = folder();
  const logs: string[] = [];
  const calls: unknown[] = [];
  const push = await setupPush({
    config: {} as never,
    push: { folder: dir, panes: join(dir, "panes"), presence: join(dir, "presence") },
    headless: options.headless ?? true,
    ownID: "66666666-6666-4666-8666-666666666666",
    askTabs: async () => ({ ok: true, reply: { tabs: [] } }),
    hostTabs: new Shared(async () => ({ ok: true as const, reply: { tabs: [] } }), () => Date.now(), 1500),
    tabsStamp: () => "none",
    devices: () => options.devices ?? [device],
    log: (line) => logs.push(line),
    fetch: (async (url: string) => { calls.push(url); return new Response(null, { status: 201 }); }) as unknown as typeof fetch,
  });
  return { push: push!, dir, logs, calls };
}

describe("setting push up", () => {
  test("a host with a key has a public key and a fingerprint, and the subscriptions file is its own", async () => {
    const { push, dir } = await pushIn();
    expect(b64u.decode(push.publicKey)).toHaveLength(65);
    expect(push.fingerprint).toBe(await fingerprint(push.key));
    expect(pushStatus(push, "Studio").body).toEqual({ ok: true, supported: true, host: "Studio", key: push.publicKey, fingerprint: push.fingerprint });
    expect(pushStatus(null, "Studio").body).toEqual({ ok: true, supported: false, host: "Studio" });
    await pushRoute(push, device, "/api/push/subscribe", { subscription: subscription() }, { now: () => 1, log: () => {} });
    expect(mode(join(dir, subscriptionsFileName))).toBe(0o600);
  });

  test("no key, no push, and the reason is logged", async () => {
    const dir = folder();
    const logs: string[] = [];
    const push = await setupPush({
      config: {} as never, push: { folder: dir, panes: "/p", presence: "/q" }, headless: false, ownID: "x", askTabs: async () => ({ ok: false, error: "x" }),
      hostTabs: new Shared(async () => ({ ok: false as const, error: "x" }), () => 0, 0), tabsStamp: () => "", devices: () => [], log: (line) => logs.push(line),
    });
    expect(push).toBeNull();
    expect(logs[0]).toContain("push off");
  });

  test("subscriptions made for another key are dropped at the start", async () => {
    const { push, dir } = await pushIn();
    await pushRoute(push, device, "/api/push/subscribe", { subscription: subscription() }, { now: () => 1, log: () => {} });
    // A new key (the file lost): the old subscription carried the old fingerprint.
    writeFileSync(join(dir, keyFileName), "x");
    const again = await setupPush({
      config: {} as never, push: { folder: dir, panes: join(dir, "panes"), presence: join(dir, "presence") }, headless: true, ownID: "x",
      askTabs: async () => ({ ok: true, reply: {} }), hostTabs: new Shared(async () => ({ ok: true as const, reply: {} }), () => 0, 0), tabsStamp: () => "", devices: () => [device], log: () => {},
    });
    expect(again!.fingerprint).not.toBe(push.fingerprint);
    expect(again!.store.all()).toEqual([]);
  });
});

describe("the routes", () => {
  const world = { now: () => 1000, log: () => {} };

  test("subscribe, ask the state, unsubscribe", async () => {
    const { push } = await pushIn();
    const subscribed = await pushRoute(push, device, "/api/push/subscribe", { subscription: subscription(), switches: { done: false } }, world);
    expect(subscribed).toEqual({ status: 200, body: { ok: true, switches: { needsMe: true, done: false, errors: true } } });
    expect((await pushRoute(push, device, "/api/push/state", { endpoint: subscription().endpoint }, world)).body).toEqual({ ok: true, subscribed: true, switches: { needsMe: true, done: false, errors: true } });
    expect((await pushRoute(push, device, "/api/push/state", { endpoint: subscription(2).endpoint }, world)).body).toEqual({ ok: true, subscribed: false });
    expect((await pushRoute(push, device, "/api/push/unsubscribe", { endpoint: subscription().endpoint }, world)).body).toEqual({ ok: true });
    expect((await pushRoute(push, device, "/api/push/state", { endpoint: subscription().endpoint }, world)).body).toEqual({ ok: true, subscribed: false });
  });

  test("a device sees and removes only its own", async () => {
    const { push } = await pushIn();
    const other: Device = { ...device, id: "77777777-7777-4777-8777-777777777777", name: "Tablet" };
    await pushRoute(push, device, "/api/push/subscribe", { subscription: subscription() }, world);
    expect((await pushRoute(push, other, "/api/push/state", { endpoint: subscription().endpoint }, world)).body).toEqual({ ok: true, subscribed: false });
    await pushRoute(push, other, "/api/push/unsubscribe", { endpoint: subscription().endpoint }, world);
    expect(push.store.all()).toHaveLength(1);
  });

  test("an address that isn't a push service's is refused before it is stored", async () => {
    const { push } = await pushIn();
    for (const endpoint of ["https://example.com/x", "http://fcm.googleapis.com/x", "https://127.0.0.1/x", "https://100.64.1.1:8444/x"]) {
      const refused = await pushRoute(push, device, "/api/push/subscribe", { subscription: { endpoint, keys: { p256dh: point, auth } } }, world);
      expect(refused.status).toBe(400);
    }
    expect(push.store.all()).toEqual([]);
    expect((await pushRoute(push, device, "/api/push/test", { endpoint: "https://example.com/x" }, world)).status).toBe(400);
    expect((await pushRoute(push, device, "/api/push/state", null, world)).status).toBe(400);
  });

  test("a test goes to the device's own subscription, no more than one in a few seconds", async () => {
    const { push, calls, logs } = await pushIn();
    let now = 1_000_000;
    const clock = { now: () => now, log: (line: string) => logs.push(line) };
    expect((await pushRoute(push, device, "/api/push/test", { endpoint: subscription().endpoint }, clock)).status).toBe(404);
    await pushRoute(push, device, "/api/push/subscribe", { subscription: subscription() }, clock);
    expect((await pushRoute(push, device, "/api/push/test", { endpoint: subscription().endpoint }, clock)).body).toEqual({ ok: true });
    expect(calls).toEqual([subscription().endpoint]);
    expect((await pushRoute(push, device, "/api/push/test", { endpoint: subscription().endpoint }, clock)).status).toBe(429);
    now += testEveryMs;
    expect((await pushRoute(push, device, "/api/push/test", { endpoint: subscription().endpoint }, clock)).status).toBe(200);
    expect(logs.filter((line) => line.includes("test"))).toEqual(["push Phone test sent 201", "push Phone test sent 201"]);
    // Nothing logged names an endpoint.
    expect(logs.join("\n")).not.toContain("fcm.googleapis");
  });

  test("a host with no push answers 404 to every route", async () => {
    expect((await pushRoute(null, device, "/api/push/subscribe", {}, world)).status).toBe(404);
  });
});
