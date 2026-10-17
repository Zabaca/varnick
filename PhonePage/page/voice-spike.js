// The Voice mode spike's page (voicespike.ts, phone-page-is-only-a-browser-tab option 05 phase 1). Throwaway: it measures what Chrome keeps alive when the
// page is hidden or the phone is locked, and sends only levels, states and timings to the host's log, never audio.

const $ = (id) => document.getElementById(id);
const run = Array.from(crypto.getRandomValues(new Uint8Array(4)), (byte) => byte.toString(16).padStart(2, "0")).join("");
const began = Date.now();
$("run").textContent = run;

// ---------------------------------------------------------------------------------------------------------------
// The log: events queue here and go to the host in batches. A batch that fails stays queued, so what a frozen or offline page missed arrives when it can.

const queue = [];
const queueLimit = 3000;
const batchSize = 100;
let sending = false;
let lastRtt = null;
const tail = [];

function log(kind, fields = {}) {
  const t = Date.now() - began;
  queue.push({ t, k: kind, f: fields });
  if (queue.length > queueLimit) queue.splice(0, queue.length - queueLimit);
  tail.push(`${(t / 1000).toFixed(1).padStart(7)}s ${kind} ${Object.entries(fields).map(([key, value]) => `${key}=${value}`).join(" ")}`);
  if (tail.length > 60) tail.shift();
  $("tail").textContent = tail.join("\n");
  $("tail").scrollTop = $("tail").scrollHeight;
  $("queued").textContent = String(queue.length);
}

async function flush(keepalive = false) {
  if (sending || queue.length === 0) return;
  sending = true;
  const batch = queue.slice(0, batchSize);
  try {
    const response = await fetch("/api/voice-spike/log", {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({ run, events: batch }),
      keepalive,
    });
    if (response.ok) queue.splice(0, batch.length);
    else if (response.status === 400 || response.status === 507) {
      // The host will never take these: drop them and say so (the next batch carries it).
      queue.splice(0, batch.length);
      queue.push({ t: Date.now() - began, k: "post-refused", f: { status: response.status, dropped: batch.length } });
    }
  } catch {
    // Offline or frozen: the batch stays queued.
  }
  sending = false;
  $("queued").textContent = String(queue.length);
  if (queue.length >= batchSize) void flush(keepalive);
}
setInterval(() => void flush(), 2000);

// ---------------------------------------------------------------------------------------------------------------
// The page's own lifecycle.

const visibility = () => document.visibilityState;
const standalone = matchMedia("(display-mode: standalone)").matches;
const chrome = /Chrome\/(\d+)/.exec(navigator.userAgent)?.[1] ?? "other";

function showVisibility() {
  $("vis").textContent = visibility();
}

document.addEventListener("visibilitychange", () => {
  showVisibility();
  log("vis", { state: visibility() });
  if (visibility() === "hidden") void flush(true);
});
document.addEventListener("freeze", () => { log("freeze"); void flush(true); });
document.addEventListener("resume", () => log("resume", { vis: visibility() }));
addEventListener("pagehide", (event) => { log("pagehide", { persisted: event.persisted }); void flush(true); });
addEventListener("pageshow", (event) => log("pageshow", { persisted: event.persisted }));

// A timer that ran late says the page was throttled or frozen, whatever the microphone says.
let lastTick = Date.now();
setInterval(() => {
  const now = Date.now();
  if (now - lastTick > 2500) log("timer-gap", { ms: now - lastTick, vis: visibility() });
  lastTick = now;
}, 1000);

addEventListener("error", (event) => log("error", { msg: String(event.message).slice(0, 60) }));
addEventListener("unhandledrejection", (event) => log("error", { msg: String(event.reason?.message ?? event.reason).slice(0, 60) }));

// ---------------------------------------------------------------------------------------------------------------
// The websocket ping: every 5 s, timed. It reconnects when it is closed, which a thawed page does at once.

let socket = null;
let pings = 0;

