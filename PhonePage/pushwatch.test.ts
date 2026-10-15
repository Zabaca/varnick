import { describe, expect, test } from "bun:test";
import { busyAskMs, idleAskMs, OpenPanes, perDeviceHourLimit, PushWatcher, Shared, tickMs, type PushWorld } from "./pushwatch";
import { defaultSwitches, seenAfterMs, doneSettleMs, urgentSettleMs, type PresenceReport, type PushPayload } from "./pushrule";
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

/** `said` is a message the pane holds, recorded at `at` (ms on the fake clock). */
interface FakeSaid { title: string; body?: string; at: number }
interface FakePane { id: string; turn?: string; control?: string | null; clients?: number; failure?: string; esc?: boolean; running?: boolean; kind?: string; keepBegan?: boolean; said?: FakeSaid | null }

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
    /** Every call of `presenceMarker`, in order. */
    marker: [] as boolean[],
    /** How long after an ask starts the relay runs, in ms. */
    latency: 0,
    /** The newest turn-file date each ask said its answer must know of, and something that happens while an ask runs (a hook writing a turn file). */
    notBefore: [] as number[],
    duringAsk: null as (() => void) | null,
    /** While set, a send waits for it (a retry waiting out a Retry-After). */
    hold: null as Promise<void> | null,
  };
  const world: PushWorld = {
    now: () => now,
    ownID: own,
    askTabs: async (notBefore) => {
      state.asks += 1;
      state.notBefore.push(notBefore);
      const startedAt = now;
      // The relay runs after the ask starts, and its answer may be the shared one: a host's age is counted when it runs.
      const ran = now + state.latency;
      now = ran;
      if (!state.ok) return { result: { ok: false as const, error: "down" }, startedAt };
      // A host's age is how long ago the turn began: a new word begins a turn, unless the test says the turn is the same (an error that follows its waiting).
      const panes = state.panes.map((p) => {
        const known = state.began.get(p.id);
        if (!known || (known.word !== p.turn && !p.keepBegan)) state.began.set(p.id, { word: p.turn ?? "", at: ran });
        else state.began.set(p.id, { word: p.turn ?? "", at: known.at });
        const { keepBegan: _, said, ...rest } = p;
        const saidField = said ? { said: { title: said.title, ...(said.body ? { body: said.body } : {}), age: Math.max(0, Math.floor((ran - said.at) / 1000)) } } : {};
        return { kind: "claude", running: true, ...rest, ...saidField, turnAge: Math.floor((ran - state.began.get(p.id)!.at) / 1000) };
      });
      const answer = { result: { ok: true as const, reply: { tabs: [{ tab, panes }] } }, startedAt };
      // What happens after the relay has read the files and before the answer is back.
      state.duringAsk?.();
      return answer;
    },
    turnDates: (ids) => new Map(ids.map((id) => [id, state.dates.get(id) ?? 0])),
    newPaneFolder: () => { const seen = state.folder; state.folder = false; return seen; },
    tabsStamp: () => state.stamp,
    devices: () => state.listed,
    presence: (id) => state.presence.get(id) ?? null,
    presenceMarker: (on) => { state.marker.push(on); },
    hasPaneOpen: (device, id) => state.open.has(`${device}:${id}`),
    send: async (subscription: Subscription, payload) => {
      state.sends.push({ device: subscription.device, payload });
      if (state.hold) await state.hold;
      return state.result;
    },
    log: (line) => state.logs.push(line),
  };
  const watcher = new PushWatcher(world, store);
  const advance = async (ms: number) => {
    // The server ticks every 2 s.
    for (let left = ms; left > 0; left -= tickMs) {
      now += Math.min(tickMs, left);
      await watcher.tick();
      // A send runs off the tick; unless a test holds it, it is over by the next one.
      if (!state.hold) await watcher.settled();
    }
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
      await r.advance(doneSettleMs * 3);
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
    await r.advance(doneSettleMs - tickMs * 2);
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
    await r.advance(doneSettleMs + tickMs);
    expect(r.state.sends.at(-1)!.payload).toEqual({ v: 1, kind: "question", tab, pane });

    const e = rig();
    e.state.panes[0].control = phone;
    await finishTurn(e, "failed", { failure: "rate_limit" });
    await e.advance(doneSettleMs + tickMs);
    expect(e.state.sends.at(-1)!.payload).toEqual({ v: 1, kind: "failed", tab, pane, failure: "rate limit" });
  });

  test("each kind has its own settle: Needs you and an error after about 2 s, a Done after about 10", async () => {
    for (const [word, extra, kind, settle] of [
      ["question", {}, "question", urgentSettleMs],
      ["permission", {}, "permission", urgentSettleMs],
      ["plan", {}, "plan", urgentSettleMs],
      ["input", {}, "input", urgentSettleMs],
      ["failed", { failure: "rate_limit" }, "failed", urgentSettleMs],
      ["waiting", {}, "done", doneSettleMs],
    ] as const) {
      const r = rig();
      r.state.panes[0].control = phone;
      await finishTurn(r, word, extra);
      // Not before the settle, whatever the kind.
      await r.advance(settle - tickMs * 2);
      expect(r.state.sends).toEqual([]);
      // Pushed once soon after it.
      await r.advance(tickMs * 4);
      expect(r.state.sends.map((s) => s.payload.kind)).toEqual([kind]);
      await r.advance(doneSettleMs * 3);
      expect(r.state.sends).toHaveLength(1);
    }
  });

  test("a question is not held to the Done's 10 s, and a Done is not pushed at the question's 2 s", async () => {
    const q = rig();
    q.state.panes[0].control = phone;
    await finishTurn(q, "question");
    await q.advance(urgentSettleMs + tickMs * 2);
    expect(q.state.sends).toHaveLength(1);

    const d = rig();
    d.state.panes[0].control = phone;
    await finishTurn(d);
    await d.advance(urgentSettleMs + tickMs * 2);
    expect(d.state.sends).toEqual([]);
  });

  test("the second read still holds a Needs-you push back: a dialog answered during the read isn't pushed", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r, "question");
    // The user answers, but no turn file changed (its date is the same), so only the read after the settle can find out.
    const asks = r.state.asks;
    r.state.panes[0] = { ...r.state.panes[0], turn: "working" };
    await r.advance(urgentSettleMs + tickMs * 4);
    expect(r.state.asks).toBeGreaterThan(asks);
    expect(r.state.sends).toEqual([]);
    expect(r.watcher.noticeFor(pane)).toBeUndefined();
  });

  test("a Needs-you push is read again after its 2 s settle", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r, "question");
    const asks = r.state.asks;
    await r.advance(urgentSettleMs + tickMs);
    expect(r.state.asks).toBeGreaterThan(asks);
    expect(r.state.sends).toHaveLength(1);
  });

  test("an error from a host that says no kind has none in the payload", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r, "failed");
    await r.advance(doneSettleMs + tickMs);
    expect(r.state.sends.at(-1)!.payload).toEqual({ v: 1, kind: "failed", tab, pane });
  });

  test("answering the dialog before the settle pushes nothing", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r, "permission");
    r.state.panes[0] = { ...r.state.panes[0], turn: "working" };
    r.state.dates.set(pane, 2);
    await r.advance(doneSettleMs * 3);
    expect(r.state.sends).toEqual([]);
    expect(r.watcher.noticeFor(pane)).toBeUndefined();
  });

  test("Esc raises nothing", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r, "waiting", { esc: true });
    await r.advance(doneSettleMs * 2);
    expect(r.state.sends).toEqual([]);
  });

  test("a Done that the read after the settle finds was background work isn't pushed", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r);
    // The turn file said waiting, and the transcript now says work goes on.
    const asks = r.state.asks;
    r.state.panes[0] = { ...r.state.panes[0], turn: "background" };
    await r.advance(doneSettleMs * 2);
    expect(r.state.sends).toEqual([]);
    expect(r.state.asks).toBeGreaterThan(asks);
  });

  test("waiting and then failed in the same turn is an error, and the Done never goes", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r);
    r.state.panes[0] = { ...r.state.panes[0], turn: "failed", failure: "overloaded", keepBegan: true };
    await r.advance(doneSettleMs + tickMs * 2);
    expect(r.state.sends.map((s) => s.payload)).toEqual([{ v: 1, kind: "failed", tab, pane, failure: "overloaded" }]);
  });

  test("a notice is read again before it goes: a fresh ask follows the settle", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r);
    const asks = r.state.asks;
    await r.advance(doneSettleMs + tickMs);
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
    await none.advance(doneSettleMs + tickMs * 2);
    expect(none.state.sends).toHaveLength(1);

    const stale = rig();
    stale.present(own, { at: Math.floor(stale.now() / 1000) - 60 });
    await finishTurn(stale);
    await stale.advance(doneSettleMs + tickMs * 2);
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
    await r.advance(doneSettleMs + tickMs * 2);
    expect(r.state.sends.map((s) => s.device)).toEqual([tablet]);
  });

  test("closing the pane afterwards doesn't push a notice the device was there for", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    r.state.open.add(`${phone}:${pane}`);
    await finishTurn(r);
    await r.advance(doneSettleMs + tickMs * 2);
    r.state.open.clear();
    await r.advance(doneSettleMs * 3);
    expect(r.state.sends).toEqual([]);
  });

  test("each switch is its own, and an error is not Done", async () => {
    for (const [word, extra, off] of [
      ["permission", {}, "needsMe"], ["waiting", {}, "done"], ["failed", { failure: "rate_limit" }, "errors"],
    ] as const) {
      const r = rig({ subscribed: [{ device: phone, switches: { [off]: false } }] });
      r.state.panes[0].control = phone;
      await finishTurn(r, word, extra);
      await r.advance(doneSettleMs * 2);
      expect(r.state.sends).toEqual([]);
    }
    const r = rig({ subscribed: [{ device: phone, switches: { done: false } }] });
    r.state.panes[0].control = phone;
    await finishTurn(r, "permission");
    await r.advance(doneSettleMs * 2);
    expect(r.state.sends).toHaveLength(1);
  });

  test("a device the host no longer lists loses its subscription, and gets nothing", async () => {
    const r = rig({ listed: [tablet] });
    r.state.panes[0].control = phone;
    await finishTurn(r);
    await r.advance(doneSettleMs * 2);
    expect(r.state.sends).toEqual([]);
    expect(r.store.all()).toEqual([]);
  });

  test("a notice for one pane replaces the last, and another pane is its own", async () => {
    const r = rig();
    r.state.panes = [{ id: pane, turn: "working", control: phone, clients: 1 }, { id: other, turn: "working", control: phone, clients: 1 }];
    await r.watcher.tick();
    r.state.panes = r.state.panes.map((p) => ({ ...p, turn: "permission" }));
    r.state.dates.set(pane, 1);
    await r.advance(doneSettleMs + tickMs * 3);
    expect(r.state.sends.map((s) => s.payload.kind)).toEqual(["permission", "permission"]);
    expect(new Set(r.state.sends.map((s) => (s.payload as { pane: string }).pane))).toEqual(new Set([pane, other]));
  });
});

