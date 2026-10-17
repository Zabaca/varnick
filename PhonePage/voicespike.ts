// The Voice mode spike (phone-page-is-only-a-browser-tab option 05, phase 1): a throwaway diagnostic page at /voice-spike that measures what Chrome
// on a phone keeps alive when the page is hidden or the phone is locked. It is off until the phone folder holds an empty file named
// `voice-spike-on`, and it is not linked from the page. Delete this file, its page, its route in server.ts and its tests once the figures are in.
//
// The page sends its events here, and this appends them as lines to `voice-spike.log` in the phone folder. Nothing it logs is audio or text a person
// said: a level, a state change, a round trip. A line is `<epoch ms> <ISO time> <run> <kind> t=<ms since the run began> dev=<device> k=v ...`
// (the one-line summary in the spike's script reads that). The host adds its own lines (`host-*`) for the websocket and each ping it receives, so a
// page that has gone quiet shows as a gap on the host's side too, whatever its own log got through.

import { appendFileSync, existsSync, statSync } from "node:fs";
import { join } from "node:path";
import type { ServerWebSocket, WebSocketHandler } from "bun";
import type { Device } from "./checks";
import { isObject } from "./json";
import { Admissions, firstMessageMs, type Admission } from "./relay";

export const spikePaths = { page: "/voice-spike", worklet: "/voice-spike-worklet.js", script: "/voice-spike.js", log: "/api/voice-spike/log", socket: "/ws/voice-spike" };

/** The marker that turns the spike on, and the log it writes, both in the phone folder. */
export function spikeFiles(folder: string): { marker: string; log: string } {
  return { marker: join(folder, "voice-spike-on"), log: join(folder, "voice-spike.log") };
}

/** Whether the spike is on: asked on every request, so touching or removing the marker needs no restart. */
export const spikeIsOn = (folder: string | undefined): boolean => folder !== undefined && existsSync(spikeFiles(folder).marker);

/**
 * The one-line summary of a log, for the person running the spike: each run's timeline of what changed (the microphone going silent or live, the page
 * hiding, freezing and resuming, the wake lock, the tone, the websocket) and its gaps in levels (over 3 s) and in the host's pings (over 7 s),
 * ending with a summary line. Times are seconds since the run began.
 */
