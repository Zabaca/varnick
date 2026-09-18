// Fixtures for the headless tests: a real Host against a temp git repo with a
// stub `claude` in place of the model (ADR-0006, spec Testing Decisions).
// Nothing here imports a Machine; the Door is the only way in.
import { type HostOptions, startHost } from "./main.ts";
import type { SessionView } from "./machines/sessions.ts";
import { answersNow } from "./terminals.ts";

export const FIXTURE_SECRETS = new URL("./testdata/secrets.yaml", import.meta.url).pathname;
export const FIXTURE_AGE_KEY = new URL("./testdata/test-age-key.txt", import.meta.url).pathname;

// Creating a Session needs git, zmx and ttyd as well as the sops a launch
// needs. Without any of them the tests skip with a message (spec Testing
// Decisions) rather than failing for a reason that is not the code's.
export const MISSING = await (async () => {
  const probes: [string, string[]][] = [
    ["git", ["--version"]],
    ["zmx", ["version"]],
    ["ttyd", ["--version"]],
    ["sops", ["--version"]],
  ];
  const missing: string[] = [];
  for (const [bin, args] of probes) {
    try {
      const { success } = await new Deno.Command(bin, { args, stdout: "null", stderr: "null" })
        .output();
      if (!success) missing.push(bin);
    } catch {
      missing.push(bin);
    }
  }
  return missing;
})();

// What a Host needs to launch at all, as against what opening a Session in one
// needs. The `varnick` command is driven against a Host with no Session in it,
// so it skips only when git or sops is missing.
const MISSING_FOR_HOST = MISSING.filter((bin) => bin === "git" || bin === "sops");

export function hostTest(name: string, fn: () => Promise<void>) {
  Deno.test({
    name: MISSING_FOR_HOST.length === 0
      ? name
      : `${name} (skipped: ${MISSING_FOR_HOST.join(", ")} not installed)`,
    ignore: MISSING_FOR_HOST.length > 0,
    fn,
  });
}

export function sessionTest(name: string, fn: () => Promise<void>) {
  Deno.test({
    name: MISSING.length === 0 ? name : `${name} (skipped: ${MISSING.join(", ")} not installed)`,
    ignore: MISSING.length > 0,
    fn,
  });
}

export async function run(bin: string, args: string[], cwd?: string) {
  const { success, stdout, stderr } = await new Deno.Command(bin, {
    args,
    cwd,
    stdout: "piped",
    stderr: "piped",
  }).output();
  const decoder = new TextDecoder();
  return { success, out: decoder.decode(stdout), err: decoder.decode(stderr) };
}

// A Live tree to launch a Host against: a git repo with one commit, so
// `git worktree add` has something to branch from.
export async function makeLiveTree(): Promise<string> {
  // Resolved, because macOS hands out `/var/...` for a temp dir and every
  // child process reports `/private/var/...` as its cwd; the Host records what
  // the child says, so the fixture must compare against the same spelling.
  const tree = await Deno.realPath(await Deno.makeTempDir({ prefix: "varnick-live-" }));
  await run("git", ["init", "-b", "main", tree]);
  await run("git", ["config", "user.name", "Test Developer"], tree);
  await run("git", ["config", "user.email", "test@example.com"], tree);
  await Deno.writeTextFile(`${tree}/README.md`, "live tree\n");
  // The same two paths the real clone ignores: the per-clone machine state the
  // Host writes (the agent's Claude Code home, the command on its PATH) and the
  // Worktrees. Without them a Host doing its ordinary work makes the Live tree
  // dirty, and Landing refuses a tree it dirtied itself.
  await Deno.writeTextFile(`${tree}/.gitignore`, "/.varnick/\n/.claude/worktrees/\n");
  await run("git", ["add", "."], tree);
  await run("git", ["commit", "-m", "first"], tree);
  return tree;
}

// The stub `claude` (spec user story 29). It records the environment and cwd it
// was given, then idles so the zmx session and its ttyd stay up to be observed.
export async function makeStubClaude(recordTo: string): Promise<string> {
  const path = `${await Deno.makeTempDir({ prefix: "varnick-stub-" })}/claude`;
  await Deno.writeTextFile(
    path,
    `#!/bin/sh\n[ "$1" = --version ] && { echo 0.0.0-stub; exit 0; }\n{ printf 'CWD=%s\\n' "$PWD"; env; printf 'ARGV=%s\\n' "$*"; } > ${recordTo}\nexec sleep 300\n`,
  );
  await Deno.chmod(path, 0o755);
  return path;
}

