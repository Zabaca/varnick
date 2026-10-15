import { describe, expect, test } from "bun:test";
import { busyAskMs, idleAskMs, OpenPanes, perDeviceHourLimit, PushWatcher, Shared, tickMs, type PushWorld } from "./pushwatch";
import { defaultSwitches, settleMs, type PresenceReport, type PushPayload } from "./pushrule";
import { SubscriptionStore, type StoreFile, type Subscription } from "./pushstore";
import { b64u } from "./webpush";
import type { SendResult } from "./pushsend";

const own = "aaaaaaaa-0000-4000-8000-000000000000";
const phone = "bbbbbbbb-0000-4000-8000-000000000000";
const tablet = "cccccccc-0000-4000-8000-000000000000";
const mac = "dddddddd-0000-4000-8000-000000000000";
const tab = "eeeeeeee-0000-4000-8000-000000000000";
const pane = "ffffffff-0000-4000-8000-000000000000";
const other = "ffffffff-0000-4000-8000-000000000001";

const point = b64u.encode(new Uint8Array([4, ...Array.from({ length: 64 }, (_, index) => index)]));
const auth = b64u.encode(new Uint8Array(16));

interface FakePane { id: string; turn?: string; control?: string | null; clients?: number; failure?: string; esc?: boolean; running?: boolean; kind?: string; keepBegan?: boolean }

function rig(options: { subscribed?: Array<{ device: string; switches?: Partial<typeof defaultSwitches> }>; listed?: string[] } = {}) {
  let now = 1_000_000_000_000;
  const file: StoreFile & { text: string | null } = { text: null, read() { return file.text; }, write(text) { file.text = text; } };
  const store = new SubscriptionStore(file, "k");
  for (const [index, s] of (options.subscribed ?? [{ device: phone }]).entries()) {
    store.upsert(s.device, { endpoint: `https://fcm.googleapis.com/fcm/send/${s.device}-${index}`, p256dh: point, auth, switches: { ...defaultSwitches, ...s.switches } }, now);
  }
  const state = {
    panes: [{ id: pane, turn: "working", control: null, clients: 1 }] as FakePane[],
    presence: new Map<string, PresenceReport>(),
    open: new Set<string>(),
    sends: [] as Array<{ device: string; payload: PushPayload }>,
    asks: 0,
    began: new Map<string, { word: string; at: number }>(),
    ok: true,
    dates: new Map<string, number>(),
    stamp: "1",
    folder: false,
    listed: new Map((options.listed ?? [phone, tablet]).map((id) => [id, id === phone ? "Phone" : "Tablet"])),
    result: { outcome: "sent", status: 201 } as SendResult,
    logs: [] as string[],
  };
  const world: PushWorld = {
    now: () => now,
    ownID: own,
    askTabs: async () => {
      state.asks += 1;
      if (!state.ok) return { ok: false, error: "down" };
      // A host's age is how long ago the turn began: a new word begins a turn, unless the test says the turn is the same (an error that follows its waiting).
      const panes = state.panes.map((p) => {
        const known = state.began.get(p.id);
        if (!known || (known.word !== p.turn && !p.keepBegan)) state.began.set(p.id, { word: p.turn ?? "", at: now });
        else state.began.set(p.id, { word: p.turn ?? "", at: known.at });
        const { keepBegan: _, ...rest } = p;
        return { kind: "claude", running: true, ...rest, turnAge: Math.floor((now - state.began.get(p.id)!.at) / 1000) };
      });
      return { ok: true, reply: { tabs: [{ tab, panes }] } };
    },
    turnDates: (ids) => new Map(ids.map((id) => [id, state.dates.get(id) ?? 0])),
    newPaneFolder: () => { const seen = state.folder; state.folder = false; return seen; },
    tabsStamp: () => state.stamp,
    devices: () => state.listed,
    presence: (id) => state.presence.get(id) ?? null,
    hasPaneOpen: (device, id) => state.open.has(`${device}:${id}`),
    send: async (subscription: Subscription, payload) => { state.sends.push({ device: subscription.device, payload }); return state.result; },
    log: (line) => state.logs.push(line),
  };
  const watcher = new PushWatcher(world, store);
  const advance = async (ms: number) => {
    // The server ticks every 2 s.
    for (let left = ms; left > 0; left -= tickMs) { now += Math.min(tickMs, left); await watcher.tick(); }
  };
  const present = (id: string, extra: Partial<PresenceReport> = {}) => state.presence.set(id, { idle: 5, away: false, at: Math.floor(now / 1000), ...extra });
  /** A report kept fresh, as the Mac's 5 s status requests and the host's 10 s writes keep it. */
  const keep = (id: string, extra: Partial<PresenceReport> = {}) => present(id, extra);
  return { watcher, store, state, advance, present, keep, now: () => now, setNow: (value: number) => { now = value; } };
}

