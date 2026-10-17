import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { checkOrigin, gateUpgrade, type Device } from "./checks";
import { buildRequest, relayEnvironment } from "./relay";
import {
  attachEnvironment, clampGrid, closeCode, decideExit, decideOpen, recheckControl, takenReason, endText, firstOutput, fitReason, isSessionName, parseClient, parseOpen, refusal,
} from "./terminal";
import { closeAction, ctrlCode, dragLines, keys, livedLongEnough, reconnectDelay, takenController } from "./page/rules.js";
import { PROTOCOL as V } from "./fixtures/protocol";

const device: Device = { id: "5f0f3a4e-2b6e-4c0a-9d58-0a2f6f8d1c11", node: "nEXAMPLE4CNTRL", name: "Phone" };
const mac = "00000000-0000-4000-8000-000000000001";
const name = "varnick-7c0e1f3a-5b2d-4c9e-8a11-3d4f5a6b7c8d";
const reply = (sessions: Record<string, unknown>) => ({ ok: true as const, reply: { v: V, ok: true, sessions } });

describe("a reconnect, from status and the device's id", () => {
  test("labelled for this device: attach without take", () => {
    // The relay tells a device only its own id, so `control` present is "mine"; the case is the relay's to compare, not the page's.
    expect(decideOpen(reply({ [name]: { running: true, clients: 0, control: device.id.toUpperCase(), controlName: "Phone" } }), name, device)).toEqual({ state: "mine", title: null });
  });

  test("labelled for anyone else, the host included: the session view, saying who", () => {
    expect(decideOpen(reply({ [name]: { running: true, clients: 1, controlName: "Mac mini" } }), name, device)).toEqual({
      state: "other", controller: "Mac mini", text: "Controlled on Mac mini", title: null,
    });
    expect(decideOpen(reply({ [name]: { running: true, clients: 0, controlName: "Alex’s MacBook Pro" } }), name, device)).toMatchObject({
      state: "other", text: "Last controlled on Alex’s MacBook Pro",
    });
  });

  test("a controller's id the relay should have hidden doesn't make the session this device's", () => {
    const opening = decideOpen(reply({ [name]: { running: true, clients: 1, control: mac, controlName: "Mac mini" } }), name, device);
    expect(opening.state).toBe("other");
    expect(JSON.stringify(opening)).not.toContain(mac);
  });

  test("a controller the host can't name still reads", () => {
    expect(decideOpen(reply({ [name]: { running: true, clients: 1 } }), name, device)).toMatchObject({ state: "other", text: "Controlled on another device" });
  });

  test("gone: not running, missing, or no sessions at all", () => {
    expect(decideOpen(reply({ [name]: { running: false } }), name, device)).toEqual({ state: "gone", text: "Session ended" });
    expect(decideOpen(reply({}), name, device).state).toBe("gone");
    expect(decideOpen({ ok: true, reply: { v: V, ok: true } }, name, device).state).toBe("gone");
  });

  test("the host not answering is neither attach nor ended", () => {
    expect(decideOpen({ ok: false, error: "The relay didn't answer in time" }, name, device)).toEqual({ state: "error", error: "The relay didn't answer in time" });
  });

  test("the title is the host's, when it said one", () => {
    expect(decideOpen(reply({ [name]: { running: true, control: device.id, title: "Fix the build" } }), name, device)).toEqual({ state: "mine", title: "Fix the build" });
  });
});

describe("what closes the websocket when the zmx client exits", () => {
  test("taken: 4001 and the controller's name", () => {
    expect(decideExit(reply({ [name]: { running: true, controlName: "Mac mini" } }), name, device)).toEqual({ code: 4001, reason: "{\"controller\":\"Mac mini\"}" });
  });

  test("ended: 4002", () => {
    expect(decideExit(reply({ [name]: { running: false } }), name, device)).toEqual({ code: 4002, reason: "Session ended" });
    expect(decideExit(reply({}), name, device).code).toBe(4002);
  });

  test("still this device's, a dropped client: 4003", () => {
    expect(decideExit(reply({ [name]: { running: true, control: device.id } }), name, device).code).toBe(4003);
  });

  test("the host can't say: 4003, and the reconnect asks again before it attaches", () => {
    expect(decideExit({ ok: false, error: "busy" }, name, device).code).toBe(4003);
  });

  test("the reason fits a close frame, whatever the name, and is still JSON the page reads", () => {
    const long = decideExit(reply({ [name]: { running: true, controlName: "あ".repeat(100) } }), name, device);
    expect(Buffer.byteLength(long.reason, "utf8")).toBeLessThanOrEqual(123);
    expect(takenController(long.reason)).toMatch(/^あ+$/);
    expect(takenController(takenReason('Mac "mini"\n'))).toBe('Mac "mini" ');
    expect(fitReason("a\r\nb\x00c")).toBe("a  b c");
  });

  test("the page takes the controller from the field, and nothing else is a controller", () => {
    expect(takenController('{"controller":"Mac mini"}')).toBe("Mac mini");
    for (const reason of ["", "Taken over on Mac mini", "{}", '{"controller":""}', '{"controller":5}', "null"]) expect(takenController(reason)).toBeNull();
  });

  test("the page reads the same codes", () => {
    expect(closeAction(closeCode.taken)).toBe("taken");
    expect(closeAction(closeCode.ended)).toBe("ended");
    expect(closeAction(closeCode.refused)).toBe("refused");
    expect(closeAction(closeCode.dropped)).toBe("reconnect");
    expect(closeAction(1006)).toBe("reconnect");
    expect(closeAction(1000)).toBe("reconnect");
  });
});

