// The Phone page's home: the host's open tabs, each a row, and its Recent, which lists closed tabs, from /api/home. A tab row opens the tab
// (tab.js) at `#t=<tab>`, so Back returns here; a session started or found without its tab opens at `#s=<name>` (session.js). Everything the
// host sent goes in with textContent, never as markup.

import { element, notListed, postJSON, shortFolder } from "/dom.js";
import { startInstall } from "/install.js";
import { closeNew, openNew } from "/new.js";
import { closeNotices, startPush } from "/push.js";
import { closeSession, openSession } from "/session.js";
import { closeTab, openTab } from "/tab.js";
import { closeVoice, openVoice } from "/voice.js";
import { paneSummary, parseTabHash, tabHash, tabTitle } from "/tabrules.js";

const $ = (id) => document.getElementById(id);
const refreshButton = $("refresh");
let generation = 0;
/** What the last home said, for the session view's first paint. */
let hostName = "";
const titles = new Map();

const ago = (seconds) => {
  const elapsed = Math.round(Date.now() / 1000 - seconds);
  const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  for (const [limit, unit, size] of [[60, "second", 1], [3600, "minute", 60], [86400, "hour", 3600], [86400 * 30, "day", 86400]]) {
    if (elapsed < limit) return formatter.format(-Math.floor(elapsed / size), unit);
  }
  return new Date(seconds * 1000).toLocaleDateString();
};

/** A row's content; an open session's row is a link that opens it. */
function row(title, folder, agent, session) {
  const item = element("li");
  const body = session ? element("a", "row-link") : item;
  if (session) body.href = `#s=${session}`;
  body.append(title ? element("div", "title", title) : element("div", "title untitled", "Untitled"));
  const meta = element("div", "meta");
  if (folder) {
    const path = element("span", "folder", shortFolder(folder));
    path.title = folder;
    meta.append(path);
  }
  if (agent) meta.append(element("span", "agent", agent));
  body.append(meta);
  if (session) item.append(body);
  return { item, body };
}

/** An open tab's row: a link that opens it, with what it holds and who is in control. */
function tabRow(tab) {
  const first = tab.panes.find((pane) => pane.kind === "claude") ?? tab.panes[0];
  const item = element("li");
  const link = element("a", "row-link");
  link.href = tabHash(tab.tab, null);
  link.append(element("div", "title", tabTitle(tab)));
  const meta = element("div", "meta");
  if (first.folder) {
    const path = element("span", "folder", shortFolder(first.folder));
    path.title = first.folder;
    meta.append(path);
  }
  if (first.agent) meta.append(element("span", "agent", first.agent));
  meta.append(element("span", "", paneSummary(tab)));
  link.append(meta);
  if (tab.text) link.append(element("div", tab.mine ? "control mine" : "control", tab.text));
  item.append(link);
  return item;
}

function fill(container, part, emptyText, build) {
  container.replaceChildren();
  if (part.error !== undefined) {
    container.append(element("p", "error", part.error));
  } else if (part.rows.length === 0) {
    container.append(element("p", "empty", emptyText));
  } else {
    const list = element("ul");
    for (const rowData of part.rows) list.append(build(rowData));
    container.append(list);
  }
}

function show(home) {
  $("host").textContent = home.host.name;
  $("device").textContent = `You are ${home.device.name}`;
  document.title = `${home.host.name} · Phone page`;
  hostName = home.host.name;
  // Voice mode needs a Mac's transcriber and voice: a headless host has neither.
  $("voice-mode").hidden = home.host.headless === true;
  titles.clear();
  fill($("sessions"), home.tabs, "No tabs are open.", (tab) => {
    for (const pane of tab.panes) if (pane.session) titles.set(pane.session, pane.title);
    return tabRow(tab);
  });
  // Runs nobody opened: their own section, there only while there are some (a host before protocol 29 sends none).
  const runs = home.runs?.rows ?? [];
  $("runs-section").hidden = runs.length === 0;
  if (runs.length > 0) {
    fill($("runs"), home.runs, "", (tab) => {
      for (const pane of tab.panes) if (pane.session) titles.set(pane.session, pane.title);
      return tabRow(tab);
    });
  } else {
    $("runs").replaceChildren();
  }
  showHosts(home.hosts);
  fill($("recent"), home.recent, "Nothing in Recent yet.", (recent) => {
    const first = recent.sessions[0];
    const { item, body } = row(recent.title, first.folder, first.agent);
    if (recent.sessions.length > 1) body.append(element("div", "control", `${recent.sessions.length} sessions`));
    if (recent.last) body.append(element("div", "control", ago(recent.last)));
    item.dataset.tab = recent.tab;
    const button = element("button", "resume", "Resume");
    button.type = "button";
    button.addEventListener("click", () => resume(recent));
    item.append(button, element("div", "resume-message"));
    paintResume(item);
    return item;
  });
}

