// Voice mode's rules that need no DOM or audio (option 05 of phone-page-is-only-a-browser-tab): where a request ends, how it is cut into chunks, and what
// the host's events make of the view. Tested by `bun test` (voice.test.ts).

/** What the page sends: 16 kHz, 16-bit mono (`VoiceAudio.uploadRate`). */
export const uploadRate = 16000;
/** A chunk is a second of audio; the host takes up to 1.5 s (`VoiceAudio.maxChunkBytes`). */
export const chunkSamples = 16000;
/** The longest request the host takes: 30 s (`VoiceAudio.maxUtteranceBytes`), counting the pre-roll and the closing chunk. */
export const maxUtteranceMs = 30000;

// ---------------------------------------------------------------------------------------------------------------
// Where a request ends

/** Named, so a hand test can tune them. A request ends after this much quiet once it has begun. */
export const silenceMs = 900;
/** Speech must last this long, in all, to be a request and not a click or a cough. */
export const minSpeechMs = 300;
/** Audio kept from before speech was heard, so the first word isn't clipped. */
export const preRollMs = 300;
/** A request ends here, so that with its pre-roll and its last chunk (10 ms) it is under what the host takes. */
export const requestCapMs = maxUtteranceMs - preRollMs - 100;
/** Sound that stays above the threshold this long without a quiet frame is not speech (a television, a fan that stepped up): the floor rises over it. */
export const noiseRunMs = 10000;
/** Speech is a level above the noise floor times this, and never below the lowest. */
export const floorTimes = 3;
export const lowestThreshold = 0.015;
/** How fast the noise floor follows the level while no one speaks (0 to 1 per frame). */
const floorFollows = 0.05;
/** The first frames only measure the room: the floor starts as the quietest of them, so a steady sound (the keep-alive tone, a fan) is never speech. */
export const calibrationFrames = 5;

/**
 * Decides, a frame at a time, where a request begins and ends. `feed(rms, ms)` takes a frame's level and length and answers:
 *   "idle"    nothing heard
 *   "pending" a sound that may be speech, not yet long enough
 *   "begin"   it was long enough: the request has begun (the page starts sending)
 *   "speech"  the request goes on
 *   "end"     the request ended after `silenceMs` of quiet, or at `requestCapMs`
 *   "drop"    the sound ended before it was long enough: nothing was sent
 *   "abort"   the sound never let up for `noiseRunMs`, so it was the room and not a person: whatever was sent is abandoned
 * The threshold follows the room: three times the level of the quiet, and never below `lowestThreshold`, so the keep-alive tone a speaker lets the
 * microphone hear doesn't begin a request. The first `calibrationFrames` only measure it, and an "abort" raises it to the sound's lowest level, so a room
 * that got louder is learned in one go.
 */
export class Endpointer {
  constructor() {
    this.floor = 0;
    this.measuring = calibrationFrames;
    this.quietest = Infinity;
    this.reset();
  }

  reset() {
    this.state = "idle";
    this.speechMs = 0;
    this.quietMs = 0;
    this.totalMs = 0;
    this.runMs = 0;
    this.runMin = Infinity;
  }

  get threshold() {
    return Math.max(lowestThreshold, this.floor * floorTimes);
  }

  feed(rms, ms) {
    if (this.measuring > 0) {
      this.quietest = Math.min(this.quietest, rms);
      if (--this.measuring === 0) this.floor = this.quietest;
      return "idle";
    }
    const loud = rms >= this.threshold;
    if (this.state === "idle") {
      if (!loud) {
        this.floor += (rms - this.floor) * floorFollows;
        return "idle";
      }
      this.state = "pending";
      this.speechMs = ms;
      this.quietMs = 0;
      this.totalMs = ms;
      this.runMs = ms;
      this.runMin = rms;
      return this.confirm();
    }
    this.totalMs += ms;
    if (loud) {
      this.speechMs += ms;
      this.quietMs = 0;
      this.runMs += ms;
      this.runMin = Math.min(this.runMin, rms);
    } else {
      this.quietMs += ms;
      this.runMs = 0;
      this.runMin = Infinity;
    }
    if (this.runMs >= noiseRunMs) {
      this.floor = Math.max(this.floor, this.runMin);
      this.reset();
      return "abort";
    }
    if (this.state === "pending") {
      if (this.quietMs >= silenceMs) {
        this.reset();
        return "drop";
      }
      return this.confirm();
    }
    if (this.quietMs >= silenceMs || this.totalMs >= requestCapMs) {
      this.reset();
      return "end";
    }
    return "speech";
  }

