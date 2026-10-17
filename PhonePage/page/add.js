// Add pane: a Claude session or a terminal beside the pane the tab view shows, in a tab this phone controls (option 03 of
// panes-open-only-by-hand-at-a-mac). A small form in a dialog: Claude, with the agents of the shown pane's folder as chips and a prompt as New
// session has them, or Terminal, which has nothing to fill in. Add asks the server (`POST /api/split`), which checks the tab, the pane and the
// agent and sends the host the split; on success the tab view opens the new pane with take (tab.js). The page keeps no value for next time.
// Everything the host sent goes in with textContent, never as markup.

import { element, getJSON, postJSON } from "/dom.js";

const $ = (id) => document.getElementById(id);

let current = null;

function setStatus(text, isError = false) {
  const line = $("add-status");
  line.textContent = text ?? "";
  line.hidden = !text;
  line.classList.toggle("error", isError);
}

function render(s) {
  for (const button of $("add-kinds").children) button.setAttribute("aria-pressed", String(button.dataset.kind === s.kind));
  $("add-claude").hidden = s.kind !== "claude";
  $("add-go").disabled = s.busy;
  $("add-go").textContent = s.busy ? "Adding…" : "Add";
  $("add-cancel").disabled = s.busy;
  for (const button of $("add-kinds").children) button.disabled = s.busy;
  const wrap = $("add-agents-wrap");
  const box = $("add-agents");
  box.replaceChildren();
  wrap.hidden = s.agents.length === 0 && !s.agentsError;
  for (const agent of s.agents) {
    const chip = element("button", "chip", agent.name);
    chip.type = "button";
    chip.setAttribute("aria-pressed", String(agent.name === s.agent));
    chip.dataset.name = agent.name;
    chip.disabled = s.busy;
    if (agent.description) chip.title = agent.description;
    box.append(chip);
  }
  if (s.agentsError) box.append(element("p", "error", s.agentsError));
}

async function loadAgents(s) {
  const answer = await getJSON(`/api/split-agents?tab=${encodeURIComponent(s.tab)}&pane=${encodeURIComponent(s.pane)}`);
  if (s.closed) return;
  // Without chips Claude starts with no agent; the error says why there are none.
  if (!answer.ok) s.agentsError = answer.error;
  else s.agents = answer.agents;
  render(s);
}

async function add(s) {
  if (s.busy) return;
  s.busy = true;
  render(s);
  setStatus("Adding. A Mac can take up to half a minute to answer.");
  const body = { tab: s.tab, pane: s.pane, kind: s.kind };
  if (s.kind === "claude") {
    body.agent = s.agent;
    body.prompt = $("add-prompt").value;
  }
  // The host may have added it all the same: the switcher shows the pane when it has.
  const result = await postJSON("/api/split", body, "The host didn't answer. If it was added, the pane is in the switcher.");
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
  added({ session: result.session });
}

/**
 * Opens Add pane beside `pane` of `tab`. `added({session})` says the host added a session: the tab view then opens it with take.
 * `failed(error)` says an add failed after the dialog was closed.
 */
export function openAdd({ tab, pane, host, added, failed }) {
  closeAdd();
  const s = { closed: false, busy: false, tab, pane, kind: "claude", agents: [], agentsError: null, agent: null, added, failed };
  current = s;
  $("add-host").textContent = host || "";
  $("add-prompt").value = "";
  setStatus(null);
  render(s);
  if (!$("add").open) $("add").showModal();
  loadAgents(s);
}

export function closeAdd() {
  const s = current;
  if (!s) return;
  current = null;
  s.closed = true;
  $("add-prompt").value = "";
  if ($("add").open) $("add").close();
}

$("add-kinds").addEventListener("click", (event) => {
  const button = event.target.closest("button");
  if (!current || !button || current.busy) return;
  current.kind = button.dataset.kind;
  render(current);
});
$("add-agents").addEventListener("click", (event) => {
  const chip = event.target.closest("button.chip");
  const s = current;
  if (!s || !chip || s.busy) return;
  // Tapping the chosen chip again picks no agent.
  s.agent = s.agent === chip.dataset.name ? null : chip.dataset.name;
  render(s);
});
$("add-go").addEventListener("click", () => { if (current) add(current); });
$("add-cancel").addEventListener("click", () => { if (current && !current.busy) closeAdd(); });
// Escape and the system's back close it, but not while the host is being asked: the answer is still to be told.
$("add").addEventListener("cancel", (event) => { if (current?.busy) event.preventDefault(); });
$("add").addEventListener("close", () => { if (current && !current.busy) closeAdd(); });
