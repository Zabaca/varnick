// Starting and resuming from the phone, and the lists New session draws (ADR 0011). The rules each request is held to are
// in docs/agents/where-it-breaks.md › Starting and resuming on the phone; the decisions here are pure and the flows take the
// relay as a seam (`Asker`), so `bun test` runs them against a fake.

import type { Device } from "./checks";
import { optional, same, shapeTab, type HomePane, type HomeTab, type RelayResult } from "./home";
import { isObject, objects, uuidPattern, type Json } from "./json";
import { projectName } from "./page/newrules.js";
import { launchTimeoutMs, reopenTimeoutMs } from "./relay";
import { endText } from "./terminal";

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

/** A tab and a pane of it, as a split and a restart name them: lowercase ids. */
function readPlace(body: unknown): Parsed<{ tab: string; pane: string }> {
  if (!isObject(body)) return refuse("The request wasn't a JSON object");
  if (typeof body.tab !== "string" || !uuidPattern.test(body.tab)) return refuse("That isn't a tab id");
  if (typeof body.pane !== "string" || !uuidPattern.test(body.pane)) return refuse("That isn't a pane id");
  return { ok: true, value: { tab: body.tab.toLowerCase(), pane: body.pane.toLowerCase() } };
}

/** The longest address an Add pane may send: a URL's usual limit. */
const addressLimit = 2048;

/** An app's folder name as `apps` lists it: one line, short, and not a path. */
export function isAppName(value: unknown): value is string {
  return typeof value === "string" && value !== "" && value.length <= nameLimit && value !== "." && value !== ".." && !value.includes("/") && !anyControl.test(value) && value.isWellFormed();
}

/** A page's address as typed: one line, trimmed, at most a URL's usual length. The host decides whether it is an http or https address. */
export function isAddress(value: unknown): value is string {
  return typeof value === "string" && value !== "" && value === value.trim() && value.length <= addressLimit && !anyControl.test(value) && value.isWellFormed();
}

/** A host path as a listing gives it: absolute, one line, with no empty, `.` or `..` part, so it can be checked against a folder by its text. */
export function isCleanPath(value: unknown): value is string {
  return isFolder(value) && (value === "/" || value.split("/").slice(1).every((part) => part !== "" && part !== "." && part !== ".."));
}

const withoutSlash = (folder: string): string => folder.replace(/\/+$/, "");

/** Whether `path` is `folder` itself or below it, by text: the host resolves links and holds the tab's folders. */
export const isInsideFolder = (path: string, folder: string): boolean => path === folder || path.startsWith(`${withoutSlash(folder)}/`);

/** The folder above `dir` while it is below `root`, else null: where Up goes, and it stops at the shown pane's folder. */
export function parentWithin(dir: string, root: string): string | null {
  if (!isInsideFolder(dir, root) || withoutSlash(dir) === withoutSlash(root)) return null;
  const parent = dir.slice(0, dir.lastIndexOf("/"));
  return parent === "" ? "/" : parent;
}

export type SplitAsk = { tab: string; pane: string } & (
  | { kind: "claude" | "terminal"; agent: string | null; prompt: string }
  | { kind: "app"; app: string }
  | { kind: "web"; url: string }
  | { kind: "file"; file: string }
);

const given = (value: unknown): boolean => value !== undefined && value !== null && value !== "";

/**
 * `POST /api/split`'s body: tab, pane, kind and that kind's own fields, and nothing else is read. Claude takes an agent and a prompt, a page its
 * `url`, an app its `app` (the folder name `apps` lists) and a file its `file` path; a kind with a field of another kind is refused. No folder is read.
 */
