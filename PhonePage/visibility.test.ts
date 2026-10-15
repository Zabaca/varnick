import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Terminals, type TerminalData } from "./bridge";
import type { Config, Device } from "./checks";
import { OpenPanes } from "./pushwatch";
import { Relay } from "./relay";
import { PROTOCOL as V } from "./fixtures/protocol";

// The terminal's socket says whether its page is visible (page/session.js): Android keeps a hidden app's socket for over a minute, and a pane
// nobody is looking at is not open on the phone, or a push for what happened in it is held back (pushwatch.ts, OpenPane).

const folder = mkdtempSync(join(tmpdir(), "visibility-"));
afterAll(() => rmSync(folder, { recursive: true, force: true }));
const pane = "7c0e1f3a-5b2d-4c9e-8a11-3d4f5a6b7c8d";
const device: Device = { id: "11111111-1111-4111-8111-111111111111", node: "n", name: "Phone" };

function rig() {
  // A relay that stays up and prints nothing: the attach never completes, which is all these messages need.
  const script = join(folder, "relay.sh");
  writeFileSync(script, "#!/bin/sh\nsleep 30\n", { mode: 0o755 });
  const config = { mode: "loopback", loopbackPort: 0, port: 8444, relay: script, devices: "/dev/null", tailscale: "tailscale" } as unknown as Config;
  const panes = new OpenPanes();
  const terminals = new Terminals(config, new Relay(config, V, folder), V, folder, () => {}, panes);
  const data = terminals.admit(device)!;
  const ws = { data, send: () => 0, close: () => {}, readyState: 1 } as unknown as Bun.ServerWebSocket<TerminalData>;
  const handlers = terminals.handlers();
  const send = (message: unknown) => handlers.message!(ws, typeof message === "string" ? message : JSON.stringify(message));
  return { panes, handlers, ws, send, data };
}

describe("a terminal socket's page says whether it is visible", () => {
  test("the pane is open while the page is visible, not while it is hidden, and again when it shows", () => {
    const r = rig();
    r.handlers.open!(r.ws);
    r.send({ session: `varnick-${pane}`, cols: 80, rows: 24, take: false });
    expect(r.panes.has(device.id, pane)).toBe(true);
    r.send({ t: "visibility", visible: false });
    expect(r.panes.has(device.id, pane)).toBe(false);
    r.send({ t: "visibility", visible: true });
    expect(r.panes.has(device.id, pane)).toBe(true);
    r.send({ t: "visibility", visible: false });
    r.handlers.close!(r.ws, 1006, "");
    expect(r.panes.has(device.id, pane)).toBe(false);
    r.data.process?.kill();
  });

  test("a message that isn't a visibility change, or comes before the socket is open, changes nothing", () => {
    const r = rig();
    r.handlers.open!(r.ws);
    r.send({ session: `varnick-${pane}`, cols: 80, rows: 24, take: false });
    r.send({ t: "visibility", visible: "no" });
    r.send("not json");
    expect(r.panes.has(device.id, pane)).toBe(true);
    r.handlers.close!(r.ws, 1000, "");
    r.data.process?.kill();
  });

  test("the socket closing ends it whatever its page last said", () => {
    const r = rig();
    r.handlers.open!(r.ws);
    r.send({ session: `varnick-${pane}`, cols: 80, rows: 24, take: false });
    r.handlers.close!(r.ws, 1006, "");
    expect(r.panes.has(device.id, pane)).toBe(false);
    r.send({ t: "visibility", visible: true });
    expect(r.panes.has(device.id, pane)).toBe(false);
    r.data.process?.kill();
  });
});

describe("the page announces it", () => {
  const session = new URL("./page/session.js", import.meta.url);

  test("on hiding and showing, on leaving, and from a socket that opens while hidden", async () => {
    const source = await Bun.file(session).text();
    expect(source).toContain('send(s, { t: "visibility", visible: visible() })');
    expect(source).toContain('window.addEventListener("pagehide"');
    expect(source).toContain("if (!visible()) announceVisibility(s);");
    // announceVisibility runs before the handler closes the live screen's channel, on every change.
    const handler = source.slice(source.indexOf('document.addEventListener("visibilitychange"'));
    expect(handler.indexOf("announceVisibility(s);")).toBeGreaterThan(-1);
    expect(handler.indexOf("announceVisibility(s);")).toBeLessThan(handler.indexOf("pauseWatch(s);"));
  });
});
