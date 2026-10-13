// The only way the page asks about sessions: the host's own relay, run as a child with an argument list and a device's
// id as `by`. The page decides nothing about sessions, so every rule of the relay and of the host's Varnick holds for it
// unchanged (ADR 0011). User text only ever goes inside the request's JSON.

import type { Config, Device } from "./checks";
import type { RelayResult } from "./home";

/**
 * One request as the relay reads it. `by` is the device the server found calling (or nobody, for a hello): it is
 * written last, so nothing a client sent in `fields` can replace it.
 */
export function buildRequest(version: number, op: string, by: string | null, fields: Record<string, unknown> = {}): string {
  const request: Record<string, unknown> = { ...fields, v: version, op };
  delete request.by;
  if (by !== null) request.by = by;
  return JSON.stringify(request);
}

/** `[relay, "--peer", <base64 JSON>]`: what `PeerClient.remoteCommand` sends over ssh, without a shell. */
export function relayArguments(relay: string, request: string): string[] {
  return [relay, "--peer", Buffer.from(request, "utf8").toString("base64")];
}

/**
 * Nothing of the server's environment reaches the relay but what it needs: a home and a plain PATH (as the package's
 * own zmx commands get), and the two folders a check points elsewhere.
 */
export function relayEnvironment(config: Pick<Config, "zmxDir" | "userHome">, home: string): Record<string, string> {
  const env: Record<string, string> = { HOME: home, PATH: "/usr/bin:/bin" };
  if (config.zmxDir) env.VARNICK_ZMX_DIR = config.zmxDir;
  if (config.userHome) env.CFFIXED_USER_HOME = config.userHome;
  return env;
}

/** The reply line: the last line of output that is a JSON object with `v` and `ok`, since a shell may print a greeting first. */
export function parseReply(output: string): Record<string, unknown> | null {
  for (const line of output.split("\n").reverse()) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("{")) continue;
    try {
      const reply = JSON.parse(trimmed);
      if (typeof reply === "object" && reply !== null && typeof reply.ok === "boolean" && typeof reply.v === "number") return reply;
    } catch {
      continue;
    }
  }
  return null;
}

/** A name or code as a log line may hold it: printable ASCII, short. Never a prompt, a title, a screen or typed text. */
export const clean = (text: string): string => text.replace(/[^\x20-\x7e]/g, "?").slice(0, 120);

/** A cap on child processes running at once, in all and per key, so one caller can't take every slot. */
export class Slots {
  private total = 0;
  private perKey = new Map<string, number>();

  constructor(private limit: number, private perKeyLimit: number) {}

  acquire(key: string): boolean {
    const used = this.perKey.get(key) ?? 0;
    if (this.total >= this.limit || used >= this.perKeyLimit) return false;
    this.total += 1;
    this.perKey.set(key, used + 1);
    return true;
  }

  release(key: string): void {
    const used = this.perKey.get(key) ?? 0;
    if (used <= 0) return;
    this.total -= 1;
    if (used === 1) this.perKey.delete(key);
    else this.perKey.set(key, used - 1);
  }
}

/**
 * One websocket's place among the open ones (the terminal's and the live screen's each have their own caps): its slot, given
 * back once, and the timer that closes it when its first message never comes.
 */
export class Admission {
  private released = false;
  private timer: ReturnType<typeof setTimeout> | undefined;

  constructor(private slots: Slots, readonly device: Device) {}

  /** `late` runs when no first message has come after `ms`. */
  expectFirstMessage(ms: number, late: () => void): void {
    this.timer = setTimeout(late, ms);
  }

  /** The first message came, or the websocket is over: no more waiting for one. */
  stopWaiting(): void {
    clearTimeout(this.timer);
  }

  giveBack(): void {
    if (this.released) return;
    this.released = true;
    this.slots.release(this.device.id);
  }
}

/** The first message of a websocket must come this soon after the upgrade. */
export const firstMessageMs = 10_000;

export class Admissions {
  private slots: Slots;

  constructor(limit: number, perDeviceLimit: number) {
    this.slots = new Slots(limit, perDeviceLimit);
  }

  /** A slot for one more websocket of this device, or null when it, or the host, has its share open already. */
  admit(device: Device): Admission | null {
    return this.slots.acquire(device.id) ? new Admission(this.slots, device) : null;
  }
}

const timeoutMs = 15_000;
/** A Mac host takes up to 25 s to answer `start` and `resume` (it waits for the session to exist): they get longer than a lookup. */
export const launchTimeoutMs = 40_000;
/** A Mac host waits up to 60 s for the panes of a `reopen` (`MacPeerHost.forward`): the relay is given a little more. */
export const reopenTimeoutMs = 70_000;
/**
 * The most the request's one base64 argument may be. Linux allows 131,072 bytes (with the final NUL) for one argument, and
 * a request over it can't be spawned at all. `launch.ts` holds a prompt to what fits, with room for the rest of the request.
 */
export const argumentLimit = 120_000;
const outputLimit = 8 << 20;
/** At most this many relays at once, and this many for one device (a page asks twice at a time). */
const concurrentLimit = 8;
const perDeviceLimit = 4;

export class Relay {
  private slots = new Slots(concurrentLimit, perDeviceLimit);

  constructor(private config: Config, private version: number, private home: string) {}

  /** Asks the relay one thing as `by`. Never throws: a relay that fails to start, answer or answer in time is a failed result. */
  async ask(op: string, by: string | null, fields: Record<string, unknown> = {}, limitMs: number = timeoutMs, slotKey?: string): Promise<RelayResult> {
    // Slots are per device; a caller whose answer isn't the device's own names another key.
    const key = slotKey ?? by ?? "";
    if (!this.slots.acquire(key)) return { ok: false, error: "The host is busy: try again" };
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const argv = relayArguments(this.config.relay, buildRequest(this.version, op, by, fields));
      if (argv[2].length > argumentLimit) return { ok: false, error: "The request is too long" };
      const process = Bun.spawn(argv, {
        env: relayEnvironment(this.config, this.home),
        stdin: "ignore",
        stdout: "pipe",
        stderr: "ignore",
      });
      // The read ends at the timeout whatever holds the pipe: a child the relay started could keep its stdout open
      // after the relay is gone, and the read alone would wait for it.
      const timedOut = new Promise<null>((resolve) => {
        timer = setTimeout(() => {
          process.kill();
          resolve(null);
        }, limitMs);
      });
      const output = await Promise.race([new Response(process.stdout).text(), timedOut]);
      if (output === null) return { ok: false, error: "The relay didn't answer in time" };
      if (output.length > outputLimit) return { ok: false, error: "The relay's answer was too long" };
      const reply = parseReply(output);
      if (!reply) return { ok: false, error: "The relay didn't answer" };
      if (reply.v !== this.version) return { ok: false, error: "The relay speaks another protocol version" };
      if (reply.ok !== true) return { ok: false, error: typeof reply.error === "string" ? reply.error.slice(0, 300) : "The relay refused the request" };
      return { ok: true, reply };
    } catch {
      return { ok: false, error: "The relay couldn't be started" };
    } finally {
      clearTimeout(timer);
      this.slots.release(key);
    }
  }
}
