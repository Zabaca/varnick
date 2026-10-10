import { describe, expect, test } from "bun:test";
import type { Device } from "./checks";
import { controlledText, escapeHTML, shapeHome, unlistedLines, unlistedPage } from "./home";
import { buildRequest, parseReply, relayArguments, relayEnvironment, Slots } from "./relay";
import { PROTOCOL as V } from "./fixtures/protocol";

const device: Device = { id: "5f0f3a4e-2b6e-4c0a-9d58-0a2f6f8d1c11", node: "nEXAMPLE4CNTRL", name: "Phone" };
const mac = "00000000-0000-4000-8000-000000000001";
const ok = (reply: Record<string, unknown>) => ({ ok: true as const, reply: { v: V, ok: true, ...reply } });
const host = { name: "Mac mini", headless: false };

describe("a session row", () => {
  const rows = (open: Record<string, unknown>[]) => {
    const home = shapeHome({ host, loopback: false, device, sessions: ok({ open }), recent: ok({ recent: [] }), hosts: [] });
    return (home.sessions as { rows: any[] }).rows;
  };

  test("says who is in control, and Last when no client is attached", () => {
    const [attached, detached] = rows([
      { session: "varnick-a", title: "T", folder: "/f", controlName: "Mac mini", clients: 1 },
      { session: "varnick-b", title: "T", folder: "/f", controlName: "Alex’s MacBook Pro", clients: 0 },
    ]);
    expect(attached.text).toBe("Controlled on Mac mini");
    expect(detached.text).toBe("Last controlled on Alex’s MacBook Pro");
    expect(attached.mine).toBe(false);
  });

  test("says this phone when the label is the device's own id, whatever its case", () => {
    const [row] = rows([{ session: "varnick-a", title: "T", folder: "/f", control: device.id.toUpperCase(), controlName: "Phone", clients: 1 }]);
    expect(row.mine).toBe(true);
    expect(row.text).toBe("Controlled on this phone");
  });

  test("never passes a controller's id on to the browser", () => {
    const home = shapeHome({
      host, loopback: false, device,
      sessions: ok({ open: [{ session: "varnick-a", title: "T", folder: "/f", control: mac, controlName: "Mac mini", clients: 1 }, { session: "varnick-b", title: "T", folder: "/f", control: device.id, clients: 0 }] }),
      recent: ok({ recent: [] }),
    });
    const json = JSON.stringify(home);
    expect(json).not.toContain(mac);
    expect(json).not.toContain(device.id);
    expect(json).not.toContain('"control"');
  });

  test("a row whose controller the host can't name still reads", () => {
    const [row] = rows([{ session: "varnick-a", title: "T", folder: "/f", clients: 1 }]);
    expect(row.text).toBe("Controlled on another device");
  });

  test("the wording is the Mac app's", () => {
    expect(controlledText("Mac mini", true)).toBe("Controlled on Mac mini");
    expect(controlledText("Mac mini", false)).toBe("Last controlled on Mac mini");
  });
});

describe("the home reply", () => {
  test("one part failing leaves the other", () => {
    const home = shapeHome({ host, loopback: true, device, sessions: { ok: false, error: "nope" }, recent: ok({ recent: [{ conversation: "c", title: "t", folder: "/f", agent: "", last: 5 }] }), hosts: [] });
    expect(home.sessions).toEqual({ error: "nope" });
    expect(home.recent).toEqual({ rows: [{ conversation: "c", title: "t", folder: "/f", agent: null, last: 5 }] });
    expect(home.loopback).toBe(true);
  });

  test("junk in a reply makes no rows", () => {
    const home = shapeHome({ host, loopback: false, device, sessions: ok({ open: "x" }), recent: ok({ recent: [1, null, "s"] }), hosts: [] });
    expect(home.sessions).toEqual({ rows: [] });
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
    const request = JSON.parse(buildRequest(V, "sessions", device.id, { by: "11111111-1111-4111-8111-111111111111", op: "rows" }));
    expect(request).toEqual({ v: V, op: "sessions", by: device.id });
  });

  test("a hello carries no by", () => {
    expect(JSON.parse(buildRequest(V, "hello", null, { by: mac, from: { id: mac } }))).toEqual({ v: V, op: "hello", from: { id: mac } });
  });

  test("the request is one base64 argument of an argument list", () => {
    const request = buildRequest(V, "sessions", device.id);
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