/** The pane's turn goes from working to waiting: a Done stands from the next ask. */
async function finishTurn(r: ReturnType<typeof rig>, word = "waiting", extra: Partial<FakePane> = {}) {
  await r.watcher.tick();
  r.state.panes[0] = { ...r.state.panes[0], turn: word, ...extra };
  r.state.dates.set(pane, 1);
  await r.advance(tickMs);
}

describe("the starting point", () => {
  test("the first word read for a pane raises nothing, whatever it is", async () => {
    for (const word of ["waiting", "permission", "failed", "working"]) {
      const r = rig();
      r.state.panes[0].turn = word;
      r.state.panes[0].control = phone;
      await r.advance(settleMs * 3);
      expect(r.state.sends).toEqual([]);
      expect(r.watcher.noticeFor(pane)).toBeUndefined();
    }
  });

  test("nothing is asked or watched without a subscription", async () => {
    const r = rig({ subscribed: [] });
    await r.advance(60_000);
    expect(r.state.asks).toBe(0);
  });
});

describe("a device in control", () => {
  test("Done is pushed after the settle, once, with the ids and the kind only", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r);
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "done" });
    await r.advance(settleMs - tickMs * 2);
    expect(r.state.sends).toEqual([]);
    await r.advance(tickMs * 4);
    expect(r.state.sends).toEqual([{ device: phone, payload: { v: 1, kind: "done", tab, pane } }]);
    await r.advance(60_000);
    expect(r.state.sends).toHaveLength(1);
  });

  test("a dialog is Needs you, saying which, and a rate limit names its kind", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r, "question");
    await r.advance(settleMs + tickMs);
    expect(r.state.sends.at(-1)!.payload).toEqual({ v: 1, kind: "question", tab, pane });

    const e = rig();
    e.state.panes[0].control = phone;
    await finishTurn(e, "failed", { failure: "rate_limit" });
    await e.advance(settleMs + tickMs);
    expect(e.state.sends.at(-1)!.payload).toEqual({ v: 1, kind: "failed", tab, pane, failure: "rate limit" });
  });

  test("an error from a host that says no kind has none in the payload", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r, "failed");
    await r.advance(settleMs + tickMs);
    expect(r.state.sends.at(-1)!.payload).toEqual({ v: 1, kind: "failed", tab, pane });
  });

  test("answering the dialog before the settle pushes nothing", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r, "permission");
    await r.advance(tickMs * 2);
    r.state.panes[0] = { ...r.state.panes[0], turn: "working" };
    r.state.dates.set(pane, 2);
    await r.advance(settleMs * 3);
    expect(r.state.sends).toEqual([]);
    expect(r.watcher.noticeFor(pane)).toBeUndefined();
  });

  test("Esc raises nothing", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r, "waiting", { esc: true });
    await r.advance(settleMs * 2);
    expect(r.state.sends).toEqual([]);
  });

  test("a Done that the read after the settle finds was background work isn't pushed", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r);
    // The turn file said waiting, and the transcript now says work goes on.
    const asks = r.state.asks;
    r.state.panes[0] = { ...r.state.panes[0], turn: "background" };
    await r.advance(settleMs * 2);
    expect(r.state.sends).toEqual([]);
    expect(r.state.asks).toBeGreaterThan(asks);
  });

  test("waiting and then failed in the same turn is an error, and the Done never goes", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r);
    r.state.panes[0] = { ...r.state.panes[0], turn: "failed", failure: "overloaded", keepBegan: true };
    await r.advance(settleMs + tickMs * 2);
    expect(r.state.sends.map((s) => s.payload)).toEqual([{ v: 1, kind: "failed", tab, pane, failure: "overloaded" }]);
  });

  test("a notice is read again before it goes: a fresh ask follows the settle", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r);
    const asks = r.state.asks;
    await r.advance(settleMs + tickMs);
    expect(r.state.asks).toBeGreaterThan(asks);
  });
});

