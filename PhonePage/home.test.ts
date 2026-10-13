import { describe, expect, test } from "bun:test";
import type { Device } from "./checks";
import { controlledText, escapeHTML, shapeHome, shapePane, unlistedLines, unlistedPage } from "./home";
import { buildRequest, parseReply, relayArguments, relayEnvironment, Slots } from "./relay";
import { PROTOCOL as V } from "./fixtures/protocol";

const device: Device = { id: "5f0f3a4e-2b6e-4c0a-9d58-0a2f6f8d1c11", node: "nEXAMPLE4CNTRL", name: "Phone" };
const mac = "00000000-0000-4000-8000-000000000001";
const ok = (reply: Record<string, unknown>) => ({ ok: true as const, reply: { v: V, ok: true, ...reply } });
const host = { name: "Mac mini", headless: false };
const tabA = "aaaaaaaa-0000-4000-8000-00000000000a";
const tabB = "bbbbbbbb-0000-4000-8000-00000000000b";
const conversationA = "cccccccc-0000-4000-8000-00000000000c";
const conversationB = "dddddddd-0000-4000-8000-00000000000d";

/** A listed pane of a Claude session or a terminal, with what the relay leaves on it for this device. */
const pane = (id: string, fields: Record<string, unknown> = {}) => ({ id, kind: "claude", title: "T", folder: "/f", running: true, ...fields });
const paneA = "aaaaaaaa-0000-4000-8000-0000000000a1";
const paneB = "bbbbbbbb-0000-4000-8000-0000000000b1";
const paneC = "cccccccc-0000-4000-8000-0000000000c1";

describe("the proxied address of a pane", () => {
  const device = { id: "5f0f3a4e-2b6e-4c0a-9d58-0a2f6f8d1c11", node: "n", name: "Phone" };
  const shape = (fields: Record<string, unknown>) => shapePane({ id: "aaaaaaaa-0000-4000-8000-0000000000a1", kind: "app", ...fields }, device)!;

  test("an https address the host sent is kept, and the reason it has none", () => {
    expect(shape({ proxy: "https://mac-mini.example.ts.net:5173/x" })).toMatchObject({ proxy: "https://mac-mini.example.ts.net:5173/x", proxyNote: null });
    expect(shape({ proxyNote: "Its server isn't answering on that machine yet." })).toMatchObject({ proxy: null, proxyNote: "Its server isn't answering on that machine yet." });
  });

  test("an address that isn't https is not one the page frames", () => {
    for (const bad of ["http://mac-mini.example.ts.net:5173/", "javascript:alert(1)", "data:text/html,x", "nonsense", 5, null]) expect(shape({ proxy: bad }).proxy).toBeNull();
  });
});

describe("a pane", () => {
  const rows = (panes: Record<string, unknown>[], control: Record<string, unknown> = {}) => {
    const home = shapeHome({ host, loopback: false, device, tabs: ok({ tabs: [{ tab: tabA, panes, ...control }] }), recent: ok({ recent: [] }), hosts: [] });
    return (home.tabs as { rows: any[] }).rows.flatMap((tab) => tab.panes);
  };

  test("says who is in control, and Last when no client is attached", () => {
    const [attached, detached] = rows([
      pane(paneA, { controlName: "Mac mini", clients: 1 }),
      pane(paneB, { controlName: "Alex’s MacBook Pro", clients: 0 }),
    ]);
    expect(attached.text).toBe("Controlled on Mac mini");
    expect(detached.text).toBe("Last controlled on Alex’s MacBook Pro");
    expect(attached.mine).toBe(false);
  });

  test("says this phone when the label is the device's own id, whatever its case", () => {
    const [row] = rows([pane(paneA, { control: device.id.toUpperCase(), controlName: "Phone", clients: 1 })]);
    expect(row.mine).toBe(true);
    expect(row.text).toBe("Controlled on this phone");
  });

  test("never passes a controller's id on to the browser", () => {
    const home = shapeHome({
      host, loopback: false, device,
      tabs: ok({ tabs: [{ tab: tabA, control: mac, controlName: "Mac mini", clients: 1, panes: [pane(paneA, { control: mac, controlName: "Mac mini", clients: 1 }), pane(paneB, { control: device.id, clients: 0 })] }] }),
      recent: ok({ recent: [] }),
    });
    const json = JSON.stringify(home);
    expect(json).not.toContain(mac);
    expect(json).not.toContain(device.id);
    expect(json).not.toContain('"control"');
  });

  test("a controller the host can't name still reads", () => {
    const [row] = rows([pane(paneA, { clients: 1 })]);
    expect(row.text).toBe("Controlled on another device");
  });

  test("a Claude or terminal pane has its zmx session's name, the other kinds none, and the id of a pane is a uuid or none", () => {
    const listed = rows([
      pane(paneA), pane(paneB, { kind: "terminal" }), pane(paneC, { kind: "web", url: "https://example.com/", running: undefined }),
      { id: "not an id", kind: "claude" },
    ]);
    expect(listed.map((row) => [row.kind, row.session])).toEqual([
      ["claude", `varnick-${paneA}`], ["terminal", `varnick-${paneB}`], ["web", null],
    ]);
    expect(listed[2]).toMatchObject({ url: "https://example.com/", running: false, text: "" });
  });

  test("a pane that doesn't run says nothing of control", () => {
    const [row] = rows([pane(paneA, { running: false, controlName: "Mac mini", clients: 1 }), pane(paneB)]);
    expect([row.running, row.text, row.mine]).toEqual([false, "", false]);
  });

  test("the wording is the Mac app's", () => {
    expect(controlledText("Mac mini", true)).toBe("Controlled on Mac mini");
    expect(controlledText("Mac mini", false)).toBe("Last controlled on Mac mini");
  });
});

