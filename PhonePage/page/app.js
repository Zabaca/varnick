// The Phone page's home: the host's open Claude sessions and its Recent, from /api/home. A session row opens its
// session (session.js) at `#s=<name>`, so Back returns here. Everything the host sent goes in with textContent, never as markup.

import { element, notListed, postJSON, shortFolder } from "/dom.js";
import { closeNew, openNew } from "/new.js";
import { closeSession, openSession } from "/session.js";

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
  titles.clear();
  fill($("sessions"), home.sessions, "No Claude sessions are open.", (session) => {
    titles.set(session.session, session.title);
    const { item, body } = row(session.title, session.folder, session.agent, session.session);
    body.append(element("div", session.mine ? "control mine" : "control", session.text));
    return item;
  });
  showHosts(home.hosts);
  fill($("recent"), home.recent, "Nothing in Recent yet.", (recent) => {
    const { item, body } = row(recent.title, recent.folder, recent.agent);
    if (recent.last) body.append(element("div", "control", ago(recent.last)));
    item.dataset.conversation = recent.conversation;
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
 * Resume: the host starts that conversation again under a new session id (`POST /api/resume`: the server finds the folder
 * and agent in the host's own Recent) and the terminal opens with take. A conversation the host has open in a running
 * session comes back as that session's row, with Take over on it. What is under way, or was refused, is kept by
 * conversation and painted onto whatever rows show it: a home that reloads while the host answers builds new rows.
 */
const resuming = new Map();

function paintResume(item) {
  const state = resuming.get(item.dataset.conversation);
  const button = item.querySelector("button.resume");
  const message = item.querySelector(".resume-message");
  button.disabled = state?.busy === true;
  button.textContent = state?.busy ? "Resuming…" : "Resume";
  message.replaceChildren();
  message.hidden = !state?.error;
  if (!state?.error) return;
  message.append(element("p", "error", state.error));
  const open = state.open;
  if (!open) return;
  message.append(element("p", "open-line", open.text));
  const take = element("button", "take-here", "Take over");
  take.type = "button";
  take.addEventListener("click", () => enterSession(open.session, open.title, false));
  const link = element("a", "open-link", "Open");
  link.href = `#s=${open.session}`;
  titles.set(open.session, open.title);
  message.append(take, link);
}

function paintResumes(conversation) {
  for (const item of document.querySelectorAll("li[data-conversation]")) {
    if (item.dataset.conversation === conversation) paintResume(item);
  }
}

async function resume(recent) {
  const conversation = recent.conversation;
  if (resuming.get(conversation)?.busy) return;
  resuming.set(conversation, { busy: true, error: null, open: null });
  paintResumes(conversation);
  const result = await postJSON("/api/resume", { conversation }, "The host didn't answer. If it started, the session is in Open sessions.");
  if (result.ok) {
    resuming.delete(conversation);
    paintResumes(conversation);
    // Whatever the page shows now: the session is the host's, and it was asked for.
    return enterSession(result.session, recent.title, false);
  }
  resuming.set(conversation, { busy: false, error: result.error, open: result.open ?? null });
  paintResumes(conversation);
}

/**
 * Opens a session this page has just started or resumed: the terminal attaches with take, the one place besides Take over
 * that sets it. `replace` swaps New session's history entry, so Back goes to the home and not to an empty form.
 */
function enterSession(session, title, replace) {
  titles.set(session, title);
  takeOnce = session;
  if (replace) {
    history.replaceState(null, "", `#s=${session}`);
    route();
  } else {
    location.hash = `s=${session}`;
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

/** The address says which view: `#s=<session>` is a session, `#new` is New session, anything else the home. */
function route() {
  const match = sessionHash.exec(location.hash);
  // Take is for the one session the page has just started or resumed, once: a reload or a revisit never repeats it.
  const take = match !== null && takeOnce === match[1];
  takeOnce = null;
  if (match) {
    closeNew();
    $("home").hidden = true;
    document.body.classList.remove("in-new");
    document.body.classList.add("in-session");
    // Never a session's title or a prompt: the title goes into the browser's history, and into Chrome Sync.
    document.title = hostName ? `${hostName} · Phone page` : "Phone page";
    openSession({ name: match[1], title: titles.get(match[1]) ?? "", host: hostName, done: goHome, take });
  } else if (location.hash === "#new") {
    closeSession();
    $("home").hidden = true;
    document.body.classList.remove("in-session");
    document.body.classList.add("in-new");
    document.title = hostName ? `New session · ${hostName}` : "New session · Phone page";
    openNew({ host: hostName, started: ({ session, title }) => enterSession(session, title, true), done: goHome });
  } else {
    closeSession();
    closeNew();
    document.body.classList.remove("in-session", "in-new");
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

refreshButton.addEventListener("click", () => { notice(null); load(); });
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && !$("home").hidden) load();
});
window.addEventListener("hashchange", route);
route();
