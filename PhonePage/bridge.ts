// The terminal channel (ADR 0011): one websocket per open terminal, carrying bytes to and from the relay's `attach` run in
// Bun's pseudo-terminal at the phone's grid. The relay checks the label itself, so an attach without take only succeeds
// for a session this device controls, and after a take-over the zmx client is detached and exits: nothing typed afterwards
// can reach the session. The server decides nothing about control; it reads `status` to say why a client went.
//
// What is logged: opens, closes, codes and grids. Never what was typed or shown.

import type { ServerWebSocket, Subprocess, WebSocketHandler } from "bun";
import type { Config, Device } from "./checks";
import { buildRequest, clean, relayArguments, relayEnvironment, Admissions, firstMessageMs, type Admission, type Relay } from "./relay";
import type { OpenPane, OpenPanes } from "./pushwatch";
import {
  attachEnvironment, closeCode, decideExit, firstOutput, fitReason, inputLimit, parseClient, parseOpen, recheckControl, refusal, type OpenRequest,
} from "./terminal";

/** A refused attach's reply line is held this long at most before it is taken for a screen. */
const holdLimitMs = 1000;
/** After the client exits its last output is still in flight: wait this long before reading what was held. */
const settleMs = 100;
/** A zmx client that ignores its pty closing is killed after this. */
const killAfterMs = 3000;
/** The label is read once this long after a client goes live: two Macs taking at once can leave both attached. */
const recheckAfterMs = 1000;
const concurrentLimit = 8;
const perDeviceLimit = 3;

export interface TerminalData {
  kind: "terminal";
  device: Device;
  admission: Admission;
  opened: number;
  phase: "waiting" | "holding" | "live" | "closed";
  open?: OpenRequest;
  process?: Subprocess;
  held: Uint8Array[];
  holdTimer?: ReturnType<typeof setTimeout>;
  recheckTimer?: ReturnType<typeof setTimeout>;
  /** This socket in `OpenPanes`: the pane is open on the device while the page says it is visible. */
  pane?: OpenPane | null;
}

type Socket = ServerWebSocket<TerminalData>;

export class Terminals {
  private admissions = new Admissions(concurrentLimit, perDeviceLimit);

  /** `panes` learns which pane a device has open, for the push that a device with the pane open doesn't get (pushwatch.ts). */
  constructor(private config: Config, private relay: Relay, private version: number, private home: string, private log: (line: string) => void, private panes?: OpenPanes) {}

  /** A place for one more terminal of this device, or null when it, or the host, has its share open already. An admitted terminal that is never upgraded gives its slot back (`admission.giveBack`). */
  admit(device: Device): TerminalData | null {
    const admission = this.admissions.admit(device);
    return admission && { kind: "terminal", device, admission, opened: Date.now(), phase: "waiting", held: [] };
  }

  /** The websocket's handlers for `Bun.serve`; its options are the server's (`socketHandlers`), shared with the live screen's. */
  handlers(): Pick<WebSocketHandler<TerminalData>, "open" | "message" | "close"> {
    return {
      open: (ws) => {
        ws.data.admission.expectFirstMessage(firstMessageMs, () => this.finish(ws, closeCode.badRequest, "No request"));
      },
      message: (ws, message) => {
        if (typeof message !== "string") return;
        const data = ws.data;
        if (data.phase === "waiting") {
          data.admission.stopWaiting();
          const open = parseOpen(message);
          if (!open) return this.finish(ws, closeCode.badRequest, "Bad request");
          this.start(ws, open);
          return;
        }
        if (data.phase === "closed") return;
        const input = parseClient(message);
        // Whether the page is visible: Android keeps a hidden app's socket for over a minute, and a pane nobody is looking at isn't open (pushwatch.ts).
        if (input?.t === "visibility") {
          data.pane?.setVisible(input.visible);
          return;
        }
        const terminal = data.process?.terminal;
        if (!input || !terminal) return;
        // Typed bytes wait for the screen: before it is live the pty may only be echoing a refused attach's reply line.
        if (input.t !== "resize" && data.phase !== "live") return;
        try {
          if (input.t === "resize") terminal.resize(input.cols, input.rows);
          else terminal.write(input.data);
        } catch {
          // The client exited between the check and the write: its exit is handled below.
        }
      },
      close: (ws, code) => {
        this.log(`terminal close ${clean(ws.data.device.name)} ${code} after ${Math.round((Date.now() - ws.data.opened) / 1000)}s`);
        this.cleanup(ws);
      },
    };
  }

  private start(ws: Socket, open: OpenRequest): void {
    const data = ws.data;
    data.open = open;
    data.phase = "holding";
    data.pane = this.panes?.open(data.device.id, open.session);
    // `take` is whatever the page said it pressed: the relay is what decides, and without it refuses a session this device doesn't control.
    const request = buildRequest(this.version, "attach", data.device.id, open.take ? { session: open.session, take: true } : { session: open.session });
    let process: Subprocess;
    try {
      process = Bun.spawn(relayArguments(this.config.relay, request), {
        env: attachEnvironment(relayEnvironment(this.config, this.home), Bun.env.LANG, globalThis.process.platform),
        terminal: { cols: open.cols, rows: open.rows, data: (_terminal, chunk) => this.output(ws, chunk) },
      });
    } catch {
      this.log(`terminal ${clean(data.device.name)} couldn't start the relay`);
      return this.finish(ws, closeCode.failed, "The terminal couldn't be started");
    }
    data.process = process;
    this.log(`terminal start ${clean(data.device.name)} ${open.session} ${open.cols}x${open.rows} take=${open.take}`);
    void process.exited.then((code) => this.exited(ws, code));
  }

