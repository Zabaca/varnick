// One tab on the phone (ADR 0034): its panes in a switcher, shown one at a time. A Claude or terminal pane that runs is today's session view
// (session.js: the live screen, then the terminal after Take over), and only the shown pane's terminal is open. Any other pane is a note: a
// file's text from the host, or where a page, an app or the Transcript runs; a page or an app the host proxies (ADR 0035) is framed instead,
// with a link to open it alone. Take over takes the whole tab; End ends it or hands it back. While the phone is in control of the tab the switcher
// ends in + (Add pane, add.js): a Claude session, a terminal, an app, a page or a file beside the pane shown. The
// host's listing is asked again every few seconds while the page is visible, so a pane added or closed elsewhere shows. Everything the host
// sent goes in with textContent, never as markup.

import { element, notListed, postJSON } from "/dom.js";
import { closeAdd, openAdd } from "/add.js";
import { confirmClose, confirmDone, confirmEnd, holdsForRestart, markVoice, offerRestart, openSession, releaseSession, tell } from "/session.js";
import {
  choosePane, closeQuestion, doneQuestion, framedAddress, hasSession, isLocalAddress, isOpenable, isVoiceSession, kindWord, offersAdd, offersClose, offersDone, offersRestart, offersTake, paneLabel, paneNote, readyToShow, samePanes, showsSwitcher, tabHash, tabTitle,
} from "/tabrules.js";

const $ = (id) => document.getElementById(id);
const visible = () => document.visibilityState === "visible";
const refreshMs = 5_000;
/** How long a pane this page just added is waited for in the host's listing before it is given up on. */
const addedWaitMs = 60_000;

/** The open tab, or null. One at a time. */
let current = null;

/** The tab as the host lists it now, with whether the host still has it. */
async function fetchTab(id) {
  try {
    const response = await fetch(`/api/tab?tab=${encodeURIComponent(id)}`, { cache: "no-store", headers: { accept: "application/json" } });
    const body = await response.json().catch(() => ({}));
    if (response.ok && body.ok === true) return { ok: true, tab: body.tab, host: body.host };
    if (response.status === 403) return { ok: false, error: notListed };
    return { ok: false, gone: response.status === 404, error: body.error ?? `The host answered ${response.status}.` };
  } catch {
    return { ok: false, error: "The host didn't answer. Check that you're on the tailnet." };
  }
}

function header(t, sub) {
  $("session-title").textContent = t.data ? tabTitle(t.data) : "Tab";
  $("session-sub").textContent = sub ? `${t.host} · ${sub}` : t.host;
}

/** Whether End is hidden over a pane that is not a session's screen. Redraw is never shown there: session.js shows it with the screens it redraws. */
function setEnd(hidden) {
  $("end").hidden = hidden;
  $("redraw").hidden = true;
  $("restart").hidden = true;
}

/** Done is in the menu while the tab has a Claude pane, whether or not this phone controls the tab (`offersDone`). */
function paintDone(t) {
  $("done").hidden = !(t.data && offersDone(t.data));
}

/** What Restart acts on over the pane shown, or null when it isn't offered (session.js shows the button with the terminal). */
const restartOffer = (t, pane) => (pane && offersRestart(t.data, pane) ? { tab: t.id, pane: pane.id } : null);

/** Shows the switcher, a button per pane, when the tab has more than one or this phone can add one; then + while the phone is in control. */
function renderSwitcher(t) {
  const nav = $("panes");
  nav.replaceChildren();
  nav.hidden = !showsSwitcher(t.data);
  for (const pane of t.data.panes) {
    const button = element("button", "pane-tab");
    button.type = "button";
    button.append(element("span", "pane-kind", kindWord(pane.kind)), element("span", "pane-name", paneLabel(pane)));
    if (!isOpenable(pane) && hasSession(pane.kind)) button.classList.add("idle");
    button.dataset.pane = pane.id;
    button.setAttribute("aria-pressed", String(pane.id === t.pane));
    button.addEventListener("click", () => { if (current === t) { dropAdded(t); showPane(t, pane); } });
    nav.append(button);
  }
  t.add = offersAdd(t.data);
  if (!t.add) return;
  // Close and + stay at the end of the row together, whatever its scroll.
  const actions = element("span", "pane-actions");
  nav.append(actions);
  if (offersClose(t.data)) {
    const close = element("button", "pane-close", "×");
    close.type = "button";
    close.setAttribute("aria-label", "Close the pane shown");
    close.addEventListener("click", () => { if (current === t) closeShown(t); });
    actions.append(close);
  }
  const plus = element("button", "pane-add", "+");
  plus.type = "button";
  plus.setAttribute("aria-label", "Add pane");
  plus.addEventListener("click", () => {
    const beside = t.data.panes.find((pane) => pane.id === t.pane) ?? t.data.panes[0];
    if (current === t && beside) openAdd({ tab: t.id, pane: beside.id, host: t.host, added: (result) => added(t, result),
      failed: (error) => { if (current === t) $("session-sub").textContent = `Couldn't add the pane: ${error}`; },
    });
  });
  actions.append(plus);
}

