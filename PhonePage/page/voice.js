// Voice mode (option 05 of phone-page-is-only-a-browser-tab): talk to the host's voice session. One microphone stream for the whole mode, read by a worklet
// into 16 kHz blocks, cut into segments at each pause and sent; the host collects them into a request that ends only at "over" (the mechanism is in
// docs/agents/where-it-breaks.md, Voice mode on the phone). The page polls the segments it sent, shows the request so far, and plays the reply.
//
// Kept alive by a quiet tone for as long as the mode runs, because a page that is hidden and silent is frozen by Chrome within about a minute, and a
// page that plays audio is not (the spike, 2026-10-16). The screen is kept on while the page is shown. If the page is frozen anyway, the next resume
// reconnects the microphone and says so. Nothing is kept: the exchange lives in this view and goes with it.
// Everything the host sent goes in with textContent, never as markup.

import { element, getJSON, postJSON } from "/dom.js";
import {
  applyEvents, DeadMic, Endpointer, fromBase64, hint, minSpeechMs, newView, pauseNote, preRollMs, Segments, serial, settled, shortSpeechMs, stateLine, Utterance,
} from "/voicerules.js";

const $ = (id) => document.getElementById(id);

/** The open Voice mode, or null. One at a time. */
let current = null;

const blockMs = 100;
/** The mic is ignored this long after a reply ends, for the room's echo of it. */
const echoTailMs = 500;
/** The tone: quiet and low, looping for as long as the mode runs. */
const toneHz = 220;
const toneGain = 0.02;
/** The tone has been sounding this long before the microphone is listened to, so the room it is measured in includes the tone. */
const toneSettleMs = 700;
const pollMs = 1000;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function openVoice({ host, done, openSession }) {
  closeVoice();
  current = {
    host, done, openSession, closed: false, running: false, view: newView(), note: "",
    ctx: null, stream: null, node: null, osc: null, lock: null, held: false,
    endpoint: new Endpointer(), dead: new DeadMic(), ring: [], utt: null, lastBlock: 0, ignoreUntil: 0, frozenAt: 0, noted: 0,
    // One Voice mode run (its id goes with every segment), the segments sent and not yet answered, and the one line their chunks are sent in.
    run: null, segments: new Segments(), send: serial(), polling: false, releaseTimer: null,
  };
  const v = current;
  $("voice").hidden = false;
  $("voice-host").textContent = host;
  $("voice-log").replaceChildren();
  $("voice-start").onclick = () => void start(v);
  $("voice-end").onclick = () => end(v);
  $("voice-back").onclick = () => end(v);
  $("voice-open").onclick = () => { if (v.view.session) v.openSession(v.view.session); };
  v.onVisibility = () => { if (document.visibilityState === "visible") { void wake(v); void ensureLive(v); } };
  v.onFreeze = () => { v.frozenAt = Date.now(); };
  v.onResume = () => afterPause(v, v.frozenAt ? Date.now() - v.frozenAt : 0);
  document.addEventListener("visibilitychange", v.onVisibility);
  document.addEventListener("freeze", v.onFreeze);
  document.addEventListener("resume", v.onResume);
  render(v);
}

export function closeVoice() {
  const v = current;
  if (!v) return;
  current = null;
  v.closed = true;
  document.removeEventListener("visibilitychange", v.onVisibility);
  document.removeEventListener("freeze", v.onFreeze);
  document.removeEventListener("resume", v.onResume);
  clearTimeout(v.releaseTimer);
  stopAudio(v);
  void v.lock?.release().catch(() => {});
  v.lock = null;
  clearMediaSession();
  // The exchange goes with the view.
  $("voice-log").replaceChildren();
  $("voice").hidden = true;
}

/** Leaves Voice mode for the home; `text` is what the home then says. */
function end(v, text) {
  if (current !== v) return;
  v.done(text);
}

// ---------------------------------------------------------------------------------------------------------------
// What is shown