describe("the label read a second after a client attaches", () => {
  test("still this device's: nothing happens", () => {
    expect(recheckControl(reply({ [name]: { running: true, control: device.id } }), name, device)).toBeNull();
  });

  test("another Mac took the session between the relay's check and the attach: let go with 4001 and its name", () => {
    expect(recheckControl(reply({ [name]: { running: true, controlName: "Mac mini (check)" } }), name, device)).toEqual({ code: 4001, reason: '{"controller":"Mac mini (check)"}' });
  });

  test("ended: 4002", () => {
    expect(recheckControl(reply({ [name]: { running: false } }), name, device)?.code).toBe(4002);
  });

  test("the host not answering lets go of nothing", () => {
    expect(recheckControl({ ok: false, error: "The host is busy: try again" }, name, device)).toBeNull();
  });
});

describe("the first message", () => {
  test("a session, a grid, and take only when it is literally true", () => {
    expect(parseOpen(JSON.stringify({ session: name, cols: 50, rows: 30 }))).toEqual({ session: name, cols: 50, rows: 30, take: false });
    expect(parseOpen(JSON.stringify({ session: name, cols: 50, rows: 30, take: true }))!.take).toBe(true);
    for (const take of ["true", 1, "yes", null, [true]]) expect(parseOpen(JSON.stringify({ session: name, cols: 50, rows: 30, take }))!.take).toBe(false);
  });

  test("a name that isn't varnick-<uuid> is refused", () => {
    for (const session of ["phone", "varnick-", "varnick-not-a-uuid", `${name}x`, `x${name}`, `${name}\n`, "../varnick-7c0e1f3a-5b2d-4c9e-8a11-3d4f5a6b7c8d", 5, null]) {
      expect(parseOpen(JSON.stringify({ session, cols: 50, rows: 30 }))).toBeNull();
      expect(isSessionName(session)).toBe(false);
    }
    expect(isSessionName(name.toUpperCase().replace("VARNICK", "varnick"))).toBe(false);
    expect(isSessionName(name)).toBe(true);
  });

  test("not JSON, or not an object, is refused", () => {
    for (const text of ["", "nope", "[]", "null", "5", '"x"']) expect(parseOpen(text)).toBeNull();
  });

  test("an absurd grid is clamped, and a missing one defaults", () => {
    expect(clampGrid(0, 0)).toEqual({ cols: 20, rows: 5 });
    expect(clampGrid(100000, 100000)).toEqual({ cols: 400, rows: 200 });
    expect(clampGrid(-5, -5)).toEqual({ cols: 20, rows: 5 });
    expect(clampGrid(72.9, 30.2)).toEqual({ cols: 72, rows: 30 });
    expect(clampGrid("70", undefined)).toEqual({ cols: 80, rows: 24 });
    expect(clampGrid(NaN, Infinity)).toEqual({ cols: 80, rows: 24 });
  });

  test("a client's `by` has nowhere to go", () => {
    const open = parseOpen(JSON.stringify({ session: name, cols: 50, rows: 30, by: mac, op: "end" }))!;
    expect(Object.keys(open).sort()).toEqual(["cols", "rows", "session", "take"]);
    // The request is built from the open's fields and the server's device: `by` is written last.
    const request = JSON.parse(buildRequest(V, "attach", device.id, { session: open.session, by: mac }));
    expect(request.by).toBe(device.id);
    expect(request.op).toBe("attach");
  });
});

