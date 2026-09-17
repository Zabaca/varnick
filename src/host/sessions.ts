import { wrap as identityWrap, type Wrap } from "./wrap.ts";
import { API_KEY_PLACEHOLDER, OAUTH_TOKEN_PLACEHOLDER } from "./proxy.ts";
import type { CredentialKind } from "./secrets.ts";
import {
  answersNow,
  forgetTerminal,
  freePort,
  readTerminals,
  recordTerminal,
} from "./terminals.ts";

// What a Session is made of: a Worktree, a zmx session and a ttyd. This module
// holds everything that touches the world, including the order the three are
// made in; the states that order moves through are named in the Machine and
// nowhere else (ADR-0010).

/**
 * A Proxy that is running, as everything but the Proxy itself needs it: the URL
 * to send the agent to and the Credential's kind, which is all the Snapshot may
 * say of it (ADR-0005). Its absence is the whole of the off mode.
 */
export interface Proxied {
  url: string;
  kind: CredentialKind;
}

export interface SessionOptions {
  /** Applied to the agent's command; the identity in v1 (ADR-0004). */
  wrap?: Wrap;
  /** The Live tree the Worktree is added to. */
  liveTree: string;
  /** The agent's executable; `which claude` unless a launch overrode it. */
  claudePath: string;
  /**
   * The Proxy this Host is running: where it answers, and which placeholder it
   * takes. Absent when there is no Secrets file, and then the agent is given no
   * credential at all (ADR-0005, amended). The two travel together because
   * neither is any use alone.
   */
  proxy?: Proxied;
  /** What goes in the agent's `VARNICK_DOOR` (ADR-0006). */
  doorUrl: string;
}