export function parseSplitBody(body: unknown): Parsed<SplitAsk> {
  const place = readPlace(body);
  if (!place.ok) return place;
  const { tab, pane } = place.value;
  if (!isObject(body)) return refuse("The request wasn't a JSON object");
  const only = (...own: string[]): boolean => ["agent", "prompt", "app", "url", "file"].every((field) => own.includes(field) || !given(body[field]));
  switch (body.kind) {
    case "terminal":
      if (!only()) return refuse("A terminal takes no agent, prompt, app, address or file");
      return { ok: true, value: { tab, pane, kind: "terminal", agent: null, prompt: "" } };
    case "claude": {
      if (!only("agent", "prompt")) return refuse("Claude takes only an agent and a prompt");
      const claude = readClaude(body);
      return claude.ok ? { ok: true, value: { tab, pane, kind: "claude", ...claude.value } } : claude;
    }
    case "app":
      if (!only("app")) return refuse("An app takes only its name");
      return isAppName(body.app) ? { ok: true, value: { tab, pane, kind: "app", app: body.app } } : refuse("Pick an app");
    case "web": {
      if (!only("url")) return refuse("A page takes only its address");
      const url = typeof body.url === "string" ? body.url.trim() : body.url;
      return isAddress(url) ? { ok: true, value: { tab, pane, kind: "web", url } } : refuse("That isn't a page address on one line");
    }
    case "file":
      if (!only("file")) return refuse("A file takes only its path");
      return isCleanPath(body.file) && body.file !== "/" ? { ok: true, value: { tab, pane, kind: "file", file: body.file } } : refuse("Pick a file");
    default:
      return refuse("Add Claude, a terminal, an app, a page or a file");
  }
}

export interface RestartAsk {
  tab: string;
  pane: string;
}

/** `POST /api/restart`'s body: a tab and a pane of it, and nothing else is read. */
export const parseRestartBody = (body: unknown): Parsed<RestartAsk> => readPlace(body);

/** `POST /api/close`'s body: a tab and a pane of it, and nothing else is read. */
export const parseCloseBody = (body: unknown): Parsed<RestartAsk> => readPlace(body);

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

