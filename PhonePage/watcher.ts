// The live screen channel (ADR 0008, ADR 0011): one websocket per shown session view, carrying the frames of the relay's `watch`
// to the page. A watch is read-only. The relay runs on pipes, never a pseudo-terminal (a reader never sends input, Init or a
// size), nothing the page sends after its first message is read, and the relay's input is a pipe held open for the watch's whole
// life: closing it is how the relay learns its viewer has gone, so the websocket closing closes it, then terminates the relay
// after 1 s and kills it after 2 s, as the app's `SSHRunner.stream` does.
//
// What is logged: opens, closes, codes and counts. Never a screen.

import type { ServerWebSocket, Subprocess, WebSocketHandler } from "bun";
import type { Config, Device } from "./checks";
import { buildRequest, clean, relayArguments, relayEnvironment, Admissions, firstMessageMs, type Admission } from "./relay";
import { closeCode, fitReason } from "./terminal";
import type { OpenPanes } from "./pushwatch";
import { Outbox, parseWatchOpen, WatchDecoder, watchMessage, type WatchEvent } from "./watch";

/** The relay is asked to end this long after its input closes, and killed this long after. */
const terminateAfterMs = 1000;
const killAfterMs = 2000;
/**
 * A frame goes out only while the socket holds less than this unsent: a screen is some tens of KB, so a few at most. With
 * `longestMessage` it stays well under the server's `backpressureLimit`, which would close the socket.
 */
export const sendHighWater = 256 << 10;
/** A waiting frame is tried again this often, in case the socket's own drain signal doesn't come. */
const flushEveryMs = 250;
const concurrentLimit = 8;
const perDeviceLimit = 3;

export interface WatchData {
  kind: "watch";
  device: Device;
  admission: Admission;
  opened: number;
  phase: "waiting" | "live" | "closed";
  session?: string;
  process?: Subprocess<"pipe", "pipe", "ignore">;
  decoder: WatchDecoder;
  outbox: Outbox;
  frames: number;
  flushTimer?: ReturnType<typeof setTimeout>;
  /** Counted as open in `OpenPanes`, so it is counted out once. */
  counted?: boolean;
}

type Socket = ServerWebSocket<WatchData>;

export class Watches {
  private admissions = new Admissions(concurrentLimit, perDeviceLimit);

  /** `panes` learns which pane a device has open, for the push that a device with the pane open doesn't get (pushwatch.ts). */
  constructor(private config: Config, private version: number, private home: string, private log: (line: string) => void, private panes?: OpenPanes) {}

  /**
   * A place for one more watch of this device, or null when it, or the host, has its share open already. The slot goes back when the
   * relay is gone (`start`), or at once for a watch that never started.
   */
  admit(device: Device): WatchData | null {
    const admission = this.admissions.admit(device);
    return admission && { kind: "watch", device, admission, opened: Date.now(), phase: "waiting", decoder: new WatchDecoder(), outbox: new Outbox(), frames: 0 };
  }

  /** The handlers for `Bun.serve`; its options are the server's (`socketHandlers`), shared with the terminal's. */
  handlers(): Pick<WebSocketHandler<WatchData>, "open" | "message" | "close" | "drain"> {
    return {
      open: (ws) => {
        ws.data.admission.expectFirstMessage(firstMessageMs, () => this.finish(ws, closeCode.badRequest, "No request"));
      },
      message: (ws, message) => {
        if (ws.data.phase === "waiting") return this.first(ws, message);
        // Read-only: after the first message nothing the page sends is read, and a page that sends anything is closed.
        this.finish(ws, closeCode.badRequest, "A watch sends nothing");
      },
      close: (ws, code) => {
        const data = ws.data;
        this.log(`watch close ${clean(data.device.name)} ${code} after ${Math.round((Date.now() - data.opened) / 1000)}s frames=${data.frames} dropped=${data.outbox.dropped}`);
        this.cleanup(ws);
      },
      drain: (ws) => this.flush(ws),
    };
  }

  /** The websocket's first message. Anything but a text message naming a session closes it. */
  private first(ws: Socket, message: string | Buffer): void {
    const data = ws.data;
    data.admission.stopWaiting();
    const open = typeof message === "string" ? parseWatchOpen(message) : null;
    if (!open) return this.finish(ws, closeCode.badRequest, "Bad request");
    this.start(ws, open.session);
  }

