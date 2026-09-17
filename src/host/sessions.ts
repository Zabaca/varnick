import { wrap as identityWrap, type Wrap } from "./wrap.ts";
import { API_KEY_PLACEHOLDER, OAUTH_TOKEN_PLACEHOLDER } from "./proxy.ts";
import type { CredentialKind } from "./secrets.ts";
import { answersNow, readTerminals, recordTerminal } from "./terminals.ts";

// What a Session is made of: a Worktree, a zmx session and a ttyd. This module
// holds everything that touches the world, including the order the three are
// made in; the states that order moves through are named in the Machine and
// nowhere else (ADR-0010).

export interface SessionOptions {
  /** Applied to the agent's command; the identity in v1 (ADR-0004). */
  wrap?: Wrap;
  /** The Live tree the Worktree is added to. */
  liveTree: string;
  /** The agent's executable; `which claude` unless a launch overrode it. */
  claudePath: string;
  /** What goes in the agent's `ANTHROPIC_BASE_URL` (ADR-0005). */
  proxyUrl: string;
  /** What goes in the agent's `VARNICK_DOOR` (ADR-0006). */
  doorUrl: string;
  /** Which placeholder the agent carries; never the Credential (ADR-0005). */
  credentialKind: CredentialKind;
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

// The Worktree is created on a new branch, which is what makes a Session's
// branch its own: the agent works there and nowhere else (ADR-0003).
async function addWorktree(liveTree: string, branch: string): Promise<string> {
  const path = worktreePathFor(liveTree, branch);
  await git(["worktree", "add", "-b", branch, path], liveTree);
  return path;
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
  const listed = await pollUntil(async () => {
    const { stdout } = await new Deno.Command("zmx", { args: ["ls", "--short"], stdout: "piped" })
      .output();
    return new TextDecoder().decode(stdout).split("\n").some((line) => line.trim() === name);
  }, 10_000);

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

function freePort(): number {
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const { port } = listener.addr as Deno.NetAddr;
  listener.close();
  return port;
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

// The environment the agent runs with. Built from the Host's own so git, npm
// and Claude Code find their tools, then given the Session's own variables.
// Both credential variables are cleared first: whichever kind the Credential
// is, the agent carries a placeholder and never the Credential (ADR-0005), and
// a real one inherited from the developer's shell would defeat that.
function agentEnvironment(
  options: SessionOptions,
  identity: GitIdentity,
): Record<string, string> {
  const env = { ...Deno.env.toObject() };
  delete env.ANTHROPIC_API_KEY;
  delete env.CLAUDE_CODE_OAUTH_TOKEN;

  return {
    ...env,
    ANTHROPIC_BASE_URL: options.proxyUrl,
    [options.credentialKind === "apiKey" ? "ANTHROPIC_API_KEY" : "CLAUDE_CODE_OAUTH_TOKEN"]:
      options.credentialKind === "apiKey" ? API_KEY_PLACEHOLDER : OAUTH_TOKEN_PLACEHOLDER,
    CLAUDE_CONFIG_DIR: agentHome(options.liveTree),
    GIT_AUTHOR_NAME: identity.name,
    GIT_AUTHOR_EMAIL: identity.email,
    GIT_COMMITTER_NAME: identity.name,
    GIT_COMMITTER_EMAIL: identity.email,
    VARNICK_DOOR: options.doorUrl,
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
  const environment = agentEnvironment(options, await readGitIdentity(options.liveTree));
  // Claude Code is handed a home that exists (ADR-0009); it is shared by every
  // Session, so the first one to want it is the one that makes it.
  await Deno.mkdir(agentHome(options.liveTree), { recursive: true });

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
  if (!(await discoverSessions(options.liveTree)).includes(branch)) {
    throw new Error(`no Session is running on "${branch}" to adopt`);
  }
  const terminal = await adoptOrStartTerminal(branch, options.liveTree);
  return { worktreePath, terminalUrl: terminal.url, ttydPid: terminal.pid };
}

// Which branches have a zmx session running right now.
async function zmxSessions(): Promise<Set<string>> {
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

// Which branches have a Worktree under `.claude/worktrees/` in the Live tree.
async function worktreeBranches(liveTree: string): Promise<string[]> {
  const { success, stdout } = await new Deno.Command("git", {
    args: ["worktree", "list", "--porcelain"],
    cwd: liveTree,
    stdout: "piped",
    stderr: "null",
  }).output();
  if (!success) return [];

  const branches: string[] = [];
  let path = "";
  for (const line of new TextDecoder().decode(stdout).split("\n")) {
    if (line.startsWith("worktree ")) path = line.slice("worktree ".length);
    if (!line.startsWith("branch refs/heads/")) continue;
    const branch = line.slice("branch refs/heads/".length);
    // The Live tree is a worktree too, and it is not a Session; a Session's
    // Worktree is the one at the path the spec fixes for that branch.
    if (path === worktreePathFor(liveTree, branch)) branches.push(branch);
  }
  return branches;
}

// The Sessions already running on this machine, rebuilt from git and zmx alone
// (ADR-0007). A Worktree whose zmx session is gone is not one: nothing is left
// running for the Host to adopt.
export async function discoverSessions(liveTree: string): Promise<string[]> {
  const running = await zmxSessions();
  return (await worktreeBranches(liveTree)).filter((branch) => running.has(branch));
}