/** `GET /api/split-files`'s folder, when one is asked for: a clean host path. None asks for the shown pane's own folder. */
export function parseSplitDir(dir: string | null): Parsed<string | null> {
  if (dir === null || dir === "") return { ok: true, value: null };
  return isCleanPath(dir) ? { ok: true, value: dir } : refuse("That isn't a folder");
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

export interface AppRow {
  /** The app's folder name, which a split names it by. */
  folder: string;
  name: string;
}

export function shapeApps(result: RelayResult): { rows: AppRow[] } | { error: string } {
  if (!result.ok) return { error: result.error };
  const rows: AppRow[] = [];
  for (const app of objects(result.reply.apps)) {
    if (!isAppName(app.folder)) continue;
    rows.push({ folder: app.folder, name: typeof app.name === "string" && app.name !== "" && !anyControl.test(app.name) ? app.name.slice(0, nameLimit) : app.folder });
  }
  return { rows };
}

export interface FileRow {
  name: string;
  folder: boolean;
}

/** One level of a folder as the host listed it, in its order (folders first); a name that isn't one line, or is a path, is dropped. */
export function shapeFiles(result: RelayResult): { rows: FileRow[]; more: boolean } | { error: string } {
  if (!result.ok) return { error: result.error };
  const rows: FileRow[] = [];
  for (const entry of objects(result.reply.entries)) {
    const name = entry.name;
    if (typeof name !== "string" || name === "" || name === "." || name === ".." || name.length > 255 || name.includes("/") || anyControl.test(name) || !name.isWellFormed()) continue;
    rows.push({ name, folder: entry.isDirectory === true });
  }
  return { rows, more: result.reply.more === true };
}

// ---------------------------------------------------------------------------------------------------------------
// The flows

/**
 * What a start or a reopen made: the tab the host put it in, and for a start the session. A refusal because the tab is open on the host
 * already names that tab, for the page to open and take over.
 */
export type Launched =
  | { status: 200; body: { ok: true; session: string | null; tab: string | null; pane?: string } }
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

/** The shown pane's own folder, as the host lists it (a worktree or Home is not a project): the only place its agents, apps and files are read from. */
const folderOf = (pane: HomePane): string | null => (isFolder(pane.folder) ? pane.folder : null);

/** A headless host's own words for a page, an app or a file, which its tabs don't hold (`HeadlessHosting.start`). */
const noPaneKinds = (host: string): string => `${host} has no browser, custom apps or files: its tabs hold Claude sessions and terminals`;

/**
 * `GET /api/split-offer`: what Add pane offers for a pane of a tab this phone controls: the agents of its folder, the apps the host can run from it,
 * and the kinds to show. A headless host offers Claude and a terminal only; a page is offered for any pane, an app and a file need the pane's folder.
 */
export async function splitOffer(asker: Asker, device: Device, host: string, tab: string, pane: string, headless = false): Promise<{ status: number; body: Json }> {
  const found = await splittable(asker, device, host, tab.toLowerCase(), pane.toLowerCase());
  if ("body" in found) return found;
  const folder = folderOf(found.pane);
  const kinds = headless ? ["claude", "terminal"] : folder === null ? ["claude", "terminal", "app", "web"] : ["claude", "terminal", "app", "web", "file"];
  if (folder === null) return { status: 200, body: { ok: true, folder: null, agents: [], apps: [], kinds } };
  const [agentsReply, appsReply] = await Promise.all([asker.ask("agents", device.id, { folder }), headless ? null : asker.ask("apps", device.id, { folder })]);
  const agents = shapeAgents(agentsReply);
  if ("error" in agents) return { status: 502, body: { ok: false, error: agents.error } };
  const apps = appsReply === null ? { rows: [] as AppRow[] } : shapeApps(appsReply);
  const appsFields = "error" in apps ? { apps: [], appsError: apps.error } : { apps: apps.rows };
  return { status: 200, body: { ok: true, folder: agents.folder, agents: agents.rows, ...appsFields, kinds } };
}

/**
 * `GET /api/split-files`: one level of a folder of a tab this phone controls, for the file picker. The root is the shown pane's folder as the host
 * lists it, never the page's, and a folder outside it is refused here (the host keeps the tab's folders besides). `parent` is where Up goes: null at the root.
 */
export async function splitFiles(asker: Asker, device: Device, host: string, tab: string, pane: string, dir: string | null, headless = false): Promise<{ status: number; body: Json }> {
  if (headless) return failed(400, noPaneKinds(host));
  const found = await splittable(asker, device, host, tab.toLowerCase(), pane.toLowerCase());
  if ("body" in found) return found;
  const root = folderOf(found.pane);
  if (root === null) return failed(400, "That pane has no folder to pick a file from");
  const wanted = dir ?? root;
  if (!isInsideFolder(wanted, root)) return failed(400, "That folder is outside the pane's folder");
  const listed = shapeFiles(await asker.ask("files", device.id, { tab: tab.toLowerCase(), folder: wanted }));
  if ("error" in listed) return failed(502, listed.error);
  return { status: 200, body: { ok: true, dir: wanted, root, parent: parentWithin(wanted, root), entries: listed.rows, more: listed.more } };
}

/** Whether the host lists a pane with this id in the tab: how a page, an app or a file, which have no session to ask about, shows it was made. */
async function listsPane(asker: Asker, device: Device, tab: string, id: string): Promise<boolean> {
  const raw = findTab(await asker.ask("tabs", device.id), tab);
  return raw !== null && objects(raw.panes).some((pane) => same(pane.id, id));
}

/**
 * Add a pane beside a pane of a tab the phone controls: the `start` a Mac sends for a split, with no folder (a file names its tree's folder, the shown
 * pane's) and no `skipPermissions`. A page, an app and a file are refused on a headless host before it is asked, an app is checked against the apps
 * of the pane's folder and a file against that folder.
 */
export async function splitTab(asker: Asker, device: Device, host: string, ask: SplitAsk, newID: () => string, headless = false): Promise<Launched> {
  if (headless && ask.kind !== "claude" && ask.kind !== "terminal") return failed(400, noPaneKinds(host));
  const found = await splittable(asker, device, host, ask.tab, ask.pane);
  if ("body" in found) return found;
  const folder = folderOf(found.pane);
  const id = newID();
  const start: Json = { id, prompt: "", kind: ask.kind };
  switch (ask.kind) {
    case "claude":
    case "terminal":
      start.prompt = ask.prompt;
      if (ask.agent !== null) {
        const known = folder === null ? { rows: [] as AgentRow[] } : shapeAgents(await asker.ask("agents", device.id, { folder }));
        if ("error" in known) return failed(502, known.error);
        if (!known.rows.some((agent) => agent.name === ask.agent)) return failed(400, `${ask.agent} isn't an agent of that pane's folder on ${host}`);
        start.agent = ask.agent;
      }
      break;
    case "app": {
      if (folder === null) return failed(400, "That pane has no folder to find apps in");
      const known = shapeApps(await asker.ask("apps", device.id, { folder }));
      if ("error" in known) return failed(502, known.error);
      if (!known.rows.some((app) => app.folder === ask.app)) return failed(400, `${ask.app} isn't an app of that pane's folder on ${host}`);
      start.app = ask.app;
      break;
    }
    case "web":
      start.url = ask.url;
      break;
    case "file":
      if (folder === null || !isInsideFolder(ask.file, folder)) return failed(400, "That file is outside the pane's folder");
      start.file = ask.file;
      start.folder = folder;
      break;
  }
  const hasSession = ask.kind === "claude" || ask.kind === "terminal";
  const session = sessionNameFor(id);
  const started = await asker.ask("start", device.id, { start, tab: ask.tab, pane: ask.pane, axis: "sideBySide" }, launchTimeoutMs);
  // A start whose answer was lost may have made the pane, and a second tap would add another: a Claude or terminal pane is found by its running
  // session, any other by the host's listing of the tab.
  if (started.ok || (hasSession ? await isRunning(asker, device, session) : await listsPane(asker, device, ask.tab, id))) {
    return { status: 200, body: { ok: true, session: hasSession ? session : null, tab: ask.tab, pane: id } };
  }
  return failed(502, started.error);
}

/** `POST /api/restart` (protocol 32; where-it-breaks, The tab view on the phone): the gates of Add pane, and a Claude session that runs. Asked once. */
export async function restartPane(asker: Asker, device: Device, host: string, ask: RestartAsk): Promise<{ status: number; body: Json }> {
  const found = await splittable(asker, device, host, ask.tab, ask.pane);
  if ("body" in found) return found;
  if (found.pane.kind !== "claude") return failed(400, "Only a Claude session restarts");
  if (!found.pane.running) return failed(409, "That session isn't running: there is nothing to restart");
  const restarted = await asker.ask("restartPane", device.id, { tab: ask.tab, pane: ask.pane }, launchTimeoutMs);
  return restarted.ok ? { status: 200, body: { ok: true } } : failed(502, restarted.error);
}

/**
 * `POST /api/close` (an addition to option 05 of `panes-open-only-by-hand-at-a-mac`): close one pane of a tab this phone controls, whatever its kind,
 * with the host's existing `end`: a Claude or terminal pane by its session with the tab, any other by the pane with the tab. Both are the closes ADR 0034
 * has for the Mac's own close of a pane, so there is no new request. The host, not this server, decides whether the pane is the tab's last, and then
 * handles it as the tab's `end`: it ends if its origin names this phone, else it is handed back (`text` says which).
 */
export async function closePane(asker: Asker, device: Device, host: string, ask: RestartAsk): Promise<{ status: number; body: Json }> {
  const found = await splittable(asker, device, host, ask.tab, ask.pane);
  if ("body" in found) return found;
  const hasSession = found.pane.kind === "claude" || found.pane.kind === "terminal";
  const closed = await asker.ask("end", device.id, hasSession ? { tab: ask.tab, session: sessionNameFor(ask.pane) } : { tab: ask.tab, pane: ask.pane });
  return closed.ok ? { status: 200, body: { ok: true, released: closed.reply.released === true, text: endText(closed.reply, host) } } : failed(502, closed.error);
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