describe("a Mac in control", () => {
  test("a present user at the host gets no push, however long the notice stands", async () => {
    const r = rig();
    r.keep(own);
    await r.watcher.tick();
    r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
    r.state.dates.set(pane, 1);
    for (let i = 0; i < 100; i += 1) { r.keep(own); await r.advance(tickMs); }
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "done" });
    expect(r.state.sends).toEqual([]);
  });

  test("the Mac turning away with the notice still standing sends it then", async () => {
    const r = rig();
    r.keep(own);
    await r.watcher.tick();
    r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
    r.state.dates.set(pane, 1);
    for (let i = 0; i < 20; i += 1) { r.keep(own); await r.advance(tickMs); }
    expect(r.state.sends).toEqual([]);
    r.keep(own, { away: true });
    await r.advance(tickMs * 3);
    expect(r.state.sends.map((s) => s.payload.kind)).toEqual(["done"]);
  });

  test("two minutes without input is away", async () => {
    const r = rig();
    r.keep(own, { idle: 100 });
    await r.watcher.tick();
    r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
    r.state.dates.set(pane, 1);
    await r.advance(tickMs);
    // Reports keep coming, the user touches nothing: idle grows 2 s a tick, so the 120 s mark passes within a minute.
    let idle = 102;
    while (r.state.sends.length === 0 && idle < 400) { r.keep(own, { idle }); await r.advance(tickMs); idle += 2; }
    expect(r.state.sends).toHaveLength(1);
    expect(idle).toBeGreaterThanOrEqual(118);
  });

  test("a host with no report, or a stale one, can't be told and pushes after the settle", async () => {
    const none = rig();
    await finishTurn(none);
    await none.advance(settleMs + tickMs * 2);
    expect(none.state.sends).toHaveLength(1);

    const stale = rig();
    stale.present(own, { at: Math.floor(stale.now() / 1000) - 60 });
    await finishTurn(stale);
    await stale.advance(settleMs + tickMs * 2);
    expect(stale.state.sends).toHaveLength(1);
  });

  test("a peer Mac in control is told by its own file, not the host's", async () => {
    const r = rig();
    r.state.panes[0].control = mac;
    r.keep(own, { away: true });
    r.keep(mac);
    await r.watcher.tick();
    r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
    r.state.dates.set(pane, 1);
    for (let i = 0; i < 12; i += 1) { r.keep(mac); await r.advance(tickMs); }
    expect(r.state.sends).toEqual([]);
    r.keep(mac, { away: true });
    await r.advance(tickMs * 3);
    expect(r.state.sends).toHaveLength(1);
  });

  test("a peer Mac whose client is detached can't be told, so it pushes though its last report says present", async () => {
    const r = rig();
    r.state.panes[0].control = mac;
    r.state.panes[0].clients = 0;
    r.keep(mac);
    await finishTurn(r);
    for (let i = 0; i < 8; i += 1) { r.keep(mac); await r.advance(tickMs); }
    expect(r.state.sends).toHaveLength(1);
  });

  test("the host's own pane with no client is its Varnick's to notify: a present user is not pushed", async () => {
    const r = rig();
    r.state.panes[0].clients = 0;
    r.keep(own);
    await r.watcher.tick();
    r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
    r.state.dates.set(pane, 1);
    for (let i = 0; i < 12; i += 1) { r.keep(own); await r.advance(tickMs); }
    expect(r.state.sends).toEqual([]);
  });
});