function connect() {
  if (socket && socket.readyState <= 1) return;
  const opened = new WebSocket(`wss://${location.host}/ws/voice-spike`);
  socket = opened;
  opened.onopen = () => { log("ws-open"); showSocket(); sendPing(); };
  opened.onmessage = (event) => {
    try {
      const answer = JSON.parse(event.data);
      lastRtt = Date.now() - answer.sent;
      $("rtt").textContent = `${lastRtt} ms (ping ${answer.pong})`;
      log("pong", { n: answer.pong, rtt: lastRtt, vis: visibility() });
    } catch { /* not ours */ }
  };
  opened.onclose = (event) => { log("ws-close", { code: event.code, vis: visibility() }); showSocket(); };
  opened.onerror = () => log("ws-error");
  showSocket();
}

function showSocket() {
  $("ws").textContent = ["connecting", "open", "closing", "closed"][socket ? socket.readyState : 3];
}

function sendPing() {
  if (!socket || socket.readyState !== 1) return;
  socket.send(JSON.stringify({ run, n: pings++, sent: Date.now() }));
}

setInterval(() => {
  if (!socket || socket.readyState > 1) connect();
  else sendPing();
}, 5000);

// ---------------------------------------------------------------------------------------------------------------
// The microphone: one getUserMedia stream, read by a worklet on the audio thread.

let context = null;
let stream = null;
let meterNode = null;
let micLoaded = false;

async function audioContext() {
  context ??= new AudioContext();
  if (context.state !== "running") await context.resume();
  return context;
}

$("mic").onclick = async () => {
  if (stream) return stopMic();
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  } catch (error) {
    log("mic-error", { msg: String(error?.name ?? error) });
    return;
  }
  const track = stream.getAudioTracks()[0];
  for (const name of ["mute", "unmute", "ended"]) track.addEventListener(name, () => log(`track-${name}`, { vis: visibility() }));
  try {
    const audio = await audioContext();
    if (!micLoaded) { await audio.audioWorklet.addModule("/voice-spike-worklet.js"); micLoaded = true; }
    meterNode = new AudioWorkletNode(audio, "spike-meter");
    meterNode.port.onmessage = (event) => {
      const { rms, peak, blank } = event.data;
      const live = stream?.getAudioTracks()[0];
      $("level").textContent = `rms ${rms.toFixed(4)}`;
      log("level", {
        rms: rms.toFixed(5), peak: peak.toFixed(4), blank, mute: live?.muted ? 1 : 0, ready: live?.readyState ?? "none",
        ctx: context.state, vis: visibility(), ws: socket ? socket.readyState : 3,
      });
    };
    const silent = audio.createGain();
    silent.gain.value = 0;
    audio.createMediaStreamSource(stream).connect(meterNode);
    // The worklet is pulled only when it reaches the destination: through a gain of zero, which is silent output.
    meterNode.connect(silent).connect(audio.destination);
    log("mic-on", { rate: audio.sampleRate, ctx: audio.state });
    $("mic-state").textContent = "listening";
    $("mic").textContent = "Stop microphone";
    $("mic").setAttribute("aria-pressed", "true");
  } catch (error) {
    log("mic-error", { msg: String(error?.name ?? error) });
    stopMic();
  }
};

function stopMic() {
  stream?.getTracks().forEach((track) => track.stop());
  meterNode?.disconnect();
  stream = null;
  meterNode = null;
  log("mic-off");
  $("mic-state").textContent = "off";
  $("mic").textContent = "Start microphone";
  $("mic").setAttribute("aria-pressed", "false");
}

// ---------------------------------------------------------------------------------------------------------------
// The tone: quiet, looping, in two forms (Web Audio and an audio element), to see whether either keeps a hidden page awake.

let oscillator = null;
let toneElement = null;

const showTone = () => {
  const on = [oscillator ? "Web Audio" : null, toneElement ? "audio element" : null].filter(Boolean);
  $("tone-state").textContent = on.length ? on.join(" + ") : "off";
  $("tone-ctx").setAttribute("aria-pressed", String(oscillator !== null));
  $("tone-audio").setAttribute("aria-pressed", String(toneElement !== null));
};

