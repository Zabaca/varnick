import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Terminals, type TerminalData } from "./bridge";
import type { Config } from "./checks";
import { Relay } from "./relay";
import { socketHandlers, socketOptions } from "./server";
import { sendHighWater, Watches, type WatchData } from "./watcher";
import { Outbox, WatchDecoder, longestMessage, longestScreen, pageGrid, parseWatchOpen, tooLargeMessage, watchMessage, type WatchEvent } from "./watch";
import { fitScale, gridLimits, parseFrame } from "./page/liverules.js";
import { PROTOCOL as V } from "./fixtures/protocol";

const name = "varnick-7c0e1f3a-5b2d-4c9e-8a11-3d4f5a6b7c8d";
const encoder = new TextEncoder();
const replyLine = (extra: Record<string, unknown> = {}) => `${JSON.stringify({ v: V, ok: true, ...extra })}\n`;
const frame = (cols: number, rows: number, text: string) => {
  const body = encoder.encode(text);
  return Buffer.concat([encoder.encode(`screen ${cols} ${rows} ${body.length}\n`), body]);
};
const concat = (...parts: (string | Uint8Array)[]) => Buffer.concat(parts.map((part) => (typeof part === "string" ? encoder.encode(part) : part)));

function decode(chunks: Uint8Array[]): { events: WatchEvent[]; failure: string | null } {
  const decoder = new WatchDecoder();
  const events: WatchEvent[] = [];
  for (const chunk of chunks) events.push(...decoder.feed(chunk));
  return { events, failure: decoder.failure };
}

describe("a watch's first message", () => {
  test("names a session and nothing else matters", () => {
    expect(parseWatchOpen(JSON.stringify({ session: name }))).toEqual({ session: name });
    // Nothing a watch could be told to do beyond watching is read: no take, no grid, no input.
    expect(parseWatchOpen(JSON.stringify({ session: name, take: true, cols: 80, rows: 24, by: "someone" }))).toEqual({ session: name });
  });

  test("anything else is refused", () => {
    for (const text of ["", "not json", "[]", "null", "{}", JSON.stringify({ session: "varnick-1" }), JSON.stringify({ session: `${name}; rm -rf /` }), JSON.stringify({ session: 5 })]) {
      expect(parseWatchOpen(text)).toBeNull();
    }
    expect(parseWatchOpen(JSON.stringify({ session: name, pad: "x".repeat(2000) }))).toBeNull();
  });
});

