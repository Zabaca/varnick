// Headless tests that drive a real Host through the Door against a temp git
// repo, with a stub `claude` in place of the model (ADR-0006, spec Testing
// Decisions). Nothing here imports a Machine; the Door is the only way in.
import { API_KEY_PLACEHOLDER } from "./proxy.ts";
import type { SessionView } from "./machines/sessions.ts";
import {
  makeLiveTree,
  makeStubClaude,
  newSession,
  readSessions,
  recordedEnvironment,
  run,
  sessionTest,
  setHostEnvironment,
  startTestHost,
  waitForSettled,
} from "./test_support.ts";

const FIXTURE_CREDENTIAL = "sk-ant-api03-test-fixture-not-a-real-key";
// Shaped like the credentials a developer's shell would carry, and neither one.
const INHERITED_OAUTH_TOKEN = "sk-ant-oat01-test-inherited-not-a-real-token";
const INHERITED_API_KEY = "sk-ant-api03-test-inherited-not-a-real-key";

// A Session outlives its Host by design (spec user story 5), so a test that
// made one takes it away itself rather than leaving it on the machine.
async function reap(view: SessionView | undefined, branch: string) {
  if (view?.ttydPid) {
    try {
      Deno.kill(view.ttydPid, "SIGTERM");
    } catch {
      // already gone
    }
  }
  await run("zmx", ["kill", branch, "--force"]);
}

sessionTest("NEW_SESSION creates the Worktree and reaches running with branch and path", async () => {
  const liveTree = await makeLiveTree();
  const record = `${liveTree}/stub-record.txt`;
  const branch = `agent-${crypto.randomUUID().slice(0, 8)}`;
  const host = await startTestHost({
    liveTree,
    claudePath: await makeStubClaude(record),
  });
  let view: SessionView | undefined;
  try {
    await newSession(host.url, branch);
    view = await waitForSettled(host.url, branch);

    if (view.state !== "running") {
      throw new Error(`expected state "running", got ${JSON.stringify(view)}`);
    }
    // The spec fixes the Worktree's path: `.claude/worktrees/{branch}` in the
    // Live tree. The expected value is that literal, not a recomputation.
    const expectedPath = `${liveTree}/.claude/worktrees/${branch}`;
    if (view.branch !== branch || view.worktreePath !== expectedPath) {
      throw new Error(`expected branch ${branch} at ${expectedPath}, got ${JSON.stringify(view)}`);
    }
    if (!(await Deno.stat(expectedPath)).isDirectory) {
      throw new Error(`${expectedPath} is not a directory`);
    }
    const head = await run("git", ["rev-parse", "--abbrev-ref", "HEAD"], expectedPath);
    if (head.out.trim() !== branch) {
      throw new Error(`the Worktree is on ${head.out.trim()}, not ${branch}`);
    }
  } finally {
    await reap(view, branch);
    await host.stop();
  }
});

sessionTest("the command a Session runs passes through Wrap", async () => {
  const liveTree = await makeLiveTree();
  const record = `${liveTree}/stub-record.txt`;
  const branch = `agent-${crypto.randomUUID().slice(0, 8)}`;
  const host = await startTestHost({
    liveTree,
    claudePath: await makeStubClaude(record),
    // v1's Wrap is the identity (ADR-0004), so a wrapper that is visibly not
    // the identity is what proves the command goes through the seam at all.
    wrap: (command) => ["/usr/bin/env", "VARNICK_WRAPPED=yes", ...command],
  });
  let view: SessionView | undefined;
  try {
    await newSession(host.url, branch);
    view = await waitForSettled(host.url, branch);
    if (view.state !== "running") {
      throw new Error(`expected state "running", got ${JSON.stringify(view)}`);
    }

    const deadline = Date.now() + 10_000;
    let dump = "";
    while (Date.now() < deadline && !dump.includes("ARGV=")) {
      dump = await Deno.readTextFile(record).catch(() => "");
      if (!dump.includes("ARGV=")) await new Promise((resolve) => setTimeout(resolve, 100));
    }
    if (!dump.includes("VARNICK_WRAPPED=yes")) {
      throw new Error(`the wrapped command did not run; the stub saw:\n${dump}`);
    }
  } finally {
    await reap(view, branch);
    await host.stop();
  }
});

