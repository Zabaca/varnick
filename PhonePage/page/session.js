// One open session on the phone: the session view ("Controlled on X", Take over, and the session's live screen, read-only) and the
// terminal (xterm.js and the key bar). The server decides everything about control; this page asks `status` before
// every attach, and again whenever the live screen's channel ends (which never means the session ended), sets `take` only
// right after a press (Take over, or the Start or Resume that made the session: `openSession`'s `take`), and never sends
// anything while hidden. Rules that need no DOM are in rules.js.
// Everything the host sent goes in with textContent, never as markup.

import { notListed, postJSON } from "/dom.js";
import { Terminal } from "/vendor/xterm.mjs";
import { FitAddon } from "/vendor/addon-fit.mjs";
import { createLive } from "/live.js";
import { parseFrame } from "/liverules.js";
import { closeAction, ctrlCode, dragLines, keys, livedLongEnough, reconnectDelay, takenController } from "/rules.js";

const $ = (id) => document.getElementById(id);

/** The open session, or null. One at a time. */
let current = null;

const visible = () => document.visibilityState === "visible";

function setSub(s, state) {
  $("session-sub").textContent = state ? `${s.host} · ${state}` : s.host;
}

function setTitle(s, title) {
  if (title) s.title = title;
  $("session-title").textContent = s.title;
}

/** Shows one of the session view's bodies, and whether End is offered (only in the terminal). The live screen belongs to "other" alone. */
function showView(s, view) {
  s.view = view;
  $("card").hidden = view === "terminal";
  // "Controlled on X" is a bar over the live screen; every other card is the whole body.
  $("card").classList.toggle("bar", view === "other");
  $("live").hidden = view !== "other";
  $("terminal-view").hidden = view !== "terminal";
  $("end").hidden = view !== "terminal";
  if (view !== "other") stopLive(s);
}

function showCard(s, view, text, { take = false, retry = false } = {}) {
  showView(s, view);
  $("card-text").textContent = text;
  // "Taken over on X" belongs to the session view; a relay's refusal stays until the next try.
  const note = view === "other" ? s.note : "";
  $("card-note").textContent = note;
  $("card-note").hidden = note === "";
  showNotice(s);
  $("take").hidden = !take;
  $("retry").hidden = !retry;
  setSub(s, "");
}

/**
 * This page held the session and now another controller does: say so once. The note is set here only, the moment the
 * loss is found (a 4001, or a reconnect's status), and stays while the card is up; a later status finding the same
 * controller doesn't set it again, because `mine` is then false.
 */
function markTaken(s, controller) {
  if (!s.mine) return;
  s.mine = false;
  s.note = `Taken over on ${controller || "another device"}`;
}

/** "Controlled on X" or "Last controlled on X", under the "Taken over on X" note when this page just lost it. */
function showOther(s, text, controller) {
  markTaken(s, controller);
  showCard(s, "other", text, { take: true });
  startWatch(s);
  liveSub(s);
}

function liveSub(s) {
  if (s.view === "other") setSub(s, s.lv.drawn ? "Live" : visible() ? "Loading screen…" : "");
}

/** The live screen's state, all in one place: its channel, its xterm view and what is waiting to be drawn. */
function newLive() {
  return {
    ws: null, view: null, observer: null,
    // The newest frame not drawn yet, and its animation frame; whether this channel has drawn one; the host's screen too large to send.
    frame: null, draw: 0, drawn: false, tooLarge: false,
  };
}

const tooLargeText = "Screen too large to show";

/**
 * The session's live screen, read-only, under "Controlled on X": a websocket to `/ws/watch` that is open only while the page is
 * visible and this view is up, so the first frame is always a fresh snapshot. The page sends the session's name and nothing else.
 */
