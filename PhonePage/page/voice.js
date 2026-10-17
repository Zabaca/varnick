// Voice mode (option 05 of phone-page-is-only-a-browser-tab): talk to the host's voice session. One microphone stream for the whole mode, read by a worklet
// into 16 kHz blocks. The page finds where a request ends (voicerules.js `Endpointer`), sends it to the host in chunks, and polls the host for what
// happens: the host's Mac turns the speech into text, asks its voice session and makes the reply's audio, which this page plays. While a request is out
// and its reply plays, the microphone's audio is not sent, so Varnick doesn't hear itself.
//
// Kept alive by a quiet tone for as long as the mode runs, because a page that is hidden and silent is frozen by Chrome within about a minute, and a
// page that plays audio is not (the spike, 2026-10-16). The screen is kept on while the page is shown. If the page is frozen anyway, the next resume
// reconnects the microphone and says so. Nothing is kept: the exchange lives in this view and goes with it.
// Everything the host sent goes in with textContent, never as markup.

import { element, getJSON, postJSON } from "/dom.js";
import { applyEvents, chunkSamples, cut, Endpointer, fromBase64, hint, newView, pauseNote, preRollMs, stateLine, toBase64 } from "/voicerules.js";

const $ = (id) => document.getElementById(id);

/** The open Voice mode, or null. One at a time. */
let current = null;

