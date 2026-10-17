// Starting and resuming from the phone, and the lists New session draws (ADR 0011). The rules each request is held to are
// in docs/agents/where-it-breaks.md › Starting and resuming on the phone; the decisions here are pure and the flows take the
// relay as a seam (`Asker`), so `bun test` runs them against a fake.

import type { Device } from "./checks";
import { optional, same, shapeTab, type HomePane, type HomeTab, type RelayResult } from "./home";
import { isObject, objects, uuidPattern, type Json } from "./json";
import { projectName } from "./page/newrules.js";
import { launchTimeoutMs, reopenTimeoutMs } from "./relay";

/** What the flows need of `Relay`: one relay request as a device. */
export interface Asker {
  ask(op: string, by: string | null, fields?: Record<string, unknown>, limitMs?: number): Promise<RelayResult>;
}

// ---------------------------------------------------------------------------------------------------------------
// What a browser may send

/**
 * The most a prompt may be, in the UTF-8 bytes of its JSON string (quotes included): that is what goes into the request,
 * and a newline or a quote costs two. The request is one base64 argument (`argumentLimit` in relay.ts), a third bigger again;
 * the rest of a request is at most about 6,000 bytes (a 1,024-character folder, a 128-character agent), so this leaves room.
 */
export const promptLimitBytes = 80_000;
const folderLimit = 1024;
const nameLimit = 128;

/** Control characters, tab, newline and carriage return aside. A NUL could never be an argument. */
const controls = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/;
/** Every control character, for a folder or a name that is one line. */
const anyControl = /[\x00-\x1f\x7f]/;

export type Parsed<Value> = { ok: true; value: Value } | { ok: false; error: string };
const refuse = (error: string): { ok: false; error: string } => ({ ok: false, error });

/** A host path as the host listed it: absolute, one line, a length a path can have. */
export function isFolder(value: unknown): value is string {
  return typeof value === "string" && value.startsWith("/") && value.length <= folderLimit && !anyControl.test(value) && value.isWellFormed();
}

/** An agent's name as `claude --agent` takes it: one line, short, and never one that starts like an option. */
export function isAgentName(value: unknown): value is string {
  return typeof value === "string" && value !== "" && value.length <= nameLimit && value === value.trim() && !value.startsWith("-") && !anyControl.test(value) && value.isWellFormed();
}

export interface StartAsk {
  folder: string;
  agent: string | null;
  prompt: string;
}

/**
 * `POST /api/start`'s body: `folder`, `agent` and `prompt`, and nothing else is read. The prompt may be empty, as on a Mac.
 * A prompt that starts with a dash is refused until every host puts `--` before the prompt (`ClaudeCommand.arguments`): an
 * older host's claude would read it as an option. Remove that check once they all do.
 */
export function parseStartBody(body: unknown): Parsed<StartAsk> {
  if (!isObject(body)) return refuse("The request wasn't a JSON object");
  if (!isFolder(body.folder)) return refuse("Pick a project");
  const claude = readClaude(body);
  return claude.ok ? { ok: true, value: { folder: body.folder, ...claude.value } } : claude;
}

/** The agent and the prompt of a request for a Claude session: what a start and a split read alike. */
function readClaude(body: Record<string, unknown>): Parsed<{ agent: string | null; prompt: string }> {
  const agent = body.agent === undefined || body.agent === null || body.agent === "" ? null : body.agent;
  if (agent !== null && !isAgentName(agent)) return refuse("That isn't an agent's name");
  const prompt = body.prompt === undefined || body.prompt === null ? "" : body.prompt;
  if (typeof prompt !== "string" || !prompt.isWellFormed()) return refuse("The prompt isn't text");
  if (controls.test(prompt)) return refuse("The prompt has a control character in it");
  if (Buffer.byteLength(JSON.stringify(prompt), "utf8") > promptLimitBytes) return refuse("The prompt is too long (newlines and quotes count double)");
  if (prompt.startsWith("-")) return refuse("A prompt can't start with a dash: begin it with a word");
  return { ok: true, value: { agent, prompt } };
}

export interface SplitAsk {
  /** The tab and the pane of it the new pane goes beside: lowercase ids. */
  tab: string;
  pane: string;
  kind: "claude" | "terminal";
  agent: string | null;
  prompt: string;
}