describe("what comes after it", () => {
  test("typed text, binary reports and resizes", () => {
    expect(parseClient(JSON.stringify({ t: "in", d: "ls\r" }))).toEqual({ t: "in", data: "ls\r" });
    expect(parseClient(JSON.stringify({ t: "bin", d: "\x1b[M\xff" }))).toEqual({ t: "bin", data: Buffer.from([0x1b, 0x5b, 0x4d, 0xff]) });
    expect(parseClient(JSON.stringify({ t: "resize", cols: 9999, rows: 1 }))).toEqual({ t: "resize", cols: 400, rows: 5 });
    expect(parseClient(JSON.stringify({ t: "visibility", visible: false }))).toEqual({ t: "visibility", visible: false });
    expect(parseClient(JSON.stringify({ t: "visibility", visible: true }))).toEqual({ t: "visibility", visible: true });
  });

  test("nothing else is a message", () => {
    for (const text of ["", "x", "[]", '{"t":"in"}', '{"t":"in","d":""}', '{"t":"in","d":5}', '{"t":"other"}', '{"t":"bin","d":"あ"}', '{"t":"visibility"}', '{"t":"visibility","visible":"no"}']) expect(parseClient(text)).toBeNull();
    expect(parseClient(JSON.stringify({ t: "in", d: "x".repeat((256 << 10) + 1) }))).toBeNull();
  });
});

describe("a refused attach", () => {
  const line = '{"error":"That session isn\'t controlled by the Mac that asked: take it over","ok":false,"v":' + V + '}';

  test("its reply line starts with a brace, a screen doesn't", () => {
    const bytes = (text: string) => new TextEncoder().encode(text);
    expect(firstOutput(bytes(`${line}\r\n`))).toBe("reply");
    expect(firstOutput(bytes(`\r\n  ${line}`))).toBe("reply");
    expect(firstOutput(bytes("\x1b[?1049h\x1b[2J"))).toBe("screen");
    expect(firstOutput(bytes("hello"))).toBe("screen");
    expect(firstOutput(bytes(" \r\n"))).toBe("undecided");
    expect(firstOutput(bytes(""))).toBe("undecided");
  });

  test("the held line, with its terminal's line endings, is the relay's error", () => {
    expect(refusal(`${line}\r\n`)).toBe("That session isn't controlled by the Mac that asked: take it over");
  });

  test("anything that isn't the relay's refusal stays a screen", () => {
    expect(refusal("")).toBeNull();
    expect(refusal("{ not json")).toBeNull();
    expect(refusal('{"a":1}\r\n')).toBeNull();
    expect(refusal('{"ok":true,"v":' + V + '}\r\n')).toBeNull();
    expect(refusal('{"ok":false,"v":' + V + '}\r\n')).toBe("The relay refused the attach");
  });
});

describe("End", () => {
  test("says what the host did", () => {
    expect(endText({ ok: true, v: V }, "Mac mini")).toBe("Ended");
    expect(endText({ ok: true, v: V, released: false }, "Mac mini")).toBe("Ended");
    expect(endText({ ok: true, v: V, released: true }, "Mac mini")).toBe("Handed back to Mac mini, still running");
  });
});

describe("the terminal's environment", () => {
  test("a home, a plain PATH, TERM and LANG, and the check folders; nothing else", () => {
    const env = attachEnvironment(relayEnvironment({ zmxDir: "/tmp/zmx-check", userHome: undefined }, "/home/me"), "en_US.UTF-8", "linux");
    expect(env).toEqual({ HOME: "/home/me", PATH: "/usr/bin:/bin", VARNICK_ZMX_DIR: "/tmp/zmx-check", TERM: "xterm-256color", LANG: "en_US.UTF-8" });
    expect(Object.keys(attachEnvironment({ HOME: "/h", PATH: "/usr/bin:/bin" }, undefined, "darwin")).sort()).toEqual(["HOME", "LANG", "PATH", "TERM"]);
    expect(attachEnvironment({}, undefined, "darwin").LANG).toBe("en_US.UTF-8");
    expect(attachEnvironment({}, undefined, "linux").LANG).toBe("C.UTF-8");
    expect(attachEnvironment({}, "bad lang; rm", "linux").LANG).toBe("C.UTF-8");
  });
});

