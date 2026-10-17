import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Device } from "./checks";
import { Terminals, type TerminalData } from "./bridge";
import { Relay } from "./relay";
import { socketHandlers } from "./server";
import { Watches, type WatchData } from "./watcher";
import {
  fileSink, formatLine, logLimitBytes, logValue, maxEventsPerBatch, parseBatch, readPing, SpikeLog, SpikeSockets, spikeFiles, spikeIsOn, summaryCommand,
  type LogSink, type SpikeData,
} from "./voicespike";

const device: Device = { id: "2b6b0d6e-8f0a-4c1e-9d3a-5a7c1e2f3b4d", node: "nodeid", name: "Test Phone" };
const run = "0a1b2c3d";

function memorySink(initial = 0): LogSink & { text: string } {
  const sink = { text: "", append(more: string) { sink.text += more; }, size: () => initial + Buffer.byteLength(sink.text) };
  return sink;
}

describe("a batch from the page", () => {
  const event = { t: 1500.4, k: "level", f: { rms: "0.01234", vis: "hidden", ws: 1 } };

  test("is a run and a list of events, each a time, a kind and a few fields", () => {
    expect(parseBatch({ run, events: [event, { t: 0, k: "start" }] })).toEqual({
      ok: true, run, events: [
        { t: 1500, kind: "level", fields: [["rms", "0.01234"], ["vis", "hidden"], ["ws", "1"]] },
        { t: 0, kind: "start", fields: [] },
      ],
    });
  });

  test("anything else is refused whole, so a bad page writes nothing", () => {
    const bad: unknown[] = [
      null, [], "text", {}, { run: "ABCDEF12", events: [event] }, { run: "short", events: [event] }, { run, events: [] }, { run, events: "x" },
      { run, events: Array.from({ length: maxEventsPerBatch + 1 }, () => event) },
      { run, events: [{ ...event, t: -1 }] }, { run, events: [{ ...event, t: "5" }] }, { run, events: [{ ...event, t: Infinity }] }, { run, events: [{ ...event, t: 90_000_000 }] },
      { run, events: [{ ...event, k: "Level" }] }, { run, events: [{ ...event, k: "a b" }] }, { run, events: [{ ...event, k: 5 }] }, { run, events: [{ t: 1 }] },
      { run, events: [{ ...event, f: [] }] }, { run, events: [{ ...event, f: { "Bad": 1 } }] }, { run, events: [{ ...event, f: { rms: { nested: 1 } } }] },
      { run, events: [{ ...event, f: { a: 1, b: 1, c: 1, d: 1, e: 1, f: 1, g: 1, h: 1, i: 1 } }] }, { run, events: [{ ...event, f: { rms: NaN } }] },
      { run, events: [event, 7] },
    ];
    for (const body of bad) expect(parseBatch(body).ok).toBe(false);
  });

  test("a value can't carry a space, a newline or a quote into the line", () => {
    expect(logValue("a b\nc\"d=e")).toBe("a_b_c_d_e");
    expect(logValue("x".repeat(500)).length).toBe(64);
    expect(logValue(true)).toBe("true");
    const batch = parseBatch({ run, events: [{ t: 1, k: "mark", f: { label: "lock 30s\n2000 fake line" } }] });
    expect(batch.ok && formatLine(0, run, device, batch.events[0]).split("\n").length).toBe(2);
  });
});

describe("the log's lines", () => {
  test("are epoch, time, run, kind, t and device, then the fields", () => {
    expect(formatLine(1_760_000_000_123, run, device, { t: 4200, kind: "vis", fields: [["state", "hidden"]] }))
      .toBe(`1760000000123 2025-10-09T08:53:20.123Z ${run} vis t=4200 dev=Test_Phone state=hidden\n`);
  });
});