describe("a notice the Mac has already shown the user", () => {
  /** A Mac's report with its lists, as its Varnick writes them. */
  const report = (r: ReturnType<typeof rig>, id: string, notices: string[], onScreen: string[], extra: Partial<PresenceReport> = {}) =>
    r.keep(id, { notices, onScreen, ...extra });

  /** Done is raised, and the Mac raises its own notice a second later. */
  async function macHoldsNotice(r: ReturnType<typeof rig>, id: string) {
    report(r, id, [], []);
    await r.watcher.tick();
    r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
    r.state.dates.set(pane, 1);
    await r.advance(tickMs);
    for (let i = 0; i < 2; i += 1) { report(r, id, [pane], []); await r.advance(tickMs); }
  }

  test("seen at the Mac, then the user locks and leaves: nothing goes to the phone", async () => {
    const r = rig();
    await macHoldsNotice(r, own);
    // The user opens the pane: the Mac's notice goes and the pane is on screen.
    report(r, own, [], [pane]);
    await r.advance(tickMs);
    for (let i = 0; i < 20; i += 1) { report(r, own, [], [pane], { away: true }); await r.advance(tickMs); }
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "done" });
    expect(r.state.sends).toEqual([]);
  });

  test("the Mac's notice gone without the pane on screen (cleared by the user in another way) is seen too", async () => {
    const r = rig();
    await macHoldsNotice(r, own);
    report(r, own, [], []);
    await r.advance(tickMs);
    for (let i = 0; i < 20; i += 1) { report(r, own, [], [], { away: true }); await r.advance(tickMs); }
    expect(r.state.sends).toEqual([]);
  });

  test("a notice the Mac still holds when it turns away is pushed", async () => {
    const r = rig();
    await macHoldsNotice(r, own);
    for (let i = 0; i < 12; i += 1) { report(r, own, [pane], []); await r.advance(tickMs); }
    expect(r.state.sends).toEqual([]);
    report(r, own, [pane], [], { away: true });
    await r.advance(tickMs * 3);
    expect(r.state.sends.map((s) => s.payload.kind)).toEqual(["done"]);
  });

  test("a Mac that never held the notice (its switch is off) is no evidence: leaving pushes it", async () => {
    const r = rig();
    report(r, own, [], []);
    await r.watcher.tick();
    r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
    r.state.dates.set(pane, 1);
    await r.advance(tickMs);
    for (let i = 0; i < 4; i += 1) { report(r, own, [], []); await r.advance(tickMs); }
    for (let i = 0; i < 8; i += 1) { report(r, own, [], [], { away: true }); await r.advance(tickMs); }
    expect(r.state.sends.map((s) => s.payload.kind)).toEqual(["done"]);
  });

  test("the pane on the screen of a Mac that is away isn't looked at: it is pushed", async () => {
    const r = rig();
    report(r, own, [], [], { away: true });
    await r.watcher.tick();
    r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
    r.state.dates.set(pane, 1);
    for (let i = 0; i < 8; i += 1) { report(r, own, [], [pane], { away: true }); await r.advance(tickMs); }
    expect(r.state.sends.map((s) => s.payload.kind)).toEqual(["done"]);
  });

  test("a peer Mac in control is told the same way, by its own report", async () => {
    const r = rig();
    r.state.panes[0].control = mac;
    await macHoldsNotice(r, mac);
    report(r, mac, [], [pane]);
    await r.advance(tickMs);
    for (let i = 0; i < 20; i += 1) { report(r, mac, [], [pane], { away: true }); await r.advance(tickMs); }
    expect(r.state.sends).toEqual([]);
  });

  test("a device in control has no Mac to ask", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    report(r, own, [], [pane]);
    await finishTurn(r);
    await r.advance(doneSettleMs + tickMs * 2);
    expect(r.state.sends).toHaveLength(1);
  });
});