describe("who gets it", () => {
  test("a device with the pane open gets none, in every row, and another device does", async () => {
    const r = rig({ subscribed: [{ device: phone }, { device: tablet }] });
    r.state.panes[0].control = phone;
    r.state.open.add(`${phone}:${pane}`);
    await finishTurn(r);
    await r.advance(settleMs + tickMs * 2);
    expect(r.state.sends.map((s) => s.device)).toEqual([tablet]);
  });

  test("closing the pane afterwards doesn't push a notice the device was there for", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    r.state.open.add(`${phone}:${pane}`);
    await finishTurn(r);
    await r.advance(settleMs + tickMs * 2);
    r.state.open.clear();
    await r.advance(settleMs * 3);
    expect(r.state.sends).toEqual([]);
  });

  test("each switch is its own, and an error is not Done", async () => {
    for (const [word, extra, off] of [
      ["permission", {}, "needsMe"], ["waiting", {}, "done"], ["failed", { failure: "rate_limit" }, "errors"],
    ] as const) {
      const r = rig({ subscribed: [{ device: phone, switches: { [off]: false } }] });
      r.state.panes[0].control = phone;
      await finishTurn(r, word, extra);
      await r.advance(settleMs * 2);
      expect(r.state.sends).toEqual([]);
    }
    const r = rig({ subscribed: [{ device: phone, switches: { done: false } }] });
    r.state.panes[0].control = phone;
    await finishTurn(r, "permission");
    await r.advance(settleMs * 2);
    expect(r.state.sends).toHaveLength(1);
  });

  test("a device the host no longer lists loses its subscription, and gets nothing", async () => {
    const r = rig({ listed: [tablet] });
    r.state.panes[0].control = phone;
    await finishTurn(r);
    await r.advance(settleMs * 2);
    expect(r.state.sends).toEqual([]);
    expect(r.store.all()).toEqual([]);
  });

  test("a notice for one pane replaces the last, and another pane is its own", async () => {
    const r = rig();
    r.state.panes = [{ id: pane, turn: "working", control: phone, clients: 1 }, { id: other, turn: "working", control: phone, clients: 1 }];
    await r.watcher.tick();
    r.state.panes = r.state.panes.map((p) => ({ ...p, turn: "permission" }));
    r.state.dates.set(pane, 1);
    await r.advance(settleMs + tickMs * 3);
    expect(r.state.sends.map((s) => s.payload.kind)).toEqual(["permission", "permission"]);
    expect(new Set(r.state.sends.map((s) => (s.payload as { pane: string }).pane))).toEqual(new Set([pane, other]));
  });
});

describe("what the push service says", () => {
  test("gone drops the subscription; a failure is kept and not repeated for the notice", async () => {
    const gone = rig();
    gone.state.panes[0].control = phone;
    gone.state.result = { outcome: "gone", status: 410 };
    await finishTurn(gone);
    await gone.advance(settleMs + tickMs * 2);
    expect(gone.store.all()).toEqual([]);

    const failed = rig();
    failed.state.panes[0].control = phone;
    failed.state.result = { outcome: "failed", status: 403 };
    await finishTurn(failed);
    await failed.advance(settleMs * 6);
    expect(failed.state.sends).toHaveLength(1);
    expect(failed.store.all()[0].lastFailure).toBeDefined();
  });

  test("the log holds the device's name, the kind and the status, never an endpoint or an id of a pane", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r);
    await r.advance(settleMs + tickMs * 2);
    expect(r.state.logs).toEqual(["push Phone done sent 201"]);
  });

  test("60 pushes to a device an hour, then they are dropped", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await r.watcher.tick();
    let dropped = false;
    for (let i = 0; i < perDeviceHourLimit + 5; i += 1) {
      r.state.panes[0] = { ...r.state.panes[0], turn: "permission" };
      r.state.dates.set(pane, 2 * i + 10);
      await r.advance(settleMs + tickMs * 3);
      r.state.panes[0] = { ...r.state.panes[0], turn: "working" };
      r.state.dates.set(pane, 2 * i + 11);
      await r.advance(tickMs);
      dropped ||= r.state.logs.some((line) => line.includes("dropped"));
    }
    expect(r.state.sends).toHaveLength(perDeviceHourLimit);
    expect(dropped).toBe(true);
  });
});