function startWatch(s) {
  const lv = s.lv;
  if (s.closed || lv.ws || s.view !== "other" || !visible()) return;
  if (!lv.view) {
    lv.view = createLive({ host: $("live"), sizer: $("live-size"), mount: $("live-term") });
    lv.observer = new ResizeObserver(() => lv.view?.refit());
    lv.observer.observe($("live"));
  }
  const ws = new WebSocket(`wss://${location.host}/ws/watch`);
  lv.ws = ws;
  let openedAt = 0;
  ws.onopen = () => {
    if (lv.ws !== ws) return;
    openedAt = Date.now();
    ws.send(JSON.stringify({ session: s.name }));
  };
  ws.onmessage = (event) => {
    if (lv.ws !== ws) return;
    const frame = parseFrame(event.data);
    if (!frame) return;
    if (frame.tooLarge) {
      // Said in the bar; the last screen stays drawn, and the channel goes on (a smaller screen may follow).
      lv.tooLarge = true;
      showNotice(s);
      return;
    }
    if (lv.tooLarge) {
      lv.tooLarge = false;
      showNotice(s);
    }
    // The newest frame replaces one not drawn yet: a slow phone draws the latest screen, never a backlog.
    lv.frame = frame;
    if (!lv.draw) lv.draw = requestAnimationFrame(() => drawFrame(s));
  };
  ws.onclose = () => {
    if (lv.ws !== ws) return;
    lv.ws = null;
    if (s.closed || s.view !== "other") return;
    // The channel ending never means the session ended: Take over, a release and the session ending all end it alike. So the
    // status is asked, as for a reconnect, and decides (this view again, with the new controller; the terminal; or "Session ended").
    // A channel that worked for a while asks at once; one that failed at once backs off.
    if (openedAt && livedLongEnough(Date.now() - openedAt)) {
      s.tries = 0;
      connect(s, false);
    } else {
      scheduleReconnect(s);
    }
  };
}

/** The bar's second line: a relay's refusal, else that the host's screen is too large to show. */
function showNotice(s) {
  const text = s.error || (s.view === "other" && s.lv.tooLarge ? tooLargeText : "");
  $("card-error").textContent = text;
  $("card-error").hidden = text === "";
}

function drawFrame(s) {
  const lv = s.lv;
  lv.draw = 0;
  const frame = lv.frame;
  lv.frame = null;
  if (!frame || s.closed || !lv.view) return;
  lv.view.show(frame);
  if (!lv.drawn) {
    lv.drawn = true;
    liveSub(s);
  }
}

/**
 * Closes the channel only (the page is hidden): the last frame stays drawn, but it is old, so coming back says "Loading screen…"
 * until a fresh one arrives.
 */
function pauseWatch(s) {
  const ws = s.lv.ws;
  s.lv.ws = null;
  s.lv.drawn = false;
  if (ws) try { ws.close(1000); } catch { /* closed already */ }
}

/** Closes the channel and takes the screen down: the session view is over, or another body took its place. */
function stopLive(s) {
  pauseWatch(s);
  const lv = s.lv;
  if (lv.draw) cancelAnimationFrame(lv.draw);
  lv.observer?.disconnect();
  lv.view?.dispose();
  s.lv = newLive();
}

async function fetchOpening(name) {
  try {
    const response = await fetch(`/api/session?name=${encodeURIComponent(name)}`, { cache: "no-store", headers: { accept: "application/json" } });
    if (response.status === 403) return { state: "error", error: notListed };
    if (!response.ok) return { state: "error", error: `The host answered ${response.status}.` };
    return await response.json();
  } catch {
    return { state: "error", error: "The host didn't answer. Check that you're on the tailnet." };
  }
}

function scheduleReconnect(s) {
  clearTimeout(s.timer);
  s.timer = null;
  // Never while hidden: coming back to the page reconnects at once.
  if (s.closed || !visible()) return;
  s.timer = setTimeout(() => connect(s, false), reconnectDelay(s.tries++));
}

/**
 * Opens the terminal. Without `take` the status is asked first, and decides: attach (labelled for this device), the
 * session view (anyone else), or "Session ended". `take` is true only right after a press, and then nothing is asked first.
 */
async function connect(s, take) {
  clearTimeout(s.timer);
  s.timer = null;
  if (s.closed || s.ws) return;
  const generation = ++s.generation;
  setSub(s, take ? "Taking over…" : s.view === "terminal" ? "Reconnecting…" : "Opening…");
  if (!take) {
    const opening = await fetchOpening(s.name);
    if (s.closed || s.ws || generation !== s.generation) return;
    if (opening.host) s.host = opening.host;
    setTitle(s, opening.title);
    if (opening.state === "other") return showOther(s, opening.text, opening.controller);
    if (opening.state === "gone") return showGone(s, opening.text);
    if (opening.state === "error") {
      // A terminal that was working keeps its screen and says it is reconnecting; a first open says why it can't.
      if (s.view === "terminal") setSub(s, "Reconnecting…");
      else showCard(s, "error", opening.error, { retry: true });
      scheduleReconnect(s);
      return;
    }
  }
  setSub(s, "Connecting…");
  openSocket(s, take);
}

