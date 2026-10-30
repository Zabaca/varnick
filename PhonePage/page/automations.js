// Automations: the Mac's list (name, when it next runs, how the last run ended, the mark a session or this phone left), one automation with Switch, Run now,
// Edit and Delete (which asks first, because it drops the run list), and the form that makes or edits one. The Mac decides everything: it checks each field as it
// checks a session's call and writes through its automation store, and this page shows its lines. The phone never offers Skip permissions. Everything the host
// sent goes in with textContent, never as markup.

import { element, getJSON, postJSON, shortFolder } from "/dom.js";
import {
  automationsHash, blankDraft, cadenceKinds, cadenceOf, draftOf, draftProblems, folderName, hourSteps, markText, minuteSteps, permissionChoices,
  permissionsText, saveBody, statusText, timeText, weekdayNames,
} from "/automationsrules.js";

const $ = (id) => document.getElementById(id);

let current = null;

function setStatus(text, isError = false) {
  const line = $("automations-status");
  line.textContent = text ?? "";
  line.hidden = !text;
  line.classList.toggle("error", isError);
}

/** What the Mac says an ask did, or why it did nothing, on the status line. */
function say(result) {
  if (result.refused?.length) return setStatus(result.refused.join("\n"), true);
  setStatus(result.note ?? null);
}

// ---------------------------------------------------------------------------------------------------------------
// The list

async function load(s) {
  const result = await getJSON("/api/automations");
  if (s.closed) return;
  s.loaded = true;
  if (!result.ok) {
    s.loadError = result.error;
    return render(s);
  }
  s.loadError = null;
  take(s, result);
  render(s);
}

/** What a reply carries of the Mac's state: the list, its problem, the zone and Skip's state. */
function take(s, result) {
  s.items = result.automations;
  s.problem = result.problem;
  s.skip = result.skipPermissions;
  s.zone = result.timeZone;
}

function rowFor(automation) {
  const item = element("li", automation.enabled ? "" : "auto-off");
  const link = element("a", "auto-row");
  link.href = automationsHash(automation.id);
  link.append(element("div", "auto-name", automation.name || "Untitled"));
  link.append(element("div", "auto-line", [automation.cadenceLabel, folderName(automation.folder), automation.agent ? `@${automation.agent}` : null].filter(Boolean).join(" · ")));
  const status = statusText(automation);
  if (status) link.append(element("div", "auto-line", status));
  if (automation.mark) link.append(element("div", "auto-mark", markText(automation.mark)));
  item.append(link);
  return item;
}

function renderList(s) {
  const list = $("automations-list");
  list.replaceChildren(...s.items.map(rowFor));
  const empty = $("automations-empty");
  empty.hidden = s.items.length > 0 || !s.loaded || s.loadError !== null || s.problem !== null;
  empty.textContent = "No automations on this Mac yet. Make one with New automation.";
}

// ---------------------------------------------------------------------------------------------------------------
// One automation

function fact(list, name, value) {
  list.append(element("dt", "", name), element("dd", "", value));
}

function button(label, className, onClick) {
  const node = element("button", className, label);
  node.type = "button";
  node.addEventListener("click", onClick);
  return node;
}