function render(v) {
  const log = $("voice-log");
  const lines = v.view.exchange.map((line) => element("p", `voice-line ${line.who}`, line.text));
  // The request so far, still being built: it becomes a line of the exchange when the Mac has it whole.
  if (v.view.pending) lines.push(element("p", "voice-line you building", v.view.pending));
  log.replaceChildren(...lines);
  log.scrollTop = log.scrollHeight;
  $("voice-state").textContent = stateLine[v.view.state];
  $("voice-start").hidden = v.running;
  $("voice-end").hidden = !v.running;
  $("voice-open").hidden = v.view.session === null || v.view.state !== "needsYou";
  $("voice-notice").textContent = v.note;
  $("voice-notice").hidden = v.note === "";
}

function setState(v, state) {
  v.view = { ...v.view, state };
  render(v);
}

function say(v, text) {
  v.note = text;
  render(v);
}

// ---------------------------------------------------------------------------------------------------------------
// The microphone, the tone, the screen

async function start(v) {
  if (v.running) return;
  $("voice-start").disabled = true;
  say(v, "");
  // Each Start is a run of its own: the Mac drops what the last one left unfinished.
  v.run = crypto.randomUUID();
  try {
    await bring(v);
  } catch (error) {
    $("voice-start").disabled = false;
    stopAudio(v);
    return say(v, micError(error));
  }
  $("voice-start").disabled = false;
  if (v.closed) return stopAudio(v);
  v.running = true;
  await wake(v);
  mediaSession(v);
  setState(v, "listening");
}

function micError(error) {
  const name = error?.name ?? "";
  if (name === "NotAllowedError" || name === "SecurityError") return "The microphone is blocked. Allow it for this page in the browser's site settings, then tap Start.";
  if (name === "NotFoundError") return "This phone has no microphone to use.";
  if (name === "NotReadableError") return "Another app is using the microphone.";
  return "Voice mode couldn't start the microphone.";
}

/** The audio graph: the context, the microphone stream, the worklet that reads it, and the tone. Built again where a part has gone. */
async function bring(v) {
  if (!v.ctx || v.ctx.state === "closed") {
    // Asked for 16 kHz so the browser resamples; the worklet averages down from whatever it got.
    try { v.ctx = new AudioContext({ sampleRate: 16000, latencyHint: "interactive" }); } catch { v.ctx = new AudioContext(); }
    v.node = null;
    v.osc = null;
    await v.ctx.audioWorklet.addModule("/voice-worklet.js");
  }
  if (v.ctx.state !== "running") await v.ctx.resume();
  const live = v.stream?.getAudioTracks()[0];
  if (!live || live.readyState !== "live") {
    v.node?.disconnect();
    v.node = null;
    v.stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
  }
  if (!v.node) {
    const track = v.stream.getAudioTracks()[0];
    track.onended = () => { if (!v.closed) void ensureLive(v); };
    v.node = new AudioWorkletNode(v.ctx, "voice-capture");
    v.node.port.onmessage = (event) => onBlock(v, event.data);
    const silent = v.ctx.createGain();
    silent.gain.value = 0;
    // The worklet is pulled only when it reaches the destination: through a gain of zero, which is silent.
    v.ctx.createMediaStreamSource(v.stream).connect(v.node);
    v.node.connect(silent).connect(v.ctx.destination);
  }
  if (!v.osc) startTone(v);
}

function startTone(v) {
  const gain = v.ctx.createGain();
  gain.gain.value = toneGain;
  v.osc = v.ctx.createOscillator();
  v.osc.frequency.value = toneHz;
  v.osc.connect(gain).connect(v.ctx.destination);
  v.osc.onended = () => { v.osc = null; };
  v.osc.start();
  // What the microphone hears of the tone is part of the room, so the room is measured after it has begun.
  v.ignoreUntil = Math.max(v.ignoreUntil, Date.now() + toneSettleMs);
}

function stopAudio(v) {
  try { v.osc?.stop(); } catch { /* already stopped */ }
  v.osc = null;
  v.node?.disconnect();
  v.node = null;
  v.stream?.getTracks().forEach((track) => track.stop());
  v.stream = null;
  void v.ctx?.close().catch(() => {});
  v.ctx = null;
}

