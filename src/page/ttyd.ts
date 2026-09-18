// ttyd 1.7.7's client protocol, as functions over bytes. The page speaks this
// itself because it owns the terminal widget now (ADR-0002, amended); nothing
// here touches a socket or a terminal, so it is all testable as data.

const encoder = new TextEncoder();

/** ttyd's one-byte command prefixes, its own names for them kept. */
const INPUT = "0";
const RESIZE_TERMINAL = "1";
const PAUSE = "2";
const RESUME = "3";

/** The ttyd URL the Snapshot carries, as the websocket ttyd serves beside it. */
export function socketUrl(terminalUrl: string): string {
  const url = new URL("/ws", terminalUrl);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  return url.href;
}

// The handshake has no command prefix: it is the one frame ttyd reads as JSON.
// ttyd here is started with no credential, so the token is empty and there is
// nothing to fetch from /token first.
export function handshake(columns: number, rows: number): Uint8Array {
  return encoder.encode(JSON.stringify({ AuthToken: "", columns, rows }));
}

export function input(data: string): Uint8Array {
  return encoder.encode(INPUT + data);
}

export function resize(columns: number, rows: number): Uint8Array {
  return encoder.encode(RESIZE_TERMINAL + JSON.stringify({ columns, rows }));
}

export function pause(): Uint8Array {
  return encoder.encode(PAUSE);
}

export function resume(): Uint8Array {
  return encoder.encode(RESUME);
}

const OUTPUT = "0";

/**
 * A decoder for one socket's server frames: the text of an output frame, and
 * the empty string for a title or a preferences frame. One TextDecoder is kept
 * across frames because ttyd splits its output on byte boundaries, so a
 * multibyte character arrives in two.
 */
export function outputDecoder(): (frame: Uint8Array) => string {
  const decoder = new TextDecoder();
  return (frame) => {
    if (String.fromCharCode(frame[0]) !== OUTPUT) return "";
    return decoder.decode(frame.subarray(1), { stream: true });
  };
}

// ttyd's own flow-control numbers: it only starts counting writes once a burst
// has passed a byte limit, then stops the far end when too many writes are
// still unrendered and starts it again when the terminal has caught up.
const LIMIT = 100_000;
const HIGH_WATER = 10;
const LOW_WATER = 4;

export interface FlowControl {
  /**
   * Bytes about to be written to the terminal: `counted` says the caller must
   * report the write landing with `written()`, `pause` that ttyd should stop.
   */
  writing(bytes: number): { counted: boolean; pause: boolean };
  /** A counted write has landed; `resume` says ttyd should start again. */
  written(): { resume: boolean };
}

export function flowControl(): FlowControl {
  let unlimited = 0;
  let pending = 0;
  let paused = false;
  return {
    writing(bytes) {
      unlimited += bytes;
      if (unlimited <= LIMIT) return { counted: false, pause: false };
      unlimited = 0;
      pending++;
      const pause = !paused && pending > HIGH_WATER;
      if (pause) paused = true;
      return { counted: true, pause };
    },
    written() {
      pending = Math.max(pending - 1, 0);
      const resume = paused && pending < LOW_WATER;
      if (resume) paused = false;
      return { resume };
    },
  };
}
