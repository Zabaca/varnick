import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { workerSource } from "./webapp";

const template = readFileSync(new URL("./page/sw.js", import.meta.url), "utf8");
const tab = "eeeeeeee-0000-4000-8000-000000000000";
const pane = "ffffffff-0000-4000-8000-000000000000";

interface Shown { title: string; options: { body: string; tag: string; renotify: boolean; icon: string; data: { tab: string | null; pane: string | null } } }

/** The worker as a browser loads it, with the push events it registers kept, the network as given and the notifications it shows recorded. */
function load(host: string, network: (url: string, init: { signal: AbortSignal }) => Promise<unknown>, windows: Array<{ url: string; focus?: () => Promise<void>; postMessage: (message: unknown) => void }> = []) {
  const handlers: Record<string, (event: any) => void> = {};
  const shown: Shown[] = [];
  const opened: string[] = [];
  const self = {
    addEventListener: (type: string, handler: (event: any) => void) => { handlers[type] = handler; },
    skipWaiting: () => {},
    location: { origin: "https://host.example.test:8444" },
    registration: { showNotification: async (title: string, options: Shown["options"]) => { shown.push({ title, options }); } },
    clients: { claim: async () => {}, matchAll: async () => windows, openWindow: async (url: string) => { opened.push(url); } },
  };
  new Function("self", "fetch", workerSource(template, host))(self, network);
  return { handlers, shown, opened };
}

/** Delivers a push and waits for the notification: `data` is what the push service carried, decrypted. */
async function push(world: ReturnType<typeof load>, data: unknown | "unreadable" | null) {
  let work: Promise<unknown> = Promise.resolve();
  world.handlers.push({
    data: data === null ? null : { json: () => { if (data === "unreadable") throw new SyntaxError("x"); return data; } },
    waitUntil: (promise: Promise<unknown>) => { work = promise; },
  });
  await work;
}

const titled = (title: string, status = 200) => async () => new Response(JSON.stringify({ ok: true, host: "Studio", tab: { panes: [{ id: pane, title }, { id: "other", title: "Not this" }] } }), { status });
const unreachable = async () => { throw new TypeError("Failed to fetch"); };

describe("a push, with the host on the tailnet", () => {
  test("is the session's title and what happened, with the host", async () => {
    const cases: Array<[Record<string, unknown>, string]> = [
      [{ kind: "permission" }, "Needs permission · Mac Studio"],
      [{ kind: "question" }, "Has a question · Mac Studio"],
      [{ kind: "plan" }, "Plan to approve · Mac Studio"],
      [{ kind: "input" }, "Waiting on an MCP server · Mac Studio"],
      [{ kind: "done" }, "Done · Mac Studio"],
      [{ kind: "failed", failure: "rate limit" }, "Stopped on an error: rate limit · Mac Studio"],
      [{ kind: "failed" }, "Stopped on an error: API error · Mac Studio"],
    ];
    for (const [payload, body] of cases) {
      const world = load("Mac Studio", titled("Fix the parser"));
      await push(world, { v: 1, tab, pane, ...payload });
      expect(world.shown).toHaveLength(1);
      expect(world.shown[0].title).toBe("Fix the parser");
      expect(world.shown[0].options.body).toBe(body);
    }
  });

  test("asks for the tab by its id, within three seconds", async () => {
    let asked = "";
    let signal: AbortSignal | undefined;
    const world = load("Mac Studio", async (url, init) => { asked = url; signal = init.signal; return titled("x")(); });
    await push(world, { v: 1, tab, pane, kind: "done" });
    expect(asked).toBe(`/api/tab?tab=${tab}`);
    expect(signal).toBeDefined();
  });

  test("is one notification per pane: its tag is the pane, and a newer one alerts again", async () => {
    const world = load("Mac Studio", titled("x"));
    await push(world, { v: 1, tab, pane, kind: "done" });
    expect(world.shown[0].options.tag).toBe(pane);
    expect(world.shown[0].options.renotify).toBe(true);
    expect(world.shown[0].options.data).toEqual({ tab, pane });
  });
});