// Everything here waits on another process to reach a state it does not
// announce, so one shape carries all of it.
async function pollUntil(
  ready: () => boolean | Promise<boolean>,
  withinMs: number,
): Promise<boolean> {
  const deadline = Date.now() + withinMs;
  while (Date.now() < deadline) {
    if (await ready()) return true;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return false;
}

// The Worktree for a branch: `.claude/worktrees/{branch}` in the Live tree.
export function worktreePathFor(liveTree: string, branch: string): string {
  return `${liveTree}/.claude/worktrees/${branch}`;
}

async function git(args: string[], cwd: string) {
  const { success, stderr } = await new Deno.Command("git", {
    args,
    cwd,
    stdout: "null",
    stderr: "piped",
  }).output();
  if (!success) {
    throw new Error(new TextDecoder().decode(stderr).trim() || `git ${args[0]} failed`);
  }
}

// git that answers a question rather than doing something. Whether it answered
// is kept separate from what it said, because a question that could not be put
// is not the same as an answer of "nothing" — and here the difference is
// between reaping a Worktree and refusing to.
async function gitRead(args: string[], cwd: string): Promise<{ answered: boolean; out: string }> {
  try {
    const { success, stdout } = await new Deno.Command("git", {
      args,
      cwd,
      stdout: "piped",
      stderr: "null",
    }).output();
    return { answered: success, out: new TextDecoder().decode(stdout) };
  } catch {
    return { answered: false, out: "" };
  }
}

// The Worktree is created on a new branch, which is what makes a Session's
// branch its own: the agent works there and nowhere else (ADR-0003).
async function addWorktree(liveTree: string, branch: string): Promise<string> {
  const path = worktreePathFor(liveTree, branch);
  await git(["worktree", "add", "-b", branch, path], liveTree);
  return path;
}

// The zmx sessions running on this machine, by name. A zmx that will not
// answer — no server running yet, most often — means no sessions, not a
// failure: at launch that reads as every Worktree being detached, which is
// both true and recoverable.
async function listZmxSessions(): Promise<Set<string>> {
  try {
    const { success, stdout } = await new Deno.Command("zmx", {
      args: ["ls", "--short"],
      stdout: "piped",
      stderr: "null",
    }).output();
    if (!success) return new Set();
    return new Set(
      new TextDecoder().decode(stdout).split("\n").map((line) => line.trim()).filter(Boolean),
    );
  } catch {
    return new Set();
  }
}

// The zmx session is named by the branch and runs Wrap applied to the agent's
// command, with cwd the Worktree. `zmx attach` creates the session and starts
// the command in it; with no controlling terminal the client detaches at once
// and the session stays, which is what makes a Session outlive the Host.
async function startZmxSession(
  name: string,
  command: string[],
  cwd: string,
  env: Record<string, string>,
): Promise<void> {
  const { stderr } = await new Deno.Command("zmx", {
    args: ["attach", name, ...command],
    cwd,
    env,
    clearEnv: true,
    stdin: "null",
    stdout: "null",
    stderr: "piped",
  }).output();

  // The client's own exit code says nothing about the session, so the session
  // being listed is what is waited for.
  const listed = await pollUntil(async () => (await listZmxSessions()).has(name), 10_000);

  if (!listed) {
    throw new Error(
      `zmx did not start a session named "${name}": ${new TextDecoder().decode(stderr).trim()}`,
    );
  }
}

// ttyd and the zmx server stay unconfined on the Host; only the Session's
// command is wrapped (ADR-0004, and the spike that proved the shape).
function loopbackInterface(): string {
  return Deno.build.os === "darwin" ? "lo0" : "lo";
}

async function answersOn(port: number): Promise<boolean> {
  return await pollUntil(() => answersNow(port), 10_000);
}

// One ttyd per Session, on its own loopback port, attached to the zmx session.
// It is not a child the Host waits on: a Session outlives the window and the
// Host (spec user stories 5 and 6), so the process is let go of here.
// Because it is let go of, the port is written down (`terminals.ts`) before it
// is returned: a Host that relaunches has no other way back to this process.
async function startTerminal(name: string, liveTree: string): Promise<Terminal> {
  const port = freePort();
  const ttyd = new Deno.Command("ttyd", {
    args: ["-W", "-i", loopbackInterface(), "-p", String(port), "zmx", "attach", name],
    stdin: "null",
    stdout: "null",
    stderr: "null",
  }).spawn();
  ttyd.unref();

  if (!(await answersOn(port))) {
    try {
      ttyd.kill("SIGTERM");
    } catch {
      // already gone
    }
    throw new Error(`ttyd did not answer on 127.0.0.1:${port} for session "${name}"`);
  }
  await recordTerminal(liveTree, name, { port, pid: ttyd.pid });
  return { url: terminalUrl(port), pid: ttyd.pid };
}

interface Terminal {
  url: string;
  pid: number;
}

function terminalUrl(port: number): string {
  return `http://127.0.0.1:${port}`;
}

// The terminal for a Session the Host did not open: the recorded one if it
// still answers, a new one if it does not. A ttyd is not a child of the Host
// (spec user stories 5 and 6), so surviving one is adopted rather than
// replaced — replacing it would drop the websocket the window is showing.
async function adoptOrStartTerminal(branch: string, liveTree: string): Promise<Terminal> {
  const recorded = (await readTerminals(liveTree))[branch];
  if (recorded && await answersNow(recorded.port)) {
    return { url: terminalUrl(recorded.port), pid: recorded.pid };
  }
  return await startTerminal(branch, liveTree);
}

// The developer's git identity, read by the Host so commits made in a Session
// are attributable (spec user story 13). Read with the Live tree as cwd, so a
// repo-local identity wins over the global one exactly as git would have it.
interface GitIdentity {
  name: string;
  email: string;
}

async function readGitIdentity(liveTree: string): Promise<GitIdentity> {
  const read = async (key: string) => {
    const { success, stdout } = await new Deno.Command("git", {
      args: ["config", "--get", key],
      cwd: liveTree,
      stdout: "piped",
      stderr: "null",
    }).output();
    return success ? new TextDecoder().decode(stdout).trim() : "";
  };
  return { name: await read("user.name"), email: await read("user.email") };
}

// The Claude Code home the agent runs with: one directory inside the clone,
// shared by every Session and separate from the developer's own (ADR-0009).
export function agentHome(liveTree: string): string {
  return `${liveTree}/.varnick/claude`;
}

// The directory the Host puts its own commands on the agent's PATH from: one
// per clone, beside the agent's Claude Code home and gitignored with it.
export function agentBinDir(liveTree: string): string {
  return `${liveTree}/.varnick/bin`;
}

// Where the `varnick` command's code is. The module beside this one is
// preferred and the Live tree's copy is the fallback, for the same reason the
// page directory has two candidates: under `deno desktop` this module loads out
// of a compiled bundle and its own path may not exist on disk.
function agentCliPath(liveTree: string): string {
  for (
    const candidate of [
      new URL("../agent/varnick.ts", import.meta.url).pathname,
      `${liveTree}/src/agent/varnick.ts`,
    ]
  ) {
    try {
      if (Deno.statSync(candidate).isFile) return candidate;
    } catch {
      // keep looking
    }
  }
  throw new Error("the `varnick` command's source is neither beside the Host nor in the Live tree");
}

// Put `varnick` on the agent's PATH (spec §The varnick command). It is a shim
// rather than a copy, so the command the agent runs is the landed source and
// not a snapshot of it taken when some earlier Session opened (ADR-0003).
//
// Deno's permissions are named here and nowhere else: the command talks to the
// Door and reads its own environment, so that is all it is given.
export async function installAgentBin(liveTree: string): Promise<string> {
  const dir = agentBinDir(liveTree);
  await Deno.mkdir(dir, { recursive: true });
  const path = `${dir}/varnick`;
  await Deno.writeTextFile(
    path,
    [
      "#!/bin/sh",
      `exec ${shellQuote(Deno.execPath())} run --quiet --allow-net=127.0.0.1 --allow-env \\`,
      `  ${shellQuote(agentCliPath(liveTree))} "$@"`,
      "",
    ].join("\n"),
  );
  await Deno.chmod(path, 0o755);
  return dir;
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

// The environment the agent runs with. Built from the Host's own so git, npm
// and Claude Code find their tools, then given the Session's own variables.
// Both credential variables are cleared first: whichever kind the Credential
// is, the agent carries a placeholder and never the Credential (ADR-0005), and
// a real one inherited from the developer's shell would defeat that.
function agentEnvironment(
  branch: string,
  options: SessionOptions,
  identity: GitIdentity,
): Record<string, string> {
  const env = { ...Deno.env.toObject() };
  delete env.ANTHROPIC_API_KEY;
  delete env.CLAUDE_CODE_OAUTH_TOKEN;
  // And the base URL with them: inherited, it would send the agent somewhere
  // this Host did not choose, and in the off mode there is nowhere to send it.
  delete env.ANTHROPIC_BASE_URL;
  // A Preview was handed its Door port in `VARNICK_PORT` and would otherwise
  // pass it on: an agent inside a Preview running `deno task dev` would launch
  // onto the port its own Host is already listening on.
  delete env.VARNICK_PORT;

  // With no Proxy there is nothing to point the agent at and no placeholder to
  // give it, so the three stay deleted and Claude Code `/login`s for itself
  // (ADR-0005, amended). With one, the Proxy is where the agent goes and the
  // placeholder its kind calls for is what it presents.
  const proxied: Record<string, string> = options.proxy
    ? {
      ANTHROPIC_BASE_URL: options.proxy.url,
      [options.proxy.kind === "apiKey" ? "ANTHROPIC_API_KEY" : "CLAUDE_CODE_OAUTH_TOKEN"]:
        options.proxy.kind === "apiKey" ? API_KEY_PLACEHOLDER : OAUTH_TOKEN_PLACEHOLDER,
    }
    : {};

  return {
    ...env,
    ...proxied,
    CLAUDE_CONFIG_DIR: agentHome(options.liveTree),
    GIT_AUTHOR_NAME: identity.name,
    GIT_AUTHOR_EMAIL: identity.email,
    GIT_COMMITTER_NAME: identity.name,
    GIT_COMMITTER_EMAIL: identity.email,
    VARNICK_DOOR: options.doorUrl,
    // This Session's own branch, so `varnick land` and `varnick preview` have
    // one to mean without the agent having to name it.
    VARNICK_BRANCH: branch,
    // `varnick` first, so the command the Host installed is the one found; the
    // rest of the Host's PATH follows, which is where git and node are.
    PATH: [agentBinDir(options.liveTree), env.PATH].filter(Boolean).join(":"),
  };
}

// The agent's executable is whatever `which claude` finds on the Host's PATH.
// A Host launches without it — only opening a Session needs it — so not finding
// it is left to be reported by the Session that wanted it.
export async function whichClaude(): Promise<string> {
  try {
    const { success, stdout } = await new Deno.Command("which", {
      args: ["claude"],
      stdout: "piped",
      stderr: "null",
    }).output();
    return success ? new TextDecoder().decode(stdout).trim() : "";
  } catch {
    return "";
  }
}

// The command a Session runs: the agent's, through Wrap and nowhere else.
function sessionCommand(options: SessionOptions): string[] {
  if (!options.claudePath) {
    throw new Error("no `claude` on the Host's PATH; a launch option can name one");
  }
  return (options.wrap ?? identityWrap)([options.claudePath]);
}

export interface OpenedSession {
  worktreePath: string;
  terminalUrl: string;
  ttydPid: number;
}

// Opening a Session: the Worktree is added, then the zmx session is started
// with the wrapped command, then a ttyd is attached to it (spec §Sessions).
// Either all three exist or none does — a Session that never opened leaves no
// Worktree behind, though removing a real one is Reap's Event and not this.
export async function openSession(
  branch: string,
  options: SessionOptions,
): Promise<OpenedSession> {
  // Settled before anything is made, so a Host with no `claude` fails without
  // having created a Worktree first.
  const command = sessionCommand(options);
  const environment = agentEnvironment(branch, options, await readGitIdentity(options.liveTree));
  // Claude Code is handed a home that exists (ADR-0009); it is shared by every
  // Session, so the first one to want it is the one that makes it.
  await Deno.mkdir(agentHome(options.liveTree), { recursive: true });
  // The PATH the agent was just given has to have something on it: `varnick`
  // is written afresh for every Session, so a landed change to it takes effect
  // in the next Session opened rather than the next clone (ADR-0003).
  await installAgentBin(options.liveTree);

  const worktreePath = await addWorktree(options.liveTree, branch);
  try {
    await startZmxSession(branch, command, worktreePath, environment);
    const terminal = await startTerminal(branch, options.liveTree);
    return { worktreePath, terminalUrl: terminal.url, ttydPid: terminal.pid };
  } catch (error) {
    try {
      // Not `--force`: the Worktree is seconds old and holds nothing, and
      // forcing one away is Reap's to do on an Event that asks for it.
      await git(["worktree", "remove", worktreePath], options.liveTree);
    } catch {
      // A Worktree that will not go is not a better error than this one.
    }
    throw error;
  }
}

// A Worktree git knows about. `--porcelain` emits one stanza per worktree, of
// `worktree <path>` then `HEAD <sha>` then `branch <ref>`, blank-line separated.
interface ListedWorktree {
  path: string;
  branch?: string;
}

function parseWorktreeList(porcelain: string): ListedWorktree[] {
  const worktrees: ListedWorktree[] = [];
  let current: ListedWorktree | undefined;
  for (const line of porcelain.split("\n")) {
    if (line.startsWith("worktree ")) {
      current = { path: line.slice("worktree ".length) };
      worktrees.push(current);
    } else if (line.startsWith("branch refs/heads/") && current) {
      current.branch = line.slice("branch refs/heads/".length);
    }
  }
  return worktrees;
}

/** A Session found in the world at launch, before any actor exists. */
export interface DiscoveredSession {
  branch: string;
  worktreePath: string;
  /** Whether a zmx session named by the branch is running. */
  attached: boolean;
}

// The Host's picture at launch: `git worktree list --porcelain` joined with
// `zmx ls`, and nothing read from disk (ADR-0007). Only worktrees at the path
// the Host would have made — `.claude/worktrees/{branch}` — are Sessions, so
// the Live tree itself and a worktree someone made elsewhere are not adopted.
export async function discoverSessions(liveTree: string): Promise<DiscoveredSession[]> {
  const worktrees = await gitRead(["worktree", "list", "--porcelain"], liveTree);
  // An empty answer and an unanswered question look the same in the Snapshot,
  // and a Host showing no Sessions when there are some is the stale picture
  // ADR-0007 exists to prevent. So a git that will not answer fails the launch.
  if (!worktrees.answered) {
    throw new Error(`git worktree list failed in the Live tree ${liveTree}`);
  }
  const listed = parseWorktreeList(worktrees.out);
  const attached = await listZmxSessions();
  const sessions: DiscoveredSession[] = [];
  for (const worktree of listed) {
    if (!worktree.branch) continue;
    // Matched by shape rather than by string-equality with `worktreePathFor`,
    // because git reports the resolved path and the Live tree may be a symlink.
    if (!worktree.path.endsWith(`/.claude/worktrees/${worktree.branch}`)) continue;
    sessions.push({
      branch: worktree.branch,
      worktreePath: worktree.path,
      attached: attached.has(worktree.branch),
    });
  }
  return sessions;
}

export interface ReapRequest {
  branch: string;
  liveTree: string;
  worktreePath?: string;
  ttydPid?: number;
  /** Whether there is a zmx session and a ttyd to take away. */
  attached: boolean;
  /** Reap anyway, whatever the Worktree still holds. */
  force: boolean;
}

// Why a Reap did not happen. Thrown rather than returned, because reaping is
// invoked as a promise and a refusal is the one thing it can fail with that
// the developer is meant to read; the Machine puts it in the Snapshot.
export class ReapRefused extends Error {
  constructor(reason: string) {
    super(reason);
    this.name = "ReapRefused";
  }
}

// What the Worktree still holds that reaping would destroy: work the developer
// has not saved, or saved and not sent anywhere. Both are checked before
// anything is taken away, so a refusal leaves all three in place — git's own
// `worktree remove` refusal comes too late, after the terminal is already gone.
async function refusalFor(request: ReapRequest): Promise<string | undefined> {
  if (!request.worktreePath) return undefined;
  if (!await Deno.stat(request.worktreePath).then(() => true, () => false)) return undefined;

  // Both questions fail closed: work is destroyed by reaping and cannot be got
  // back, so a check that could not be run refuses rather than waving it
  // through. `force` is the way past a refusal, including one of these.
  const status = await gitRead(["status", "--porcelain"], request.worktreePath);
  if (!status.answered) return "git could not say whether the Worktree is dirty";
  if (status.out.trim().length > 0) {
    return `the Worktree is dirty: ${status.out.trim().split("\n").length} uncommitted change(s)`;
  }

  // Commits on this branch that no remote has. A Live tree with no remote at
  // all makes every commit unpushed, which is true and is what `force` is for.
  const unpushed = await gitRead(
    ["rev-list", "--count", "HEAD", "--not", "--remotes"],
    request.worktreePath,
  );
  const count = Number(unpushed.out.trim());
  if (!unpushed.answered || !Number.isInteger(count)) {
    return "git could not say whether the branch has unpushed commits";
  }
  if (count > 0) return `the branch has ${count} unpushed commit(s)`;
  return undefined;
}

// Reaping a Session: the ttyd, the zmx session and the Worktree go away
// together (spec user story 19). Order matters — the terminal is closed before
// what it is showing, and the Worktree goes last, once nothing is in it.
export async function reapSession(request: ReapRequest): Promise<void> {
  if (!request.force) {
    const refusal = await refusalFor(request);
    if (refusal) throw new ReapRefused(refusal);
  }

  if (request.attached && request.ttydPid !== undefined) {
    try {
      Deno.kill(request.ttydPid, "SIGTERM");
    } catch {
      // A ttyd that is already gone is the state we wanted.
    }
  }
  if (request.attached) {
    await new Deno.Command("zmx", {
      args: ["kill", request.branch, "--force"],
      stdout: "null",
      stderr: "null",
    }).output();
  }
  if (request.worktreePath) {
    const args = ["worktree", "remove", request.worktreePath];
    if (request.force) args.push("--force");
    await git(args, request.liveTree);
  }
  // The recorded port pointed at the ttyd just killed; leaving it would offer a
  // relaunched Host a terminal for a Session that no longer exists.
  await forgetTerminal(request.liveTree, request.branch);
}

// Adopting a Session the Host finds already running: its Worktree and its zmx
// session were made by an earlier Host and are left exactly as they are. Only
// the terminal is decided, because only the terminal's port was the Host's to
// remember (spec §Restart).
export async function adoptSession(
  branch: string,
  options: SessionOptions,
): Promise<OpenedSession> {
  const worktreePath = worktreePathFor(options.liveTree, branch);
  // Adopting is asked for through the Door like anything else (ADR-0006), so
  // what is being taken over is checked rather than assumed: without both the
  // Worktree and the zmx session there is no Session here to adopt, and a ttyd
  // must not be started for one.
  const found = (await discoverSessions(options.liveTree))
    .find((session) => session.branch === branch);
  if (!found?.attached) {
    throw new Error(`no Session is running on "${branch}" to adopt`);
  }
  const terminal = await adoptOrStartTerminal(branch, options.liveTree);
  return { worktreePath, terminalUrl: terminal.url, ttydPid: terminal.pid };
}