describe("the relay's watch stream", () => {
  const stream = concat(
    replyLine(),
    frame(132, 41, "first\r\nscreen"),
    "\n", // a keep-alive
    frame(132, 41, "second \u{1F600} é screen"),
    "\n\n",
    frame(0, 0, "unreadable grid"),
    frame(80, 24, ""),
  );
  const expected: WatchEvent[] = [
    { kind: "reply", reply: { v: V, ok: true } },
    { kind: "frame", cols: 132, rows: 41, text: "first\r\nscreen" },
    { kind: "frame", cols: 132, rows: 41, text: "second \u{1F600} é screen" },
    { kind: "frame", cols: 0, rows: 0, text: "unreadable grid" },
    { kind: "frame", cols: 80, rows: 24, text: "" },
  ];

  test("the reply, then each frame, drops the keep-alives", () => {
    expect(decode([stream])).toEqual({ events: expected, failure: null });
  });

  test("the same frames however the reads cut the stream: at every byte, and in two at every position", () => {
    expect(decode([...stream].map((byte) => Uint8Array.of(byte)))).toEqual({ events: expected, failure: null });
    for (let cut = 0; cut <= stream.length; cut++) {
      expect(decode([stream.subarray(0, cut), stream.subarray(cut)])).toEqual({ events: expected, failure: null });
    }
  });

  test("the caller's buffer may be reused for the next read", () => {
    const decoder = new WatchDecoder();
    const buffer = new Uint8Array(8);
    const events: WatchEvent[] = [];
    const wire = concat(replyLine(), frame(10, 5, "abcdefghijklmnop"));
    for (let offset = 0; offset < wire.length; offset += buffer.length) {
      const part = wire.subarray(offset, offset + buffer.length);
      buffer.set(part);
      events.push(...decoder.feed(buffer.subarray(0, part.length)));
      buffer.fill(0x58);
    }
    expect(events.at(-1)).toEqual({ kind: "frame", cols: 10, rows: 5, text: "abcdefghijklmnop" });
  });

  test("lines before the reply are skipped, as a greeting", () => {
    const { events, failure } = decode([concat("Welcome to the host\n", "\n", replyLine(), frame(10, 5, "x"))]);
    expect(failure).toBeNull();
    expect(events.map((event) => event.kind)).toEqual(["reply", "frame"]);
  });

  test("a screen's text may hold what looks like a header or a reply: it is body bytes", () => {
    const tricky = `screen 1 1 1\n${JSON.stringify({ v: V, ok: false })}\n`;
    const { events, failure } = decode([concat(replyLine(), frame(10, 5, tricky), frame(10, 5, "after"))]);
    expect(failure).toBeNull();
    expect(events.slice(1)).toEqual([
      { kind: "frame", cols: 10, rows: 5, text: tricky },
      { kind: "frame", cols: 10, rows: 5, text: "after" },
    ]);
  });

  test("a refusal is the reply, and nothing after it is read", () => {
    const refusal = `${JSON.stringify({ v: V, ok: false, error: "That session isn't running on Mac mini" })}\n`;
    const { events, failure } = decode([concat(refusal, frame(10, 5, "never"))]);
    expect(failure).toBeNull();
    expect(events).toEqual([{ kind: "reply", reply: { v: V, ok: false, error: "That session isn't running on Mac mini" } }]);
  });

  test("a header it can't parse ends the channel", () => {
    for (const header of ["screen 10 5\n", "screen a b c\n", "scream 10 5 3\n", "screen 10 5 3 4\n", "screen -1 5 3\n", "garbage\n", `screen 10 5 ${64 * 1024 * 1024 + 1}\n`]) {
      const { events, failure } = decode([concat(replyLine(), header, "abc")]);
      expect(failure).not.toBeNull();
      expect(events.filter((event) => event.kind === "frame")).toEqual([]);
    }
  });

  test("a header with no end, or a greeting with no reply, is bounded", () => {
    expect(decode([concat(replyLine(), "screen ".padEnd(200, "1"))]).failure).not.toBeNull();
    expect(decode([encoder.encode("x".repeat(70 << 10))]).failure).not.toBeNull();
    expect(decode([encoder.encode("not a reply\n".repeat(7000))]).failure).not.toBeNull();
  });

  test("a screen that stops short is a frame not yet whole, never a half frame", () => {
    const whole = frame(10, 5, "hello world");
    const { events, failure } = decode([concat(replyLine(), whole.subarray(0, whole.length - 3))]);
    expect(failure).toBeNull();
    expect(events.map((event) => event.kind)).toEqual(["reply"]);
  });
});

describe("a frame's grid", () => {
  test("the host's own, or 0 0 when it couldn't read it or it is past what the page draws", () => {
    expect(pageGrid(132, 41)).toEqual({ cols: 132, rows: 41 });
    expect(pageGrid(0, 0)).toEqual({ cols: 0, rows: 0 });
    expect(pageGrid(0, 24)).toEqual({ cols: 0, rows: 0 });
    expect(pageGrid(gridLimits.maxCols, gridLimits.maxRows)).toEqual({ cols: 400, rows: 200 });
    expect(pageGrid(gridLimits.maxCols + 1, 24)).toEqual({ cols: 0, rows: 0 });
    expect(pageGrid(80, gridLimits.maxRows + 1)).toEqual({ cols: 0, rows: 0 });
  });
});