describe("a send is off the tick", () => {
  test("a push waiting out a retry stalls nothing: the host is still asked, and the next pane's push goes", async () => {
    const r = rig();
    let release!: () => void;
    r.state.hold = new Promise<void>((resolve) => { release = resolve; });
    r.state.panes = [{ id: pane, turn: "working", control: phone, clients: 1 }, { id: other, turn: "working", control: phone, clients: 1 }];
    await r.watcher.tick();
    r.state.panes = [{ id: pane, turn: "permission", control: phone, clients: 1 }, { id: other, turn: "working", control: phone, clients: 1 }];
    r.state.dates.set(pane, 1);
    await r.advance(doneSettleMs + tickMs * 2);
    expect(r.state.sends).toHaveLength(1);
    // The first is still in flight; a second pane's notice is raised and pushed meanwhile.
    const asks = r.state.asks;
    r.state.panes = [{ id: pane, turn: "permission", control: phone, clients: 1 }, { id: other, turn: "question", control: phone, clients: 1 }];
    r.state.dates.set(other, 1);
    await r.advance(doneSettleMs + tickMs * 3);
    expect(r.state.asks).toBeGreaterThan(asks);
    expect(r.state.sends.map((s) => (s.payload as { pane: string }).pane)).toEqual([pane, other]);
    expect(r.state.logs.filter((line) => line.startsWith("push ") && line.endsWith("201"))).toEqual([]);
    release();
    r.state.hold = null;
    await r.watcher.settled();
    expect(r.state.logs.filter((line) => line.endsWith("sent 201"))).toEqual(["push Phone permission sent 201", "push Phone question sent 201"]);
  });
});

describe("a turn that is over before it is seen", () => {
  test("a turn shorter than the cadence: waiting again with a later start is a Done", async () => {
    const r = rig();
    r.state.panes[0] = { id: pane, turn: "waiting", control: phone, clients: 1 };
    await r.watcher.tick();
    expect(r.watcher.noticeFor(pane)).toBeUndefined();
    await r.advance(idleAskMs - tickMs * 3);
    // A turn ran and ended since the last look, and no look saw it working: the word is the same, its start is not.
    r.state.began.set(pane, { word: "waiting", at: r.now() - 3000 });
    await r.advance(tickMs * 4);
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "done" });
    expect(r.state.logs.some((line) => line.startsWith("push watch: a turn ran between two looks"))).toBe(true);
    await r.advance(doneSettleMs + tickMs * 2);
    expect(r.state.sends.map((s) => s.payload.kind)).toEqual(["done"]);
  });

  test("the same turn read again is not another: its start only wobbles by whole seconds and the relay's run", async () => {
    const r = rig();
    r.state.panes[0] = { id: pane, turn: "waiting", control: phone, clients: 1 };
    r.state.latency = 900;
    await r.watcher.tick();
    for (let ask = 0; ask < 8; ask += 1) {
      r.state.latency = ask % 2 === 0 ? 1400 : 100;
      await r.advance(idleAskMs);
    }
    expect(r.state.asks).toBeGreaterThan(5);
    expect(r.watcher.noticeFor(pane)).toBeUndefined();
    expect(r.state.sends).toEqual([]);
  });

  test("a dialog that was raised and answered between two looks is a Needs me when the next one is read", async () => {
    const r = rig();
    r.state.panes[0] = { id: pane, turn: "permission", control: phone, clients: 1 };
    await r.watcher.tick();
    await r.advance(idleAskMs - tickMs * 3);
    r.state.began.set(pane, { word: "permission", at: r.now() - 3000 });
    await r.advance(tickMs * 4);
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "needs", turn: "permission" });
  });

  test("a turn file written while the host is being asked is a change the next look sees", async () => {
    const r = rig();
    r.state.panes[0] = { id: pane, turn: "working", control: phone, clients: 1 };
    await r.watcher.tick();
    // The prompt is sent: the turn file changes and the host is asked. While its relay runs the turn ends and the hook writes "waiting":
    // the answer says working, and a date read after the answer would call that handled.
    r.state.dates.set(pane, 1);
    r.state.duringAsk = () => {
      r.state.duringAsk = null;
      r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
      r.state.dates.set(pane, 2);
    };
    await r.advance(tickMs);
    expect(r.watcher.noticeFor(pane)).toBeUndefined();
    await r.advance(tickMs);
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "done" });
  });

  test("an answer must know of the newest turn file write: the ask says which, so a shared answer from before it is not used", async () => {
    const r = rig();
    await r.watcher.tick();
    expect(r.state.notBefore.at(-1)).toBe(0);
    // A turn file written: the ask that follows must be answered by a relay that ran after the write.
    r.state.dates.set(pane, 1_700_000_123_456);
    await r.advance(tickMs);
    expect(r.state.notBefore.at(-1)).toBe(1_700_000_123_456);
    // And an ask that nothing in the files caused names the newest date the watcher knows.
    r.state.stamp = "2";
    await r.advance(tickMs);
    expect(r.state.notBefore.at(-1)).toBe(1_700_000_123_456);
  });
});

