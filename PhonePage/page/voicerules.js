// Voice mode's rules that need no DOM or audio (option 05 of phone-page-is-only-a-browser-tab): where a request ends, how it is cut into chunks, and what
// the host's events make of the view. Tested by `bun test` (voice.test.ts).

/** What the page sends: 16 kHz, 16-bit mono (`VoiceAudio.uploadRate`). */
export const uploadRate = 16000;
/** A chunk is a second of audio; the host takes up to 1.5 s (`VoiceAudio.maxChunkBytes`). */
export const chunkSamples = 16000;
/** The longest request: 30 s (`VoiceAudio.maxUtteranceBytes`). */
export const maxUtteranceMs = 30000;

// ---------------------------------------------------------------------------------------------------------------
// Where a request ends

/** Named, so a hand test can tune them. A request ends after this much quiet once it has begun. */
export const silenceMs = 900;
/** Speech must last this long, in all, to be a request and not a click or a cough. */
export const minSpeechMs = 300;
/** Audio kept from before speech was heard, so the first word isn't clipped. */
export const preRollMs = 300;
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
 *   "end"     the request ended after `silenceMs` of quiet, or at `maxUtteranceMs`
 *   "drop"    the sound ended before it was long enough: nothing was sent
 * The threshold follows the room: three times the level of the quiet, and never below `lowestThreshold`, so the keep-alive tone a speaker lets the
 * microphone hear doesn't begin a request. The first `calibrationFrames` only measure it.
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
      return this.confirm();
    }
    this.totalMs += ms;
    if (loud) {
      this.speechMs += ms;
      this.quietMs = 0;
    } else {
      this.quietMs += ms;
    }
    if (this.state === "pending") {
      if (this.quietMs >= silenceMs) {
        this.reset();
        return "drop";
      }
      return this.confirm();
    }
    if (this.quietMs >= silenceMs || this.totalMs >= maxUtteranceMs) {
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
// What the host's events make of the view

/** What the state line says, by state. */
export const stateLine = {
  idle: "Tap Start to talk",
  listening: "Listening",
  hearing: "Listening…",
  sending: "Sent",
  working: "Let me check.",
  lookingUp: "Looking that up.",
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