describe("recording", () => {
  const batch = (t: number, kind = "level") => ({ run, events: [{ t, k: kind, f: { rms: "0.1" } }] });

  test("a batch is appended, one line an event", () => {
    const sink = memorySink();
    const log = new SpikeLog(sink, () => 5000);
    expect(log.record(device, { run, events: [{ t: 0, k: "start" }, { t: 1000, k: "level" }] })).toEqual({ status: 200, body: { ok: true, logged: 2 } });
    expect(sink.text.trimEnd().split("\n").map((line) => line.split(" ")[3])).toEqual(["start", "level"]);
  });

  test("a refused batch answers 400 and writes nothing", () => {
    const sink = memorySink();
    expect(new SpikeLog(sink).record(device, { run: "no", events: [] }).status).toBe(400);
    expect(sink.text).toBe("");
  });

  test("the host's lines are on the page's time scale, however late the page's first batch came", () => {
    let now = 100_000;
    const sink = memorySink();
    const log = new SpikeLog(sink, () => now);
    // The page's first event was 8 s into its run when this arrived: the run began at 92,000 here.
    log.record(device, batch(8000));
    now = 130_000;
    log.host(device, run, "ping", [["n", "3"]]);
    expect(sink.text.trimEnd().split("\n")[1]).toContain(` ${run} host-ping t=38000 `);
  });

  test("a run the host hears first from the websocket begins then", () => {
    const sink = memorySink();
    const log = new SpikeLog(sink, () => 7000);
    log.host(device, run, "ws-open");
    expect(sink.text).toContain(" host-ws-open t=0 ");
  });

  test("the log stops at its limit, says so once, and tells the page", () => {
    const sink = memorySink(logLimitBytes - 10);
    const log = new SpikeLog(sink, () => 1);
    expect(log.record(device, batch(1)).status).toBe(507);
    expect(log.record(device, batch(2)).status).toBe(507);
    expect(sink.text.match(/log-full/g)?.length).toBe(1);
    expect(sink.text).not.toContain(" level ");
  });

  test("a log that can't be written is a 500, not a crash", () => {
    const broken: LogSink = { append() { throw new Error("disk"); }, size: () => 0 };
    const log = new SpikeLog(broken);
    expect(log.record(device, batch(1)).status).toBe(500);
    expect(() => log.host(device, run, "ping")).not.toThrow();
  });

  test("a hundred runs don't grow the host's memory without bound", () => {
    const log = new SpikeLog(memorySink(), () => 1);
    for (let i = 0; i < 200; i++) log.host(device, i.toString(16).padStart(8, "0"), "ping");
    expect((log as unknown as { starts: Map<string, number> }).starts.size).toBe(64);
  });
});

describe("the files", () => {
  test("the spike is on only while its marker is in the phone folder", () => {
    const folder = mkdtempSync(join(tmpdir(), "spike-"));
    try {
      expect(spikeIsOn(folder)).toBe(false);
      expect(spikeIsOn(undefined)).toBe(false);
      writeFileSync(spikeFiles(folder).marker, "");
      expect(spikeIsOn(folder)).toBe(true);
      rmSync(spikeFiles(folder).marker);
      expect(spikeIsOn(folder)).toBe(false);
    } finally {
      rmSync(folder, { recursive: true, force: true });
    }
  });

  test("the log is an owner-only file the sink appends to", () => {
    const folder = mkdtempSync(join(tmpdir(), "spike-"));
    try {
      const path = spikeFiles(folder).log;
      const sink = fileSink(path);
      expect(sink.size()).toBe(0);
      const log = new SpikeLog(sink, () => 1_760_000_000_000);
      log.record(device, { run, events: [{ t: 0, k: "start", f: { chrome: "141" } }] });
      log.record(device, { run, events: [{ t: 1000, k: "level", f: { rms: "0.2" } }] });
      expect(readFileSync(path, "utf8").trimEnd().split("\n").length).toBe(2);
      expect(statSync(path).mode & 0o777).toBe(0o600);
      expect(sink.size()).toBe(statSync(path).size);
      // A restart picks up the size, so the limit holds across restarts.
      expect(new SpikeLog(fileSink(path)).record(device, { run, events: [{ t: 2000, k: "level" }] }).status).toBe(200);
    } finally {
      rmSync(folder, { recursive: true, force: true });
    }
  });
});

describe("the ping", () => {
  test("is a run, a count and the time it was sent", () => {
    expect(readPing(JSON.stringify({ run, n: 4, sent: 1760000000000 }))).toEqual({ run, n: 4, sent: 1760000000000 });
    for (const text of ["", "x", "[]", JSON.stringify({ run, n: -1, sent: 1 }), JSON.stringify({ run, n: 1.5, sent: 1 }), JSON.stringify({ run: "zz", n: 1, sent: 1 }), JSON.stringify({ run, n: 1 })]) {
      expect(readPing(text)).toBeNull();
    }
  });
});