describe("when the host is asked", () => {
  test("without a change, every 60 s, and every 15 s while a notice stands", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await r.watcher.tick();
    const first = r.state.asks;
    await r.advance(idleAskMs - tickMs);
    expect(r.state.asks).toBe(first);
    await r.advance(tickMs * 2);
    expect(r.state.asks).toBe(first + 1);

    const b = rig();
    b.state.panes[0].control = phone;
    await finishTurn(b, "permission");
    const base = b.state.asks;
    await b.advance(busyAskMs + tickMs);
    expect(b.state.asks).toBeGreaterThan(base);
  });

  test("a turn file's new date, new saved tabs or a new pane folder ask at once", async () => {
    const r = rig();
    await r.watcher.tick();
    let asks = r.state.asks;
    await r.advance(tickMs);
    expect(r.state.asks).toBe(asks);
    r.state.dates.set(pane, 5);
    await r.advance(tickMs);
    expect(r.state.asks).toBe(asks + 1);
    asks = r.state.asks;
    r.state.stamp = "2";
    await r.advance(tickMs);
    expect(r.state.asks).toBe(asks + 1);
    asks = r.state.asks;
    r.state.folder = true;
    await r.advance(tickMs);
    expect(r.state.asks).toBe(asks + 1);
  });

  test("a failed ask changes nothing, and the next one that works is read as a change", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await r.watcher.tick();
    r.state.ok = false;
    r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
    r.state.dates.set(pane, 1);
    await r.advance(tickMs * 3);
    expect(r.watcher.noticeFor(pane)).toBeUndefined();
    r.state.ok = true;
    r.state.dates.set(pane, 2);
    await r.advance(tickMs * 2);
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "done" });
  });

  test("a pane that is gone takes its notice with it, and a word the watcher doesn't know changes nothing", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r);
    expect(r.watcher.noticeFor(pane)).toBeDefined();
    r.state.panes[0] = { ...r.state.panes[0], turn: "from-the-future" };
    r.state.dates.set(pane, 9);
    await r.advance(tickMs);
    expect(r.watcher.noticeFor(pane)).toBeDefined();
    r.state.panes = [];
    r.state.dates.set(pane, 10);
    await r.advance(tickMs * 2);
    expect(r.watcher.noticeFor(pane)).toBeUndefined();
  });

  test("turning the last subscription off forgets the panes, so a later one starts from the starting point", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await r.watcher.tick();
    for (const entry of [...r.store.all()]) r.store.drop(entry);
    await r.advance(tickMs * 3);
    r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
    r.store.upsert(phone, { endpoint: "https://fcm.googleapis.com/fcm/send/new", p256dh: point, auth, switches: null }, r.now());
    await r.advance(settleMs * 3);
    expect(r.state.sends).toEqual([]);
  });
});

describe("the panes a device has open", () => {
  test("counted by socket, by session name", () => {
    const open = new OpenPanes();
    open.add(phone, `varnick-${pane}`);
    open.add(phone, `varnick-${pane}`);
    expect(open.has(phone, pane)).toBe(true);
    expect(open.has(tablet, pane)).toBe(false);
    open.remove(phone, `varnick-${pane}`);
    expect(open.has(phone, pane)).toBe(true);
    open.remove(phone, `varnick-${pane}`);
    expect(open.has(phone, pane)).toBe(false);
    open.add(phone, "not-a-session");
    expect(open.has(phone, "not-a-session")).toBe(false);
    open.remove(phone, `varnick-${other}`);
  });
});

describe("one ask for two readers", () => {
  test("callers within the moment share the ask; a failure is asked again", async () => {
    let now = 0;
    let loads = 0;
    let fail = false;
    const shared = new Shared(async () => { loads += 1; if (fail) throw new Error("x"); return loads; }, () => now, 1500);
    expect(await shared.get()).toBe(1);
    expect(await shared.get()).toBe(1);
    now = 1600;
    expect(await shared.get()).toBe(2);
    fail = true;
    now = 3200;
    await expect(shared.get()).rejects.toThrow();
    fail = false;
    expect(await shared.get()).toBe(4);
  });
});
