import { wrap as identityWrap, type Wrap } from "./wrap.ts";
import { API_KEY_PLACEHOLDER, OAUTH_TOKEN_PLACEHOLDER } from "./proxy.ts";
import type { CredentialKind } from "./secrets.ts";

// What a Session is made of: a Worktree, a zmx session and a ttyd. This module
// holds the parts that touch the world; the states they move through are named
// in the Machine and nowhere else (ADR-0010).

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
export async function addWorktree(liveTree: string, branch: string): Promise<string> {
  const path = worktreePathFor(liveTree, branch);
  await git(["worktree", "add", "-b", branch, path], liveTree);
  return path;
}

// Undo of `addWorktree`, for a create that got no further. `--force` because
// the Worktree was made moments ago and holds nothing the developer wrote.
export async function removeWorktree(liveTree: string, path: string): Promise<void> {
  try {
    await git(["worktree", "remove", "--force", path], liveTree);
  } catch {
    // A Worktree that cannot be removed is not a better error than the one
    // that is about to be reported.
  }
}

// The zmx session is named by the branch and runs Wrap applied to the agent's
// command, with cwd the Worktree. `zmx attach` creates the session and starts
// the command in it; with no controlling terminal the client detaches at once
// and the session stays, which is what makes a Session outlive the Host.
export async function startZmxSession(
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
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const listed = await new Deno.Command("zmx", { args: ["ls", "--short"], stdout: "piped" })
      .output();
    if (
      new TextDecoder().decode(listed.stdout).split("\n").some((line) => line.trim() === name)
    ) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(
    `zmx did not start a session named "${name}": ${new TextDecoder().decode(stderr).trim()}`,
  );
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

async function answersOn(port: number, withinMs: number): Promise<boolean> {
  const deadline = Date.now() + withinMs;
  while (Date.now() < deadline) {
    try {
      const connection = await Deno.connect({ hostname: "127.0.0.1", port });
      connection.close();
      return true;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  return false;
}

export interface Terminal {
  url: string;
  pid: number;
}

// One ttyd per Session, on its own loopback port, attached to the zmx session.
// It is not a child the Host waits on: a Session outlives the window and the
// Host (spec user stories 5 and 6), so the process is let go of here.
export async function startTerminal(name: string): Promise<Terminal> {
  const port = freePort();
  const ttyd = new Deno.Command("ttyd", {
    args: ["-W", "-i", loopbackInterface(), "-p", String(port), "zmx", "attach", name],
    stdin: "null",
    stdout: "null",
    stderr: "null",
  }).spawn();
  ttyd.unref();

  if (!(await answersOn(port, 10_000))) {
    try {
      ttyd.kill("SIGTERM");
    } catch {
      // already gone
    }
    throw new Error(`ttyd did not answer on 127.0.0.1:${port} for session "${name}"`);
  }
  return { url: `http://127.0.0.1:${port}`, pid: ttyd.pid };
}

// The developer's git identity, read by the Host so commits made in a Session
// are attributable (spec user story 13). Read with the Live tree as cwd, so a
// repo-local identity wins over the global one exactly as git would have it.
export interface GitIdentity {
  name: string;
  email: string;
}

export async function readGitIdentity(liveTree: string): Promise<GitIdentity> {
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
export function agentEnvironment(
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
export function sessionCommand(options: SessionOptions): string[] {
  if (!options.claudePath) {
    throw new Error("no `claude` on the Host's PATH; a launch option can name one");
  }
  return (options.wrap ?? identityWrap)([options.claudePath]);
}