export function summaryCommand(logPath: string): string {
  const program = [
    '{ r=$3; k=$4; delete f; for (i=5; i<=NF; i++) { n=index($i,"="); f[substr($i,1,n-1)]=substr($i,n+1) } t=f["t"]/1000; if (t>last[r]) last[r]=t }',
    'k=="level" { m=(f["rms"]+0<0.0005)?"silent":"live"; if (m!=mic[r]) { printf "%s %8.1f mic %s (vis=%s mute=%s ctx=%s ready=%s)\\n",r,t,m,f["vis"],f["mute"],f["ctx"],f["ready"]; mic[r]=m }',
    'levels[r]++; if ((r in lv) && t-lv[r]>3) printf "%s %8.1f level-gap %.1fs\\n",r,t,t-lv[r]; lv[r]=t; next }',
    'k=="host-ping" { pings[r]++; if ((r in hp) && t-hp[r]>7) printf "%s %8.1f host-ping-gap %.1fs\\n",r,t,t-hp[r]; hp[r]=t; next }',
    'k=="pong" { pongs[r]++; if (f["rtt"]+0>rtt[r]) rtt[r]=f["rtt"]+0; if (f["rtt"]+0>1000) printf "%s %8.1f slow-pong rtt=%sms\\n",r,t,f["rtt"]; next }',
    '{ line=""; for (i=5; i<=NF; i++) if ($i !~ /^(t|dev)=/) line=line " " $i; printf "%s %8.1f %s%s\\n",r,t,k,line }',
    'END { for (r in last) printf "%s %8.1f summary levels=%d host-pings=%d pongs=%d max-rtt=%dms\\n",r,last[r]+0.05,levels[r],pings[r],pongs[r],rtt[r] }',
  ].join(" ");
  return `awk '${program}' '${logPath.replace(/'/g, `'\\''`)}' | sort -s -k1,1 -k2,2n`;
}

/** The log stops growing here: a line past it is refused once, with a line saying so. */
export const logLimitBytes = 4 << 20;
export const maxEventsPerBatch = 100;
const maxFields = 8;
const maxValue = 64;
const maxRuns = 64;
const maxMessage = 200;
/** The page's longest time stamp (a day), in ms. */
const maxT = 86_400_000;

const runPattern = /^[0-9a-f]{8}$/;
const kindPattern = /^[a-z][a-z0-9-]{0,23}$/;
const keyPattern = /^[a-z]{1,16}$/;

/** A value as the log keeps it: spaces and anything unusual become `_`, so a line splits on spaces into `k=v` and nothing else. */
export const logValue = (value: string | number | boolean): string => String(value).replace(/[^A-Za-z0-9._:/+-]/g, "_").slice(0, maxValue);

export interface SpikeEvent {
  /** Milliseconds since the page's run began. */
  t: number;
  kind: string;
  fields: [string, string][];
}

/** A batch of events from the page, checked for what it must be: it is written to a file, so nothing in it is taken on trust. */
export function parseBatch(body: unknown): { ok: true; run: string; events: SpikeEvent[] } | { ok: false; error: string } {
  if (!isObject(body) || typeof body.run !== "string" || !runPattern.test(body.run)) return { ok: false, error: "Not a run" };
  if (!Array.isArray(body.events) || body.events.length === 0 || body.events.length > maxEventsPerBatch) return { ok: false, error: "Not a list of events" };
  const events: SpikeEvent[] = [];
  for (const raw of body.events) {
    if (!isObject(raw) || typeof raw.t !== "number" || !Number.isFinite(raw.t) || raw.t < 0 || raw.t > maxT) return { ok: false, error: "An event has no time" };
    if (typeof raw.k !== "string" || !kindPattern.test(raw.k)) return { ok: false, error: "An event has no kind" };
    const fields: [string, string][] = [];
    if (raw.f !== undefined) {
      if (!isObject(raw.f) || Object.keys(raw.f).length > maxFields) return { ok: false, error: "An event's fields are wrong" };
      for (const [key, value] of Object.entries(raw.f)) {
        const usable = typeof value === "string" || typeof value === "boolean" || (typeof value === "number" && Number.isFinite(value));
        if (!keyPattern.test(key) || !usable) return { ok: false, error: "An event's fields are wrong" };
        fields.push([key, logValue(value)]);
      }
    }
    events.push({ t: Math.round(raw.t), kind: raw.k, fields });
  }
  return { ok: true, run: body.run, events };
}

export function formatLine(now: number, run: string, device: Device, event: SpikeEvent): string {
  const fields = event.fields.map(([key, value]) => ` ${key}=${value}`).join("");
  return `${now} ${new Date(now).toISOString()} ${run} ${event.kind} t=${event.t} dev=${logValue(device.name)}${fields}\n`;
}

/** Where the log goes: a file in the real server, a list in the tests. */
export interface LogSink {
  append(text: string): void;
  size(): number;
}

export function fileSink(path: string): LogSink {
  return {
    append: (text) => appendFileSync(path, text, { mode: 0o600 }),
    size: () => { try { return statSync(path).size; } catch { return 0; } },
  };
}

export type SpikeAnswer = { status: number; body: { ok: boolean; error?: string; logged?: number } };

export class SpikeLog {
  /** When each run began on this host's clock, so the host's own lines carry a `t` on the page's scale. Bounded: the oldest run is forgotten. */
  private starts = new Map<string, number>();
  private written: number;
  private full = false;

  constructor(private sink: LogSink, private now: () => number = Date.now, private limit: number = logLimitBytes) {
    this.written = sink.size();
  }

  /** The page's batch, written. A refused batch writes nothing. */
  record(device: Device, body: unknown): SpikeAnswer {
    const batch = parseBatch(body);
    if (!batch.ok) return { status: 400, body: { ok: false, error: batch.error } };
    const now = this.now();
    // The first event of a run, whenever it arrives, says when the run began here: arrival minus its own time stamp.
    if (!this.starts.has(batch.run)) this.begin(batch.run, now - batch.events[0].t);
    return this.write(batch.events.map((event) => formatLine(now, batch.run, device, event)), batch.events.length);
  }

  /** A line of the host's own, on the page's time scale. A run the host hasn't heard from before begins now. */
  host(device: Device, run: string, kind: string, fields: [string, string][] = []): void {
    const now = this.now();
    if (!this.starts.has(run)) this.begin(run, now);
    // A host line the log can't take is dropped: the page's own batches report a full or unwritable log.
    this.write([formatLine(now, run, device, { t: now - this.starts.get(run)!, kind: `host-${kind}`, fields })], 1);
  }

  private begin(run: string, at: number): void {
    if (this.starts.size >= maxRuns) this.starts.delete(this.starts.keys().next().value!);
    this.starts.set(run, at);
  }

  private write(lines: string[], count: number): SpikeAnswer {
    const text = lines.join("");
    const bytes = Buffer.byteLength(text);
    if (this.written + bytes > this.limit) {
      if (!this.full) {
        this.full = true;
        try { this.sink.append(`${this.now()} ${new Date(this.now()).toISOString()} 00000000 log-full t=0 limit=${this.limit}\n`); } catch { /* nothing more to do */ }
      }
      return { status: 507, body: { ok: false, error: "The log is full" } };
    }
    try {
      this.sink.append(text);
    } catch {
      return { status: 500, body: { ok: false, error: "The log couldn't be written" } };
    }
    this.written += bytes;
    return { status: 200, body: { ok: true, logged: count } };
  }
}

// ---------------------------------------------------------------------------------------------------------------
// The ping websocket: the page sends `{run, n, sent}` every 5 s and gets `{pong: n, sent}` back at once, so it can time the round trip. The host
// logs each ping it receives, and the websocket's opening and closing with the close code.

const concurrentLimit = 4;
const perDeviceLimit = 2;

export interface SpikeData {
  kind: "spike";
  device: Device;
  admission: Admission;
  run?: string;
  pings: number;
  opened: number;
}

const closeBad = 4400;

export class SpikeSockets {
  private admissions = new Admissions(concurrentLimit, perDeviceLimit);

  constructor(private spike: SpikeLog, private now: () => number = Date.now) {}

  admit(device: Device): SpikeData | null {
    const admission = this.admissions.admit(device);
    return admission && { kind: "spike", device, admission, pings: 0, opened: this.now() };
  }

  handlers(): Pick<WebSocketHandler<SpikeData>, "open" | "message" | "close"> {
    return {
      open: (ws) => ws.data.admission.expectFirstMessage(firstMessageMs, () => ws.close(closeBad, "No ping")),
      message: (ws, message) => this.ping(ws, message),
      close: (ws, code) => {
        const data = ws.data;
        data.admission.stopWaiting();
        data.admission.giveBack();
        if (data.run) this.spike.host(data.device, data.run, "ws-close", [["code", String(code)], ["pings", String(data.pings)]]);
      },
    };
  }

  private ping(ws: ServerWebSocket<SpikeData>, message: string | Buffer): void {
    const data = ws.data;
    data.admission.stopWaiting();
    const parsed = typeof message === "string" && message.length <= maxMessage ? readPing(message) : null;
    if (!parsed) return void ws.close(closeBad, "Bad ping");
    if (data.run === undefined) {
      data.run = parsed.run;
      this.spike.host(data.device, parsed.run, "ws-open");
    } else if (data.run !== parsed.run) {
      return void ws.close(closeBad, "Bad ping");
    }
    data.pings += 1;
    this.spike.host(data.device, parsed.run, "ping", [["n", String(parsed.n)]]);
    ws.send(JSON.stringify({ pong: parsed.n, sent: parsed.sent }));
  }
}

export function readPing(text: string): { run: string; n: number; sent: number } | null {
  let value: unknown;
  try { value = JSON.parse(text); } catch { return null; }
  if (!isObject(value) || typeof value.run !== "string" || !runPattern.test(value.run)) return null;
  if (typeof value.n !== "number" || !Number.isSafeInteger(value.n) || value.n < 0) return null;
  if (typeof value.sent !== "number" || !Number.isFinite(value.sent)) return null;
  return { run: value.run, n: value.n, sent: value.sent };
}