describe("work that goes on in the background", () => {
  test("a turn that ends with background work is silent while it runs, and says so in the log; when it drains the Done comes", async () => {
    const r = rig();
    r.state.panes[0] = { id: pane, turn: "working", control: phone, clients: 1 };
    await r.watcher.tick();
    r.state.panes[0] = { ...r.state.panes[0], turn: "background" };
    r.state.dates.set(pane, 1);
    await r.advance(doneSettleMs * 3);
    expect(r.watcher.noticeFor(pane)).toBeUndefined();
    expect(r.state.sends).toEqual([]);
    expect(r.state.logs.filter((line) => line.startsWith("push watch tick")).at(-1)).toBe("push watch tick panes=1 working=0 waiting=0 background=1 notices=0");
    r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
    await r.advance(idleAskMs + busyAskMs);
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "done" });
    expect(r.state.sends.map((s) => s.payload.kind)).toEqual(["done"]);
  });
});

describe("what the watcher says about itself", () => {
  const mine = (r: ReturnType<typeof rig>) => r.state.logs.filter((line) => line.startsWith("push watch"));

  test("it says how many subscriptions it watches, at the start and when the number changes", async () => {
    const r = rig({ subscribed: [{ device: phone }, { device: tablet }] });
    await r.watcher.tick();
    expect(r.state.logs[0]).toBe("push watching 2 subscriptions");
    await r.advance(tickMs * 3);
    expect(r.state.logs.filter((line) => line.startsWith("push watching"))).toHaveLength(1);
    for (const entry of [...r.store.all()]) r.store.drop(entry);
    await r.advance(tickMs);
    expect(r.state.logs.at(-1)).toBe("push watching 0 subscriptions");
  });

  test("a tick line gives the counts, once a minute when nothing changes and at once when something does", async () => {
    const r = rig();
    r.state.panes = [{ id: pane, turn: "working", control: phone, clients: 1 }, { id: other, turn: "waiting", control: phone, clients: 1 }];
    await r.advance(tickMs * 3);
    expect(mine(r).filter((line) => line.startsWith("push watch tick"))).toEqual(["push watch tick panes=2 working=1 waiting=1 background=0 notices=0"]);
    await r.advance(idleAskMs * 3 - tickMs * 3);
    expect(mine(r).filter((line) => line.startsWith("push watch tick"))).toHaveLength(3);
    r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
    r.state.dates.set(pane, 1);
    await r.advance(tickMs);
    expect(mine(r).at(-1)).toContain("working=0 waiting=2 background=0 notices=1");
  });

  test("a host that can't be asked is said once, and again when it says something else", async () => {
    const r = rig();
    r.state.ok = false;
    for (let i = 0; i < 4; i += 1) { r.state.stamp = `s${i}`; await r.advance(tickMs); }
    expect(mine(r).filter((line) => line.includes("can't read"))).toEqual(["push watch can't read the host's tabs: down"]);
    r.state.ok = true;
    await r.advance(tickMs * 2);
    r.state.ok = false;
    r.state.stamp = "again";
    await r.advance(tickMs);
    expect(mine(r).filter((line) => line.includes("can't read"))).toHaveLength(2);
  });

  test("no line names a pane, a tab, a device id or an endpoint", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r);
    await r.advance(doneSettleMs * 2);
    const text = r.state.logs.join("\n");
    for (const secret of [pane, tab, own, phone, "fcm.googleapis"]) expect(text).not.toContain(secret);
  });
});

describe("how often the host is asked once everything is pushed", () => {
  test("a Done pushed to every subscription drops back to the idle cadence", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r);
    await r.advance(doneSettleMs + tickMs * 2);
    expect(r.state.sends).toHaveLength(1);
    const asks = r.state.asks;
    await r.advance(idleAskMs - tickMs * 3);
    expect(r.state.asks).toBe(asks);
    await r.advance(tickMs * 4);
    expect(r.state.asks).toBe(asks + 1);
  });

  test("a notice with a subscription still waiting keeps the busy cadence", async () => {
    const r = rig({ subscribed: [{ device: phone }, { device: tablet, switches: { done: true } }] });
    r.state.panes[0].control = tablet;
    r.state.open.add(`${phone}:${pane}`);
    // Pushed to the tablet and dropped for the phone: every subscription is handled.
    await finishTurn(r);
    await r.advance(doneSettleMs + tickMs * 2);
    const settled = r.state.asks;
    await r.advance(idleAskMs - tickMs * 3);
    expect(r.state.asks).toBe(settled);

    // A Mac that is present holds the notice for a subscription that may yet need it.
    const waiting = rig();
    waiting.keep(own);
    await waiting.watcher.tick();
    waiting.state.panes[0] = { ...waiting.state.panes[0], turn: "waiting" };
    waiting.state.dates.set(pane, 1);
    await waiting.advance(tickMs);
    const before = waiting.state.asks;
    for (let i = 0; i < 12; i += 1) { waiting.keep(own); await waiting.advance(tickMs); }
    expect(waiting.state.asks).toBeGreaterThan(before);
  });
});