describe("tabs", () => {
  const tabs = (list: Record<string, unknown>[]) => {
    const home = shapeHome({ host, loopback: false, device, tabs: ok({ tabs: list }), recent: ok({ recent: [] }), hosts: [] });
    return (home.tabs as { rows: any[] }).rows;
  };

  test("a tab is a row with its panes in the host's order, named by its own name", () => {
    const rows = tabs([
      { tab: tabA.toUpperCase(), name: "Work", panes: [pane(paneA, { title: "A" }), pane(paneB, { kind: "terminal", title: "B" })] },
      { tab: tabB, panes: [pane(paneC, { title: "C" })] },
    ]);
    expect(rows.map((tab) => [tab.tab, tab.name, tab.panes.map((p: any) => p.title)])).toEqual([[tabA, "Work", ["A", "B"]], [tabB, null, ["C"]]]);
  });

  test("the tab's control is the host's word for it: this phone, or somebody else, or none when nothing runs", () => {
    const [mine, other, idle] = tabs([
      { tab: tabA, control: device.id, controlName: "Phone", clients: 1, panes: [pane(paneA, { control: device.id })] },
      { tab: tabB, controlName: "Mac mini", clients: 0, panes: [pane(paneA)] },
      { tab: "dddddddd-0000-4000-8000-00000000000d", panes: [pane(paneA, { kind: "file", file: "/f/x.md", running: undefined })] },
    ]);
    expect([mine.mine, mine.text]).toEqual([true, "Controlled on this phone"]);
    expect([other.mine, other.text]).toEqual([false, "Last controlled on Mac mini"]);
    expect([idle.mine, idle.text]).toEqual([false, ""]);
  });

  test("a tab with no id or no pane makes no row, and neither does one that is only Claude and terminal panes that don't run", () => {
    const rows = tabs([
      { tab: "x", panes: [pane(paneA)] },
      { tab: tabA, panes: [] },
      { tab: tabB, panes: [pane(paneA, { running: false }), pane(paneB, { kind: "terminal", running: false })] },
      { tab: "dddddddd-0000-4000-8000-00000000000d", panes: [pane(paneA, { running: false }), pane(paneB, { kind: "web", url: "http://localhost:3000" })] },
    ]);
    expect(rows.map((tab) => tab.tab)).toEqual(["dddddddd-0000-4000-8000-00000000000d"]);
  });
});

describe("Recent as closed tabs", () => {
  const recent = (rows: unknown[]) => (shapeHome({ host, loopback: false, device, tabs: ok({ tabs: [] }), recent: ok({ recent: rows }), hosts: [] }).recent as { rows: any[] }).rows;
  const session = (conversation: string, title: string) => ({ conversation, title, folder: "/f" });

  test("a tab is its sessions, named by its own name or its first session's title", () => {
    const [named, plain] = recent([
      { tab: tabA, name: "Release", last: 9, sessions: [session(conversationA, "one"), session(conversationB, "two")] },
      { tab: tabB, last: 3, sessions: [session(conversationB, "two")] },
    ]);
    expect([named.title, named.sessions.length, named.last]).toEqual(["Release", 2, 9]);
    expect(plain.title).toBe("two");
  });

  test("a tab with no id or no usable session makes no row, and a bad session is dropped", () => {
    const rows = recent([
      { tab: "x", sessions: [session(conversationA, "a")] },
      { tab: tabA, sessions: [] },
      { tab: tabB, sessions: [session("not a conversation", "a"), session(conversationA, "ok")] },
    ]);
    expect(rows.map((row) => [row.tab, row.sessions.map((s: any) => s.conversation)])).toEqual([[tabB, [conversationA]]]);
  });
});

describe("the home reply", () => {
  test("one part failing leaves the other", () => {
    const closed = { tab: tabA, last: 5, sessions: [{ conversation: conversationA, title: "t", folder: "/f", agent: "" }] };
    const home = shapeHome({ host, loopback: true, device, tabs: { ok: false, error: "nope" }, recent: ok({ recent: [closed] }), hosts: [] });
    expect(home.tabs).toEqual({ error: "nope" });
    expect(home.recent).toEqual({ rows: [{ tab: tabA, title: "t", last: 5, sessions: [{ conversation: conversationA, title: "t", folder: "/f", agent: null }] }] });
    expect(home.loopback).toBe(true);
  });

  test("junk in a reply makes no rows", () => {
    const home = shapeHome({ host, loopback: false, device, tabs: ok({ tabs: "x" }), recent: ok({ recent: [1, null, "s"] }), hosts: [] });
    expect(home.tabs).toEqual({ rows: [] });
    expect(home.recent).toEqual({ rows: [] });
  });
});

