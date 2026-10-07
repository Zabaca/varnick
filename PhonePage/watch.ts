// The live screen's decisions, with no I/O: what a watch websocket's first message may ask, how the relay's `watch` stream is read
// (its reply line, then frames cut anywhere), and what a slow phone is sent. watcher.ts does the spawning; everything it decides by
// is here, so `bun test` can check it (ADR 0008, ADR 0011).

import { gridLimits } from "./page/liverules.js";
import { parseReply } from "./relay";
import { isSessionName } from "./terminal";

/** The first message names the session and nothing else: a watch is read-only, so there is no take, no grid and no input. */
export function parseWatchOpen(text: string): { session: string } | null {
  if (text.length > 1024) return null;
  let json: unknown;
  try { json = JSON.parse(text); } catch { return null; }
  if (typeof json !== "object" || json === null || Array.isArray(json)) return null;
  const session = (json as Record<string, unknown>).session;
  return isSessionName(session) ? { session } : null;
}

/** What the relay's `watch` printed, in order: one reply, then frames. */
export type WatchEvent =
  | { kind: "reply"; reply: Record<string, unknown> }
  | { kind: "frame"; cols: number; rows: number; text: string }
  /** A screen past `longestScreen`: its bytes were skipped, and the channel goes on. */
  | { kind: "oversize" };

/** More than this before a reply that parses isn't a greeting (as `WatchChannel.longestGreeting` in the app). */
const longestGreeting = 64 << 10;
/** A header line is `screen <cols> <rows> <bytes>`: `WatchFrames.Decoder.longestHeader`. */
const longestHeader = 64;
/**
 * A screen of more text than this isn't drawn: it is skipped as it arrives and the page is told it is too large. A real screen, with
 * its 500 lines of tail, is some tens of KB. The package's own bound, past which a header is taken for a stream that isn't ours, is 64 MB.
 */
export const longestScreen = 1 << 20;
const longestStreamScreen = 64 << 20;
/**
 * The most one websocket message may be. JSON writes a control character (every escape sequence's ESC) as six bytes, so a
 * screen under `longestScreen` can still be several times that as a message. `Bun.serve` has one `backpressureLimit` for every
 * socket (4 MB, in `socketHandlers`) and closes a socket whose unsent bytes pass it, so a message plus what `sendHighWater`
 * lets wait must stay under that: a message past this is replaced by `tooLargeMessage`.
 */
export const longestMessage = 3 << 20;
export const tooLargeMessage = JSON.stringify({ tooLarge: true });

const newline = 0x0a;

/** A frame's grid as the page may use it: the host's, or `0 0` when the host couldn't read it or it is past what the page draws. */
export function pageGrid(cols: number, rows: number): { cols: number; rows: number } {
  return cols >= 1 && rows >= 1 && cols <= gridLimits.maxCols && rows <= gridLimits.maxRows ? { cols, rows } : { cols: 0, rows: 0 };
}

/**
 * Reads the relay's `watch` stream however it is cut into reads, as `WatchChannel` and `WatchFrames.Decoder` do in the app:
 * lines before the reply are skipped (a shell's greeting), then each frame is a header line `screen <cols> <rows> <bytes>` and
 * exactly that many bytes. A blank line between frames is a keep-alive and says nothing. A header it can't parse, a screen
 * past `longestScreen` or a greeting that never ends is a `failure`, and nothing more is read.
 */
export class WatchDecoder {
  private phase: "reply" | "header" | "body" | "skip" | "done" = "reply";
  private line: number[] = [];
  private chunks: Uint8Array[] = [];
  private have = 0;
  private wanted: { cols: number; rows: number; bytes: number } | null = null;
  private skipped = 0;
  failure: string | null = null;