describe("an error that follows its waiting is the same turn however slow the ask", () => {
  test("a relay that runs a second and a half after its ask began, over a 1.5 s old shared answer", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    r.state.latency = 0;
    await finishTurn(r);
    r.state.latency = 1900;
    r.state.panes[0] = { ...r.state.panes[0], turn: "failed", failure: "rate_limit", keepBegan: true };
    await r.advance(doneSettleMs + tickMs * 4);
    expect(r.state.sends.map((s) => s.payload)).toEqual([{ v: 1, kind: "failed", tab, pane, failure: "rate limit" }]);
  });
});

describe("what the push service says", () => {
  test("gone drops the subscription; a failure is kept and not repeated for the notice", async () => {
    const gone = rig();
    gone.state.panes[0].control = phone;
    gone.state.result = { outcome: "gone", status: 410 };
    await finishTurn(gone);
    await gone.advance(doneSettleMs + tickMs * 2);
    expect(gone.store.all()).toEqual([]);

    const failed = rig();
    failed.state.panes[0].control = phone;
    failed.state.result = { outcome: "failed", status: 403 };
    await finishTurn(failed);
    await failed.advance(doneSettleMs * 6);
    expect(failed.state.sends).toHaveLength(1);
    expect(failed.store.all()[0].lastFailure).toBeDefined();
  });

  test("the log holds the device's name, the kind and the status, never an endpoint or an id of a pane", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r);
    await r.advance(doneSettleMs + tickMs * 2);
    expect(r.state.logs.filter((line) => line.endsWith("sent 201"))).toEqual(["push Phone done sent 201"]);
  });

  test("60 pushes to a device an hour, then they are dropped", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await r.watcher.tick();
    let dropped = false;
    for (let i = 0; i < perDeviceHourLimit + 5; i += 1) {
      r.state.panes[0] = { ...r.state.panes[0], turn: "permission" };
      r.state.dates.set(pane, 2 * i + 10);
      await r.advance(doneSettleMs + tickMs * 3);
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
    await r.advance(doneSettleMs * 3);
    expect(r.state.sends).toEqual([]);
  });
});

describe("the panes a device has open", () => {
  test("counted by socket, by session name, for as long as a socket is there", () => {
    const open = new OpenPanes();
    const first = open.open(phone, `varnick-${pane}`)!;
    const second = open.open(phone, `varnick-${pane}`)!;
    expect(open.has(phone, pane)).toBe(true);
    expect(open.has(tablet, pane)).toBe(false);
    first.close();
    expect(open.has(phone, pane)).toBe(true);
    second.close();
    second.close();
    expect(open.has(phone, pane)).toBe(false);
    expect(open.open(phone, "not-a-session")).toBeNull();
    expect(open.has(phone, "not-a-session")).toBe(false);
  });

  test("open means visible: a socket whose page says it is hidden is not an open pane, and is again when the page shows", () => {
    const open = new OpenPanes();
    const socket = open.open(phone, `varnick-${pane}`)!;
    expect(open.has(phone, pane)).toBe(true);
    socket.setVisible(false);
    expect(open.has(phone, pane)).toBe(false);
    socket.setVisible(true);
    expect(open.has(phone, pane)).toBe(true);
  });

  test("one visible socket of two is enough, and a hidden one cannot hold the pane open", () => {
    const open = new OpenPanes();
    const hidden = open.open(phone, `varnick-${pane}`)!;
    hidden.setVisible(false);
    const live = open.open(phone, `varnick-${pane}`)!;
    expect(open.has(phone, pane)).toBe(true);
    live.close();
    expect(open.has(phone, pane)).toBe(false);
  });
});

describe("a notice the phone was and wasn't looking at", () => {
  test("the app left for the home screen the moment the turn ended: the socket is still there, the page is hidden, the push goes", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    r.state.open.add(`${phone}:${pane}`);
    await r.watcher.tick();
    r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
    r.state.dates.set(pane, 1);
    await r.advance(tickMs);
    // Under a moment later the page hides (the terminal says so); its socket stays up for another minute.
    r.state.open.delete(`${phone}:${pane}`);
    await r.advance(doneSettleMs + tickMs * 2);
    expect(r.state.sends.map((s) => s.payload.kind)).toEqual(["done"]);
  });

  test("a pane looked at long enough while the notice stands is seen, and leaving afterwards pushes nothing", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    r.state.open.add(`${phone}:${pane}`);
    await r.watcher.tick();
    r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
    r.state.dates.set(pane, 1);
    await r.advance(seenAfterMs + tickMs);
    r.state.open.delete(`${phone}:${pane}`);
    await r.advance(doneSettleMs * 3);
    expect(r.state.sends).toEqual([]);
  });

  test("a notice that stood before the pane was opened is seen by opening it", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r);
    await r.advance(tickMs);
    r.state.open.add(`${phone}:${pane}`);
    await r.advance(seenAfterMs + tickMs);
    r.state.open.delete(`${phone}:${pane}`);
    await r.advance(doneSettleMs * 3);
    expect(r.state.sends).toEqual([]);
  });

  test("a look that breaks off starts over: two glances are not a view, and the push goes once the pane is left", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r);
    for (let glance = 0; glance < 3; glance += 1) {
      r.state.open.add(`${phone}:${pane}`);
      await r.advance(tickMs);
      r.state.open.delete(`${phone}:${pane}`);
      await r.advance(tickMs);
    }
    await r.advance(doneSettleMs);
    expect(r.state.sends.map((s) => s.payload.kind)).toEqual(["done"]);
  });

  test("a pane that stays open and visible while the notice stands never sends, and the page showing again later changes nothing", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    r.state.open.add(`${phone}:${pane}`);
    await r.watcher.tick();
    r.state.panes[0] = { ...r.state.panes[0], turn: "permission" };
    r.state.dates.set(pane, 1);
    await r.advance(doneSettleMs * 3);
    expect(r.state.sends).toEqual([]);
    r.state.open.delete(`${phone}:${pane}`);
    await r.advance(doneSettleMs);
    r.state.open.add(`${phone}:${pane}`);
    await r.advance(doneSettleMs);
    expect(r.state.sends).toEqual([]);
  });

  test("each device is its own: the tablet that was looking, and the phone that left", async () => {
    const r = rig({ subscribed: [{ device: phone }, { device: tablet }] });
    r.state.panes[0].control = phone;
    r.state.open.add(`${tablet}:${pane}`);
    await r.watcher.tick();
    r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
    r.state.dates.set(pane, 1);
    await r.advance(doneSettleMs + tickMs * 3);
    expect(r.state.sends.map((s) => s.device)).toEqual([phone]);
  });
});

