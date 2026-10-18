// Voice mode on the phone (option 05 of phone-page-is-only-a-browser-tab, protocol 30): what a browser may send the three voice routes, how each is put into
// the relay's request, and what of the host's reply the page is shown. No I/O, so `bun test` runs it. The rules each request is held to are in
// docs/agents/where-it-breaks.md › Voice mode on the phone.
//
//   POST /api/voice/audio   one chunk of a segment (16 kHz 16-bit mono, base64), in order        -> relay `voiceAudio`
//   POST /api/voice/ask     the request as text                                                  -> relay `voiceAsk`
//   GET  /api/voice/status  the ask's events after the ones the page has                         -> relay `voiceStatus`
//
// A segment is what the page heard between two pauses (a request ends only when the user says "over", protocol 31): its id is the page's own (a uuid), so
// a chunk and the polls of the same segment share it, and every segment carries the id of the Voice mode run it belongs to. Nothing a request holds
// (audio, words, an answer) is logged: the server's access line is the method, the path, the status, the device and the time.

import { isObject, uuidPattern, type Json } from "./json";
import type { RelayResult } from "./home";
import { uploadRate } from "./page/voicerules.js";

type Parsed<Value> = { ok: true; value: Value } | { ok: false; error: string };
const refuse = (error: string): { ok: false; error: string } => ({ ok: false, error });

/** The largest chunk the host takes (`VoiceAudio.maxChunkBytes`: 1.5 s), as bytes and as base64 text. */
export const maxChunkBytes = 48_000;
export const maxChunkText = Math.ceil(maxChunkBytes / 3) * 4;
/** The most chunks of one utterance: 30 s of 1 s chunks, with room. */
export const maxChunks = 60;
/** The most of a typed request: `VoiceSession.maxRequestCharacters`, with room for what is cut. */
const maxText = 600;
const zonePattern = /^[A-Za-z0-9_+\-/]{1,64}$/;
const base64Pattern = /^[A-Za-z0-9+/]*={0,2}$/;

export type VoiceUnits = "us" | "metric";

/** The asker's moment, time zone and units, each optional: the host uses its own for one missing or unreadable. */
interface Hint {
  moment?: number;
  zone?: string;
  units?: VoiceUnits;
}

function parseHint(body: Json): Parsed<Hint> {
  const hint: Hint = {};
  if (body.moment !== undefined && body.moment !== null) {
    if (typeof body.moment !== "number" || !Number.isFinite(body.moment) || body.moment < 0 || body.moment > 4_000_000_000) return refuse("That isn't a time");
    hint.moment = Math.round(body.moment);
  }
  if (body.zone !== undefined && body.zone !== null) {
    if (typeof body.zone !== "string" || !zonePattern.test(body.zone)) return refuse("That isn't a time zone");
    hint.zone = body.zone;
  }
  if (body.units !== undefined && body.units !== null) {
    if (body.units !== "us" && body.units !== "metric") return refuse("Units are us or metric");
    hint.units = body.units;
  }
  return { ok: true, value: hint };
}

const parseID = (value: unknown): string | null => (typeof value === "string" && uuidPattern.test(value) ? value.toLowerCase() : null);

export interface AudioChunk extends Hint {
  id: string;
  /** The Voice mode run: segments of one run, from one device, make one request. */
  mode: string;
  seq: number;
  last: boolean;
  audio: string;
}

/** `POST /api/voice/audio`'s body: `id`, `mode`, `seq`, `last`, `audio` (base64 of the chunk) and the hint, which the last chunk carries. Nothing else is read. */
export function parseAudioBody(body: unknown): Parsed<AudioChunk> {
  if (!isObject(body)) return refuse("The request wasn't a JSON object");
  const id = parseID(body.id);
  if (id === null) return refuse("That isn't a request id");
  const mode = parseID(body.mode);
  if (mode === null) return refuse("A chunk names its Voice mode run");
  if (typeof body.seq !== "number" || !Number.isInteger(body.seq) || body.seq < 0 || body.seq >= maxChunks) return refuse("That isn't a chunk number");
  if (typeof body.last !== "boolean") return refuse("A chunk says whether it is the last");
  if (typeof body.audio !== "string" || body.audio.length === 0 || body.audio.length > maxChunkText || !base64Pattern.test(body.audio)) {
    return refuse("The audio isn't a chunk the host takes");
  }
  const hint = parseHint(body);
  if (!hint.ok) return hint;
  return { ok: true, value: { id, mode, seq: body.seq, last: body.last, audio: body.audio, ...hint.value } };
}

export interface TextAsk extends Hint {
  id: string;
  text: string;
}