/** The other hosts' pages: a link each, by name. The server made every URL; one that isn't https is dropped all the same. */
function showHosts(hosts) {
  const list = $("hosts");
  list.replaceChildren();
  for (const host of hosts ?? []) {
    if (typeof host.url !== "string" || !host.url.startsWith("https://")) continue;
    const item = element("li");
    const link = element("a", "row-link", host.name);
    link.href = host.url;
    link.rel = "noreferrer";
    item.append(link);
    list.append(item);
  }
  $("hosts-section").hidden = list.children.length === 0;
}

/**
 * Resume: the host reopens the closed tab whole, in its layout (`POST /api/resume`): its Claude panes resumed and its terminals started
 * fresh, all labelled for this phone, and the tab opens. A tab that is open on the host already comes back as a link to open it, where
 * Take over is. What is under way, or was refused, is kept by tab and painted onto whatever rows show it: a home that reloads while the
 * host answers builds new rows.
 */
const resuming = new Map();

function paintResume(item) {
  const state = resuming.get(item.dataset.tab);
  const button = item.querySelector("button.resume");
  const message = item.querySelector(".resume-message");
  button.disabled = state?.busy === true;
  button.textContent = state?.busy ? "Resuming…" : "Resume";
  message.replaceChildren();
  message.hidden = !state?.error;
  if (!state?.error) return;
  message.append(element("p", "error", state.error));
  if (!state.openTab) return;
  const link = element("a", "open-link", "Open the tab");
  link.href = tabHash(state.openTab, null);
  message.append(link);
}

function paintResumes(tab) {
  for (const item of document.querySelectorAll("li[data-tab]")) {
    if (item.dataset.tab === tab) paintResume(item);
  }
}

async function resume(recent) {
  const tab = recent.tab;
  if (resuming.get(tab)?.busy) return;
  resuming.set(tab, { busy: true, error: null, openTab: null });
  paintResumes(tab);
  const result = await postJSON("/api/resume", { tab }, "The host didn't answer. If it started, the tab is in Open tabs.");
  if (result.ok) {
    resuming.delete(tab);
    paintResumes(tab);
    // Whatever the page shows now: the tab is the host's, labelled for this phone, and it was asked for.
    location.hash = tabHash(result.tab ?? tab, null).slice(1);
    return;
  }
  resuming.set(tab, { busy: false, error: result.error, openTab: result.openTab ?? null });
  paintResumes(tab);
}

/**
 * Opens a session this page has just started: the terminal attaches with take, the one place besides Take over that sets it. It opens in
 * its tab when the host named one, else alone. `replace` swaps New session's history entry, so Back goes to the home and not to an empty form.
 */
function enterSession(session, title, replace, tab = null) {
  titles.set(session, title);
  takeOnce = session;
  const hash = tab ? tabHash(tab, session.slice("varnick-".length)) : `#s=${session}`;
  if (replace) {
    history.replaceState(null, "", hash);
    route();
  } else {
    location.hash = hash.slice(1);
  }
}

/** The one session that opens with take, once: set by `enterSession`, used (and cleared) by the next `route`. */
let takeOnce = null;

function failed(message) {
  for (const id of ["sessions", "recent"]) {
    const container = $(id);
    container.replaceChildren(element("p", "error", message));
  }
}

async function load() {
  const mine = ++generation;
  refreshButton.disabled = true;
  try {
    const response = await fetch("/api/home", { cache: "no-store", headers: { accept: "application/json" } });
    if (mine !== generation) return;
    if (response.status === 403) failed(notListed);
    else if (!response.ok) failed(`The host answered ${response.status}.`);
    else show(await response.json());
  } catch {
    if (mine === generation) failed("The host didn't answer. Check that you're on the tailnet, then Refresh.");
  } finally {
    if (mine === generation) refreshButton.disabled = false;
  }
}

/** `#s=<session>`: a pane's zmx session name, which has a lowercase uuid (`Zmx.paneID`). */
const sessionHash = /^#s=(varnick-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/;
const noticeLine = $("notice");