describe("what the log says of each decision", () => {
  const decisions = (r: ReturnType<typeof rig>) => r.state.logs.filter((line) => line.startsWith("push decide") || line.startsWith("push notice"));

  test("a device in control: raised, waiting for the settle, pushing, sent", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r);
    await r.advance(doneSettleMs + tickMs * 2);
    expect(r.state.logs.filter((line) => /^push (notice|decide|[A-Z])/.test(line))).toEqual([
      "push notice done raised",
      "push decide done Phone -> waiting(settle) controller=device",
      "push decide done Phone -> pushing controller=device",
      "push Phone done sent 201",
    ]);
  });

  test("a present Mac, and then away: which controller and what its report said", async () => {
    const r = rig();
    r.keep(own);
    await r.watcher.tick();
    r.state.panes[0] = { ...r.state.panes[0], turn: "waiting" };
    r.state.dates.set(pane, 1);
    for (let i = 0; i < 10; i += 1) { r.keep(own); await r.advance(tickMs); }
    r.keep(own, { away: true });
    await r.advance(tickMs * 3);
    expect(decisions(r)).toEqual([
      "push notice done raised",
      "push decide done Phone -> waiting(settle) controller=host presence=present",
      "push decide done Phone -> waiting(present) controller=host presence=present",
      "push decide done Phone -> pushing controller=host presence=away",
    ]);
  });

  test("a Mac that can't be told, and a peer whose client is detached", async () => {
    const none = rig();
    await finishTurn(none);
    await none.advance(doneSettleMs + tickMs * 2);
    expect(decisions(none)).toContain("push decide done Phone -> pushing controller=host presence=unknown");

    const detached = rig();
    detached.state.panes[0].control = mac;
    detached.state.panes[0].clients = 0;
    detached.keep(mac);
    await finishTurn(detached);
    for (let i = 0; i < 8; i += 1) { detached.keep(mac); await detached.advance(tickMs); }
    expect(decisions(detached)).toContain("push decide done Phone -> pushing controller=mac-detached presence=present");
  });

  test("suppressed by the pane being open, by the switch and by the Mac having shown it", async () => {
    const open = rig();
    open.state.panes[0].control = phone;
    open.state.open.add(`${phone}:${pane}`);
    await open.watcher.tick();
    open.state.panes[0] = { ...open.state.panes[0], turn: "waiting" };
    open.state.dates.set(pane, 1);
    await open.advance(doneSettleMs);
    expect(decisions(open)).toEqual([
      "push notice done raised",
      "push decide done Phone -> waiting(viewing) controller=device",
      "push decide done Phone -> suppressed(open-pane) controller=device",
    ]);

    const off = rig({ subscribed: [{ device: phone, switches: { done: false } }] });
    off.state.panes[0].control = phone;
    await finishTurn(off);
    expect(decisions(off)).toContain("push decide done Phone -> suppressed(switch) controller=device");

    const shown = rig();
    shown.keep(own, { notices: [], onScreen: [] });
    await shown.watcher.tick();
    shown.state.panes[0] = { ...shown.state.panes[0], turn: "waiting" };
    shown.state.dates.set(pane, 1);
    await shown.advance(tickMs);
    shown.keep(own, { notices: [pane], onScreen: [] });
    await shown.advance(tickMs);
    shown.keep(own, { notices: [], onScreen: [pane] });
    await shown.advance(tickMs);
    expect(decisions(shown).at(-1)).toBe("push decide done Phone -> suppressed(seen-on-mac) controller=host presence=present");
  });

  test("nothing in a line names a pane, a tab, a title or an endpoint", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r);
    await r.advance(doneSettleMs + tickMs * 2);
    const text = r.state.logs.join("\n");
    for (const secret of [pane, tab, own, phone, "fcm.googleapis"]) expect(text).not.toContain(secret);
  });

  test("a cleared notice says so", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await finishTurn(r, "permission");
    r.state.panes[0] = { ...r.state.panes[0], turn: "working" };
    r.state.dates.set(pane, 2);
    await r.advance(tickMs);
    expect(decisions(r)).toContain("push notice permission cleared");
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

  test("an answer whose ask began before a change the caller needs to know of is not shared", async () => {
    let now = 1000;
    let loads = 0;
    const shared = new Shared(async () => { loads += 1; return loads; }, () => now, 1500);
    expect((await shared.stamped()).value).toBe(1);
    now = 1200;
    expect((await shared.stamped(900)).value).toBe(1);
    expect((await shared.stamped(1000)).value).toBe(1);
    expect(await shared.stamped(1100)).toEqual({ value: 2, startedAt: 1200 });
    expect((await shared.stamped(1200)).value).toBe(2);
  });

  test("the answer says when its ask began, also to a caller that shares an earlier one", async () => {
    let now = 1000;
    const shared = new Shared(async () => "answer", () => now, 1500);
    expect(await shared.stamped()).toEqual({ value: "answer", startedAt: 1000 });
    now = 2000;
    expect(await shared.stamped()).toEqual({ value: "answer", startedAt: 1000 });
    now = 2600;
    expect(await shared.stamped()).toEqual({ value: "answer", startedAt: 2600 });
  });
});

// ---------------------------------------------------------------------------------------------------------------
// A message the session sent itself (option 04 of phone-page-is-only-a-browser-tab)