function renderDetail(s, automation) {
  const view = $("automation-view");
  view.replaceChildren();
  view.append(element("div", "auto-title", automation.name || "Untitled"));
  const status = statusText(automation);
  if (status) view.append(element("p", "auto-line", status));
  if (automation.mark) view.append(element("p", "auto-mark", markText(automation.mark)));
  view.append(element("div", "auto-prompt", automation.prompt));
  const facts = element("dl", "auto-facts");
  fact(facts, "Runs", `${automation.cadenceLabel} (${automation.timeZone})`);
  fact(facts, "Folder", automation.folder === null ? "Home" : shortFolder(automation.folder));
  if (automation.agent) fact(facts, "Agent", `@${automation.agent}`);
  fact(facts, "Permissions", permissionsText(automation, s.skip));
  if (automation.allowedTools.length > 0) fact(facts, "Allowed tools", automation.allowedTools.join(", "));
  fact(facts, "Working limit", `${automation.workingLimitMinutes} minutes`);
  view.append(facts);

  const actions = element("div", "auto-actions");
  actions.append(button(automation.enabled ? "Turn off" : "Turn on", "", () => act(s, { kind: "switch", id: automation.id, on: !automation.enabled })));
  actions.append(button("Run now", "", () => act(s, { kind: "run", id: automation.id })));
  if (automation.editable) {
    const edit = element("a", "button", "Edit");
    edit.href = automationsHash(automation.id, true);
    actions.append(edit);
  }
  actions.append(button("Delete", "danger", () => { s.confirmingDelete = automation.id; renderDetail(s, automation); }));
  view.append(actions);
  if (!automation.editable) {
    view.append(element("p", "hint", "This one is set to Skip permissions on the Mac, so it is edited there. You can still turn it on or off and run it from here."));
  }
  if (s.confirmingDelete === automation.id) {
    const confirm = element("div", "auto-confirm");
    confirm.append(element("p", "", `Delete “${automation.name || "this automation"}” and its run list? A run still going stays as an ordinary tab.`));
    const row = element("div", "card-actions");
    row.append(
      button("Keep", "", () => { s.confirmingDelete = null; renderDetail(s, automation); }),
      button("Delete", "primary danger", () => remove(s, automation)),
    );
    confirm.append(row);
    view.append(confirm);
  }
  view.querySelectorAll("button").forEach((node) => { node.disabled = s.busy; });
}

/** An ask that changes something: the Mac answers with the list after it, which the page draws, and says what it did or why it did nothing. */
async function act(s, body) {
  if (s.busy) return;
  s.busy = true;
  setStatus(body.kind === "run" ? "Starting a run. A Mac can take a few seconds to answer." : null);
  render(s);
  const result = await postJSON("/api/automations/act", body, "The host didn't answer. Refresh to see whether it went through.");
  if (s.closed) return;
  s.busy = false;
  if (result.automations) take(s, result);
  if (!result.ok) setStatus(result.error, true);
  else say(result);
  render(s);
  return result;
}