function showGone(s, text) {
  s.mine = false;
  showCard(s, "gone", text);
}

/** After a refusal: the relay's error stays on the card, and the status says who has the session. Nothing attaches from here. */
async function settle(s, refusal) {
  const generation = ++s.generation;
  s.error = refusal;
  const opening = await fetchOpening(s.name);
  if (s.closed || s.ws || generation !== s.generation) return;
  if (opening.state === "other") return showOther(s, opening.text, opening.controller);
  if (opening.state === "gone") return showGone(s, opening.text);
  // The host couldn't say: the card shows the refusal while the page asks again.
  showCard(s, "error", "Couldn't ask the host who has this session.", { retry: true });
  scheduleReconnect(s);
}

function ensureTerminal(s) {
  showView(s, "terminal");
  if (s.term) return;
  const term = new Terminal({
    fontSize: 13, cursorBlink: true, scrollback: 2000, theme: { background: "#111" },
    // A link a program printed (OSC 8) opens only as http(s): never a javascript:, data: or file: address.
    linkHandler: {
      allowNonHttpProtocols: false,
      activate: (_event, link) => {
        try {
          const url = new URL(link);
          if (url.protocol === "https:" || url.protocol === "http:") window.open(url.href, "_blank", "noopener,noreferrer");
        } catch { /* not an address */ }
      },
    },
  });
  const fit = new FitAddon();
  term.loadAddon(fit);
  term.open($("term"));
  s.term = term;
  s.fit = fit;
  term.onData((data) => input(s, data));
  term.onBinary((data) => send(s, { t: "bin", d: data }));
  term.onResize(({ cols, rows }) => send(s, { t: "resize", cols, rows }));
  s.observer = new ResizeObserver(() => refit(s));
  s.observer.observe($("term"));
}

/**
 * The tallest the page has been at each width: shorter than that by a keyboard's height means the keyboard is up. Only
 * the browser knows the keyboard is there, so this is the guess.
 */
const tallest = new Map();
const keyboardUp = () => {
  const viewport = window.visualViewport;
  if (!viewport) return false;
  const height = Math.max(tallest.get(innerWidth) ?? 0, viewport.height);
  tallest.set(innerWidth, height);
  return viewport.height < height - 150;
};

/**
 * Fits the terminal to its box, except that the keyboard coming up never takes rows away: the grid keeps its height and
 * shows its bottom rows, where the prompt is (the CSS anchors it). A resize each time the keyboard came and went had the
 * session redraw at the new height while xterm.js moved lines in and out of its scrollback, and the two disagreed.
 */
function refit(s) {
  const size = s.fit.proposeDimensions();
  if (!size || !(size.cols > 0) || !(size.rows > 0)) return;
  // Asked first, every time, so it has seen the page's full height before the keyboard ever comes up.
  const keyboard = keyboardUp();
  const rows = size.rows < s.term.rows && keyboard ? s.term.rows : size.rows;
  if (size.cols !== s.term.cols || rows !== s.term.rows) s.term.resize(size.cols, rows);
}