/**
 * `POST /api/split`'s body: the tab, the pane shown, the kind (`claude` or `terminal`) and for Claude the agent and the prompt. No folder:
 * the host takes the split pane's. A terminal has no agent or prompt, and one sent is refused rather than dropped. Nothing else is read.
 */
export function parseSplitBody(body: unknown): Parsed<SplitAsk> {
  if (!isObject(body)) return refuse("The request wasn't a JSON object");
  if (typeof body.tab !== "string" || !uuidPattern.test(body.tab)) return refuse("That isn't a tab id");
  if (typeof body.pane !== "string" || !uuidPattern.test(body.pane)) return refuse("That isn't a pane id");
  const tab = body.tab.toLowerCase();
  const pane = body.pane.toLowerCase();
  if (body.kind === "terminal") {
    const given = (value: unknown): boolean => value !== undefined && value !== null && value !== "";
    if (given(body.agent) || given(body.prompt)) return refuse("A terminal takes no agent or prompt");
    return { ok: true, value: { tab, pane, kind: "terminal", agent: null, prompt: "" } };
  }
  if (body.kind !== "claude") return refuse("Add Claude or a terminal");
  const claude = readClaude(body);
  return claude.ok ? { ok: true, value: { tab, pane, kind: "claude", ...claude.value } } : claude;
}

/** `POST /api/resume`'s body: the closed tab, and nothing else. Its sessions, their folders and agents are the host's own, from its Recent. */
export function parseResumeBody(body: unknown): Parsed<string> {
  if (!isObject(body) || typeof body.tab !== "string" || !uuidPattern.test(body.tab)) return refuse("That isn't a tab id");
  return { ok: true, value: body.tab.toLowerCase() };
}

/** `GET /api/agents`'s folder, when one is asked for: a host path. None asks for the host's default folder. */
export function parseAgentsFolder(folder: string | null): Parsed<string | null> {
  if (folder === null || folder === "") return { ok: true, value: null };
  return isFolder(folder) ? { ok: true, value: folder } : refuse("That isn't a folder");
}

// ---------------------------------------------------------------------------------------------------------------
// What the host said, cut down to what the page draws

export interface ProjectRow {
  path: string;
  /** Unix seconds of the newest Claude transcript for the folder, or null. */
  lastUsed: number | null;
}

/** Foundation encodes a `Date` as seconds since 2001-01-01 (`PeerProject.lastUsed`), not since 1970. */
export const referenceDateOffset = 978_307_200;

/** The host's projects, most recently used first, then by name: the host sorts them already, but the order is the page's promise. */
export function shapeProjects(result: RelayResult): { rows: ProjectRow[] } | { error: string } {
  if (!result.ok) return { error: result.error };
  const rows: ProjectRow[] = [];
  for (const project of objects(result.reply.projects)) {
    if (!isFolder(project.path)) continue;
    const used = project.lastUsed;
    rows.push({ path: project.path, lastUsed: typeof used === "number" && Number.isFinite(used) ? Math.round(used + referenceDateOffset) : null });
  }
  rows.sort((a, b) => (b.lastUsed ?? -Infinity) - (a.lastUsed ?? -Infinity) || projectName(a.path).localeCompare(projectName(b.path), "en", { numeric: true, sensitivity: "base" }) || a.path.localeCompare(b.path));
  return { rows };
}

export interface AgentRow {
  name: string;
  description: string;
  project: boolean;
}

export function shapeAgents(result: RelayResult): { folder: string | null; rows: AgentRow[] } | { error: string } {
  if (!result.ok) return { error: result.error };
  const rows: AgentRow[] = [];
  for (const agent of objects(result.reply.agents)) {
    if (!isAgentName(agent.name)) continue;
    rows.push({ name: agent.name, description: typeof agent.description === "string" ? agent.description.slice(0, 300) : "", project: agent.project === true });
  }
  return { folder: optional(result.reply.folder), rows };
}

// ---------------------------------------------------------------------------------------------------------------
// The flows

/**
 * What a start or a reopen made: the tab the host put it in, and for a start the session. A refusal because the tab is open on the host
 * already names that tab, for the page to open and take over.
 */
export type Launched =
  | { status: 200; body: { ok: true; session: string | null; tab: string | null } }
  | { status: number; body: { ok: false; error: string; openTab?: string } };

