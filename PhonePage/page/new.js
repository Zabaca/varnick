// New session: the host's projects (most recent first, with a filter), the chosen project's agents as chips, a large prompt
// box and Start. What was started last is preselected, so the usual case is one tap and a prompt. Start asks the server
// (`POST /api/start`), which checks everything and picks the session's id; on success the page opens the terminal with
// take (app.js, `started`). Everything the host sent goes in with textContent, never as markup.

import { element, getJSON, postJSON, shortFolder } from "/dom.js";
import { filterProjects, parseKept, parseLast, parseProjects, pickAgent, pickProject, projectName, rememberAgents, rememberStart, startTitle } from "/newrules.js";

const $ = (id) => document.getElementById(id);
const keys = { last: "new.last", projects: "new.projects", agents: "new.agents" };

/** localStorage may be empty, blocked or throw (private windows): the page works without it. */
const read = (key) => { try { return localStorage.getItem(key) ?? ""; } catch { return ""; } };
const write = (key, value) => { try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* nothing kept */ } };

let current = null;

function setStatus(text, isError = false) {
  const line = $("new-status");
  line.textContent = text ?? "";
  line.hidden = !text;
  line.classList.toggle("error", isError);
}

function updateStart(s) {
  $("start").disabled = s.busy || s.folder === null;
  $("start").textContent = s.busy ? "Starting…" : "Start";
}

// ---------------------------------------------------------------------------------------------------------------
// Projects

function renderProjects(s) {
  const box = $("projects");
  box.replaceChildren();
  const shown = filterProjects(s.projects, s.query);
  if (s.projects.length === 0) {
    const note = s.projectsError ?? (s.projectsLoaded ? "This host has no projects. Add a project folder on it." : "Loading projects…");
    box.append(element("p", s.projectsError ? "error" : "empty", note));
    return;
  }
  if (shown.length === 0) box.append(element("p", "empty", "No project matches."));
  for (const project of shown) {
    const button = element("button", "project");
    button.type = "button";
    button.setAttribute("role", "radio");
    button.setAttribute("aria-checked", String(project.path === s.folder));
    button.dataset.path = project.path;
    button.append(element("span", "project-name", projectName(project.path)));
    const path = element("span", "project-path", shortFolder(project.path));
    path.title = project.path;
    button.append(path);
    box.append(button);
  }
  if (s.projectsError) box.append(element("p", "error", s.projectsError));
}

function applyProjects(s, projects, fromCache) {
  s.projects = projects;
  s.projectsLoaded = !fromCache;
  s.projectsError = null;
  // A project the user hasn't picked is the one started last, if the host still has it; one picked or kept stays while listed.
  if (s.folder !== null && !projects.some((project) => project.path === s.folder)) s.folder = null;
  if (s.folder === null && !s.projectTouched) {
    const pick = pickProject(projects.map((project) => project.path), s.last);
    if (pick !== null) chooseProject(s, pick, false);
  }
  renderProjects(s);
  updateStart(s);
}

async function loadProjects(s) {
  const cached = parseProjects(read(keys.projects));
  if (cached.length > 0) applyProjects(s, cached, true);
  else renderProjects(s);
  const answer = await getJSON("/api/projects");
  if (s.closed) return;
  if (!answer.ok) {
    s.projectsError = answer.error;
    s.projectsLoaded = true;
    renderProjects(s);
    return;
  }
  if (answer.host) $("new-host").textContent = answer.host;
  write(keys.projects, answer.projects);
  applyProjects(s, answer.projects, false);
}

function chooseProject(s, path, byUser) {
  const changed = s.folder !== path;
  s.folder = path;
  if (byUser) s.projectTouched = true;
  if (!changed && s.agentsFor === path) return;
  s.agent = null;
  s.agentTouched = false;
  s.agents = [];
  s.agentsFor = path;
  loadAgents(s, path);
  updateStart(s);
}

// ---------------------------------------------------------------------------------------------------------------
// Agents

function renderAgents(s) {
  const wrap = $("agents-wrap");
  const box = $("agents");
  box.replaceChildren();
  wrap.hidden = s.folder === null || (s.agents.length === 0 && !s.agentsError);
  for (const agent of s.agents) {
    const chip = element("button", "chip", agent.name);
    chip.type = "button";
    chip.setAttribute("aria-pressed", String(agent.name === s.agent));
    chip.dataset.name = agent.name;
    if (agent.description) chip.title = agent.description;
    box.append(chip);
  }
  if (s.agentsError) box.append(element("p", "error", s.agentsError));
}