const blockMs = 100;
/** The mic is ignored this long after a reply ends, for the room's echo of it. */
const echoTailMs = 500;
/** The tone: quiet and low, looping for as long as the mode runs. */
const toneHz = 220;
const toneGain = 0.02;
const pollMs = 1000;
/** Failed polls in a row before the page says it lost the host. */
const pollFailures = 6;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function openVoice({ host, done, openSession }) {
  closeVoice();
  current = {
    host, done, openSession, closed: false, running: false, view: newView(), note: "",
    ctx: null, stream: null, node: null, osc: null, lock: null, held: false, asking: null,
    endpoint: new Endpointer(), ring: [], utt: null, lastBlock: 0, ignoreUntil: 0, frozenAt: 0, noted: 0,
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
  stopAudio(v);
  void v.lock?.release().catch(() => {});
  v.lock = null;
  clearMediaSession();
  // The exchange goes with the view.
  $("voice-log").replaceChildren();
  $("voice").hidden = true;
}

function end(v) {
  if (current !== v) return;
  v.done();
}

// ---------------------------------------------------------------------------------------------------------------
// What is shown

function render(v) {
  const log = $("voice-log");
  log.replaceChildren(...v.view.exchange.map((line) => element("p", `voice-line ${line.who}`, line.text)));
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
  v.frozenAt = 0;
  if (now - v.noted > 2000) {
    v.noted = now;
    say(v, pauseNote(gapMs) ?? "The page was paused. Voice mode reconnected.");
  }
  void wake(v);
  void ensureLive(v);
}

// ---------------------------------------------------------------------------------------------------------------
// A request: where it ends, and sending it

function onBlock(v, { pcm, rms }) {
  if (v.closed) return;
  const now = Date.now();
  if (v.lastBlock !== 0 && now - v.lastBlock >= 5000) afterPause(v, now - v.lastBlock);
  v.lastBlock = now;
  if (now < v.ignoreUntil) return;
  if (v.held) {
    v.ring = [];
    v.endpoint.reset();
    return;
  }
  switch (v.endpoint.feed(rms, blockMs)) {
    case "idle":
      v.ring.push(pcm);
      if (v.ring.length > preRollMs / blockMs) v.ring.shift();
      break;
    case "pending":
      if (!v.utt) v.utt = newUtterance(v.ring.splice(0));
      add(v.utt, pcm);
      break;
    case "begin":
      if (!v.utt) break;
      add(v.utt, pcm);
      v.utt.begun = true;
      v.note = "";
      setState(v, "hearing");
      pump(v, v.utt);
      break;
    case "speech":
      if (!v.utt) break;
      add(v.utt, pcm);
      pump(v, v.utt);
      break;
    case "end": {
      const utt = v.utt;
      v.utt = null;
      if (!utt) break;
      add(utt, pcm);
      finish(v, utt);
      break;
    }
    case "drop":
      v.utt = null;
      break;
  }
}

function newUtterance(preRoll) {
  const utt = { id: crypto.randomUUID(), blocks: [], count: 0, seq: 0, begun: false, failed: false, chain: Promise.resolve() };
  for (const block of preRoll) add(utt, block);
  return utt;
}

function add(utt, block) {
  utt.blocks.push(block);
  utt.count += block.length;
}

/** The first `count` samples of the utterance's queue (all of them for Infinity), as one array. */
function take(utt, count) {
  const parts = [];
  let need = count;
  while (utt.blocks.length > 0 && need > 0) {
    const block = utt.blocks[0];
    if (block.length <= need) {
      parts.push(block);
      utt.blocks.shift();
      need -= block.length;
    } else {
      parts.push(block.subarray(0, need));
      utt.blocks[0] = block.subarray(need);
      need = 0;
    }
  }
  const out = new Int16Array(parts.reduce((total, part) => total + part.length, 0));
  let at = 0;
  for (const part of parts) { out.set(part, at); at += part.length; }
  utt.count -= out.length;
  return out;
}

/** A second of a request goes to the host as soon as there is one, while it is still being said. */
function pump(v, utt) {
  while (utt.begun && utt.count >= chunkSamples) send(v, utt, take(utt, chunkSamples), false);
}

/** The request ended: the rest goes, marked last, and the page waits for the answer with the mic held. */
function finish(v, utt) {
  if (!utt.begun) return;
  v.held = true;
  v.asking = utt.id;
  for (const piece of cut(take(utt, Infinity))) send(v, utt, piece, false);
  // The host wants a last chunk with audio in it: 10 ms of quiet ends the request.
  send(v, utt, new Int16Array(160), true);
  utt.chain = utt.chain.then(() => {
    if (!utt.failed && v.asking === utt.id) {
      setState(v, "sending");
      void poll(v, utt.id);
    }
  });
}

function send(v, utt, samples, last) {
  const seq = utt.seq++;
  utt.chain = utt.chain.then(async () => {
    if (utt.failed || v.closed) return;
    const result = await postJSON("/api/voice/audio", { id: utt.id, seq, last, audio: toBase64(samples), ...hint() }, "The host didn't answer.");
    if (result.ok || utt.failed || v.closed) return;
    utt.failed = true;
    if (v.asking === utt.id) releaseHold(v, 0);
    v.view = { ...v.view, state: "listening", exchange: [...v.view.exchange, { who: "note", text: result.error }] };
    render(v);
  });
}

function releaseHold(v, after) {
  v.asking = null;
  setTimeout(() => { if (!v.closed) v.held = false; }, after);
}

// ---------------------------------------------------------------------------------------------------------------
// What the host says, and the reply

async function poll(v, id) {
  v.view = { ...v.view, session: null, done: false };
  let after = 0;
  let failures = 0;
  while (!v.closed && v.asking === id) {
    const reply = await getJSON(`/api/voice/status?id=${id}&after=${after}`);
    if (v.closed || v.asking !== id) return;
    if (!reply.ok) {
      if (++failures >= pollFailures) {
        v.view = { ...v.view, state: "listening", exchange: [...v.view.exchange, { who: "note", text: reply.error }] };
        render(v);
        return releaseHold(v, 0);
      }
      await sleep(pollMs);
      continue;
    }
    failures = 0;
    after = reply.next;
    v.view = applyEvents(v.view, reply.events);
    const sound = v.view.play;
    v.view = { ...v.view, play: null };
    render(v);
    if (sound) await play(v, sound);
    if (reply.done) break;
    await sleep(pollMs);
  }
  if (v.closed || v.asking !== id) return;
  // A reply that played leaves the page listening; a question for the user, or a request that went past the deadline, keeps its line.
  if (v.view.state === "speaking") setState(v, "listening");
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