/** Whatever the page lost while hidden or frozen: the context, the microphone, the tone. */
async function ensureLive(v) {
  if (!v.running || v.closed) return;
  try {
    await bring(v);
  } catch (error) {
    say(v, micError(error));
  }
}

/** The screen stays on while the page is shown; the browser lets it go when the page is hidden, and it is asked for again when it is shown. */
async function wake(v) {
  if (v.closed || v.lock || !("wakeLock" in navigator) || document.visibilityState !== "visible") return;
  try {
    const lock = await navigator.wakeLock.request("screen");
    lock.addEventListener("release", () => { if (v.lock === lock) v.lock = null; });
    v.lock = lock;
  } catch { /* the screen may sleep */ }
}

function mediaSession(v) {
  if (!("mediaSession" in navigator)) return;
  try {
    navigator.mediaSession.metadata = new MediaMetadata({ title: "Voice mode", artist: v.host });
    for (const action of ["pause", "stop"]) navigator.mediaSession.setActionHandler(action, () => end(v));
  } catch { /* controls are a convenience */ }
}

function clearMediaSession() {
  if (!("mediaSession" in navigator)) return;
  try {
    navigator.mediaSession.metadata = null;
    for (const action of ["pause", "stop"]) navigator.mediaSession.setActionHandler(action, null);
  } catch { /* nothing set */ }
}

/** Back from a freeze, or a long gap between the microphone's blocks: what was heard before is dropped, and the audio is brought back. */
function afterPause(v, gapMs) {
  if (v.closed || !v.running) return;
  const now = Date.now();
  // The blocks that queued while the page was paused arrive at once: they are old.
  v.ignoreUntil = now + 500;
  v.utt = null;
  v.ring = [];
  v.endpoint.reset();
  v.dead.reset();
  v.frozenAt = 0;
  if (now - v.noted > 2000) {
    v.noted = now;
    say(v, pauseNote(gapMs) ?? "The page was paused. Voice mode reconnected.");
  }
  void wake(v);
  void ensureLive(v);
}

// ---------------------------------------------------------------------------------------------------------------
// A segment: where it ends, and sending it

function onBlock(v, { pcm, rms }) {
  if (v.closed) return;
  const now = Date.now();
  if (v.lastBlock !== 0 && now - v.lastBlock >= 5000) afterPause(v, now - v.lastBlock);
  v.lastBlock = now;
  if (now < v.ignoreUntil) return;
  // A microphone that reads live and delivers digital silence is muted by the system: the mode can't do its work, and says so.
  if (!v.held && v.dead.feed(rms, blockMs)) return end(v, "The microphone went silent, so Voice mode ended. Another app or the phone may have taken it.");
  if (v.held) {
    v.ring = [];
    v.utt = null;
    v.endpoint.reset();
    return;
  }
  // "Over" said alone is short: while a request is being collected, or a segment of it is out, a short sound counts.
  v.endpoint.minSpeech = v.view.pending || v.segments.size > 0 ? shortSpeechMs : minSpeechMs;
  switch (v.endpoint.feed(rms, blockMs)) {
    case "idle":
      v.ring.push(pcm);
      if (v.ring.length > preRollMs / blockMs) v.ring.shift();
      break;
    case "pending":
      if (!v.utt) v.utt = newUtterance(v, v.ring.splice(0));
      v.utt.add(pcm);
      break;
    case "begin":
      if (!v.utt) break;
      v.utt.add(pcm);
      v.utt.begin();
      v.note = "";
      setState(v, "hearing");
      break;
    case "speech":
      v.utt?.add(pcm);
      break;
    case "end": {
      const utt = v.utt;
      v.utt = null;
      if (!utt) break;
      utt.add(pcm);
      void finish(v, utt);
      break;
    }
    case "drop":
    case "abort":
      // A sound too short to be a segment, or one that never let up (the room): whatever was sent of it is left to the host to drop.
      v.utt = null;
      v.ring = [];
      if (v.view.state === "hearing") setState(v, settled(v.view));
      break;
  }
}