describe("a screen too large to show", () => {
  test("the decoder skips its bytes, says so, and goes on with the next frame, however the reads cut it", () => {
    const wire = concat(replyLine(), frame(10, 5, "x".repeat(longestScreen + 1)), "\n", frame(10, 5, "after"));
    const expected = [{ kind: "reply", reply: { v: V, ok: true } }, { kind: "oversize" }, { kind: "frame", cols: 10, rows: 5, text: "after" }];
    expect(decode([wire])).toEqual({ events: expected, failure: null });
    const pieces: Uint8Array[] = [];
    for (let at = 0; at < wire.length; at += 100_003) pieces.push(wire.subarray(at, at + 100_003));
    expect(decode(pieces)).toEqual({ events: expected, failure: null });
  });

  test("a screen at the limit is a frame", () => {
    const { events } = decode([concat(replyLine(), frame(10, 5, "x".repeat(longestScreen)))]);
    expect(events.map((event) => event.kind)).toEqual(["reply", "frame"]);
  });

  test("a message past longestMessage is replaced by saying so: JSON writes each ESC as six bytes", () => {
    const escapes = "\u001b".repeat(longestScreen / 2);
    const message = watchMessage({ kind: "frame", cols: 10, rows: 5, text: escapes });
    expect(message).toBe(tooLargeMessage);
    expect(watchMessage({ kind: "oversize" })).toBe(tooLargeMessage);
    expect(Buffer.byteLength(watchMessage({ kind: "frame", cols: 10, rows: 5, text: "\u001b".repeat(longestMessage / 6 - 100) }))).toBeLessThanOrEqual(longestMessage);
  });

  test("the page reads it and keeps what it has drawn", () => {
    expect(parseFrame(tooLargeMessage)).toEqual({ tooLarge: true });
  });
});

describe("against a real server: an oversized frame doesn't make the socket close", () => {
  const device = { id: "5f0f3a4e-2b6e-4c0a-9d58-0a2f6f8d1c11", node: "nEXAMPLE4CNTRL", name: "Phone" };
  const folder = mkdtempSync(join(tmpdir(), "watch-test-"));
  // A relay that answers `watch` with a reply, then three screens made of escape characters (JSON writes each as six bytes), then
  // one small screen, and holds its input open as the real one does.
  const frames = [
    longestScreen / 2, // 3 MB as a message: past longestMessage
    longestScreen + 1000, // past longestScreen
    (longestMessage / 6) * 0.9, // 2.7 MB as a message: the most that is sent
  ];
  const script = join(folder, "relay.sh");
  writeFileSync(script, [
    "#!/bin/sh",
    `printf '{"ok":true,"v":${V}}\\n'`,
    ...frames.map((n) => `printf 'screen 100 50 ${Math.floor(n)}\\n'; head -c ${Math.floor(n)} /dev/zero | tr '\\0' '\\033'`),
    `printf 'screen 100 50 5\\nhello'`,
    "read _",
  ].join("\n") + "\n", { mode: 0o755 });
  const config = { mode: "loopback", loopbackPort: 0, port: 8444, relay: script, devices: "/dev/null", tailscale: "tailscale" } as unknown as Config;
  const watches = new Watches(config, V, folder, () => {});
  const terminals = new Terminals(config, new Relay(config, V, folder), V, folder, () => {});
  const server = Bun.serve<TerminalData | WatchData>({
    port: 0,
    websocket: socketHandlers(terminals, watches),
    fetch(request, serving) {
      const data = watches.admit(device);
      return data && serving.upgrade(request, { data }) ? undefined : new Response("no", { status: 400 });
    },
  });

  test("the shared options keep a longest message and what waits under the backpressure limit", () => {
    expect(longestMessage + sendHighWater).toBeLessThan(socketOptions.backpressureLimit);
    expect(socketOptions.closeOnBackpressureLimit).toBe(true);
  });

  test("the too-large ones are said so, the large one arrives whole, and the socket stays open for the next", async () => {
    const received: { length: number; tooLarge: boolean; text?: string }[] = [];
    const ws = new WebSocket(`ws://127.0.0.1:${server.port}/`);
    let closed: { code: number } | null = null;
    ws.onclose = (event) => { closed = { code: event.code }; };
    ws.onmessage = (event) => {
      const value = JSON.parse(String(event.data));
      received.push({ length: String(event.data).length, tooLarge: value.tooLarge === true, text: typeof value.text === "string" ? value.text.slice(0, 5) : undefined });
    };
    ws.onopen = () => ws.send(JSON.stringify({ session: "varnick-7c0e1f3a-5b2d-4c9e-8a11-3d4f5a6b7c8d" }));
    for (let waited = 0; waited < 8000 && !(received.length >= 4 && received.at(-1)?.text === "hello") && !closed; waited += 50) await Bun.sleep(50);
    expect(closed).toBeNull();
    expect(received.map((message) => message.tooLarge)).toEqual([true, true, false, false]);
    // The screen under the limit arrived whole: its 2.7 MB of escapes, each six bytes in JSON.
    expect(received[2].length).toBeGreaterThan(2_500_000);
    expect(received[3]).toMatchObject({ text: "hello" });
    ws.close();
    server.stop(true);
    rmSync(folder, { recursive: true, force: true });
  });
});