function openSocket(s, take) {
  ensureTerminal(s);
  refit(s);
  const ws = new WebSocket(`wss://${location.host}/ws/terminal`);
  ws.binaryType = "arraybuffer";
  s.ws = ws;
  ws.onopen = () => {
    if (s.ws !== ws) return;
    // The first message goes before anything refits, so the server starts the attach at once.
    ws.send(JSON.stringify({ session: s.name, cols: s.term.cols, rows: s.term.rows, take }));
    s.openedAt = Date.now();
    s.term.reset();
    refit(s);
    setSub(s, "");
  };
  ws.onmessage = (event) => {
    if (s.ws !== ws) return;
    // Output means the attach went through: this page holds the session, and a refusal's error is old news.
    s.mine = true;
    s.error = "";
    s.term.write(typeof event.data === "string" ? event.data : new Uint8Array(event.data));
  };
  ws.onclose = (event) => {
    if (s.ws !== ws) return;
    s.ws = null;
    if (s.closed) return;
    // Only a connection that worked for a while starts the tries over: one that opens and fails at once must back off.
    if (s.openedAt && livedLongEnough(Date.now() - s.openedAt)) s.tries = 0;
    s.openedAt = 0;
    const action = closeAction(event.code);
    if (action === "taken") {
      const controller = takenController(event.reason);
      showOther(s, `Controlled on ${controller || "another device"}`, controller);
    } else if (action === "ended") {
      showGone(s, "Session ended");
    } else if (action === "refused") {
      settle(s, event.reason || "The host refused the attach.");
    } else {
      setSub(s, visible() ? "Reconnecting…" : "");
      scheduleReconnect(s);
    }
  };
}

function send(s, message) {
  if (s.ws && s.ws.readyState === WebSocket.OPEN) s.ws.send(JSON.stringify(message));
}

/** Typed bytes: the sticky Ctrl turns the next typed letter into its control code (one character only, so never a paste). */
function input(s, data) {
  if (s.ctrlOn) {
    const code = ctrlCode(data);
    if (code !== null) {
      data = code;
      setCtrl(s, false);
    }
  }
  send(s, { t: "in", d: data });
}

function setCtrl(s, on) {
  s.ctrlOn = on;
  $("ctrl").classList.toggle("on", on);
  $("ctrl").setAttribute("aria-pressed", String(on));
}

/**
 * Opens a session. `title` and `host` are what the home list knew; the host's answer replaces them. `done(text)` says the
 * user left or ended it: text is what End said, or null. `take` is true only for a session this page has just started or
 * resumed (app.js): it then attaches with take at once, as Take over does, without asking the status first.
 */
export function openSession({ name, title, host, done, take = false }) {
  closeSession();
  const s = {
    name, title: title || "Claude session", host: host || "", done,
    lv: newLive(),
    view: "", ws: null, term: null, fit: null, observer: null, timer: null, tries: 0, generation: 0, ctrlOn: false, closed: false,
    // mine: this page held the session (output arrived); note: "Taken over on X"; error: the relay's refusal; openedAt: when the socket opened.
    mine: false, note: "", error: "", openedAt: 0,
  };
  current = s;
  $("session").hidden = false;
  setTitle(s, null);
  setSub(s, "Opening…");
  showCard(s, "checking", "Opening…");
  setCtrl(s, false);
  connect(s, take);
}

/** Leaves the session: closes only this phone's websocket, so the session keeps running with its label. */
export function closeSession() {
  const s = current;
  if (!s) return;
  current = null;
  s.closed = true;
  clearTimeout(s.timer);
  stopLive(s);
  if (s.ws) {
    const ws = s.ws;
    s.ws = null;
    try { ws.close(1000); } catch { /* closed already */ }
  }
  s.observer?.disconnect();
  s.term?.dispose();
  $("term").replaceChildren();
  $("session").hidden = true;
}

async function endSession(s) {
  $("confirm-text").textContent = `End “${s.title}”? A session this phone started ends. Any other is handed back to ${s.host || "its host"} and keeps running.`;
  const dialog = $("confirm");
  dialog.returnValue = "cancel";
  dialog.showModal();
  await new Promise((resolve) => dialog.addEventListener("close", resolve, { once: true }));
  if (dialog.returnValue !== "end" || s.closed) return;
  $("end").disabled = true;
  const result = await postJSON("/api/end", { session: s.name }, "the host didn't answer");
  $("end").disabled = false;
  if (s.closed) return;
  if (result.ok) {
    const done = s.done;
    closeSession();
    done(result.text);
  } else {
    setSub(s, `Couldn't end it: ${result.error}`);
  }
}

// The controls are wired once, and act on whichever session is open.

$("back").addEventListener("click", () => current?.done(null));
$("leave").addEventListener("click", () => current?.done(null));
$("take").addEventListener("click", () => {
  const s = current;
  if (!s) return;
  s.note = "";
  s.error = "";
  // `take` is true right after this press, or for a session just started or resumed (`openSession`): nowhere else.
  connect(s, true);
});
$("retry").addEventListener("click", () => {
  const s = current;
  if (!s) return;
  s.tries = 0;
  connect(s, false);
});
$("end").addEventListener("click", () => { if (current) endSession(current); });