describe("the ping websocket, on a real server", () => {
  const folder = mkdtempSync(join(tmpdir(), "spike-ws-"));
  const config = { mode: "loopback", loopbackPort: 0, port: 8444, relay: "/bin/false", devices: "/dev/null", tailscale: "tailscale" } as never;
  const sink = memorySink();
  const spike = new SpikeLog(sink);
  const sockets = new SpikeSockets(spike);
  const server = Bun.serve<TerminalData | WatchData | SpikeData>({
    port: 0,
    websocket: socketHandlers(new Terminals(config, new Relay(config, 29, folder), 29, folder, () => {}), new Watches(config, 29, folder, () => {}), sockets),
    fetch(request, serving) {
      const data = sockets.admit(device);
      if (!data) return new Response("full", { status: 429 });
      return serving.upgrade(request, { data }) ? undefined : new Response("no", { status: 400 });
    },
  });
  const open = (): Promise<{ ws: WebSocket; messages: string[]; closed: Promise<number> }> => new Promise((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:${server.port}/`);
    const messages: string[] = [];
    const closed = new Promise<number>((done) => { ws.onclose = (event) => done(event.code); });
    ws.onmessage = (event) => messages.push(String(event.data));
    ws.onopen = () => resolve({ ws, messages, closed });
  });
  const until = async (ready: () => boolean) => { for (let waited = 0; waited < 4000 && !ready(); waited += 20) await Bun.sleep(20); };

  test("answers each ping with its count and time, and the host logs the ping, the opening and the closing", async () => {
    const { ws, messages } = await open();
    ws.send(JSON.stringify({ run, n: 0, sent: 111 }));
    ws.send(JSON.stringify({ run, n: 1, sent: 222 }));
    await until(() => messages.length === 2);
    expect(messages.map((message) => JSON.parse(message))).toEqual([{ pong: 0, sent: 111 }, { pong: 1, sent: 222 }]);
    ws.close(1000);
    await until(() => sink.text.includes("host-ws-close"));
    const kinds = sink.text.trimEnd().split("\n").map((line) => line.split(" ")[3]);
    expect(kinds).toEqual(["host-ws-open", "host-ping", "host-ping", "host-ws-close"]);
    expect(sink.text).toContain("code=1000 pings=2");
  });

  test("a message that isn't a ping closes the socket", async () => {
    const { ws, closed } = await open();
    ws.send("hello");
    expect(await closed).toBe(4400);
    expect(ws.readyState).toBe(3);
  });

  test("a second run on one socket, or a long message, closes it", async () => {
    const one = await open();
    one.ws.send(JSON.stringify({ run, n: 0, sent: 1 }));
    one.ws.send(JSON.stringify({ run: "ffffffff", n: 1, sent: 1 }));
    expect(await one.closed).toBe(4400);
    const two = await open();
    two.ws.send(JSON.stringify({ run, n: 0, sent: 1, pad: "x".repeat(300) }));
    expect(await two.closed).toBe(4400);
  });

  test("a device has two open at once, and the slot comes back when one closes", async () => {
    const first = await open(), second = await open();
    const refused = await new Promise<number>((resolve) => {
      const ws = new WebSocket(`ws://127.0.0.1:${server.port}/`);
      ws.onerror = () => resolve(0);
      ws.onclose = () => resolve(1);
      ws.onopen = () => resolve(2);
    });
    expect(refused).not.toBe(2);
    first.ws.close();
    await first.closed;
    await Bun.sleep(50);
    const third = await open();
    expect(third.ws.readyState).toBe(1);
    second.ws.close();
    third.ws.close();
  });

  afterAll(() => {
    server.stop(true);
    rmSync(folder, { recursive: true, force: true });
  });
});