/**
 * Closes the pane shown, after the page's own question (never `confirm()`): the host's `end` for one pane, whatever its kind. When the host handed the
 * tab back instead (the pane was its last, and the tab isn't this phone's to end), the page leaves it as End does; a tab the host ended is found gone by
 * the next listing. Otherwise the pane leaves the switcher at once and the next pane in it is shown.
 */
async function closeShown(t) {
  const pane = t.data.panes.find((candidate) => candidate.id === t.pane);
  if (!pane || t.closing) return;
  if (!(await confirmClose(closeQuestion(t.data, pane, t.host))) || t.closed) return;
  t.closing = true;
  $("session-sub").textContent = "Closing…";
  const result = await postJSON("/api/close", { tab: t.id, pane: pane.id }, "the host didn't answer");
  t.closing = false;
  if (t.closed) return;
  if (!result.ok) {
    $("session-sub").textContent = `Couldn't close it: ${result.error}`;
    return;
  }
  if (result.released) {
    const done = t.done;
    closeTab();
    return done(result.text);
  }
  // The host ended the whole tab if that was its last pane and the tab was this phone's: it is gone from the listing, so the page goes home at once.
  const listed = await fetchTab(t.id);
  if (t.closed) return;
  if (!listed.ok && listed.gone) {
    const done = t.done;
    closeTab();
    return done(result.text);
  }
  dropAdded(t);
  t.data = { ...t.data, panes: t.data.panes.filter((candidate) => candidate.id !== pane.id) };
  renderSwitcher(t);
  showPane(t, choosePane(t.data, null));
  load(t);
}

/** Gives up opening the pane this page added, and its one take with it. */
function dropAdded(t) {
  t.open = null;
  t.take = null;
}

/**
 * The host added a pane beside the pane shown: the tab is asked for again, and the page switches to the new pane. A Claude or terminal pane opens with
 * take, once, as after a start; a page, an app or a file has no session to take. It may not be listed yet, so it waits for the next asks
 * (`addedWaitMs`).
 */
function added(t, { session, pane }) {
  if (t.closed || !pane) return;
  t.take = session;
  t.open = pane;
  t.openUntil = Date.now() + addedWaitMs;
  load(t);
}

function markShown(t) {
  for (const button of $("panes").querySelectorAll("button.pane-tab")) button.setAttribute("aria-pressed", String(button.dataset.pane === t.pane));
}

/** Shows `pane`: a pane that runs is the session view, any other a note. */
function showPane(t, pane) {
  t.pane = pane?.id ?? null;
  history.replaceState(null, "", tabHash(t.id, t.pane));
  markShown(t);
  if (pane && isOpenable(pane)) {
    $("note").hidden = true;
    hideFrame();
    t.session = true;
    // The page's own start of this session takes it once; any other open asks the host's status first.
    const take = t.take === pane.session;
    if (take) t.take = null;
    openSession({ name: pane.session, title: tabTitle(t.data), host: t.host, done: t.done, take, tab: { id: t.id }, restart: restartOffer(t, pane), voice: isVoiceSession(t.data) });
    return;
  }
  t.session = false;
  releaseSession();
  if (pane && framedAddress(pane)) showFrame(t, pane);
  else showNote(t, pane);
}

/** Stops the framed app: the frame is emptied, so nothing of it runs while another pane shows. */
function hideFrame() {
  $("frame").hidden = true;
  const view = $("frame-view");
  if (!view.hasAttribute("src")) return;
  // A frame left to itself keeps running; a fresh one without an address is what stops it.
  const empty = view.cloneNode(false);
  empty.removeAttribute("src");
  view.replaceWith(empty);
}

/** Frames the host's proxied address of a page or an app. Navigating in it is the viewer's own browsing, and the host's pane keeps its address. */
function showFrame(t, pane) {
  for (const id of ["card", "live", "terminal-view", "note"]) $(id).hidden = true;
  setEnd(!t.data.mine);
  header(t, kindWord(pane.kind));
  const address = framedAddress(pane);
  $("frame").hidden = false;
  $("frame-address").textContent = address;
  $("frame-open").href = address;
  $("frame-view").src = address;
}