/** `POST /api/voice/ask`'s body: `id`, `text` and the hint. */
export function parseAskBody(body: unknown): Parsed<TextAsk> {
  if (!isObject(body)) return refuse("The request wasn't a JSON object");
  const id = parseID(body.id);
  if (id === null) return refuse("That isn't a request id");
  if (typeof body.text !== "string" || !body.text.isWellFormed() || body.text.trim() === "" || body.text.length > maxText) return refuse("There's nothing to ask, or too much");
  const hint = parseHint(body);
  if (!hint.ok) return hint;
  return { ok: true, value: { id, text: body.text, ...hint.value } };
}

/** `GET /api/voice/status`'s query: the ask's id and how many events the page already has. */
export function parseStatusQuery(query: URLSearchParams): Parsed<{ id: string; after: number }> {
  const id = parseID(query.get("id"));
  if (id === null) return refuse("That isn't a request id");
  const after = query.get("after") ?? "0";
  if (!/^[0-9]{1,4}$/.test(after)) return refuse("That isn't a count");
  return { ok: true, value: { id, after: Number(after) } };
}

/** The `voice` field of a relay request. The rate is the server's: a page can't ask for another. */
export function audioFields(chunk: AudioChunk): { voice: Json } {
  const { id, mode, seq, last, audio, moment, zone, units } = chunk;
  return { voice: { id, mode, seq, last, audio, rate: uploadRate, ...(moment !== undefined && { moment }), ...(zone !== undefined && { zone }), ...(units !== undefined && { units }) } };
}

export function askFields(ask: TextAsk): { voice: Json } {
  const { id, text, moment, zone, units } = ask;
  return { voice: { id, text, ...(moment !== undefined && { moment }), ...(zone !== undefined && { zone }), ...(units !== undefined && { units }) } };
}

export function statusFields(query: { id: string; after: number }): { voice: Json } {
  return { voice: { id: query.id, after: query.after } };
}

// ---------------------------------------------------------------------------------------------------------------
// What the host said, cut down to what the page draws

const kinds = new Set(["heard", "collected", "taken", "lookingUp", "needsYou", "answered", "noAnswer", "failed", "deadline"]);
/** A reply line from the relay is 1,000,000 bytes at most: an answer's audio, as base64, is cut here to what it can carry. */
const audioLimit = 900_000;
const textLimit = 9_000;
const sessionPattern = /^varnick-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export interface VoiceEvent {
  kind: string;
  text?: string;
  spoken?: string;
  audio?: string;
  session?: string;
  failure?: string;
}

function shapeEvent(raw: unknown): VoiceEvent | null {
  if (!isObject(raw) || typeof raw.kind !== "string" || !kinds.has(raw.kind)) return null;
  const event: VoiceEvent = { kind: raw.kind };
  if (typeof raw.text === "string") event.text = raw.text.slice(0, textLimit);
  if (typeof raw.spoken === "string") event.spoken = raw.spoken.slice(0, textLimit);
  if (typeof raw.audio === "string" && raw.audio.length <= audioLimit && base64Pattern.test(raw.audio)) event.audio = raw.audio;
  // A session the page may open: a pane's zmx session name, which is a lowercase uuid after the prefix.
  if (typeof raw.session === "string" && sessionPattern.test(raw.session)) event.session = raw.session;
  if (typeof raw.failure === "string") event.failure = raw.failure.slice(0, 60);
  return event;
}

export type VoiceAnswer =
  | { status: 200; body: { ok: true; id: string; events: VoiceEvent[]; next: number; done: boolean } }
  | { status: number; body: { ok: false; error: string } };

/** An upload's or an ask's reply: taken, or why not. A host before protocol 30 says it doesn't know the request. */
export function shapeTaken(result: RelayResult): { status: 200; body: { ok: true; id: string } } | { status: number; body: { ok: false; error: string } } {
  if (!result.ok) return { status: 502, body: { ok: false, error: result.error } };
  const voice = result.reply.voice;
  const id = isObject(voice) ? parseID(voice.id) : null;
  if (id === null) return { status: 502, body: { ok: false, error: "The host didn't take that" } };
  return { status: 200, body: { ok: true, id } };
}

/** A status reply: the events the host lists, ones this page doesn't know left out, and where to ask next. */
export function shapeStatus(result: RelayResult): VoiceAnswer {
  if (!result.ok) return { status: 502, body: { ok: false, error: result.error } };
  const voice = result.reply.voice;
  const id = isObject(voice) ? parseID(voice.id) : null;
  if (!isObject(voice) || id === null || typeof voice.next !== "number" || !Number.isInteger(voice.next) || voice.next < 0) {
    return { status: 502, body: { ok: false, error: "The host's answer wasn't readable" } };
  }
  const events = (Array.isArray(voice.events) ? voice.events : []).map(shapeEvent).filter((event): event is VoiceEvent => event !== null);
  return { status: 200, body: { ok: true, id, events, next: voice.next, done: voice.done === true } };
}