  confirm() {
    if (this.speechMs < minSpeechMs) return "pending";
    this.state = "speaking";
    return "begin";
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Chunks

/** The audio cut into pieces of at most `size` samples. */
export function cut(samples, size = chunkSamples) {
  const pieces = [];
  for (let start = 0; start < samples.length; start += size) pieces.push(samples.subarray(start, Math.min(start + size, samples.length)));
  return pieces;
}

/** 16-bit samples as base64 of their little-endian bytes. */
export function toBase64(samples) {
  const bytes = new Uint8Array(samples.length * 2);
  for (let i = 0; i < samples.length; i++) {
    bytes[2 * i] = samples[i] & 0xff;
    bytes[2 * i + 1] = (samples[i] >> 8) & 0xff;
  }
  let text = "";
  for (let i = 0; i < bytes.length; i += 0x2000) text += String.fromCharCode(...bytes.subarray(i, i + 0x2000));
  return btoa(text);
}

/** Base64 into bytes. */
export function fromBase64(text) {
  const raw = atob(text);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

// ---------------------------------------------------------------------------------------------------------------
// A microphone that reads live and delivers nothing

/** A live track that gives exact zeros this long is muted or silenced by the system: a quiet room still gives about 1e-5 (the spike, 2026-10-16). */
export const deadMicMs = 5000;

/** Feed it each block's level while the page is capturing; it says when the microphone has been digitally silent long enough to give up on. */
export class DeadMic {
  constructor() {
    this.zeroMs = 0;
  }

  feed(rms, ms) {
    this.zeroMs = rms === 0 ? this.zeroMs + ms : 0;
    return this.zeroMs >= deadMicMs;
  }

  reset() {
    this.zeroMs = 0;
  }
}

// ---------------------------------------------------------------------------------------------------------------
// One request on its way to the host

/**
 * A request being sent: blocks are added as they are heard, a chunk goes to the host as soon as a second of it has gathered (after `begin`), and
 * `finish` sends the rest and a last chunk. `post(body)` sends one chunk and answers `{ok, error?}`; the chunks go one after another, in order. The first
 * chunk the host refuses (or that fails) marks the request `failed` with the reason, calls `onFail` once, and stops everything after it, so a request
 * never waits for an answer that a refused one will not give.
 */
export class Utterance {
  constructor(id, post, preRoll = [], onFail = () => {}) {
    this.id = id;
    this.post = post;
    this.onFail = onFail;
    this.blocks = [];
    this.count = 0;
    this.seq = 0;
    this.begun = false;
    this.failed = null;
    this.chain = Promise.resolve();
    for (const block of preRoll) this.add(block);
  }

  add(block) {
    this.blocks.push(block);
    this.count += block.length;
    if (this.begun) this.pump();
  }

  /** The request is long enough to be one: what has gathered starts going. */
  begin() {
    this.begun = true;
    this.pump();
  }

  /** Whether the page should now wait for the host's answer, with the microphone held: the request is a request and nothing in it failed. */
  get awaitsAnswer() {
    return this.begun && this.failed === null;
  }

  pump() {
    while (this.count >= chunkSamples) this.send(this.take(chunkSamples), false);
  }

  /** The first `count` samples of the queue (all of them for Infinity), as one array. */
  take(count) {
    const parts = [];
    let need = count;
    while (this.blocks.length > 0 && need > 0) {
      const block = this.blocks[0];
      if (block.length <= need) {
        parts.push(block);
        this.blocks.shift();
        need -= block.length;
      } else {
        parts.push(block.subarray(0, need));
        this.blocks[0] = block.subarray(need);
        need = 0;
      }
    }
    const out = new Int16Array(parts.reduce((total, part) => total + part.length, 0));
    let at = 0;
    for (const part of parts) {
      out.set(part, at);
      at += part.length;
    }
    this.count -= out.length;
    return out;
  }

  send(samples, last) {
    const seq = this.seq++;
    this.chain = this.chain.then(async () => {
      if (this.failed !== null) return;
      const result = await this.post({ id: this.id, seq, last, audio: toBase64(samples) });
      if (result.ok || this.failed !== null) return;
      this.failed = result.error ?? "The host didn't take that.";
      this.onFail(this.failed);
    });
  }

  /** Sends the rest and a last chunk (the host wants audio in it: 10 ms of quiet). Resolves once every chunk is sent: null, or the reason one failed. */
  finish() {
    for (const piece of cut(this.take(Infinity))) this.send(piece, false);
    this.send(new Int16Array(160), true);
    return this.chain.then(() => this.failed);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// What the host's events make of the view

/** What the state line says, by state. */
export const stateLine = {
  idle: "Tap Start to talk",
  listening: "Listening",
  hearing: "Listening…",
  sending: "Sent",
  working: "Working…",
  lookingUp: "Searching the web…",
  speaking: "Speaking",
  needsYou: "Claude needs your OK",
  slow: "That's taking a while. Check the Mac.",
  error: "Something went wrong",
};

export function newView() {
  return { state: "idle", exchange: [], session: null, play: null, done: false };
}

/**
 * The view after the host's events (`voiceStatus`), in order. The exchange is what is shown: the user's request as the Mac heard it, and Varnick's
 * answer as text. `play` is the answer's audio (base64 WAV) to play, once; the page clears it when it starts. `done` says the ask is over; a
 * state that follows (speaking, then listening) is the page's. Never kept past the view.
 */
export function applyEvents(view, events) {
  let next = { ...view, exchange: [...view.exchange] };
  for (const event of events) {
    switch (event.kind) {
      case "heard":
        next.exchange.push({ who: "you", text: event.text ?? "" });
        break;
      // The voice session says nothing when it takes a request or goes to the web (2026-10-17): the state line shows it, the exchange does not.
      case "taken":
        next.state = "working";
        break;
      case "lookingUp":
        next.state = "lookingUp";
        break;
      case "needsYou":
        next.state = "needsYou";
        next.session = event.session ?? null;
        next.done = true;
        break;
      case "answered":
        next.exchange.push({ who: "varnick", text: event.text ?? event.spoken ?? "" });
        next.play = event.audio ?? null;
        next.state = event.audio ? "speaking" : "listening";
        next.done = true;
        break;
      case "noAnswer":
        next.exchange.push({ who: "varnick", text: "I couldn't answer that." });
        next.state = "listening";
        next.done = true;
        break;
      case "failed":
        next.exchange.push({ who: "note", text: event.text ?? "That didn't work." });
        next.state = "listening";
        next.done = true;
        break;
      case "deadline":
        next.state = "slow";
        next.done = true;
        break;
    }
  }
  return next;
}

/** A pause the page can tell of: no frame from the microphone for this long means it was frozen or throttled. */
export const pauseMs = 5000;

/** What the page says when it comes back from a pause, or null for a gap that isn't one. */
export function pauseNote(gapMs) {
  if (gapMs < pauseMs) return null;
  const seconds = Math.round(gapMs / 1000);
  return `The page was paused for ${seconds >= 120 ? `${Math.round(seconds / 60)} minutes` : `${seconds} seconds`}. Voice mode reconnected.`;
}

/** The request's moment, zone and units, for the voice hint (the host takes its own for a missing one). */
export function hint(now = new Date(), locale = navigator.language, zone = Intl.DateTimeFormat().resolvedOptions().timeZone) {
  const us = /^en-(US|LR|MM)$/i.test(locale ?? "");
  return { moment: Math.floor(now.getTime() / 1000), zone, units: us ? "us" : "metric" };
}