describe("a message the session sent itself", () => {
  let writes = 0;
  /** The first reading is taken (the starting point), then a hook records a message: the file's date moves, and the next look asks. */
  async function start(r: ReturnType<typeof rig>) {
    await r.watcher.tick();
  }
  async function say(r: ReturnType<typeof rig>, title = "Tests passed: 214", body?: string, index = 0) {
    r.state.panes[index] = { ...r.state.panes[index], said: { title, body, at: r.now() } };
    r.state.dates.set(r.state.panes[index].id, (writes += 1));
    await r.advance(tickMs);
  }
  const kinds = (r: ReturnType<typeof rig>) => r.state.sends.map((s) => s.payload.kind);

  test("the first message read for a pane is a starting point: a message already there at a start raises nothing", async () => {
    const r = rig();
    r.state.panes[0] = { ...r.state.panes[0], control: phone, said: { title: "Old news", at: r.now() - 5000 } };
    await r.advance(doneSettleMs * 3);
    expect(r.state.sends).toEqual([]);
    expect(r.watcher.noticeFor(pane)).toBeUndefined();
  });

  test("a message is Said, pushed after the 2 s settle with the ids and the kind and no words, once", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await start(r);
    await say(r, "Tests passed: 214", "all green");
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "said" });
    expect(r.state.sends).toEqual([]);
    await r.advance(tickMs);
    expect(r.state.sends).toEqual([{ device: phone, payload: { v: 1, kind: "message", tab, pane } }]);
    expect(JSON.stringify(r.state.sends)).not.toContain("Tests passed");
    expect(JSON.stringify(r.state.sends)).not.toContain("green");
    await r.advance(doneSettleMs * 3);
    expect(r.state.sends).toHaveLength(1);
  });

  test("it is held to the Needs-you settle, not the Done's 10 s", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await start(r);
    await say(r);
    await r.advance(urgentSettleMs + tickMs);
    expect(kinds(r)).toEqual(["message"]);
    expect(urgentSettleMs).toBeLessThan(doneSettleMs);
  });

  test("a hook writing the message file is a change that asks the host at once, without waiting for the cadence", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await start(r);
    const asks = r.state.asks;
    await say(r);
    expect(r.state.asks).toBe(asks + 1);
  });

  test("answering with a prompt before the push goes pushes nothing: the read after the settle finds the message gone", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await start(r);
    await say(r);
    // The prompt hook removed the file and wrote the turn file (a new date), 1 s later; the working turn is nothing to say.
    r.state.panes[0] = { ...r.state.panes[0], said: null, turn: "working" };
    r.state.dates.set(pane, (writes += 1));
    await r.advance(urgentSettleMs * 3);
    expect(r.state.sends).toEqual([]);
    expect(r.watcher.noticeFor(pane)).toBeUndefined();
    expect(r.state.logs).toContain("push notice message cleared");
  });

  test("a message gone with no other change (a /clear) clears the notice too, once the host is asked", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await start(r);
    await say(r);
    r.state.panes[0] = { ...r.state.panes[0], said: null };
    await r.advance(busyAskMs + tickMs);
    expect(r.watcher.noticeFor(pane)).toBeUndefined();
    expect(r.state.sends).toEqual([]);
  });

  test("a Done that follows a message is folded into it: one push for the two, not a Done after the message", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await start(r);
    await say(r);
    await finishTurn(r);
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "said" });
    await r.advance(doneSettleMs * 4);
    expect(kinds(r)).toEqual(["message"]);
  });

  test("a Done folded into a message that stands for a long turn is still folded: the fold has no time limit", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    r.state.panes[0].said = null;
    await start(r);
    await say(r);
    await r.advance(urgentSettleMs * 3);
    expect(kinds(r)).toEqual(["message"]);
    // The turn runs on for twenty minutes, then ends.
    await r.advance(20 * 60_000);
    await finishTurn(r);
    await r.advance(doneSettleMs * 3);
    expect(kinds(r)).toEqual(["message"]);
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "said" });
  });

  test("the turn going to work or background, or a dialog answered, leaves the message standing", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    r.state.panes[0].turn = "waiting";
    await start(r);
    await say(r);
    r.state.panes[0] = { ...r.state.panes[0], turn: "working" };
    r.state.dates.set(pane, (writes += 1));
    await r.advance(tickMs);
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "said" });
    r.state.panes[0] = { ...r.state.panes[0], turn: "background" };
    r.state.dates.set(pane, (writes += 1));
    await r.advance(tickMs);
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "said" });
  });

  test("Needs you replaces a message, and an error does", async () => {
    for (const [word, extra, kind] of [["permission", {}, "permission"], ["failed", { failure: "rate_limit" }, "failed"]] as const) {
      const r = rig();
      r.state.panes[0].control = phone;
      await start(r);
      await say(r);
      r.state.panes[0] = { ...r.state.panes[0], turn: word, ...extra };
      r.state.dates.set(pane, (writes += 1));
      await r.advance(tickMs);
      expect(r.watcher.noticeFor(pane)?.kind).toBe(kind === "failed" ? "failed" : "needs");
      await r.advance(doneSettleMs * 2);
      // The message was replaced before it was pushed, so only the dialog or the error goes.
      expect(kinds(r)).toEqual([kind]);
    }
  });

  test("a message after a Done replaces it", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await start(r);
    await finishTurn(r);
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "done" });
    await say(r);
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "said" });
    await r.advance(doneSettleMs * 3);
    expect(kinds(r)).toEqual(["message"]);
  });

  test("an error in the same turn after a message and a Done takes over the message, not a Done's wait", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await start(r);
    await say(r);
    await finishTurn(r);
    r.state.panes[0] = { ...r.state.panes[0], turn: "failed", failure: "overloaded", keepBegan: true };
    r.state.dates.set(pane, (writes += 1));
    await r.advance(tickMs);
    expect(r.watcher.noticeFor(pane)?.kind).toBe("failed");
  });

  test("at most one push a minute for a pane: five in a row give one, then one at the minute's end for the newest", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await start(r);
    for (let n = 1; n <= 5; n += 1) {
      await say(r, `Message ${n}`);
      await r.advance(tickMs * 2);
    }
    // The first went after its settle; the rest are replacing it quietly.
    expect(kinds(r)).toEqual(["message"]);
    // Said once for each message held back (the second to the fifth), not at every tick.
    expect(r.state.logs.filter((line) => line === "push message held back: one a minute for a pane")).toHaveLength(4);
    // The five took about 30 s, the first push went in the first few: the minute ends about 64 s in.
    await r.advance(24_000);
    expect(kinds(r)).toEqual(["message"]);
    await r.advance(10_000);
    expect(kinds(r)).toEqual(["message", "message"]);
    // And the newest message is the one that stands, so the worker reads its words.
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "said" });
    await r.advance(doneSettleMs * 6);
    expect(kinds(r)).toEqual(["message", "message"]);
  });

  test("the second push comes a minute after the first, not a minute after the message", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await start(r);
    await say(r);
    await r.advance(tickMs);
    expect(kinds(r)).toEqual(["message"]);
    const first = r.now();
    await r.advance(30_000);
    await say(r, "Later");
    await r.advance(tickMs * 2);
    expect(kinds(r)).toEqual(["message"]);
    while (r.now() - first < 58_000) await r.advance(tickMs);
    expect(kinds(r)).toEqual(["message"]);
    while (r.now() - first < 64_000) await r.advance(tickMs);
    expect(kinds(r)).toEqual(["message", "message"]);
  });

  test("a message replaced by one that is then answered before the minute is up is not pushed again", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await start(r);
    await say(r);
    await r.advance(tickMs);
    await say(r, "Second");
    r.state.panes[0] = { ...r.state.panes[0], said: null, turn: "working" };
    r.state.dates.set(pane, (writes += 1));
    await r.advance(120_000);
    expect(kinds(r)).toEqual(["message"]);
  });

  test("a message gap is for messages: a Needs-you right after one is pushed at its own settle", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await start(r);
    await say(r);
    await r.advance(tickMs);
    r.state.panes[0] = { ...r.state.panes[0], turn: "permission" };
    r.state.dates.set(pane, (writes += 1));
    await r.advance(tickMs * 3);
    expect(kinds(r)).toEqual(["message", "permission"]);
  });

  test("the Messages switch is its own: off gives no push, and the other switches don't decide a message", async () => {
    const off = rig({ subscribed: [{ device: phone, switches: { messages: false } }] });
    off.state.panes[0].control = phone;
    await start(off);
    await say(off);
    await off.advance(doneSettleMs * 2);
    expect(off.state.sends).toEqual([]);
    expect(off.state.logs).toContain("push decide message Phone -> suppressed(switch) controller=device");

    const others = rig({ subscribed: [{ device: phone, switches: { needsMe: false, done: false, errors: false } }] });
    others.state.panes[0].control = phone;
    await start(others);
    await say(others);
    await others.advance(urgentSettleMs * 2);
    expect(kinds(others)).toEqual(["message"]);
  });

  test("a Mac whose user is at it is not pushed to; one that turns away with the message standing is", async () => {
    const r = rig();
    r.keep(own);
    await r.watcher.tick();
    await say(r);
    for (let i = 0; i < 12; i += 1) { r.keep(own); await r.advance(tickMs); }
    expect(r.state.sends).toEqual([]);
    expect(r.watcher.noticeFor(pane)).toEqual({ kind: "said" });
    r.keep(own, { away: true });
    await r.advance(tickMs * 3);
    expect(kinds(r)).toEqual(["message"]);
  });

  test("a message the Mac showed the user is not pushed when they lock it and leave", async () => {
    const r = rig();
    r.keep(own, { notices: [], onScreen: [] });
    await r.watcher.tick();
    await say(r);
    // The Mac raises its own notice, then the user opens the pane.
    r.keep(own, { notices: [pane], onScreen: [] });
    await r.advance(tickMs);
    r.keep(own, { notices: [], onScreen: [pane] });
    await r.advance(tickMs);
    for (let i = 0; i < 20; i += 1) { r.keep(own, { notices: [], onScreen: [pane], away: true }); await r.advance(tickMs); }
    expect(r.state.sends).toEqual([]);
  });

  test("a device that has the pane open gets no message push", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    r.state.open.add(`${phone}:${pane}`);
    await start(r);
    await say(r);
    await r.advance(doneSettleMs);
    expect(r.state.sends).toEqual([]);
  });

  test("a host before protocol 28 says no message, and a message field that isn't one is none", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await start(r);
    r.state.panes[0] = { ...r.state.panes[0], said: undefined };
    await r.advance(doneSettleMs * 2);
    expect(r.state.sends).toEqual([]);
    expect(r.watcher.noticeFor(pane)).toBeUndefined();
  });

  test("a pane that is gone takes its message with it, and its next message is a starting point again", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await start(r);
    await say(r);
    const gone = r.state.panes[0];
    r.state.panes = [];
    r.state.stamp = "2";
    await r.advance(tickMs);
    expect(r.watcher.noticeFor(pane)).toBeUndefined();
    r.state.panes = [{ ...gone, said: { title: "Back", at: r.now() - 1000 } }];
    r.state.stamp = "3";
    await r.advance(doneSettleMs * 3);
    expect(r.state.sends).toEqual([]);
  });

  test("the log names the kind and the device, never the words", async () => {
    const r = rig();
    r.state.panes[0].control = phone;
    await start(r);
    await say(r, "Secret title", "Secret body");
    await r.advance(urgentSettleMs * 2);
    const text = r.state.logs.join("\n");
    expect(text).toContain("push notice message raised");
    expect(text).toContain("push decide message Phone -> pushing controller=device");
    expect(text).toContain("push Phone message sent 201");
    for (const secret of ["Secret", pane, tab]) expect(text).not.toContain(secret);
  });
});

describe("Claude Code's presence marker follows the subscriptions", () => {
  test("it is asked for as long as there is one, and asked to go when the last is removed", async () => {
    const r = rig();
    await r.watcher.tick();
    expect(r.state.marker.at(-1)).toBe(true);
    r.store.remove(phone, r.store.all()[0].endpoint);
    await r.watcher.tick();
    expect(r.state.marker.at(-1)).toBe(false);
  });

  test("a host with no subscription never asks for it", async () => {
    const r = rig({ subscribed: [] });
    await r.advance(10_000);
    expect(r.state.marker.every((on) => on === false)).toBe(true);
  });

  test("a device the host no longer lists takes its subscription, and the marker with it", async () => {
    const r = rig({ listed: [tablet] });
    await r.watcher.tick();
    expect(r.state.marker.at(-1)).toBe(false);
  });
});