  feed(bytes: Uint8Array): WatchEvent[] {
    const events: WatchEvent[] = [];
    let index = 0;
    while (index < bytes.length && this.failure === null && this.phase !== "done") {
      if (this.phase === "skip") {
        const drop = Math.min(this.wanted!.bytes - this.have, bytes.length - index);
        this.have += drop;
        index += drop;
        if (this.have === this.wanted!.bytes) {
          this.have = 0;
          this.phase = "header";
        }
        continue;
      }
      if (this.phase === "body") {
        const take = Math.min(this.wanted!.bytes - this.have, bytes.length - index);
        // A copy: the caller's buffer may be reused for the next read.
        this.chunks.push(bytes.slice(index, index + take));
        this.have += take;
        index += take;
        if (this.have === this.wanted!.bytes) {
          events.push(this.frame(Buffer.concat(this.chunks, this.have)));
          this.chunks = [];
          this.have = 0;
          this.phase = "header";
        }
        continue;
      }
      const byte = bytes[index++];
      if (byte !== newline) {
        this.line.push(byte);
        if (this.phase === "header" && this.line.length > longestHeader) this.failure = "A frame header is too long";
        continue;
      }
      const line = Buffer.from(this.line).toString("utf8");
      this.line = [];
      if (this.phase === "reply") {
        const reply = parseReply(line);
        if (reply) {
          events.push({ kind: "reply", reply });
          // A refusal ends the stream; the caller closes. A reply that said no has no frames after it.
          this.phase = reply.ok === true ? "header" : "done";
        } else {
          this.skipped += line.length + 1;
          if (this.skipped > longestGreeting) this.failure = "It sent something that isn't a reply";
        }
        continue;
      }
      if (line === "") continue;
      const fields = line.split(" ");
      const numbers = fields.slice(1).map((field) => (/^[0-9]{1,9}$/.test(field) ? Number(field) : NaN));
      if (fields.length !== 4 || fields[0] !== "screen" || numbers.some(Number.isNaN) || numbers[2] > longestStreamScreen) {
        this.failure = "Not a frame header";
        break;
      }
      this.wanted = { cols: numbers[0], rows: numbers[1], bytes: numbers[2] };
      if (this.wanted.bytes === 0) {
        events.push(this.frame(Buffer.alloc(0)));
      } else if (this.wanted.bytes > longestScreen) {
        events.push({ kind: "oversize" });
        this.phase = "skip";
      } else {
        this.phase = "body";
      }
    }
    // A reply line that never ends is bounded as the greeting is.
    if (this.phase === "reply" && this.line.length > longestGreeting) this.failure = "It sent something that isn't a reply";
    return events;
  }

  private frame(body: Uint8Array): WatchEvent {
    const { cols, rows } = pageGrid(this.wanted!.cols, this.wanted!.rows);
    // Invalid UTF-8 becomes U+FFFD, as the app's `String(decoding:)` does.
    return { kind: "frame", cols, rows, text: new TextDecoder().decode(body) };
  }
}

/** What the websocket carries for an event: a frame (the page reads exactly these three fields), or that the screen is too large to show. */
export function watchMessage(event: { kind: "frame"; cols: number; rows: number; text: string } | { kind: "oversize" }): string {
  if (event.kind === "oversize") return tooLargeMessage;
  const message = JSON.stringify({ cols: event.cols, rows: event.rows, text: event.text });
  return Buffer.byteLength(message) > longestMessage ? tooLargeMessage : message;
}

/**
 * What waits for a phone that can't keep up: only the newest message not yet sent, so a slow connection gets the latest screen
 * when it drains and memory stays at what the socket already holds plus one frame. The relay does the same for its channel
 * (`LatestFrame`).
 */
export class Outbox {
  private pending: string | null = null;
  /** How many screens were replaced before they were sent. */
  dropped = 0;

  /** The message to send now: this one when the socket has room, else null and this one waits (replacing an older one). */
  offer(message: string, buffered: number, limit: number): string | null {
    if (buffered <= limit) {
      if (this.pending !== null) this.dropped += 1;
      this.pending = null;
      return message;
    }
    if (this.pending !== null) this.dropped += 1;
    this.pending = message;
    return null;
  }

  /** The waiting message, once the socket has room again. */
  flush(buffered: number, limit: number): string | null {
    if (this.pending === null || buffered > limit) return null;
    const message = this.pending;
    this.pending = null;
    return message;
  }

  get waiting(): boolean {
    return this.pending !== null;
  }
}