// A key press must not blur xterm's input, or the phone's keyboard would drop.
for (const button of document.querySelectorAll("#keys button")) {
  button.addEventListener("pointerdown", (event) => event.preventDefault());
}
for (const button of document.querySelectorAll("#keys button[data-key]")) {
  button.addEventListener("click", () => { if (current) input(current, keys[button.dataset.key]); });
}
$("ctrl").addEventListener("click", () => { if (current) setCtrl(current, !current.ctrlOn); });
// A tap on the terminal focuses it, which brings up the phone's keyboard: typing goes straight into xterm. xterm focuses its
// input on a press inside its screen; this also covers the padding around the screen.
$("term").addEventListener("click", () => current?.term?.focus());

// Swiping the terminal scrolls it, and a flick glides on: xterm.js 6 has no touch scrolling of its own. A tap still focuses it
// (and brings up the keyboard), since nothing is prevented until the finger has moved. A program that takes the mouse or the
// alternate screen (Claude Code full screen) has no scrollback here: it scrolls itself, so each row is a wheel event, which
// xterm.js reports to it as the program asked.
{
  const element = $("term");
  let startY = 0, lastX = 0, lastY = null, lastTime = 0, dragging = false, pending = 0, velocity = 0, frame = 0;
  const scrollBy = (pixels) => {
    const term = current?.term;
    if (!term) return false;
    const screen = element.querySelector(".xterm-screen");
    const { lines, rest } = dragLines(pending + pixels, screen?.clientHeight / term.rows);
    pending = rest;
    if (!lines) return true;
    if (term.modes.mouseTrackingMode === "none" && term.buffer.active.type === "normal") {
      term.scrollLines(-lines);
      return true;
    }
    const box = screen.getBoundingClientRect();
    const at = { clientX: Math.min(Math.max(lastX, box.left), box.right - 1), clientY: box.top + box.height / 2 };
    for (let i = 0; i < Math.abs(lines); i++) {
      screen.dispatchEvent(new WheelEvent("wheel", { ...at, deltaY: lines > 0 ? -100 : 100, bubbles: true, cancelable: true }));
    }
    return true;
  };
  element.addEventListener("touchstart", (event) => {
    cancelAnimationFrame(frame);
    lastY = event.touches.length === 1 ? event.touches[0].clientY : null;
    lastX = event.touches[0]?.clientX ?? 0;
    startY = lastY;
    lastTime = event.timeStamp;
    dragging = false;
    pending = 0;
    velocity = 0;
  }, { passive: true });
  element.addEventListener("touchmove", (event) => {
    if (lastY === null || event.touches.length !== 1) return;
    const y = event.touches[0].clientY;
    if (!dragging && Math.abs(y - startY) < 8) return;
    dragging = true;
    event.preventDefault();
    velocity = (y - lastY) / Math.max(1, event.timeStamp - lastTime);
    scrollBy(y - lastY);
    lastY = y;
    lastTime = event.timeStamp;
  }, { passive: false });
  element.addEventListener("touchend", (event) => {
    // A finger that stopped before it lifted doesn't glide.
    if (!dragging || event.timeStamp - lastTime > 100) return void (lastY = null);
    lastY = null;
    let last = performance.now();
    const glide = (now) => {
      const elapsed = now - last;
      last = now;
      velocity *= Math.pow(0.95, elapsed / 16);
      if (Math.abs(velocity) < 0.05 || !scrollBy(velocity * elapsed)) return;
      frame = requestAnimationFrame(glide);
    };
    frame = requestAnimationFrame(glide);
  });
}

document.addEventListener("visibilitychange", () => {
  const s = current;
  if (!s) return;
  if (!visible()) {
    clearTimeout(s.timer);
    s.timer = null;
    // Nothing arrives while the page is hidden: the live screen's channel closes, and the host's reader goes with it.
    pauseWatch(s);
    return;
  }
  // Back from another app: reconnect at once, asking the status first, unless the socket is still up or the session is over.
  s.tries = 0;
  if (!s.ws && s.view !== "gone") connect(s, false);
});