describe("a push, with the host out of reach", () => {
  const cases: Array<[Record<string, unknown>, string]> = [
    [{ kind: "permission" }, "A session needs permission"],
    [{ kind: "question" }, "A session has a question"],
    [{ kind: "plan" }, "A session has a plan to approve"],
    [{ kind: "input" }, "A session is waiting on an MCP server"],
    [{ kind: "done" }, "A session is done"],
    [{ kind: "failed", failure: "overloaded" }, "A session stopped on an error: overloaded"],
  ];

  test("names only the host, whichever way the read fails", async () => {
    for (const network of [unreachable, titled("A secret title", 502), titled("A secret title", 403), async () => new Response("not json")]) {
      for (const [payload, body] of cases) {
        const world = load("Mac Studio", network);
        await push(world, { v: 1, tab, pane, ...payload });
        expect(world.shown[0].title).toBe("Mac Studio");
        expect(world.shown[0].options.body).toBe(body);
      }
    }
  });

  test("names only the host when the pane isn't in the tab, or has no title", async () => {
    for (const network of [titled(""), titled("   "), async () => new Response(JSON.stringify({ ok: true, tab: { panes: [] } }))]) {
      const world = load("Mac Studio", network);
      await push(world, { v: 1, tab, pane, kind: "done" });
      expect(world.shown[0].title).toBe("Mac Studio");
    }
  });

  test("gives up on a host that doesn't answer", async () => {
    const world = load("Mac Studio", (_url, init) => new Promise((_resolve, reject) => init.signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")))));
    const started = Date.now();
    await push(world, { v: 1, tab, pane, kind: "done" });
    expect(Date.now() - started).toBeGreaterThanOrEqual(2900);
    expect(world.shown[0].title).toBe("Mac Studio");
  });
});

describe("every push shows a notification", () => {
  test("one it can't read, or has no data, or a kind it doesn't know, still shows the host", async () => {
    for (const data of ["unreadable", null, { v: 2, kind: "done", tab, pane }, { v: 1, kind: "launch", tab, pane }, { v: 1, kind: "done" }, { v: 1, kind: "done", tab: "x", pane }, 7, "text"]) {
      const world = load("Mac Studio", unreachable);
      await push(world, data as never);
      expect(world.shown).toHaveLength(1);
      expect(world.shown[0].title).toBe("Mac Studio");
      expect(world.shown[0].options.body).toBe("A session needs a look");
    }
  });

  test("a test says so, with nothing to read from the host", async () => {
    let asked = 0;
    const world = load("Mac Studio", async () => { asked += 1; return titled("x")(); });
    await push(world, { v: 1, kind: "test" });
    expect(asked).toBe(0);
    expect(world.shown[0]).toMatchObject({ title: "Mac Studio", options: { body: "Notifications work" } });
  });

  test("a title or an error word from the host is text, and an odd error word is the API error", async () => {
    const world = load("Mac <b>Studio</b>", titled("<script>alert(1)</script>"));
    await push(world, { v: 1, tab, pane, kind: "failed", failure: "<img src=x>" });
    expect(world.shown[0].title).toBe("<script>alert(1)</script>");
    expect(world.shown[0].options.body).toBe("Stopped on an error: API error · Mac <b>Studio</b>");
  });
});

describe("the badge", () => {
  test("is the number of standing notifications where the browser has badges, and a push is shown without it where it hasn't", async () => {
    const badges: number[] = [];
    const handlers: Record<string, (event: any) => void> = {};
    const shown: string[] = [];
    const self = {
      addEventListener: (type: string, handler: (event: any) => void) => { handlers[type] = handler; },
      skipWaiting: () => {},
      location: { origin: "https://host.example.test:8444" },
      navigator: { setAppBadge: async (count: number) => { badges.push(count); } },
      registration: { showNotification: async (title: string) => { shown.push(title); }, getNotifications: async () => [{}, {}, {}] },
      clients: { claim: async () => {} },
    };
    new Function("self", "fetch", workerSource(template, "Mac Studio"))(self, unreachable);
    let work: Promise<unknown> = Promise.resolve();
    handlers.push({ data: { json: () => ({ v: 1, kind: "test" }) }, waitUntil: (p: Promise<unknown>) => { work = p; } });
    await work;
    expect(shown).toEqual(["Mac Studio"]);
    expect(badges).toEqual([3]);

    // A browser whose badge call throws still shows the notification.
    self.navigator.setAppBadge = async () => { throw new Error("no"); };
    handlers.push({ data: { json: () => ({ v: 1, kind: "test" }) }, waitUntil: (p: Promise<unknown>) => { work = p; } });
    await work;
    expect(shown).toHaveLength(2);
  });
});

describe("a tap", () => {
  const closed = () => { const note = { closed: false, data: { tab, pane }, close() { note.closed = true; } }; return note; };

  test("focuses the app's open window and tells it the tab and pane", async () => {
    const messages: unknown[] = [];
    let focused = false;
    const elsewhere = { url: "https://other.example.test/", postMessage: () => { throw new Error("not this window"); } };
    const world = load("Mac Studio", unreachable, [elsewhere, { url: "https://host.example.test:8444/#t=old", focus: async () => { focused = true; }, postMessage: (m) => messages.push(m) }]);
    const note = closed();
    let work: Promise<unknown> = Promise.resolve();
    world.handlers.notificationclick({ notification: note, waitUntil: (p: Promise<unknown>) => { work = p; } });
    await work;
    expect(note.closed).toBe(true);
    expect(focused).toBe(true);
    expect(messages).toEqual([{ type: "open", hash: `#t=${tab}&p=${pane}` }]);
    expect(world.opened).toEqual([]);
  });

  test("opens a window at the tab and pane when none is open", async () => {
    const world = load("Mac Studio", unreachable);
    let work: Promise<unknown> = Promise.resolve();
    world.handlers.notificationclick({ notification: closed(), waitUntil: (p: Promise<unknown>) => { work = p; } });
    await work;
    expect(world.opened).toEqual([`/#t=${tab}&p=${pane}`]);
  });

  test("a notification with no ids opens the home", async () => {
    const world = load("Mac Studio", unreachable);
    let work: Promise<unknown> = Promise.resolve();
    world.handlers.notificationclick({ notification: { close() {}, data: { tab: null, pane: null } }, waitUntil: (p: Promise<unknown>) => { work = p; } });
    await work;
    expect(world.opened).toEqual(["/"]);
  });
});