function notice(text) {
  noticeLine.textContent = text ?? "";
  noticeLine.hidden = !text;
}

/**
 * Back to the home: from the session view, with what End said, if it did. The session's entry in the history is replaced,
 * not added to, so the browser's Back doesn't open an ended (or left) session again.
 */
function goHome(text) {
  notice(text);
  history.replaceState(null, "", location.pathname + location.search);
  route();
}

/** The address says which view: `#t=<tab>` is a tab, `#s=<session>` a session, `#new` is New session, `#voice` is Voice mode, anything else the home. */
function route() {
  const tabMatch = parseTabHash(location.hash);
  const match = sessionHash.exec(location.hash);
  // Take is for the one session the page has just started, once: a reload or a revisit never repeats it.
  const take = match !== null && takeOnce === match[1];
  const takeSession = takeOnce;
  takeOnce = null;
  // Each view closes the others; the one that opens sets the body's class.
  const views = { tab: tabMatch !== null, session: match !== null, new: location.hash === "#new", voice: location.hash === "#voice" };
  if (!views.new) closeNew();
  if (!views.voice) closeVoice();
  if (!views.session) closeSession();
  if (!views.tab) closeTab();
  document.body.classList.remove("in-new", "in-voice");
  if (tabMatch) {
    $("home").hidden = true;
    document.body.classList.add("in-session");
    document.title = hostName ? `${hostName} · Phone page` : "Phone page";
    openTab({ tab: tabMatch.tab, pane: tabMatch.pane, host: hostName, done: goHome, take: takeSession });
    // Opening a tab is seeing what its notifications said.
    closeNotices(tabMatch.tab);
  } else if (match) {
    $("home").hidden = true;
    document.body.classList.add("in-session");
    // Never a session's title or a prompt: the title goes into the browser's history, and into Chrome Sync.
    document.title = hostName ? `${hostName} · Phone page` : "Phone page";
    openSession({ name: match[1], title: titles.get(match[1]) ?? "", host: hostName, done: goHome, take });
  } else if (views.new) {
    $("home").hidden = true;
    document.body.classList.remove("in-session");
    document.body.classList.add("in-new");
    document.title = hostName ? `New session · ${hostName}` : "New session · Phone page";
    openNew({ host: hostName, started: ({ session, title, tab }) => enterSession(session, title, true, tab), done: goHome });
  } else if (views.voice) {
    $("home").hidden = true;
    document.body.classList.remove("in-session");
    document.body.classList.add("in-voice");
    document.title = hostName ? `Voice mode · ${hostName}` : "Voice mode · Phone page";
    openVoice({ host: hostName, done: goHome, openSession: (session) => enterSession(session, "Hey Varnick", false) });
  } else {
    document.body.classList.remove("in-session");
    $("home").hidden = false;
    load();
  }
  // A session opened from far down the home would otherwise keep the home's scroll.
  fitViewport();
}

// The session and New session fill the screen, and the keyboard can scroll the page under them as it opens (Chrome brings the
// focused box into view before it resizes the page): the page never scrolls back, so the header stays off the top. They
// take the visible height and go back to the top whenever it changes. Not while pinched in, which also shrinks it.
const fullScreen = () => document.body.classList.contains("in-session") || document.body.classList.contains("in-new");
function fitViewport() {
  const viewport = window.visualViewport;
  if (!viewport || viewport.scale > 1.01) return;
  document.documentElement.style.setProperty("--page-height", `${viewport.height}px`);
  if (fullScreen() && (window.scrollX || window.scrollY)) window.scrollTo(0, 0);
}
window.visualViewport?.addEventListener("resize", fitViewport);
window.visualViewport?.addEventListener("scroll", fitViewport);
window.addEventListener("scroll", fitViewport);
// A rotation, a fold or a return from another app does not always send a visualViewport event the page sees (a hidden page misses it),
// so the height is set again whenever the page is resized or shown. A viewport pinched in still skips it, here as in the events above.
window.addEventListener("resize", fitViewport);
window.addEventListener("orientationchange", fitViewport);
window.addEventListener("pageshow", fitViewport);

refreshButton.addEventListener("click", () => { notice(null); load(); });
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") fitViewport();
  if (document.visibilityState === "visible" && !$("home").hidden) load();
});
window.addEventListener("hashchange", route);
route();
startInstall();
startPush((hash) => { location.hash = hash; });