describe("the page an unlisted caller gets", () => {
  test("on a Mac it says where in Varnick to add the device", () => {
    expect(unlistedLines({ reason: "not-listed", label: "phone-1" }, host)).toEqual([
      "phone-1 can't use Mac mini's phone page.",
      "Add it in Varnick › Settings › Peers › Devices on Mac mini.",
    ]);
  });

  test("on a headless host it gives the hand command", () => {
    const lines = unlistedLines({ reason: "not-listed", label: "phone-1" }, { name: "linux box", headless: true });
    expect(lines[1]).toBe("Add it on linux box with <code>varnick-peer device add phone-1</code>.");
  });

  test("on a headless host it gives the hand command even when the node's name isn't known", () => {
    const lines = unlistedLines({ reason: "not-listed", label: null }, { name: "linux box", headless: true });
    expect(lines.join(" ")).toContain("varnick-peer device add &lt;its name&gt;");
    expect(lines.join(" ")).not.toContain("Settings");
  });

  test("a node that can't be listed isn't told to add it", () => {
    expect(unlistedLines({ reason: "not-own", label: "tagged-server" }, host).join(" ")).not.toContain("Add it");
  });

  test("names are escaped", () => {
    const page = unlistedPage({ reason: "not-listed", label: null }, { name: "<script>alert(1)</script>", headless: false }, true);
    expect(page).not.toContain("<script>");
    expect(page).toContain("&lt;script&gt;");
    expect(page).toContain("Loopback mode");
    expect(escapeHTML(`a&b"c'd`)).toBe("a&amp;b&quot;c&#39;d");
  });
});

describe("the slots", () => {
  test("one key can't take every slot", () => {
    const slots = new Slots(3, 2);
    expect(slots.acquire("a")).toBe(true);
    expect(slots.acquire("a")).toBe(true);
    expect(slots.acquire("a")).toBe(false);
    expect(slots.acquire("b")).toBe(true);
    expect(slots.acquire("c")).toBe(false);
  });

  test("a released slot can be taken again, and a release without a take changes nothing", () => {
    const slots = new Slots(1, 1);
    slots.release("a");
    expect(slots.acquire("a")).toBe(true);
    expect(slots.acquire("b")).toBe(false);
    slots.release("a");
    expect(slots.acquire("b")).toBe(true);
  });
});

describe("the relay", () => {
  test("by is the server's alone: a client's by is dropped", () => {
    const request = JSON.parse(buildRequest(V, "tabs", device.id, { by: "11111111-1111-4111-8111-111111111111", op: "rows" }));
    expect(request).toEqual({ v: V, op: "tabs", by: device.id });
  });

  test("a hello carries no by", () => {
    expect(JSON.parse(buildRequest(V, "hello", null, { by: mac, from: { id: mac } }))).toEqual({ v: V, op: "hello", from: { id: mac } });
  });

  test("the request is one base64 argument of an argument list", () => {
    const request = buildRequest(V, "tabs", device.id);
    const args = relayArguments("/opt/varnick-peer", request);
    expect(args).toHaveLength(3);
    expect(args.slice(0, 2)).toEqual(["/opt/varnick-peer", "--peer"]);
    expect(Buffer.from(args[2], "base64").toString("utf8")).toBe(request);
  });

  test("text a user typed stays inside the JSON", () => {
    const args = relayArguments("/r", buildRequest(V, "start", device.id, { start: { prompt: "'; rm -rf / #\n" } }));
    expect(args[2]).toMatch(/^[A-Za-z0-9+/=]+$/);
  });

  test("the relay gets a small environment, not the server's", () => {
    expect(relayEnvironment({}, "/home/u")).toEqual({ HOME: "/home/u", PATH: "/usr/bin:/bin" });
    expect(relayEnvironment({ zmxDir: "/tmp/z", userHome: "/tmp/h" }, "/home/u")).toEqual({
      HOME: "/home/u", PATH: "/usr/bin:/bin", VARNICK_ZMX_DIR: "/tmp/z", CFFIXED_USER_HOME: "/tmp/h",
    });
  });

  test("the reply is the last line that is one", () => {
    expect(parseReply('Welcome\n{"ok":true,"v":' + V + ',"open":[]}\n')).toEqual({ ok: true, v: V, open: [] });
    expect(parseReply('{"ok":false,"v":' + V + ',"error":"x"}\nnot json\n')).toEqual({ ok: false, v: V, error: "x" });
    expect(parseReply("nothing\n")).toBeNull();
    expect(parseReply('{"hello":1}')).toBeNull();
  });
});