sessionTest("a create that cannot happen lands in failed with the error in context", async () => {
  const liveTree = await makeLiveTree();
  // `..` is not a legal git branch name, so `git worktree add` refuses it.
  const branch = "not..a..branch";
  const host = await startTestHost({
    liveTree,
    claudePath: await makeStubClaude(`${liveTree}/stub-record.txt`),
  });
  let view: SessionView | undefined;
  try {
    await newSession(host.url, branch);
    view = await waitForSettled(host.url, branch);

    if (view.state !== "failed") {
      throw new Error(`expected state "failed", got ${JSON.stringify(view)}`);
    }
    if (!view.error) throw new Error(`expected an error in context, got ${JSON.stringify(view)}`);
    // The Worktree must not be left behind by a create that did not happen.
    const path = `${liveTree}/.claude/worktrees/${branch}`;
    if (await Deno.stat(path).then(() => true, () => false)) {
      throw new Error(`${path} exists after a failed create`);
    }
  } finally {
    await reap(view, branch);
    await host.stop();
  }
});

sessionTest("a branch whose Session failed can be asked for again", async () => {
  const liveTree = await makeLiveTree();
  const branch = `agent-${crypto.randomUUID().slice(0, 8)}`;
  // The branch already exists, so `git worktree add -b` refuses it.
  await run("git", ["branch", branch], liveTree);
  const host = await startTestHost({
    liveTree,
    claudePath: await makeStubClaude(`${liveTree}/stub-record.txt`),
  });
  let view: SessionView | undefined;
  try {
    await newSession(host.url, branch);
    view = await waitForSettled(host.url, branch);
    if (view.state !== "failed") {
      throw new Error(`expected the first attempt to fail, got ${JSON.stringify(view)}`);
    }

    // With the cause removed, the same branch opens: a Session that never
    // existed must not hold its branch hostage.
    await run("git", ["branch", "-D", branch], liveTree);
    await newSession(host.url, branch);
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      view = (await readSessions(host.url))[branch];
      if (view?.state === "running") break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    if (view?.state !== "running") {
      throw new Error(`the retry never reached running: ${JSON.stringify(view)}`);
    }
  } finally {
    await reap(view, branch);
    await host.stop();
  }
});