  private start(ws: Socket, session: string): void {
    const data = ws.data;
    data.session = session;
    // Pipes, never a pseudo-terminal; `by` is the device the server found. The relay checks the device and the session itself.
    const argv = relayArguments(this.config.relay, buildRequest(this.version, "watch", data.device.id, { session }));
    let process: Subprocess<"pipe", "pipe", "ignore">;
    try {
      process = Bun.spawn(argv, { env: relayEnvironment(this.config, this.home), stdin: "pipe", stdout: "pipe", stderr: "ignore" });
    } catch {
      this.log(`watch ${clean(data.device.name)} couldn't start the relay`);
      return this.finish(ws, closeCode.failed, "The screen couldn't be read");
    }
    data.process = process;
    data.phase = "live";
    this.panes?.add(data.device.id, session);
    data.counted = true;
    this.log(`watch start ${clean(data.device.name)} ${session}`);
    // The slot goes back when the relay does, not when the websocket does: a page that reconnects quickly can't pile relays up.
    void process.exited.then(() => {
      data.admission.giveBack();
      if (data.phase !== "closed") void Bun.sleep(100).then(() => this.finish(ws, 1000, "Ended"));
    });
    void this.read(ws, process);
    // The websocket may already be closed (a close before the spawn returned): then the relay is stopped at once.
    if (ws.readyState !== 1) this.cleanup(ws);
  }

  /** Reads the relay's output for as long as it lasts, however the websocket fares: a pipe nobody reads would block the relay. */
  private async read(ws: Socket, process: Subprocess<"pipe", "pipe", "ignore">): Promise<void> {
    const data = ws.data;
    const reader = process.stdout.getReader();
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        if (data.phase === "closed") continue;
        for (const event of data.decoder.feed(value)) this.event(ws, event);
        if (data.decoder.failure !== null && data.phase !== "closed") {
          this.log(`watch ${clean(data.device.name)} bad stream`);
          this.finish(ws, closeCode.failed, "The host's screens weren't readable");
        }
      }
    } catch {
      // The pipe broke: the relay's exit is handled above.
    } finally {
      reader.releaseLock();
    }
    if (data.phase !== "closed") this.finish(ws, 1000, "Ended");
  }

  private event(ws: Socket, event: WatchEvent): void {
    const data = ws.data;
    if (data.phase === "closed") return;
    if (event.kind === "reply") {
      if (event.reply.v !== this.version) return this.finish(ws, closeCode.failed, "The relay speaks another protocol version");
      if (event.reply.ok !== true) {
        const error = typeof event.reply.error === "string" && event.reply.error !== "" ? event.reply.error : "The relay refused the watch";
        this.log(`watch ${clean(data.device.name)} refused`);
        return this.finish(ws, closeCode.refused, fitReason(error));
      }
      return;
    }
    if (event.kind === "frame") data.frames += 1;
    // A screen too large to send is said so in its place, and the channel goes on.
    const send = data.outbox.offer(watchMessage(event), ws.getBufferedAmount(), sendHighWater);
    if (send !== null) {
      ws.send(send);
    } else if (data.flushTimer === undefined) {
      data.flushTimer = setTimeout(() => this.flush(ws), flushEveryMs);
    }
  }

  /** The socket has room again: the newest frame that waited goes now. */
  private flush(ws: Socket): void {
    const data = ws.data;
    clearTimeout(data.flushTimer);
    data.flushTimer = undefined;
    if (data.phase !== "live") return;
    const send = data.outbox.flush(ws.getBufferedAmount(), sendHighWater);
    if (send !== null) ws.send(send);
    else if (data.outbox.waiting) data.flushTimer = setTimeout(() => this.flush(ws), flushEveryMs);
  }

  /** Closes the websocket with a code and reason; `close` then runs `cleanup`. */
  private finish(ws: Socket, code: number, reason: string): void {
    const data = ws.data;
    if (data.phase === "closed") return;
    const hadProcess = data.process !== undefined;
    data.phase = "closed";
    data.admission.stopWaiting();
    clearTimeout(data.flushTimer);
    try { ws.close(code, reason); } catch { /* already closed */ }
    // A close that never reaches the handler (the socket was already gone) must still stop the relay.
    if (hadProcess) this.stopRelay(data);
    else data.admission.giveBack();
  }

  /** The websocket is gone: the relay's input closes, and it is terminated after 1 s and killed after 2 s. */
  private cleanup(ws: Socket): void {
    const data = ws.data;
    data.phase = "closed";
    data.admission.stopWaiting();
    clearTimeout(data.flushTimer);
    this.stopRelay(data);
    if (data.process === undefined) data.admission.giveBack();
  }

  private stopRelay(data: WatchData): void {
    if (data.counted && data.session) {
      data.counted = false;
      this.panes?.remove(data.device.id, data.session);
    }
    const process = data.process;
    if (!process || stopped.has(process)) return;
    stopped.add(process);
    try { void Promise.resolve(process.stdin.end()).catch(() => {}); } catch { /* closed already */ }
    const terminate = setTimeout(() => { if (process.exitCode === null) process.kill("SIGTERM"); }, terminateAfterMs);
    const kill = setTimeout(() => { if (process.exitCode === null) process.kill("SIGKILL"); }, killAfterMs);
    void process.exited.then(() => { clearTimeout(terminate); clearTimeout(kill); });
  }
}

/** The relays whose stop is already under way: stopping is done once, whichever of `finish` and `cleanup` comes first. */
const stopped = new WeakSet<object>();
