// Fixtures for the headless tests: a real Host against a temp git repo with a
// stub `claude` in place of the model (ADR-0006, spec Testing Decisions).
// Nothing here imports a Machine; the Door is the only way in.
import { type HostOptions, startHost } from "./main.ts";
import type { SessionView } from "./machines/sessions.ts";

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
  const tree = await Deno.makeTempDir({ prefix: "varnick-live-" });
  await run("git", ["init", "-b", "main", tree]);
  await run("git", ["config", "user.name", "Test Developer"], tree);
  await run("git", ["config", "user.email", "test@example.com"], tree);
  await Deno.writeTextFile(`${tree}/README.md`, "live tree\n");
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
    `#!/bin/sh\n{ printf 'CWD=%s\\n' "$PWD"; env; printf 'ARGV=%s\\n' "$*"; } > ${recordTo}\nexec sleep 300\n`,
  );
  await Deno.chmod(path, 0o755);
  return path;
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

// Poll the Snapshot until the named Session settles out of `creating`.
export async function waitForSettled(doorUrl: string, branch: string): Promise<SessionView> {
  const deadline = Date.now() + 30_000;
  let last: SessionView | undefined;
  while (Date.now() < deadline) {
    last = (await readSessions(doorUrl))[branch];
    if (last && last.state !== "creating") return last;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Session "${branch}" never left creating: ${JSON.stringify(last)}`);
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

/** Whether something accepts a connection on a loopback port right now. */
export async function answers(url: string): Promise<boolean> {
  try {
    const conn = await Deno.connect({ hostname: "127.0.0.1", port: Number(new URL(url).port) });
    conn.close();
    return true;
  } catch {
    return false;
  }
}

// A Session outlives its Host by design (spec user story 5), so a test that
// made one takes it away itself rather than leaving it on the machine.
export async function reap(views: (SessionView | undefined)[], branch: string) {
  for (const view of views) {
    if (!view?.ttydPid) continue;
    try {
      Deno.kill(view.ttydPid, "SIGTERM");
    } catch {
      // already gone
    }
  }
  await run("zmx", ["kill", branch, "--force"]);
}