describe("the one-line summary", () => {
  test("reads a log into each run's timeline: when the microphone went silent, the gaps, the pings", async () => {
    const folder = mkdtempSync(join(tmpdir(), "spike-sum-"));
    try {
      const path = join(folder, "voice-spike.log");
      const lines: string[] = [];
      const add = (t: number, kind: string, fields = "") => lines.push(`${1_760_000_000_000 + t} 2025-10-09T08:53:20.000Z ${run} ${kind} t=${t} dev=Test_Phone${fields}`);
      add(0, "start", " chrome=141 app=tab");
      for (let s = 1; s <= 10; s++) {
        const silent = s > 6;
        // The page is hidden at 3 s and the microphone reads zeros from 7 s; then no level arrives until 80 s.
        if (s === 3) add(s * 1000, "vis", " state=hidden");
        add(s * 1000, "level", ` rms=${silent ? "0.00000" : "0.01234"} peak=0.1 blank=0 mute=0 ready=live ctx=running vis=${s >= 3 ? "hidden" : "visible"} ws=1`);
      }
      add(80_000, "level", " rms=0.00000 peak=0 blank=0 mute=0 ready=live ctx=running vis=hidden ws=3");
      add(80_500, "resume", " vis=visible");
      add(5000, "host-ping", " n=0");
      add(10_000, "host-ping", " n=1");
      add(40_000, "host-ping", " n=2");
      add(6000, "pong", " n=0 rtt=42 vis=hidden");
      add(41_000, "pong", " n=2 rtt=3500 vis=hidden");
      writeFileSync(path, `${lines.join("\n")}\n`);

      const done = Bun.spawnSync(["sh", "-c", summaryCommand(path)], { stdout: "pipe", stderr: "pipe" });
      expect(done.stderr.toString()).toBe("");
      expect(done.exitCode).toBe(0);
      const out = done.stdout.toString();
      expect(out).toContain(`${run}      0.0 bucket 0-30s levels=10 loudest=0.012 muted=0 vis=hidden\n`);
      expect(out).toContain(`${run}      3.0 vis state=hidden`);
      expect(out).toContain(`${run}     60.0 bucket 60-90s levels=1 loudest=0.000 muted=0 vis=hidden SILENT\n`);
      expect(out).toContain(`${run}     80.0 level-gap 70.0s`);
      expect(out).toContain(`${run}     80.5 resume vis=visible`);
      expect(out).toContain(`${run}     40.0 host-ping-gap 30.0s`);
      expect(out).toContain(`${run}     41.0 slow-pong rtt=3500ms`);
      expect(out).toContain("summary levels=11 host-pings=3 pongs=2 max-rtt=3500ms");
      // In time order, the summary last.
      const times = out.trimEnd().split("\n").map((line) => Number(line.trim().split(/\s+/)[1]));
      expect(times).toEqual([...times].sort((a, b) => a - b));
    } finally {
      rmSync(folder, { recursive: true, force: true });
    }
  });

  test("a long run whose page froze reads to its end, whatever order its lines reached the log", () => {
    const folder = mkdtempSync(join(tmpdir(), "spike-sum-"));
    try {
      const path = join(folder, "voice-spike.log");
      const lines: string[] = [];
      const add = (t: number, kind: string, fields = "") => lines.push(`${1_760_000_000_000 + t} 2025-10-09T08:53:20.000Z ${run} ${kind} t=${t} dev=Test_Phone${fields}`);
      add(0, "start");
      for (let s = 1; s <= 10; s++) add(s * 1000, "level", " rms=0.02000 peak=0.1 blank=0 mute=0 ready=live ctx=running vis=hidden ws=1");
      // The page froze at 12 s: the host heard pings until 60 s, and the page's levels from 11 s to 260 s came in one batch when it resumed.
      for (let s = 5; s <= 60; s += 5) add(s * 1000, "host-ping", ` n=${s / 5}`);
      add(12_000, "freeze");
      for (let s = 11; s <= 260; s++) add(s * 1000, "level", ` rms=${s < 100 ? "0.00000" : "0.05000"} peak=0.1 blank=0 mute=0 ready=live ctx=running vis=${s < 200 ? "hidden" : "visible"} ws=1`);
      add(200_000, "resume", " vis=visible");
      writeFileSync(path, `${lines.join("\n")}\n`);
      const done = Bun.spawnSync(["sh", "-c", summaryCommand(path)], { stdout: "pipe", stderr: "pipe" });
      const out = done.stdout.toString();
      expect(done.stderr.toString()).toBe("");
      expect(out).toContain("summary levels=260 host-pings=12 pongs=0");
      expect(out).toContain(`${run}    240.0 bucket 240-270s levels=21 loudest=0.050 muted=0 vis=visible\n`);
      expect(out).toContain(`${run}     30.0 bucket 30-60s levels=30 loudest=0.000 muted=0 vis=hidden SILENT\n`);
      expect(out).toContain(`${run}     12.0 freeze`);
      expect(out.trimEnd().split("\n").at(-1)).toContain(`${run}    260.1 summary`);
    } finally {
      rmSync(folder, { recursive: true, force: true });
    }
  });

  test("a path with a quote in it is still one argument", () => {
    expect(summaryCommand("/tmp/it's here/log")).toContain(`'/tmp/it'\\''s here/log'`);
  });
});