describe("what the page is sent, and what it makes of it", () => {
  test("a frame is exactly cols, rows and text", () => {
    const message = watchMessage({ kind: "frame", cols: 132, rows: 41, text: "a\u001b[31mb" });
    expect(JSON.parse(message)).toEqual({ cols: 132, rows: 41, text: "a\u001b[31mb" });
    expect(parseFrame(message)).toEqual({ cols: 132, rows: 41, text: "a\u001b[31mb" });
  });

  test("the page reads only a whole frame, and a grid it can't draw is fitted", () => {
    expect(parseFrame(JSON.stringify({ cols: 0, rows: 0, text: "x" }))).toEqual({ cols: 0, rows: 0, text: "x" });
    expect(parseFrame(JSON.stringify({ cols: 9999, rows: 24, text: "x" }))).toEqual({ cols: 0, rows: 0, text: "x" });
    for (const bad of [new ArrayBuffer(4), "nope", "null", JSON.stringify({ cols: 80, rows: 24 }), JSON.stringify({ cols: "80", rows: 24, text: "x" }), JSON.stringify({ cols: 80.5, rows: 24, text: "x" })]) {
      expect(parseFrame(bad)).toBeNull();
    }
  });

  test("a screen fits the phone's width and is never blown up", () => {
    expect(fitScale(412, 1030)).toBeCloseTo(0.4, 2);
    expect(fitScale(412, 300)).toBe(1);
    expect(fitScale(0, 300)).toBe(1);
    expect(fitScale(412, 0)).toBe(1);
  });
});

describe("a slow phone", () => {
  test("a frame goes at once while the socket has room", () => {
    const outbox = new Outbox();
    expect(outbox.offer("a", 0, 100)).toBe("a");
    expect(outbox.offer("b", 100, 100)).toBe("b");
    expect(outbox.waiting).toBe(false);
  });

  test("with no room only the newest waits, and it goes when there is room", () => {
    const outbox = new Outbox();
    expect(outbox.offer("a", 500, 100)).toBeNull();
    expect(outbox.offer("b", 500, 100)).toBeNull();
    expect(outbox.offer("c", 500, 100)).toBeNull();
    expect(outbox.dropped).toBe(2);
    expect(outbox.flush(500, 100)).toBeNull();
    expect(outbox.flush(10, 100)).toBe("c");
    expect(outbox.flush(10, 100)).toBeNull();
    expect(outbox.waiting).toBe(false);
  });

  test("a frame that arrives once there is room replaces the one that waited", () => {
    const outbox = new Outbox();
    outbox.offer("a", 500, 100);
    expect(outbox.offer("b", 0, 100)).toBe("b");
    expect(outbox.waiting).toBe(false);
    expect(outbox.flush(0, 100)).toBeNull();
    expect(outbox.dropped).toBe(1);
  });
});

describe("a watch is read-only", () => {
  const source = readFileSync(new URL("./watcher.ts", import.meta.url), "utf8").replace(/^\s*\/\/.*$/gm, "");
  const page = readFileSync(new URL("./page/session.js", import.meta.url), "utf8");

  test("the relay runs on pipes, never a pseudo-terminal, and nothing is ever written to its input", () => {
    expect(source).toContain('stdin: "pipe"');
    expect(source).not.toMatch(/terminal\s*:/);
    expect(source).not.toMatch(/\.stdin\.write|\.write\(/);
    expect(source).not.toContain("process.terminal");
  });

  test("it asks the relay for `watch` and nothing that takes", () => {
    expect(source).toContain('"watch"');
    expect(source).not.toMatch(/take\s*:/);
  });

  test("the page sends a watch's session name and nothing more", () => {
    const watching = page.slice(page.indexOf("function startWatch"), page.indexOf("function drawFrame"));
    expect(watching.match(/ws\.send\(/g)?.length).toBe(1);
    expect(watching).toContain("JSON.stringify({ session: s.name })");
  });
});