const failed = (status: number, error: string, openTab?: string): Launched => ({ status, body: openTab ? { ok: false, error, openTab } : { ok: false, error } });
export const sessionNameFor = (id: string): string => `varnick-${id}`;

const notAProject = (host: string): string => `That folder isn't one of ${host}'s projects`;

/** `GET /api/agents`: a folder's agents. A folder has to be one of the host's projects, like the one a start names. */
export async function agentsOf(asker: Asker, device: Device, host: string, folder: string | null): Promise<{ status: number; body: Json }> {
  if (folder !== null) {
    const listed = shapeProjects(await asker.ask("projects", device.id));
    if ("error" in listed) return { status: 502, body: { ok: false, error: listed.error } };
    if (!listed.rows.some((project) => project.path === folder)) return { status: 400, body: { ok: false, error: notAProject(host) } };
  }
  const agents = shapeAgents(await asker.ask("agents", device.id, folder === null ? {} : { folder }));
  return "error" in agents ? { status: 502, body: { ok: false, error: agents.error } } : { status: 200, body: { ok: true, folder: agents.folder, agents: agents.rows } };
}

/**
 * Whether the session exists on the host. A start whose answer was lost or came late can have made the session all the same, and
 * a second tap would then make a second one: before a failure is told, the host is asked, and a running session is a success.
 */
async function isRunning(asker: Asker, device: Device, session: string): Promise<boolean> {
  const status = await asker.ask("status", device.id, { sessions: [session] });
  if (!status.ok || !isObject(status.reply.sessions)) return false;
  const entry = status.reply.sessions[session];
  return isObject(entry) && entry.running === true;
}

/** `start` goes with a new id that only this function makes, the folder, the agent and the prompt, and no `skipPermissions`. */
export async function startSession(asker: Asker, device: Device, host: string, ask: StartAsk, newID: () => string): Promise<Launched> {
  const [projects, agents] = await Promise.all([
    asker.ask("projects", device.id),
    ask.agent === null ? Promise.resolve(null) : asker.ask("agents", device.id, { folder: ask.folder }),
  ]);
  const listed = shapeProjects(projects);
  if ("error" in listed) return failed(502, listed.error);
  if (!listed.rows.some((project) => project.path === ask.folder)) return failed(400, notAProject(host));
  if (ask.agent !== null && agents !== null) {
    const known = shapeAgents(agents);
    if ("error" in known) return failed(502, known.error);
    if (!known.rows.some((agent) => agent.name === ask.agent)) return failed(400, `${ask.agent} isn't an agent of that project on ${host}`);
  }
  const id = newID();
  const session = sessionNameFor(id);
  const start: Json = { id, folder: ask.folder, prompt: ask.prompt };
  if (ask.agent !== null) start.agent = ask.agent;
  const started = await asker.ask("start", device.id, { start }, launchTimeoutMs);
  if (started.ok) return { status: 200, body: { ok: true, session, tab: optional(started.reply.tab)?.toLowerCase() ?? null } };
  // A start whose answer was lost: the session may be there, and its tab is not known, so the page opens the session alone.
  if (await isRunning(asker, device, session)) return { status: 200, body: { ok: true, session, tab: null } };
  return failed(502, started.error);
}

/** The pane to split, in the tab the host lists, when this phone is in control of the tab and the tab has the pane. */
async function splittable(asker: Asker, device: Device, host: string, tab: string, pane: string): Promise<{ tab: HomeTab; pane: HomePane } | Launched> {
  const tabs = await asker.ask("tabs", device.id);
  if (!tabs.ok) return failed(502, tabs.error);
  const raw = findTab(tabs, tab);
  const shaped = raw ? shapeTab(raw, device) : null;
  if (!shaped) return failed(404, `That tab isn't open on ${host} any more`);
  if (!shaped.mine) return failed(409, "This phone isn't in control of that tab: take it over first");
  const found = shaped.panes.find((candidate) => candidate.id === pane);
  return found ? { tab: shaped, pane: found } : failed(400, "That pane isn't in that tab");
}

/**
 * The folder a pane's agents are read from: the pane's own, else the first pane of the tab that has one (a page or a file has none). The host
 * lists it, never the page, and it needn't be one of the host's projects: it may be a worktree or Home.
 */