async function remove(s, automation) {
  const result = await act(s, { kind: "delete", id: automation.id });
  s.confirmingDelete = null;
  // Gone: back to the list, which says it.
  if (result?.ok && !result.refused?.length) {
    s.keepStatus = true;
    location.hash = automationsHash(null).slice(1);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// The form

function renderKinds(s) {
  const box = $("auto-kinds");
  box.replaceChildren();
  for (const { kind, title } of cadenceKinds) {
    const chip = element("button", "chip", title);
    chip.type = "button";
    chip.setAttribute("aria-pressed", String(s.draft.cadence.kind === kind));
    chip.dataset.kind = kind;
    box.append(chip);
  }
  const { cadence } = s.draft;
  const steps = $("auto-steps");
  steps.replaceChildren();
  steps.hidden = cadence.kind !== "minutes" && cadence.kind !== "hours";
  for (const every of cadence.kind === "minutes" ? minuteSteps : hourSteps) {
    const chip = element("button", "chip", cadence.kind === "minutes" ? `Every ${every} min` : every === 1 ? "Every hour" : `Every ${every} hours`);
    chip.type = "button";
    chip.setAttribute("aria-pressed", String(cadence.every === every));
    chip.dataset.every = String(every);
    steps.append(chip);
  }
  const days = $("auto-days");
  days.replaceChildren();
  days.hidden = cadence.kind !== "weekly";
  weekdayNames.forEach((name, index) => {
    const chip = element("button", "chip", name.slice(0, 3));
    chip.type = "button";
    chip.title = name;
    chip.setAttribute("aria-pressed", String(cadence.weekday === index + 1));
    chip.dataset.weekday = String(index + 1);
    days.append(chip);
  });
  const time = $("auto-time");
  time.hidden = !["daily", "weekdays", "weekly"].includes(cadence.kind);
  if (!time.hidden) time.value = `${String(cadence.hour).padStart(2, "0")}:${String(cadence.minute).padStart(2, "0")}`;
  const zone = $("auto-zone");
  zone.hidden = time.hidden;
  zone.textContent = s.zone ? `${timeText(cadence.hour ?? 9, cadence.minute ?? 0)} in the Mac's time zone (${s.zone}).` : "In the Mac's time zone.";
}

function renderPermissions(s) {
  const box = $("auto-permissions");
  box.replaceChildren();
  for (const choice of permissionChoices) {
    const chip = element("button", "chip", choice.title);
    chip.type = "button";
    chip.setAttribute("aria-pressed", String(s.draft.permissions === choice.value));
    chip.dataset.value = choice.value;
    box.append(chip);
  }
  const chosen = permissionChoices.find((choice) => choice.value === s.draft.permissions);
  $("auto-permissions-detail").textContent = (chosen?.detail ?? "") + " The phone never sets Skip permissions.";
}

function renderProjects(s) {
  const box = $("auto-projects");
  box.replaceChildren();
  const row = (value, name, detail, title) => {
    const node = element("button", "project");
    node.type = "button";
    node.setAttribute("role", "radio");
    node.setAttribute("aria-checked", String(value === s.draft.folder));
    node.dataset.path = value ?? "";
    node.append(element("span", "project-name", name));
    const path = element("span", "project-path", detail);
    path.title = title;
    node.append(path);
    return node;
  };
  box.append(row(null, "Home", "No project", "Varnick's Home folder on this Mac"));
  const words = s.query.toLowerCase().split(/\s+/).filter(Boolean);
  const shown = s.projects.filter((path) => words.every((word) => path.toLowerCase().includes(word)));
  // A folder the automation has that the Mac's project list doesn't hold stays pickable, so an edit doesn't silently move it.
  if (s.draft.folder !== null && !s.projects.includes(s.draft.folder)) box.append(row(s.draft.folder, folderName(s.draft.folder), shortFolder(s.draft.folder), s.draft.folder));
  for (const path of shown) box.append(row(path, folderName(path), shortFolder(path), path));
  if (s.projectsError) box.append(element("p", "error", s.projectsError));
  else if (s.projects.length === 0 && s.projectsLoaded) box.append(element("p", "empty", "This Mac lists no projects. Home is always there."));
}

function renderAgents(s) {
  const wrap = $("auto-agents-wrap");
  const box = $("auto-agents");
  box.replaceChildren();
  wrap.hidden = s.agents.length === 0 && !s.agentsError;
  for (const agent of s.agents) {
    const chip = element("button", "chip", agent.name);
    chip.type = "button";
    chip.setAttribute("aria-pressed", String(agent.name === s.draft.agent));
    chip.dataset.name = agent.name;
    if (agent.description) chip.title = agent.description;
    box.append(chip);
  }
  if (s.agentsError) box.append(element("p", "error", s.agentsError));
}

async function loadAgents(s) {
  const folder = s.draft.folder;
  s.agentsFor = folder;
  s.agentsError = null;
  const answer = await getJSON(folder === null ? "/api/agents" : `/api/agents?folder=${encodeURIComponent(folder)}`);
  if (s.closed || s.agentsFor !== folder) return;
  if (answer.ok) s.agents = answer.agents;
  else {
    s.agents = [];
    s.agentsError = answer.error;
  }
  renderAgents(s);
}

async function loadProjects(s) {
  const answer = await getJSON("/api/projects");
  if (s.closed) return;
  s.projectsLoaded = true;
  if (answer.ok) s.projects = answer.projects.map((project) => project.path);
  else s.projectsError = answer.error;
  renderProjects(s);
}

function updateFormFields(s) {
  $("auto-name").value = s.draft.name;
  $("auto-prompt").value = s.draft.prompt;
  $("auto-tools").value = s.draft.allowedTools;
  $("auto-limit").value = String(s.draft.workingLimit);
  $("auto-enabled").checked = s.draft.enabled;
  $("auto-project-filter").value = s.query;
  renderKinds(s);
  renderPermissions(s);
  renderProjects(s);
  renderAgents(s);
}

function startForm(s, automation) {
  s.draft = automation ? draftOf(automation) : blankDraft();
  s.editingID = automation?.id ?? null;
  // What the form opened with: an edit sends only what differs from it.
  s.original = automation ? structuredClone(automation) : null;
  s.query = "";
  s.agents = [];
  s.agentsError = null;
  s.formKey = automation?.id ?? "new";
  updateFormFields(s);
  loadAgents(s);
  if (!s.projectsLoaded) loadProjects(s);
}

async function save(s) {
  if (s.busy) return;
  const problems = draftProblems(s.draft);
  if (problems.length > 0) return setStatus(problems.join("\n"), true);
  const id = s.editingID;
  const body = saveBody(id, s.draft, s.original);
  if (body === null) {
    // Nothing differs from what the form opened with: nothing is sent, and the Mac's copy is untouched.
    s.keepStatus = true;
    setStatus("No changes.");
    location.hash = automationsHash(id).slice(1);
    return;
  }
  const result = await act(s, body);
  if (!result?.ok || result.refused?.length) return;
  // Saved: its page, with what the Mac said.
  s.keepStatus = true;
  location.hash = automationsHash(id ?? result.made ?? null).slice(1);
}

// ---------------------------------------------------------------------------------------------------------------

function render(s) {
  const target = s.target;
  const found = target.id === null ? null : s.items.find((item) => item.id === target.id) ?? null;
  const listing = !target.editing && target.id === null;
  const form = target.editing && (target.isNew || found !== null);
  const detail = !listing && !form && found !== null;
  $("automations-list-view").hidden = !listing;
  $("automation-view").hidden = !detail;
  $("automation-form").hidden = !form;
  $("automations-new").hidden = !listing;
  $("automation-save").hidden = !form;
  $("automation-save").disabled = s.busy;
  $("automations-refresh").disabled = s.busy;
  $("automations-title").textContent = form ? (target.isNew ? "New automation" : "Edit automation") : detail ? "Automation" : "Automations";
  $("automations-problem").hidden = s.problem === null && s.loadError === null;
  $("automations-problem").textContent = s.loadError ?? (s.problem === null ? "" : `${s.problem} Nothing here can be changed until it is fixed on the Mac.`);
  if (s.problem !== null) $("automation-save").disabled = true;
  if (listing) renderList(s);
  if (detail) renderDetail(s, found);
  if (form) {
    // The form is built once per automation, so typing isn't undone by a redraw.
    const key = target.isNew ? "new" : target.id;
    if (s.formKey !== key) startForm(s, target.isNew ? null : found);
  } else {
    s.formKey = null;
  }
  if (!listing && !form && found === null && target.id !== null) {
    $("automation-view").hidden = false;
    $("automation-view").replaceChildren(element("p", "empty", !s.loaded ? "Loading…" : s.loadError ? "" : "That automation isn't on this Mac any more."));
  }
}

/**
 * Opens the view for `target` (`parseAutomationsHash`). It is called again as the address changes inside the view, so it keeps what it has loaded.
 * `done()` says the user went back out of the view.
 */
export function openAutomations({ host, target, done }) {
  const s = current ?? (current = {
    closed: false, keepStatus: false, items: [], loaded: false, loadError: null, problem: null, skip: false, zone: "", busy: false, confirmingDelete: null,
    draft: blankDraft(), editingID: null, original: null, formKey: null, query: "", projects: [], projectsLoaded: false, projectsError: null, agents: [], agentsFor: null, agentsError: null,
  });
  s.target = target;
  s.done = done;
  $("automations").hidden = false;
  $("automations-host").textContent = host || "";
  // A move inside the view clears the last line, except right after a save or a delete, whose word is for the page it lands on.
  if (!s.keepStatus) setStatus(null);
  s.keepStatus = false;
  if (!s.loaded) load(s);
  render(s);
}

export function closeAutomations() {
  const s = current;
  if (!s) return;
  current = null;
  s.closed = true;
  $("automations").hidden = true;
}

$("automations-back").addEventListener("click", () => {
  const s = current;
  if (!s) return;
  const { target } = s;
  setStatus(null);
  // One step up: the form returns to its automation (or the list), an automation to the list, the list to the home.
  if (target.editing && !target.isNew) location.hash = automationsHash(target.id).slice(1);
  else if (target.id !== null || target.isNew) location.hash = automationsHash(null).slice(1);
  else s.done();
});
$("automations-refresh").addEventListener("click", () => { if (current) { setStatus(null); load(current); } });
$("automation-save").addEventListener("click", () => { if (current) save(current); });

// The form's fields write into the draft as they change; the chips are rebuilt on every render, so one listener on each container handles them.
$("auto-name").addEventListener("input", (event) => { if (current) current.draft.name = event.target.value; });
$("auto-prompt").addEventListener("input", (event) => { if (current) current.draft.prompt = event.target.value; });
$("auto-tools").addEventListener("input", (event) => { if (current) current.draft.allowedTools = event.target.value; });
$("auto-limit").addEventListener("input", (event) => { if (current) current.draft.workingLimit = event.target.value; });
$("auto-enabled").addEventListener("change", (event) => { if (current) current.draft.enabled = event.target.checked; });
$("auto-project-filter").addEventListener("input", (event) => {
  if (!current) return;
  current.query = event.target.value;
  renderProjects(current);
});
$("auto-time").addEventListener("input", (event) => {
  const s = current;
  const match = /^(\d{2}):(\d{2})/.exec(event.target.value);
  if (!s || !match) return;
  s.draft.cadence = { ...s.draft.cadence, hour: Number(match[1]), minute: Number(match[2]) };
  renderKinds(s);
});
$("auto-kinds").addEventListener("click", (event) => {
  const chip = event.target.closest("button.chip");
  if (!current || !chip) return;
  current.draft.cadence = cadenceOf(chip.dataset.kind, current.draft.cadence);
  renderKinds(current);
});
$("auto-steps").addEventListener("click", (event) => {
  const chip = event.target.closest("button.chip");
  if (!current || !chip) return;
  current.draft.cadence = { ...current.draft.cadence, every: Number(chip.dataset.every) };
  renderKinds(current);
});
$("auto-days").addEventListener("click", (event) => {
  const chip = event.target.closest("button.chip");
  if (!current || !chip) return;
  current.draft.cadence = { ...current.draft.cadence, weekday: Number(chip.dataset.weekday) };
  renderKinds(current);
});
$("auto-permissions").addEventListener("click", (event) => {
  const chip = event.target.closest("button.chip");
  if (!current || !chip) return;
  current.draft.permissions = chip.dataset.value;
  renderPermissions(current);
});
$("auto-projects").addEventListener("click", (event) => {
  const node = event.target.closest("button.project");
  const s = current;
  if (!s || !node) return;
  const folder = node.dataset.path === "" ? null : node.dataset.path;
  if (folder !== s.draft.folder) {
    s.draft.folder = folder;
    s.draft.agent = null;
    s.agents = [];
    loadAgents(s);
  }
  renderProjects(s);
  renderAgents(s);
});
$("auto-agents").addEventListener("click", (event) => {
  const chip = event.target.closest("button.chip");
  if (!current || !chip) return;
  // Tapping the chosen chip again picks no agent.
  current.draft.agent = current.draft.agent === chip.dataset.name ? null : chip.dataset.name;
  renderAgents(current);
});