function showNote(t, pane) {
  hideFrame();
  for (const id of ["card", "live", "terminal-view"]) $(id).hidden = true;
  $("note").hidden = false;
  // End is the phone's to offer only while it holds the tab; otherwise Take over comes first.
  setEnd(!t.data.mine);
  header(t, pane ? kindWord(pane.kind) : "");
  const note = pane ? paneNote(pane, t.host) : { text: "This tab has no pane.", detail: "" };
  $("note-text").textContent = note.text;
  $("note-detail").textContent = note.detail;
  $("note-text").hidden = note.text === "";
  $("note-detail").hidden = note.detail === "" || pane?.kind === "file";
  // A page at an outside address opens in the browser, not here.
  const link = $("note-link");
  link.hidden = !(pane?.kind === "web" && !isLocalAddress(pane.url) && /^https?:\/\//.test(pane.url));
  if (!link.hidden) link.href = pane.url;
  paintControl(t);
  const file = $("note-file");
  file.hidden = true;
  file.textContent = "";
  if (pane?.kind === "file") readFile(t, pane);
}

/** The tab's control and Take over, over a note: the same wording as a session's card. */
function paintControl(t) {
  const control = $("note-control");
  control.textContent = t.data.text;
  control.hidden = t.data.text === "";
  control.classList.toggle("mine", t.data.mine);
  $("note-take").hidden = !offersTake(t.data);
}

async function readFile(t, pane) {
  const view = $("note-file");
  view.hidden = false;
  view.textContent = "Reading…";
  const response = await fetch(`/api/file?tab=${encodeURIComponent(t.id)}&pane=${encodeURIComponent(pane.id)}`, { cache: "no-store", headers: { accept: "application/json" } })
    .then((r) => r.json().catch(() => ({})))
    .catch(() => ({ ok: false, error: "The host didn't answer." }));
  if (t.closed || t.pane !== pane.id) return;
  view.textContent = response.ok === true ? response.text : response.error ?? "The host didn't send the file.";
}

/** Asks the host for the tab and brings the page up to date: the switcher, and the pane shown if it can no longer be. */
async function load(t) {
  const generation = ++t.generation;
  const asked = Date.now();
  const result = await fetchTab(t.id);
  if (t.closed || generation !== t.generation) return;
  if (!result.ok) {
    if (t.data === null) return failed(t, result.error);
    // A tab the host no longer lists is over; any other failure keeps what is shown, and the next try asks again.
    if (result.gone) {
      const done = t.done;
      closeTab();
      done(`That tab was closed on ${t.host}`);
    }
    return;
  }
  const first = t.data === null;
  const before = t.data?.panes ?? [];
  const shown = before.find((pane) => pane.id === t.pane);
  t.data = result.tab;
  t.host = result.host || t.host;
  paintDone(t);
  const now = choosePane(t.data, t.pane);
  const changed = first || !samePanes(before, t.data.panes) || offersAdd(t.data) !== t.add;
  if (changed) renderSwitcher(t);
  // Add pane is the phone's only while it is in control: a form open when it isn't any more is closed.
  if (!t.add) closeAdd();
  const fresh = t.open && Date.now() < t.openUntil ? t.data.panes.find((pane) => pane.id === t.open) : null;
  if (!fresh && t.open && Date.now() >= t.openUntil) dropAdded(t);
  // The pane stays unless it is gone, or it began or stopped running.
  // A page or an app is shown again when the host begins or stops proxying it; a new address of the same pane is the viewer's own browsing.
  const framingChanged = shown && Boolean(framedAddress(shown)) !== Boolean(framedAddress(now ?? shown));
  // A Restart takes the pane down and brings it back, and session.js attaches again: a listing asked before it settled may show the pane down, and
  // that must not tear the terminal down (nor take Restart away).
  const restarting = holdsForRestart(asked);
  if (fresh && readyToShow(fresh)) {
    t.open = null;
    showPane(t, fresh);
  } else if (first || !now || now.id !== t.pane || (!restarting && ((shown && isOpenable(shown) !== isOpenable(now)) || framingChanged))) {
    showPane(t, now);
  } else if (!t.session) {
    header(t, kindWord(now.kind));
    setEnd(!t.data.mine);
    if (!framedAddress(now)) paintControl(t);
  }
  // The phone's control of the tab, or the pane, can have changed since the session opened: Restart follows it.
  if (t.session && !restarting) offerRestart(restartOffer(t, now));
  // Take over makes the Voice session the user's: the host drops its mark, and the note over the screen goes.
  if (t.session) markVoice(isVoiceSession(t.data));
}

function failed(t, error) {
  hideFrame();
  for (const id of ["card", "live", "terminal-view"]) $(id).hidden = true;
  $("note").hidden = false;
  $("note-control").hidden = true;
  $("note-take").hidden = true;
  $("note-file").hidden = true;
  $("note-detail").hidden = true;
  $("note-link").hidden = true;
  $("note-text").hidden = false;
  $("note-text").textContent = error;
  setEnd(true);
  paintDone(t);
  header(t, "");
}

/**
 * Opens a tab of the host, on `pane` if it has it. `done(text)` says the user left or ended it. `take` is a session name this page has just
 * started, which then attaches with take once; a tab the host reopened for this phone is labelled for it already.
 */
export function openTab({ tab, pane, host, done, take = null }) {
  closeTab();
  const t = { id: tab, pane, host: host || "", done, take, data: null, session: false, closed: false, generation: 0, timer: null, add: false, open: null, openUntil: 0, closing: false, finishing: false };
  current = t;
  $("session").hidden = false;
  $("panes").hidden = true;
  $("done").hidden = true;
  // Nothing of the session or tab shown before: its card, live screen and terminal are gone from view until a pane is chosen.
  for (const id of ["card", "live", "terminal-view", "note"]) $(id).hidden = true;
  setEnd(true);
  header(t, "Opening…");
  load(t);
  t.timer = setInterval(() => { if (visible()) load(t); }, refreshMs);
}

/** Leaves the tab: closes the open terminal only, so everything keeps running with its label. */
export function closeTab() {
  const t = current;
  if (!t) return;
  current = null;
  t.closed = true;
  clearInterval(t.timer);
  closeAdd();
  releaseSession();
  $("session").hidden = true;
  $("panes").hidden = true;
  $("panes").replaceChildren();
  $("note").hidden = true;
  $("done").hidden = true;
  hideFrame();
}

async function endTab(t) {
  if (!(await confirmEnd(tabTitle(t.data), t.host, true)) || t.closed) return;
  $("end").disabled = true;
  const result = await postJSON("/api/end", { tab: t.id }, "the host didn't answer");
  $("end").disabled = false;
  if (t.closed) return;
  if (result.ok) {
    const done = t.done;
    closeTab();
    done(result.text);
  } else {
    $("session-sub").textContent = `Couldn't end it: ${result.error}`;
  }
}

/**
 * Done, from the menu: the host closes the whole tab, whoever controls it or started it, every pane ended (protocol 33, ADR 0045). It always asks first, in
 * the page's own dialog. The host's refusal comes in the alert dialog, since the bar is too narrow for it, and leaves the tab as it was; after Done the page
 * leaves the tab and Home says so.
 */
async function doneShown(t) {
  if (t.finishing || !t.data || !offersDone(t.data)) return;
  if (!(await confirmDone(doneQuestion(tabTitle(t.data), t.host))) || t.closed) return;
  t.finishing = true;
  $("done").disabled = true;
  const sub = $("session-sub").textContent;
  $("session-sub").textContent = "Marking done…";
  const result = await postJSON("/api/done", { tab: t.id }, "the host didn't answer");
  t.finishing = false;
  $("done").disabled = false;
  if (t.closed) return;
  if (result.ok) {
    const done = t.done;
    closeTab();
    return done(result.text);
  }
  $("session-sub").textContent = sub;
  await tell(result.error);
}

// The controls are wired once. In the session view session.js answers them; over a note this does.
$("back").addEventListener("click", () => { if (current && !current.session) current.done(null); });
$("end").addEventListener("click", () => { if (current && !current.session && current.data) endTab(current); });
// Done acts on the whole tab, so it answers over a session too.
$("done").addEventListener("click", () => { if (current) doneShown(current); });
$("note-take").addEventListener("click", async () => {
  const t = current;
  if (!t) return;
  $("note-take").disabled = true;
  const result = await postJSON("/api/take", { tab: t.id }, "the host didn't answer");
  $("note-take").disabled = false;
  if (t.closed) return;
  if (result.ok) load(t);
  else $("note-control").textContent = result.error;
});

document.addEventListener("visibilitychange", () => {
  if (current && visible()) load(current);
});
// Take over in the session view (session.js) changes who controls the tab: the switcher gets its + without waiting for the next ask.
document.addEventListener("tab-taken", () => { if (current) load(current); });