/** A segment for the host: each chunk is a POST, in the one order every segment's chunks go in, and the first the host refuses is shown at once. */
function newUtterance(v, preRoll) {
  const post = (body) => postJSON("/api/voice/audio", { ...body, run: v.run, ...hint() }, "The host didn't answer.");
  return new Utterance(crypto.randomUUID(), post, preRoll, (error) => {
    if (v.closed) return;
    v.view = { ...v.view, exchange: [...v.view.exchange, { who: "note", text: error }] };
    if (v.view.state === "hearing" || v.view.state === "sending") v.view.state = settled(v.view);
    render(v);
  }, v.send);
}

/**
 * A segment ended: the rest goes, and unless a chunk failed the page follows what becomes of it. The microphone stays live, so words said right after a
 * pause are the next segment's; it is held only once the host has taken the request (`hear`).
 */
async function finish(v, utt) {
  if (!utt.followable) return;
  if (v.view.state === "hearing") setState(v, "sending");
  const failed = await utt.finish();
  if (v.closed) return;
  // A chunk that failed was shown when it did (`newUtterance`).
  if (failed !== null) return;
  v.segments.add(utt.id);
  void follow(v);
}

/** The mic is held until the reply has played and a moment more, but not past a request taken in the meantime. */
function releaseHold(v, after) {
  clearTimeout(v.releaseTimer);
  v.releaseTimer = setTimeout(() => { if (!v.closed) v.held = false; }, after);
}

// ---------------------------------------------------------------------------------------------------------------
// What the host says, and the reply

/** Polls every segment sent and not yet answered, once a second, until none is left. One poll at a time, so a device's two relays are a chunk and a poll. */
async function follow(v) {
  if (v.polling) return;
  v.polling = true;
  try {
    while (!v.closed && v.segments.size > 0) {
      const started = Date.now();
      const replies = new Map();
      for (const id of v.segments.order()) {
        const reply = await getJSON(`/api/voice/status?id=${id}&after=${v.segments.after(id)}`);
        if (v.closed) return;
        replies.set(id, reply);
      }
      for (const news of v.segments.settle(replies)) {
        await hear(v, news);
        if (v.closed) return;
      }
      if (v.segments.size > 0) await sleep(Math.max(0, pollMs - (Date.now() - started)));
    }
  } finally {
    v.polling = false;
  }
}

/** What the host said of one segment: the request so far, or the request whole and then its answer. */
async function hear(v, news) {
  const taken = news.events.some((event) => event.kind === "heard");
  const asking = taken || v.view.asking === news.id;
  if (taken) {
    // The request is taken. Whatever is being said now is Varnick's to answer, not the next request: the mic is held until the reply has played.
    clearTimeout(v.releaseTimer);
    v.held = true;
    v.utt = null;
    v.ring = [];
    v.endpoint.reset();
  }
  if (news.lost !== null) {
    v.view = { ...v.view, exchange: [...v.view.exchange, { who: "note", text: news.lost }] };
    if (asking) v.view = { ...v.view, asking: null, state: settled(v.view) };
    render(v);
    if (asking) releaseHold(v, 0);
    return;
  }
  v.view = applyEvents(v.view, news.events, news.id);
  const sound = v.view.play;
  v.view = { ...v.view, play: null };
  render(v);
  if (sound) await play(v, sound);
  if (v.closed || !news.done || !asking) return;
  // A reply that played leaves the page listening; a question for the user, or a request that went past the deadline, keeps its line.
  if (v.view.state === "speaking") setState(v, settled(v.view));
  releaseHold(v, echoTailMs);
}

/** Plays the reply's WAV (base64) through the context that already runs, so it needs no new permission and the tone goes on under it. */
async function play(v, base64) {
  try {
    if (v.ctx.state !== "running") await v.ctx.resume();
    const bytes = fromBase64(base64);
    const buffer = await v.ctx.decodeAudioData(bytes.buffer);
    const source = v.ctx.createBufferSource();
    source.buffer = buffer;
    source.connect(v.ctx.destination);
    await new Promise((resolve) => {
      source.onended = resolve;
      source.start();
    });
  } catch {
    say(v, "The reply's voice couldn't play. Its words are above.");
  }
}