describe("the websocket upgrade", () => {
  const origin = "https://mac-mini.example.ts.net:8444";
  const headers = (values: Record<string, string>) => new Headers(values);
  const upgrade = { upgrade: "websocket", origin };

  test("the page's own origin goes through", () => {
    expect(gateUpgrade("GET", headers(upgrade), origin)).toBeNull();
    expect(gateUpgrade("GET", headers({ ...upgrade, "sec-fetch-site": "same-origin" }), origin)).toBeNull();
    expect(gateUpgrade("GET", headers({ Upgrade: "WebSocket", origin }), origin)).toBeNull();
  });

  test("a foreign origin, or none, is refused before anything is spawned", () => {
    expect(gateUpgrade("GET", headers({ upgrade: "websocket", origin: "https://evil.example" }), origin)).toEqual({ status: 403, reason: "origin" });
    expect(gateUpgrade("GET", headers({ upgrade: "websocket" }), origin)).toEqual({ status: 403, reason: "origin" });
    expect(gateUpgrade("GET", headers({ upgrade: "websocket", origin: `${origin}.evil.example` }), origin)).toEqual({ status: 403, reason: "origin" });
    expect(checkOrigin("null", origin)).toBe(false);
  });

  test("a cross-site fetch is refused even with the right-looking origin", () => {
    expect(gateUpgrade("GET", headers({ ...upgrade, "sec-fetch-site": "cross-site" }), origin)).toEqual({ status: 403, reason: "cross-site" });
    expect(gateUpgrade("GET", headers({ ...upgrade, "sec-fetch-site": "same-site" }), origin)).toEqual({ status: 403, reason: "cross-site" });
  });

  test("only a GET that asks to upgrade", () => {
    expect(gateUpgrade("POST", headers(upgrade), origin)).toEqual({ status: 405, reason: "method" });
    expect(gateUpgrade("GET", headers({ origin }), origin)).toEqual({ status: 400, reason: "not an upgrade" });
  });
});

describe("the page's rules", () => {
  test("reconnects after 1, 2, 5 and 10 seconds, then every 30", () => {
    expect([0, 1, 2, 3, 4, 5, 50].map(reconnectDelay)).toEqual([1000, 2000, 5000, 10000, 30000, 30000, 30000]);
  });

  test("a connection that opened and failed at once doesn't start the tries over", () => {
    expect(livedLongEnough(300)).toBe(false);
    expect(livedLongEnough(9_999)).toBe(false);
    expect(livedLongEnough(10_000)).toBe(true);
    expect(livedLongEnough(600_000)).toBe(true);
  });

  test("the sticky Ctrl turns a letter into its control code", () => {
    expect(ctrlCode("c")).toBe("\x03");
    expect(ctrlCode("C")).toBe("\x03");
    expect(ctrlCode("[")).toBe("\x1b");
    expect(ctrlCode(" ")).toBe("\x00");
    expect(ctrlCode("1")).toBeNull();
    expect(ctrlCode("\r")).toBeNull();
    expect(ctrlCode("ab")).toBeNull();
  });

  test("a touch drag scrolls whole rows and carries the rest into the next move", () => {
    expect(dragLines(40, 16)).toEqual({ lines: 2, rest: 8 });
    expect(dragLines(-40, 16)).toEqual({ lines: -2, rest: -8 });
    expect(dragLines(10, 16)).toEqual({ lines: 0, rest: 10 });
    // Before the terminal is measured there is no row height: nothing scrolls, and nothing is carried.
    expect(dragLines(40, 0)).toEqual({ lines: 0, rest: 0 });
    expect(dragLines(40, NaN)).toEqual({ lines: 0, rest: 0 });
  });

  test("the key bar's keys", () => {
    expect(keys.esc).toBe("\x1b");
    expect(keys.enter).toBe("\r");
    expect(Object.keys(keys)).toEqual(["esc", "tab", "up", "down", "left", "right", "enter"]);
    expect(keys.up).toBe("\x1b[A");
  });
});

describe("the vendored xterm.js", () => {
  test("VERSIONS lists every file, and its digests are the files'", () => {
    const folder = new URL("./vendor/", import.meta.url);
    const lines = readFileSync(new URL("VERSIONS", folder), "utf8").split("\n").filter((line) => line.trim() !== "" && !line.startsWith("#"));
    expect(lines.length).toBe(5);
    for (const line of lines) {
      const [digest, file, pkg] = line.trim().split(/\s+/);
      expect(pkg).toMatch(/^@xterm\/[a-z-]+@[0-9]+\.[0-9]+\.[0-9]+$/);
      expect(createHash("sha256").update(readFileSync(new URL(file, folder))).digest("hex")).toBe(digest);
    }
    expect(lines.map((line) => line.trim().split(/\s+/)[1]).sort()).toEqual(["LICENSE-addon-fit", "LICENSE-xterm", "addon-fit.mjs", "xterm.css", "xterm.mjs"]);
  });
});