  /** A chunk from the pseudo-terminal: live, or held while it could still be a refused attach's reply line. */
  private output(ws: Socket, chunk: Uint8Array): void {
    const data = ws.data;
    if (data.phase === "live") {
      ws.send(chunk);
      return;
    }
    if (data.phase !== "holding") return;
    // The chunk may be reused by the caller.
    data.held.push(chunk.slice());
    const head = Buffer.concat(data.held);
    if (firstOutput(head) === "screen") {
      this.release(ws);
    } else if (!data.holdTimer) {
      data.holdTimer = setTimeout(() => this.release(ws), holdLimitMs);
    }
  }

  /** What was held is a screen: let it go to the terminal, and every later chunk after it. */
  private release(ws: Socket): void {
    const data = ws.data;
    clearTimeout(data.holdTimer);
    data.holdTimer = undefined;
    if (data.phase !== "holding") return;
    data.phase = "live";
    const held = Buffer.concat(data.held);
    data.held = [];
    if (held.length > 0) ws.send(held);
    data.recheckTimer = setTimeout(() => void this.recheck(ws), recheckAfterMs);
  }

  /**
   * Once, a second after the client attached: read the label. The relay checked it before it became zmx, and another Mac may
   * have taken the session in between (a take landing between the relay's check and the attach), which leaves two keyboards
   * live. If the label isn't this device's, close the pty and say who has it (4001), as the Mac clients do.
   */
  private async recheck(ws: Socket): Promise<void> {
    const data = ws.data;
    if (data.phase !== "live") return;
    const name = data.open!.session;
    const result = await this.relay.ask("status", data.device.id, { sessions: [name] });
    if (data.phase !== "live") return;
    const closing = recheckControl(result, name, data.device);
    if (!closing) return;
    this.log(`terminal recheck ${clean(data.device.name)} label moved -> ${closing.code}`);
    this.finish(ws, closing.code, closing.reason);
  }

  /** The zmx client (or the relay that refused to become it) exited by itself or was closed by `cleanup`. */
  private async exited(ws: Socket, code: number | null): Promise<void> {
    const data = ws.data;
    if (data.phase === "closed") return;
    await Bun.sleep(settleMs);
    if (data.phase === "closed") return;
    if (data.phase === "holding") {
      // A refusal's one reply line never reaches the terminal: it closes the websocket with its error instead.
      const refused = refusal(Buffer.concat(data.held).toString("utf8"));
      if (refused !== null) {
        this.log(`terminal ${clean(data.device.name)} attach refused`);
        return this.finish(ws, closeCode.refused, fitReason(refused));
      }
      this.release(ws);
    }
    const name = data.open!.session;
    // The label decides what the exit meant: taken, ended, or only a dropped client.
    const result = await this.relay.ask("status", data.device.id, { sessions: [name] });
    if (data.phase === "closed") return;
    const closing = decideExit(result, name, data.device);
    this.log(`terminal exit ${clean(data.device.name)} client ${code ?? "signal"} -> ${closing.code}`);
    this.finish(ws, closing.code, closing.reason);
  }

  /** Closes the websocket with a code and reason; `close` then runs `cleanup`. */
  private finish(ws: Socket, code: number, reason: string): void {
    const data = ws.data;
    if (data.phase === "closed") return;
    data.admission.stopWaiting();
    clearTimeout(data.holdTimer);
    clearTimeout(data.recheckTimer);
    // Nothing more goes to the terminal or from it once the websocket is closing.
    const wasHolding = data.phase === "holding";
    data.phase = "closed";
    if (wasHolding) data.held = [];
    try { ws.close(code, reason); } catch { /* already closed */ }
  }

  /** The websocket is gone: closing the pseudo-terminal ends only the phone's zmx client, and the session keeps its label. */
  private cleanup(ws: Socket): void {
    const data = ws.data;
    data.phase = "closed";
    data.admission.stopWaiting();
    clearTimeout(data.holdTimer);
    clearTimeout(data.recheckTimer);
    data.held = [];
    data.pane?.close();
    data.pane = null;
    const process = data.process;
    if (process) {
      try { process.terminal?.close(); } catch { /* closed already */ }
      const timer = setTimeout(() => { if (process.exitCode === null) process.kill(); }, killAfterMs);
      void process.exited.then(() => clearTimeout(timer));
    }
    data.admission.giveBack();
  }
}

/** One input message is at most `inputLimit` characters, which can be four bytes each, and JSON around them. */
export const inputLimitBytes = inputLimit * 4 + 1024;