$("tone-ctx").onclick = async () => {
  if (oscillator) {
    oscillator.stop();
    oscillator = null;
    log("tone-off", { kind: "ctx" });
    return showTone();
  }
  const audio = await audioContext();
  const gain = audio.createGain();
  gain.gain.value = 0.02;
  oscillator = audio.createOscillator();
  oscillator.frequency.value = 220;
  oscillator.connect(gain).connect(audio.destination);
  oscillator.start();
  log("tone-on", { kind: "ctx", ctx: audio.state });
  showTone();
};

/** One second of a 220 Hz sine at 8 kHz, 16-bit mono: whole cycles, so the loop has no click. */
function toneWav() {
  const rate = 8000, frames = rate, bytes = new DataView(new ArrayBuffer(44 + frames * 2));
  const text = (offset, value) => { for (let i = 0; i < value.length; i++) bytes.setUint8(offset + i, value.charCodeAt(i)); };
  text(0, "RIFF"); bytes.setUint32(4, 36 + frames * 2, true); text(8, "WAVE"); text(12, "fmt ");
  bytes.setUint32(16, 16, true); bytes.setUint16(20, 1, true); bytes.setUint16(22, 1, true); bytes.setUint32(24, rate, true);
  bytes.setUint32(28, rate * 2, true); bytes.setUint16(32, 2, true); bytes.setUint16(34, 16, true); text(36, "data"); bytes.setUint32(40, frames * 2, true);
  for (let i = 0; i < frames; i++) bytes.setInt16(44 + i * 2, Math.round(Math.sin((2 * Math.PI * 220 * i) / rate) * 0.02 * 32767), true);
  return new Blob([bytes], { type: "audio/wav" });
}

$("tone-audio").onclick = async () => {
  if (toneElement) {
    toneElement.pause();
    URL.revokeObjectURL(toneElement.src);
    toneElement = null;
    log("tone-off", { kind: "audio" });
    return showTone();
  }
  const element = new Audio(URL.createObjectURL(toneWav()));
  element.loop = true;
  element.addEventListener("pause", () => log("audio-pause", { vis: visibility() }));
  try {
    await element.play();
    toneElement = element;
    log("tone-on", { kind: "audio" });
  } catch (error) {
    log("tone-error", { msg: String(error?.name ?? error) });
  }
  showTone();
};

// ---------------------------------------------------------------------------------------------------------------
// The wake lock. It is not asked for again when the page is shown: the log should show that the browser let it go.

let lock = null;
let releasing = false;

$("wake").onclick = async () => {
  if (lock) {
    releasing = true;
    await lock.release();
    releasing = false;
    log("wake-off");
    lock = null;
    $("wake-state").textContent = "off";
    $("wake").setAttribute("aria-pressed", "false");
    return;
  }
  if (!("wakeLock" in navigator)) return log("wake-error", { msg: "unsupported" });
  try {
    lock = await navigator.wakeLock.request("screen");
  } catch (error) {
    return log("wake-error", { msg: String(error?.name ?? error) });
  }
  log("wake-on");
  $("wake-state").textContent = "held";
  $("wake").setAttribute("aria-pressed", "true");
  lock.addEventListener("release", () => {
    if (releasing) return;
    log("wake-release", { vis: visibility() });
    lock = null;
    $("wake-state").textContent = "released by the browser";
    $("wake").setAttribute("aria-pressed", "false");
  });
};

$("mark").onclick = () => {
  log("mark", { label: $("label").value || "mark", vis: visibility() });
  void flush();
};

showVisibility();
log("start", { chrome, app: standalone ? "installed" : "tab", vis: visibility(), wake: "wakeLock" in navigator ? 1 : 0, worklet: typeof AudioWorkletNode === "function" ? 1 : 0 });
connect();
void flush();