sessionTest("the agent runs in its Worktree with the documented environment and no Credential", async () => {
  const liveTree = await makeLiveTree();
  const record = `${liveTree}/stub-record.txt`;
  const branch = `agent-${crypto.randomUUID().slice(0, 8)}`;
  // A credential in the launching shell is what this mode exists to keep from
  // the agent, so the Host is launched carrying one (ADR-0005).
  const restore = setHostEnvironment({ CLAUDE_CODE_OAUTH_TOKEN: INHERITED_OAUTH_TOKEN });
  const host = await startTestHost({ liveTree, claudePath: await makeStubClaude(record) });
  let view: SessionView | undefined;
  try {
    await newSession(host.url, branch);
    view = await waitForSettled(host.url, branch);
    if (view.state !== "running") {
      throw new Error(`expected state "running", got ${JSON.stringify(view)}`);
    }
    // The fixture Secrets file puts this Host in the Proxy's mode, so there is
    // a Proxy for the agent to be pointed at.
    if (!host.proxyUrl) throw new Error("the fixture Secrets file did not start a Proxy");

    // The stub writes what it was given the moment it starts; zmx has started
    // it by the time the session is listed, but the write may lag a beat.
    const deadline = Date.now() + 10_000;
    let dump = "";
    while (Date.now() < deadline) {
      try {
        dump = await Deno.readTextFile(record);
        if (dump.includes("ARGV=")) break;
      } catch {
        // not written yet
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    const seen = new Map(
      dump.split("\n").filter((line) => line.includes("=")).map((
        line,
      ) => [line.slice(0, line.indexOf("=")), line.slice(line.indexOf("=") + 1)]),
    );

    // The expected values are the spec's, written out here rather than asked
    // of the code that produced them.
    const worktreePath = `${liveTree}/.claude/worktrees/${branch}`;
    const expected: Record<string, string> = {
      CWD: worktreePath,
      ANTHROPIC_BASE_URL: host.proxyUrl,
      // The fixture Credential is an API key, so the API key placeholder is
      // the one the agent carries (ADR-0005).
      ANTHROPIC_API_KEY: API_KEY_PLACEHOLDER,
      CLAUDE_CONFIG_DIR: `${liveTree}/.varnick/claude`,
      GIT_AUTHOR_NAME: "Test Developer",
      GIT_AUTHOR_EMAIL: "test@example.com",
      GIT_COMMITTER_NAME: "Test Developer",
      GIT_COMMITTER_EMAIL: "test@example.com",
      VARNICK_DOOR: host.url,
      // The Session's own branch, so `varnick land` and `varnick preview` have
      // one to mean without being told.
      VARNICK_BRANCH: branch,
    };
    for (const [name, value] of Object.entries(expected)) {
      if (seen.get(name) !== value) {
        throw new Error(`${name}: expected ${value}, got ${JSON.stringify(seen.get(name))}`);
      }
    }
    // `varnick` is on the agent's PATH, and is a command it can run: the
    // Session is how the agent reaches the Door at all (ADR-0006).
    const binDir = `${liveTree}/.varnick/bin`;
    if (!(seen.get("PATH") ?? "").split(":").includes(binDir)) {
      throw new Error(`expected ${binDir} on PATH, got ${JSON.stringify(seen.get("PATH"))}`);
    }
    const varnick = `${binDir}/varnick`;
    if (!(await Deno.stat(varnick).then((s) => s.isFile, () => false))) {
      throw new Error(`no ${varnick} for the agent to run`);
    }
    if (dump.includes(FIXTURE_CREDENTIAL)) {
      throw new Error("the real Credential reached the agent's environment");
    }
    // Nor did the one the Host was launched with: here the placeholder replaces
    // it rather than sitting beside it.
    if (seen.get("CLAUDE_CODE_OAUTH_TOKEN") !== undefined) {
      throw new Error(
        `an inherited CLAUDE_CODE_OAUTH_TOKEN reached the agent: ${
          JSON.stringify(seen.get("CLAUDE_CODE_OAUTH_TOKEN"))
        }`,
      );
    }
    // A Preview's own Door port is not passed on, in either mode.
    if (seen.get("VARNICK_PORT") !== undefined) {
      throw new Error(`VARNICK_PORT reached the agent: ${JSON.stringify(seen.get("VARNICK_PORT"))}`);
    }
    // The agent home is handed over as a directory that exists (ADR-0009).
    const home = expected.CLAUDE_CONFIG_DIR;
    if (!(await Deno.stat(home).then((s) => s.isDirectory, () => false))) {
      throw new Error(`${home} is not a directory`);
    }
  } finally {
    restore();
    await reap(view, branch);
    await host.stop();
  }
});

sessionTest("with no Secrets file the agent inherits the launching shell's credential", async () => {
  // The case this serves (ADR-0005, second amendment): a shell that sourced
  // `zabaca/claude-mitm-proxy`'s client env carries that proxy in `HTTPS_PROXY`
  // and its fleet placeholder in `CLAUDE_CODE_OAUTH_TOKEN`. With varnick's own
  // Proxy off there is no boundary to keep, and stripping them sent the agent
  // to the fleet proxy with no credential at all.
  const liveTree = await makeLiveTree();
  const record = `${liveTree}/stub-record.txt`;
  const branch = `agent-${crypto.randomUUID().slice(0, 8)}`;
  // Both credential variables are set, so a delete left behind on either is
  // caught; the base URL is the one left unset, so inheriting untouched is
  // asserted in both directions.
  const restore = setHostEnvironment({
    CLAUDE_CODE_OAUTH_TOKEN: "fleet-placeholder",
    ANTHROPIC_API_KEY: INHERITED_API_KEY,
    HTTPS_PROXY: "http://127.0.0.1:1",
    ANTHROPIC_BASE_URL: undefined,
  });
  const host = await startTestHost({
    liveTree,
    secretsFile: `${liveTree}/secrets.yaml`,
    claudePath: await makeStubClaude(record),
  });
  let view: SessionView | undefined;
  try {
    await newSession(host.url, branch);
    view = await waitForSettled(host.url, branch);
    const env = await recordedEnvironment(record);

    // The values are the ones written above, not asked of the code that passed
    // them on.
    const inherited: Record<string, string> = {
      CLAUDE_CODE_OAUTH_TOKEN: "fleet-placeholder",
      ANTHROPIC_API_KEY: INHERITED_API_KEY,
      HTTPS_PROXY: "http://127.0.0.1:1",
    };
    for (const [name, value] of Object.entries(inherited)) {
      if (env[name] !== value) {
        throw new Error(`${name}: expected ${value}, got ${JSON.stringify(env[name])}`);
      }
    }
    // Untouched means untouched in both directions: the Host invents no base
    // URL for a Session it is not proxying.
    if ("ANTHROPIC_BASE_URL" in env) {
      throw new Error(
        `ANTHROPIC_BASE_URL reached the agent: ${JSON.stringify(env.ANTHROPIC_BASE_URL)}`,
      );
    }
    // A Preview's own Door port is not passed on, in either mode.
    if ("VARNICK_PORT" in env) {
      throw new Error(`VARNICK_PORT reached the agent: ${JSON.stringify(env.VARNICK_PORT)}`);
    }
  } finally {
    restore();
    await reap(view, branch);
    await host.stop();
  }
});

sessionTest("with no Secrets file the agent is given no credential at all", async () => {
  // The opt-out (ADR-0005, amended): no Proxy to point at and no placeholder to
  // carry, so Claude Code `/login`s inside the Session and keeps what it gets
  // in the agent's home (ADR-0009). All three are named because all three are
  // set in the `on` mode, and none of them may survive into the `off` one.
  const liveTree = await makeLiveTree();
  const record = `${liveTree}/stub-record.txt`;
  const branch = `agent-${crypto.randomUUID().slice(0, 8)}`;
  // "None of the three" is now a property of the launching environment rather
  // than of the code, so the test states it instead of inheriting whatever the
  // developer running the suite happens to have.
  const restore = setHostEnvironment({
    ANTHROPIC_BASE_URL: undefined,
    ANTHROPIC_API_KEY: undefined,
    CLAUDE_CODE_OAUTH_TOKEN: undefined,
  });
  const host = await startTestHost({
    liveTree,
    secretsFile: `${liveTree}/secrets.yaml`,
    claudePath: await makeStubClaude(record),
  });
  let view: SessionView | undefined;
  try {
    await newSession(host.url, branch);
    view = await waitForSettled(host.url, branch);
    const env = await recordedEnvironment(record);

    for (const name of ["ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"]) {
      if (name in env) {
        throw new Error(`${name} reached the agent: ${JSON.stringify(env[name])}`);
      }
    }
    // Everything the Session is otherwise made of is unchanged.
    const expected: Record<string, string> = {
      CLAUDE_CONFIG_DIR: `${liveTree}/.varnick/claude`,
      GIT_AUTHOR_NAME: "Test Developer",
      GIT_AUTHOR_EMAIL: "test@example.com",
      GIT_COMMITTER_NAME: "Test Developer",
      GIT_COMMITTER_EMAIL: "test@example.com",
      VARNICK_DOOR: host.url,
      VARNICK_BRANCH: branch,
    };
    for (const [name, value] of Object.entries(expected)) {
      if (env[name] !== value) {
        throw new Error(`${name}: expected ${value}, got ${JSON.stringify(env[name])}`);
      }
    }
  } finally {
    restore();
    await reap(view, branch);
    await host.stop();
  }
});

sessionTest("NEW_SESSION starts a zmx session named by the branch and a ttyd on its own loopback port", async () => {
  const liveTree = await makeLiveTree();
  const branch = `agent-${crypto.randomUUID().slice(0, 8)}`;
  const host = await startTestHost({
    liveTree,
    claudePath: await makeStubClaude(`${liveTree}/stub-record.txt`),
  });
  let view: SessionView | undefined;
  try {
    await newSession(host.url, branch);
    view = await waitForSettled(host.url, branch);
    if (view.state !== "running") {
      throw new Error(`expected state "running", got ${JSON.stringify(view)}`);
    }

    // The spec names the zmx session by the branch, and nothing else.
    const listed = (await run("zmx", ["ls", "--short"])).out.split("\n").map((l) => l.trim());
    if (!listed.includes(branch)) {
      throw new Error(`zmx ls does not list "${branch}": ${JSON.stringify(listed)}`);
    }

    // One ttyd per Session, on its own loopback port, and the Snapshot says where.
    if (!view.terminalUrl?.startsWith("http://127.0.0.1:")) {
      throw new Error(`expected a loopback terminal URL, got ${JSON.stringify(view.terminalUrl)}`);
    }
    const page = await fetch(view.terminalUrl);
    await page.body?.cancel();
    if (page.status !== 200) {
      throw new Error(`ttyd at ${view.terminalUrl} answered ${page.status}`);
    }
  } finally {
    await reap(view, branch);
    await host.stop();
  }
});

// ---------------------------------------------------------------------------
// Rebuild at launch (ADR-0007): the Host's picture comes from the world, never
// from a file. These tests prepare the world by hand *before* the Host exists.

// A Worktree made the way the Host would make one, without a Host.
async function makeWorktreeByHand(liveTree: string, branch: string): Promise<string> {
  const path = `${liveTree}/.claude/worktrees/${branch}`;
  const added = await run("git", ["worktree", "add", "-b", branch, path], liveTree);
  if (!added.success) throw new Error(`git worktree add: ${added.err}`);
  return path;
}

// A zmx session made by hand, named by the branch, as the Host would name it.
async function makeZmxSessionByHand(branch: string, cwd: string): Promise<void> {
  await new Deno.Command("zmx", {
    args: ["attach", branch, "sleep", "300"],
    cwd,
    stdin: "null",
    stdout: "null",
    stderr: "null",
  }).output();
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    if (await zmxLists(branch)) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`zmx never listed a session named "${branch}"`);
}

// Poll the Snapshot until the named Session reaches a state, so a launch that
// has to start a ttyd is waited on rather than raced.
async function waitForState(doorUrl: string, branch: string, state: string): Promise<SessionView> {
  const deadline = Date.now() + 30_000;
  let last: SessionView | undefined;
  while (Date.now() < deadline) {
    last = (await readSessions(doorUrl))[branch];
    if (last?.state === state) return last;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Session "${branch}" never reached ${state}: ${JSON.stringify(last)}`);
}

async function zmxLists(branch: string): Promise<boolean> {
  return (await run("zmx", ["ls", "--short"])).out.split("\n").map((l) => l.trim())
    .includes(branch);
}

async function exists(path: string): Promise<boolean> {
  return await Deno.stat(path).then(() => true, () => false);
}

sessionTest("a Worktree with a zmx session made before launch is running; one without is detached", async () => {
  const liveTree = await makeLiveTree();
  const attachedBranch = `agent-${crypto.randomUUID().slice(0, 8)}`;
  const aloneBranch = `agent-${crypto.randomUUID().slice(0, 8)}`;

  const attachedPath = await makeWorktreeByHand(liveTree, attachedBranch);
  await makeZmxSessionByHand(attachedBranch, attachedPath);
  await makeWorktreeByHand(liveTree, aloneBranch);

  const host = await startTestHost({
    liveTree,
    claudePath: await makeStubClaude(`${liveTree}/stub-record.txt`),
  });
  let attachedView: SessionView | undefined;
  try {
    // The spec's two words: a Worktree with a zmx session is running, one
    // without is detached. Those literals are the expectation, not a lookup.
    attachedView = await waitForState(host.url, attachedBranch, "running");
    const aloneView = await waitForState(host.url, aloneBranch, "detached");

    if (attachedView.worktreePath !== attachedPath) {
      throw new Error(`expected ${attachedPath}, got ${JSON.stringify(attachedView)}`);
    }
    if (!attachedView.terminalUrl?.startsWith("http://127.0.0.1:")) {
      throw new Error(
        `an adopted running Session needs a terminal, got ${JSON.stringify(attachedView)}`,
      );
    }
    if (aloneView.terminalUrl) {
      throw new Error(`a detached Session has no terminal: ${JSON.stringify(aloneView)}`);
    }
  } finally {
    await reap(attachedView, attachedBranch);
    await host.stop();
  }
});

// ---------------------------------------------------------------------------
// Reap (spec user stories 19 and 20).

// A Live tree whose commits are on a remote, so a branch made from it has
// nothing unpushed and Reap has no reason to refuse.
async function makeLiveTreeWithRemote(): Promise<string> {
  const tree = await makeLiveTree();
  const remote = await Deno.makeTempDir({ prefix: "varnick-remote-" });
  await run("git", ["init", "--bare", remote]);
  await run("git", ["remote", "add", "origin", remote], tree);
  const pushed = await run("git", ["push", "-u", "origin", "main"], tree);
  if (!pushed.success) throw new Error(`git push: ${pushed.err}`);
  return tree;
}

async function sendReap(doorUrl: string, branch: string, force?: boolean): Promise<void> {
  const res = await fetch(`${doorUrl}/actors/sessions/events`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ type: "REAP", branch, ...(force ? { force: true } : {}) }),
  });
  if (res.status !== 200) {
    throw new Error(`REAP: expected 200, got ${res.status} ${await res.text()}`);
  }
  await res.body?.cancel();
}

async function waitForGone(doorUrl: string, branch: string): Promise<void> {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (!(await readSessions(doorUrl))[branch]) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Session "${branch}" is still in the Snapshot`);
}

// A Reap that is refused puts the Session back where it was, with the reason.
async function waitForRefusal(doorUrl: string, branch: string): Promise<SessionView> {
  const deadline = Date.now() + 30_000;
  let last: SessionView | undefined;
  while (Date.now() < deadline) {
    last = (await readSessions(doorUrl))[branch];
    if (last?.state === "running" && last.refusal) return last;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`no refusal for "${branch}": ${JSON.stringify(last)}`);
}

sessionTest("REAP on a clean, pushed branch removes the Worktree, the zmx session and the ttyd", async () => {
  const liveTree = await makeLiveTreeWithRemote();
  const branch = `agent-${crypto.randomUUID().slice(0, 8)}`;
  const host = await startTestHost({
    liveTree,
    claudePath: await makeStubClaude(`${liveTree}/stub-record.txt`),
  });
  let view: SessionView | undefined;
  try {
    await newSession(host.url, branch);
    view = await waitForState(host.url, branch, "running");
    const terminalUrl = view.terminalUrl!;

    await sendReap(host.url, branch);
    await waitForGone(host.url, branch);

    if (await exists(`${liveTree}/.claude/worktrees/${branch}`)) {
      throw new Error("the Worktree is still there");
    }
    if (await zmxLists(branch)) throw new Error(`zmx still lists "${branch}"`);
    // The ttyd answered on this URL a moment ago; nothing should now.
    const stillServing = await fetch(terminalUrl)
      .then(async (res) => {
        await res.body?.cancel();
        return true;
      }, () => false);
    if (stillServing) throw new Error(`a ttyd is still serving ${terminalUrl}`);
  } finally {
    await reap(view, branch);
    await host.stop();
  }
});

sessionTest("REAP on a dirty Worktree is refused with a reason, and force proceeds", async () => {
  const liveTree = await makeLiveTreeWithRemote();
  const branch = `agent-${crypto.randomUUID().slice(0, 8)}`;
  const host = await startTestHost({
    liveTree,
    claudePath: await makeStubClaude(`${liveTree}/stub-record.txt`),
  });
  let view: SessionView | undefined;
  try {
    await newSession(host.url, branch);
    view = await waitForState(host.url, branch, "running");
    const worktreePath = `${liveTree}/.claude/worktrees/${branch}`;
    await Deno.writeTextFile(`${worktreePath}/unsaved.txt`, "the agent's work\n");

    await sendReap(host.url, branch);
    view = await waitForRefusal(host.url, branch);
    // The spec's word for this refusal is "dirty"; the reason must say so.
    if (!view.refusal!.includes("dirty")) {
      throw new Error(`the refusal does not name the reason: ${view.refusal}`);
    }
    if (!(await exists(worktreePath))) throw new Error("a refused Reap removed the Worktree");
    if (!(await zmxLists(branch))) throw new Error("a refused Reap killed the zmx session");

    // `force` is the way through, and it takes everything with it.
    await sendReap(host.url, branch, true);
    await waitForGone(host.url, branch);
    if (await exists(worktreePath)) throw new Error("a forced Reap left the Worktree");
    if (await zmxLists(branch)) throw new Error("a forced Reap left the zmx session");
  } finally {
    await reap(view, branch);
    await host.stop();
  }
});

sessionTest("REAP on a branch with unpushed commits is refused with a reason", async () => {
  const liveTree = await makeLiveTreeWithRemote();
  const branch = `agent-${crypto.randomUUID().slice(0, 8)}`;
  const worktreePath = `${liveTree}/.claude/worktrees/${branch}`;
  const host = await startTestHost({
    liveTree,
    claudePath: await makeStubClaude(`${liveTree}/stub-record.txt`),
  });
  let view: SessionView | undefined;
  try {
    await newSession(host.url, branch);
    view = await waitForState(host.url, branch, "running");
    // Committed, so the tree is clean; never pushed, so the work is only here.
    await Deno.writeTextFile(`${worktreePath}/done.txt`, "finished work\n");
    await run("git", ["add", "."], worktreePath);
    const committed = await run("git", ["commit", "-m", "the agent's work"], worktreePath);
    if (!committed.success) throw new Error(`git commit: ${committed.err}`);

    await sendReap(host.url, branch);
    view = await waitForRefusal(host.url, branch);
    // The spec's word for this one is "unpushed".
    if (!view.refusal!.includes("unpushed")) {
      throw new Error(`expected an unpushed refusal, got ${JSON.stringify(view)}`);
    }
    if (!(await exists(worktreePath))) throw new Error("a refused Reap removed the Worktree");
  } finally {
    await reap(view, branch);
    await run("git", ["worktree", "remove", worktreePath, "--force"], liveTree);
    await host.stop();
  }
});
