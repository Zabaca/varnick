// Add pane: a pane beside the one the tab view shows, in a tab this phone controls (options 03 and 05 of panes-open-only-by-hand-at-a-mac). A small
// form in a dialog, with the kinds the host offers for the shown pane (`GET /api/split-offer`): Claude, with the agents of its folder as chips and a
// prompt as New session has them; Terminal, which has nothing to fill in; App, a chip for each custom app the host lists from the folder; Page, one
// address field; and File, the folder browsed one level at a time (`GET /api/split-files`), Up stopping at the shown pane's folder. Add asks the
// server (`POST /api/split`), which checks the tab, the pane and what was picked and sends the host the split; on success the tab view switches to the
// new pane (tab.js). The page keeps no value for next time. Everything the host sent goes in with textContent, never as markup.

import { addable, addBody, entryPath, kindShown, kindsOffered, kindWord, relativeTo } from "/addrules.js";
import { element, getJSON, postJSON } from "/dom.js";

const $ = (id) => document.getElementById(id);

let current = null;

function setStatus(text, isError = false) {
  const line = $("add-status");
  line.textContent = text ?? "";
  line.hidden = !text;
  line.classList.toggle("error", isError);
}

/** A row of chips: one button each, `pressed` marking the chosen one. */
function chips(box, items, pressed, disabled) {
  box.replaceChildren();
  for (const item of items) {
    const chip = element("button", "chip", item.label);
    chip.type = "button";
    chip.setAttribute("aria-pressed", String(item.value === pressed));
    chip.dataset.value = item.value;
    chip.disabled = disabled;
    if (item.title) chip.title = item.title;
    box.append(chip);
  }
}

function renderAgents(s) {
  const wrap = $("add-agents-wrap");
  wrap.hidden = s.agents.length === 0 && !s.agentsError;
  chips($("add-agents"), s.agents.map((agent) => ({ value: agent.name, label: agent.name, title: agent.description })), s.agent, s.busy);
  if (s.agentsError) $("add-agents").append(element("p", "error", s.agentsError));
}

function renderApps(s) {
  const box = $("add-apps");
  chips(box, s.apps.map((app) => ({ value: app.folder, label: app.name })), s.app, s.busy);
  if (s.appsError) box.append(element("p", "error", s.appsError));
  else if (s.offer && s.apps.length === 0) box.append(element("p", "empty", "No app is found in this pane's folder."));
  else if (!s.offer) box.append(element("p", "empty", "Looking for apps…"));
}

function renderFiles(s) {
  const box = $("add-files");
  box.replaceChildren();
  const dir = s.listing;
  $("add-file-dir").textContent = dir ? relativeTo(dir.root, dir.dir) : "";
  $("add-file-picked").textContent = s.file && dir ? `Picked: ${relativeTo(dir.root, s.file)}` : "";
  $("add-file-picked").hidden = !(s.file && dir);
  if (s.fileError) box.append(element("p", "error", s.fileError));
  if (!dir) {
    if (!s.fileError) box.append(element("p", "empty", "Loading…"));
    return;
  }
  const row = (label, className, onTap, picked) => {
    const button = element("button", `project ${className}`, label);
    button.type = "button";
    button.disabled = s.busy;
    if (picked) button.setAttribute("aria-checked", "true");
    button.addEventListener("click", onTap);
    box.append(button);
  };
  if (dir.parent !== null) row("↑ Up", "up", () => loadDir(s, dir.parent));
  for (const entry of dir.entries) {
    const path = entryPath(dir.dir, entry.name);
    if (entry.folder) row(`${entry.name}/`, "dir", () => loadDir(s, path));
    else row(entry.name, "file", () => { s.file = path; render(s); }, path === s.file);
  }
  if (dir.entries.length === 0) box.append(element("p", "empty", "This folder is empty."));
  if (dir.more) box.append(element("p", "empty", "This folder has more entries than are listed."));
}

function render(s) {
  const offered = kindsOffered(s.offer);
  const kind = kindShown(s.kind, offered);
  s.kind = kind;
  chips($("add-kinds"), offered.map((value) => ({ value, label: kindWord(value) })), kind, s.busy);
  $("add-claude").hidden = kind !== "claude";
  $("add-app").hidden = kind !== "app";
  $("add-web").hidden = kind !== "web";
  $("add-file").hidden = kind !== "file";
  $("add-go").disabled = s.busy || !addable(s);
  $("add-go").textContent = s.busy ? "Adding…" : "Add";
  $("add-cancel").disabled = s.busy;
  $("add-url").disabled = s.busy;
  $("add-prompt").disabled = s.busy;
  if (kind === "claude") renderAgents(s);
  else if (kind === "app") renderApps(s);
  else if (kind === "file") renderFiles(s);
}

