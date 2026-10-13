// One tab on the phone (ADR 0034): its panes in a switcher, shown one at a time. A Claude or terminal pane that runs is today's session view
// (session.js: the live screen, then the terminal after Take over), and only the shown pane's terminal is open. Any other pane is a note: a
// file's text from the host, or where a page, an app or the Transcript runs. Take over takes the whole tab; End ends it or hands it back. The
// host's listing is asked again every few seconds while the page is visible, so a pane added or closed elsewhere shows. Everything the host
// sent goes in with textContent, never as markup.

import { element, notListed, postJSON } from "/dom.js";
import { confirmEnd, openSession, releaseSession } from "/session.js";
import { choosePane, isLocalAddress, isOpenable, kindWord, offersTake, paneLabel, paneNote, samePanes, tabHash, tabTitle } from "/tabrules.js";

const $ = (id) => document.getElementById(id);
const visible = () => document.visibilityState === "visible";
const refreshMs = 10_000;

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

/** Shows the switcher, a button per pane, when the tab has more than one. */
function renderSwitcher(t) {
  const nav = $("panes");
  nav.replaceChildren();
  nav.hidden = t.data.panes.length <= 1;
  for (const pane of t.data.panes) {
    const button = element("button", "pane-tab");
    button.type = "button";
    button.append(element("span", "pane-kind", kindWord(pane.kind)), element("span", "pane-name", paneLabel(pane)));
    if (!isOpenable(pane) && (pane.kind === "claude" || pane.kind === "terminal")) button.classList.add("idle");
    button.dataset.pane = pane.id;
    button.setAttribute("aria-pressed", String(pane.id === t.pane));
    button.addEventListener("click", () => { if (current === t) showPane(t, pane); });
    nav.append(button);
  }
}

function markShown(t) {
  for (const button of $("panes").children) button.setAttribute("aria-pressed", String(button.dataset.pane === t.pane));
}

/** Shows `pane`: a pane that runs is the session view, any other a note. */
function showPane(t, pane) {
  t.pane = pane?.id ?? null;
  history.replaceState(null, "", tabHash(t.id, t.pane));
  markShown(t);
  if (pane && isOpenable(pane)) {
    $("note").hidden = true;
    t.session = true;
    // The page's own start of this session takes it once; any other open asks the host's status first.
    const take = t.take === pane.session;
    if (take) t.take = null;
    openSession({ name: pane.session, title: tabTitle(t.data), host: t.host, done: t.done, take, tab: { id: t.id } });
    return;
  }
  t.session = false;
  releaseSession();
  showNote(t, pane);
}

function showNote(t, pane) {
  for (const id of ["card", "live", "terminal-view"]) $(id).hidden = true;
  $("note").hidden = false;
  // End is the phone's to offer only while it holds the tab; otherwise Take over comes first.
  $("end").hidden = !t.data.mine;
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
  const now = choosePane(t.data, t.pane);
  const changed = first || !samePanes(before, t.data.panes);
  if (changed) renderSwitcher(t);
  // The pane stays unless it is gone, or it began or stopped running.
  if (first || !now || now.id !== t.pane || (shown && isOpenable(shown) !== isOpenable(now))) {
    showPane(t, now);
  } else if (!t.session) {
    header(t, kindWord(now.kind));
    paintControl(t);
    $("end").hidden = !t.data.mine;
  }
}

function failed(t, error) {
  for (const id of ["card", "live", "terminal-view"]) $(id).hidden = true;
  $("note").hidden = false;
  $("note-control").hidden = true;
  $("note-take").hidden = true;
  $("note-file").hidden = true;
  $("note-detail").hidden = true;
  $("note-link").hidden = true;
  $("note-text").hidden = false;
  $("note-text").textContent = error;
  $("end").hidden = true;
  header(t, "");
}

/**
 * Opens a tab of the host, on `pane` if it has it. `done(text)` says the user left or ended it. `take` is a session name this page has just
 * started, which then attaches with take once; a tab the host reopened for this phone is labelled for it already.
 */
export function openTab({ tab, pane, host, done, take = null }) {
  closeTab();
  const t = { id: tab, pane, host: host || "", done, take, data: null, session: false, closed: false, generation: 0, timer: null };
  current = t;
  $("session").hidden = false;
  $("panes").hidden = true;
  // Nothing of the session or tab shown before: its card, live screen and terminal are gone from view until a pane is chosen.
  for (const id of ["card", "live", "terminal-view", "note"]) $(id).hidden = true;
  $("end").hidden = true;
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
  releaseSession();
  $("session").hidden = true;
  $("panes").hidden = true;
  $("panes").replaceChildren();
  $("note").hidden = true;
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

// The controls are wired once. In the session view session.js answers them; over a note this does.
$("back").addEventListener("click", () => { if (current && !current.session) current.done(null); });
$("end").addEventListener("click", () => { if (current && !current.session && current.data) endTab(current); });
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