const folderOf = (tab: HomeTab, pane: HomePane): string | null =>
  isFolder(pane.folder) ? pane.folder : tab.panes.find((candidate) => isFolder(candidate.folder))?.folder ?? null;

/** `GET /api/split-agents`: the agents of the folder of a pane of a tab this phone controls, for the chips of Add pane. */
export async function splitAgents(asker: Asker, device: Device, host: string, tab: string, pane: string): Promise<{ status: number; body: Json }> {
  const found = await splittable(asker, device, host, tab.toLowerCase(), pane.toLowerCase());
  if ("body" in found) return found;
  const folder = folderOf(found.tab, found.pane);
  if (folder === null) return { status: 200, body: { ok: true, folder: null, agents: [] } };
  const agents = shapeAgents(await asker.ask("agents", device.id, { folder }));
  return "error" in agents ? { status: 502, body: { ok: false, error: agents.error } } : { status: 200, body: { ok: true, folder: agents.folder, agents: agents.rows } };
}

/**
 * Add a Claude session or a terminal beside a pane of a tab this phone controls (option 03 of panes-open-only-by-hand-at-a-mac): the `start` a
 * Mac sends for a split of another machine's tab, naming the tab, the pane and the axis, with no folder (the host takes the split pane's). The
 * server picks the id and sends no `skipPermissions`, as a start does. The host's own check of who controls the tab holds whatever this says.
 * The answer names the tab asked for: it is the same tab, whether or not the host's reply came.
 */
export async function splitTab(asker: Asker, device: Device, host: string, ask: SplitAsk, newID: () => string): Promise<Launched> {
  const found = await splittable(asker, device, host, ask.tab, ask.pane);
  if ("body" in found) return found;
  if (ask.agent !== null) {
    const folder = folderOf(found.tab, found.pane);
    const known = folder === null ? { rows: [] as AgentRow[] } : shapeAgents(await asker.ask("agents", device.id, { folder }));
    if ("error" in known) return failed(502, known.error);
    if (!known.rows.some((agent) => agent.name === ask.agent)) return failed(400, `${ask.agent} isn't an agent of that pane's folder on ${host}`);
  }
  const id = newID();
  const session = sessionNameFor(id);
  const start: Json = { id, prompt: ask.prompt, kind: ask.kind };
  if (ask.agent !== null) start.agent = ask.agent;
  const started = await asker.ask("start", device.id, { start, tab: ask.tab, pane: ask.pane, axis: "sideBySide" }, launchTimeoutMs);
  // A start whose answer was lost may have made the pane: a running session is a success, or a second tap would add another.
  if (started.ok || (await isRunning(asker, device, session))) return { status: 200, body: { ok: true, session, tab: ask.tab } };
  return failed(502, started.error);
}

/** The tab in a `tabs` reply with this id, as the host lists it. */
function findTab(tabs: RelayResult, tab: string): Json | null {
  return tabs.ok ? objects(tabs.reply.tabs).find((candidate) => same(candidate.tab, tab)) ?? null : null;
}

/** The wording of a reopen of a tab that is open on the host. */
export const openElsewhere = (host: string): string => `That tab is open on ${host}: take it over from the list`;

/**
 * Reopen a closed tab of the host's Recent (protocol 24): the host reopens it whole, in its layout, its Claude panes resumed and its terminals
 * started fresh, every one labelled for this device. A tab that is open on the host already is answered with its id to open and take over, and
 * nothing is reopened; the same when the host refuses a reopen in a race. The page opens the tab.
 */
export async function reopenTab(asker: Asker, device: Device, host: string, asked: string): Promise<Launched> {
  const tab = asked.toLowerCase();
  if (findTab(await asker.ask("tabs", device.id), tab)) return failed(409, openElsewhere(host), tab);
  const reopened = await asker.ask("reopen", device.id, { tab }, reopenTimeoutMs);
  if (reopened.ok) return { status: 200, body: { ok: true, session: null, tab: optional(reopened.reply.tab)?.toLowerCase() ?? tab } };
  // The answer may only have been lost or late, or the tab opened meanwhile: if the host has it, it is the page's to open.
  if (findTab(await asker.ask("tabs", device.id), tab)) return failed(409, reopened.error, tab);
  return failed(502, reopened.error);
}