async function loadOffer(s) {
  const answer = await getJSON(`/api/split-offer?tab=${encodeURIComponent(s.tab)}&pane=${encodeURIComponent(s.pane)}`);
  if (s.closed) return;
  // Without chips Claude starts with no agent; the error says why there are none. Without an offer only Claude and a terminal are shown.
  if (!answer.ok) {
    s.agentsError = answer.error;
  } else {
    s.agents = answer.agents;
    s.apps = answer.apps ?? [];
    s.appsError = answer.appsError ?? null;
    s.offer = answer;
  }
  render(s);
}

/** Lists a folder of the shown pane's folder for the file picker; null asks for the pane's folder itself. */
async function loadDir(s, dir) {
  const token = ++s.listToken;
  s.fileError = null;
  const query = dir === null ? "" : `&dir=${encodeURIComponent(dir)}`;
  const answer = await getJSON(`/api/split-files?tab=${encodeURIComponent(s.tab)}&pane=${encodeURIComponent(s.pane)}${query}`);
  if (s.closed || token !== s.listToken) return;
  if (answer.ok) s.listing = answer;
  else s.fileError = answer.error;
  render(s);
}

async function add(s) {
  if (s.busy || !addable(s)) return;
  s.busy = true;
  render(s);
  setStatus("Adding. A Mac can take up to half a minute to answer.");
  // The host may have added it all the same: the switcher shows the pane when it has.
  const result = await postJSON("/api/split", addBody(s, $("add-prompt").value), "The host didn't answer. If it was added, the pane is in the switcher.");
  // The dialog can be closed under a request (the phone lost control of the tab): the error then goes to the page's own status line.
  if (s.closed) {
    if (!result.ok) s.failed(result.error);
    return;
  }
  s.busy = false;
  if (!result.ok) {
    render(s);
    return setStatus(result.error, true);
  }
  const added = s.added;
  closeAdd();
  added({ session: result.session ?? null, pane: result.pane ?? null });
}

/**
 * Opens Add pane beside `pane` of `tab`. `added({session, pane})` says the host added a pane (`session` is null for a page, an app and a file): the
 * tab view then switches to it. `failed(error)` says an add failed after the dialog was closed.
 */
export function openAdd({ tab, pane, host, added, failed }) {
  closeAdd();
  const s = {
    closed: false, busy: false, tab, pane, kind: "claude", offer: null, agents: [], agentsError: null, agent: null, apps: [], appsError: null, app: null,
    url: "", listing: null, listToken: 0, fileError: null, file: null, added, failed,
  };
  current = s;
  $("add-host").textContent = host || "";
  $("add-prompt").value = "";
  $("add-url").value = "";
  setStatus(null);
  render(s);
  if (!$("add").open) $("add").showModal();
  loadOffer(s);
}

export function closeAdd() {
  const s = current;
  if (!s) return;
  current = null;
  s.closed = true;
  $("add-prompt").value = "";
  $("add-url").value = "";
  if ($("add").open) $("add").close();
}

$("add-kinds").addEventListener("click", (event) => {
  const button = event.target.closest("button");
  const s = current;
  if (!s || !button || s.busy) return;
  s.kind = button.dataset.value;
  setStatus(null);
  render(s);
  // The folder is listed when the picker is first shown, not before.
  if (s.kind === "file" && !s.listing && !s.fileError) loadDir(s, null);
});
$("add-agents").addEventListener("click", (event) => {
  const chip = event.target.closest("button.chip");
  const s = current;
  if (!s || !chip || s.busy) return;
  // Tapping the chosen chip again picks no agent.
  s.agent = s.agent === chip.dataset.value ? null : chip.dataset.value;
  render(s);
});
$("add-apps").addEventListener("click", (event) => {
  const chip = event.target.closest("button.chip");
  const s = current;
  if (!s || !chip || s.busy) return;
  s.app = s.app === chip.dataset.value ? null : chip.dataset.value;
  render(s);
});
$("add-url").addEventListener("input", () => {
  const s = current;
  if (!s) return;
  s.url = $("add-url").value;
  render(s);
});
$("add-go").addEventListener("click", () => { if (current) add(current); });
$("add-cancel").addEventListener("click", () => { if (current && !current.busy) closeAdd(); });
// Escape and the system's back close it, but not while the host is being asked: the answer is still to be told.
$("add").addEventListener("cancel", (event) => { if (current?.busy) event.preventDefault(); });
$("add").addEventListener("close", () => { if (current && !current.busy) closeAdd(); });