function applyAgents(s, folder, agents) {
  if (s.agentsFor !== folder) return;
  s.agents = agents;
  s.agentsError = null;
  // Nothing is picked unless it was the agent started last with this project; a pick the user made stays while listed.
  if (!s.agentTouched) s.agent = pickAgent(agents.map((agent) => agent.name), s.last, folder);
  else if (s.agent !== null && !agents.some((agent) => agent.name === s.agent)) s.agent = null;
  renderAgents(s);
}

async function loadAgents(s, folder) {
  s.agentsError = null;
  const kept = parseKept(read(keys.agents));
  if (Array.isArray(kept[folder])) applyAgents(s, folder, kept[folder].filter((agent) => agent && typeof agent.name === "string"));
  else renderAgents(s);
  const answer = await getJSON(`/api/agents?folder=${encodeURIComponent(folder)}`);
  if (s.closed || s.agentsFor !== folder) return;
  if (!answer.ok) {
    // Chips from an earlier answer stay; with none the error says why there are none.
    if (s.agents.length === 0) s.agentsError = answer.error;
    renderAgents(s);
    return;
  }
  write(keys.agents, rememberAgents(kept, folder, answer.agents));
  applyAgents(s, folder, answer.agents);
}

// ---------------------------------------------------------------------------------------------------------------
// Start

async function start(s) {
  if (s.busy || s.folder === null) return;
  s.busy = true;
  updateStart(s);
  setStatus("Starting. A Mac can take up to half a minute to answer.");
  const folder = s.folder;
  const agent = s.agent;
  const prompt = $("prompt").value;
  // The host may have started it all the same: Back shows the open sessions.
  const result = await postJSON("/api/start", { folder, agent, prompt }, "The host didn't answer. If it started, the session is in Open sessions.");
  if (s.closed) return;
  s.busy = false;
  updateStart(s);
  if (!result.ok) return setStatus(result.error, true);
  setStatus(null);
  write(keys.last, rememberStart(s.last, folder, agent));
  s.started({ session: result.session, title: startTitle(prompt, folder) });
}

// ---------------------------------------------------------------------------------------------------------------

/**
 * Opens New session. `started({session, title})` says the host started a session: the page then opens its terminal with
 * take. `done()` says the user went back.
 */
export function openNew({ host, started, done }) {
  closeNew();
  const s = {
    closed: false, started, done, busy: false,
    projects: [], projectsLoaded: false, projectsError: null, query: "", folder: null, projectTouched: false,
    agents: [], agentsFor: null, agentsError: null, agent: null, agentTouched: false,
    last: parseLast(read(keys.last)),
  };
  current = s;
  $("new").hidden = false;
  $("new-host").textContent = host || "";
  $("project-filter").value = "";
  $("prompt").value = "";
  setStatus(null);
  renderProjects(s);
  renderAgents(s);
  updateStart(s);
  loadProjects(s);
  // The prompt box has the focus, so the keyboard (and its microphone) is one tap away.
  $("prompt").focus();
}

export function closeNew() {
  const s = current;
  if (!s) return;
  current = null;
  s.closed = true;
  $("new").hidden = true;
  $("prompt").value = "";
}

$("new-back").addEventListener("click", () => current?.done());
$("project-filter").addEventListener("input", (event) => {
  if (!current) return;
  current.query = event.target.value;
  renderProjects(current);
});
// The buttons are rebuilt on every render, so one listener on their container handles them.
$("projects").addEventListener("click", (event) => {
  const button = event.target.closest("button.project");
  if (!current || !button) return;
  chooseProject(current, button.dataset.path, true);
  renderProjects(current);
});
$("agents").addEventListener("click", (event) => {
  const chip = event.target.closest("button.chip");
  const s = current;
  if (!s || !chip) return;
  s.agentTouched = true;
  // Tapping the chosen chip again picks no agent.
  s.agent = s.agent === chip.dataset.name ? null : chip.dataset.name;
  renderAgents(s);
});
$("start").addEventListener("click", () => { if (current) start(current); });