// What a test launches a Preview with, in place of the window `deno task dev`
// opens. It is a real Host — the same `startHost` a launch calls — on a port
// of its own that it writes down exactly as the real entry point does, and
// the tree it runs from from its cwd. The fixtures it cannot read from the environment
// are written into it, because the Worktree it is launched in has no Secrets
// file of its own.
//
// Which is also the other mode: `"own"` names the Worktree's own `secrets.yaml`
// — the path a real Preview resolves from its cwd — so the Preview finds none
// and runs with the Proxy off (ADR-0005, amended).
export async function makePreviewLauncher(
  claudePath: string,
  secrets: "fixture" | "own" = "fixture",
): Promise<string[]> {
  const path = `${await Deno.makeTempDir({ prefix: "varnick-preview-" })}/launch.ts`;
  const main = new URL("./main.ts", import.meta.url).href;
  await Deno.writeTextFile(
    path,
    [
      `import { startHost } from ${JSON.stringify(main)};`,
      `await startHost({`,
      `  headless: true,`,
      ...(secrets === "fixture"
        ? [
          `  secretsFile: ${JSON.stringify(FIXTURE_SECRETS)},`,
          `  ageKeyFile: ${JSON.stringify(FIXTURE_AGE_KEY)},`,
        ]
        : [`  secretsFile: \`\${Deno.cwd()}/secrets.yaml\`,`]),
      `  claudePath: ${JSON.stringify(claudePath)},`,
      `});`,
      ``,
    ].join("\n"),
  );
  // The Worktree a test previews is a bare temp repo with no import map of its
  // own, unlike a real varnick Worktree; the repo's config is named so the Host
  // it launches resolves the same dependencies this one did.
  const config = new URL("../../deno.json", import.meta.url).pathname;
  return [Deno.execPath(), "run", "-A", "--config", config, path];
}

// The environment the stub `claude` recorded, as the agent actually got it.
// The stub writes the moment it starts, and a Session is listed as running the
// moment zmx has started it, so the write may lag that by a beat.
export async function recordedEnvironment(path: string): Promise<Record<string, string>> {
  const deadline = Date.now() + 10_000;
  let text = "";
  while (Date.now() < deadline) {
    text = await Deno.readTextFile(path).catch(() => "");
    if (text.includes("ARGV=")) break;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (!text.includes("ARGV=")) throw new Error(`the stub never recorded its environment at ${path}`);
  const env: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const at = line.indexOf("=");
    if (at > 0) env[line.slice(0, at)] = line.slice(at + 1);
  }
  return env;
}

// The Host in these tests runs in this process, so its environment is this
// process's, and "the shell that launched varnick" is what a test writes here.
// A name given `undefined` is unset. Restoring is the caller's, in a `finally`:
// left set, these leak into every later test in the file.
export function setHostEnvironment(vars: Record<string, string | undefined>): () => void {
  const before = new Map(Object.keys(vars).map((name) => [name, Deno.env.get(name)]));
  for (const [name, value] of Object.entries(vars)) {
    if (value === undefined) Deno.env.delete(name);
    else Deno.env.set(name, value);
  }
  return () => {
    for (const [name, value] of before) {
      if (value === undefined) Deno.env.delete(name);
      else Deno.env.set(name, value);
    }
  };
}

export function startTestHost(options: HostOptions) {
  return startHost({
    headless: true,
    port: 0,
    secretsFile: FIXTURE_SECRETS,
    ageKeyFile: FIXTURE_AGE_KEY,
    ...options,
  });
}

export async function readSessions(doorUrl: string): Promise<Record<string, SessionView>> {
  const res = await fetch(`${doorUrl}/actors/sessions`);
  if (res.status !== 200) throw new Error(`GET /actors/sessions: expected 200, got ${res.status}`);
  const snapshot = await res.json();
  return snapshot.context.sessions;
}

// The states a Session is still working in: one being opened, and one being
// taken over at launch, which is waiting on a terminal.
const IN_FLIGHT = ["creating", "attaching"];

// Poll the Snapshot until the named Session settles out of those.
export async function waitForSettled(doorUrl: string, branch: string): Promise<SessionView> {
  const deadline = Date.now() + 30_000;
  let last: SessionView | undefined;
  while (Date.now() < deadline) {
    last = (await readSessions(doorUrl))[branch];
    if (last && !IN_FLIGHT.includes(last.state)) return last;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(
    `Session "${branch}" never left ${IN_FLIGHT.join("/")}: ${JSON.stringify(last)}`,
  );
}

export async function newSession(doorUrl: string, branch: string): Promise<void> {
  const res = await fetch(`${doorUrl}/actors/sessions/events`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ type: "NEW_SESSION", branch }),
  });
  if (res.status !== 200) {
    throw new Error(`NEW_SESSION: expected 200, got ${res.status} ${await res.text()}`);
  }
  await res.body?.cancel();
}

/** Whether something accepts a connection on a loopback URL right now. */
export function answers(url: string): Promise<boolean> {
  return answersNow(Number(new URL(url).port));
}
