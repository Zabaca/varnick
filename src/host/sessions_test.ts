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
  run,
  sessionTest,
  startTestHost,
  waitForSettled,
} from "./test_support.ts";

const FIXTURE_CREDENTIAL = "sk-ant-api03-test-fixture-not-a-real-key";

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
  const host = await startTestHost({ liveTree, claudePath: await makeStubClaude(record) });
  let view: SessionView | undefined;
  try {
    await newSession(host.url, branch);
    view = await waitForSettled(host.url, branch);
    if (view.state !== "running") {
      throw new Error(`expected state "running", got ${JSON.stringify(view)}`);
    }

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
    };
    for (const [name, value] of Object.entries(expected)) {
      if (seen.get(name) !== value) {
        throw new Error(`${name}: expected ${value}, got ${JSON.stringify(seen.get(name))}`);
      }
    }
    if (dump.includes(FIXTURE_CREDENTIAL)) {
      throw new Error("the real Credential reached the agent's environment");
    }
    // The agent home is handed over as a directory that exists (ADR-0009).
    const home = expected.CLAUDE_CONFIG_DIR;
    if (!(await Deno.stat(home).then((s) => s.isDirectory, () => false))) {
      throw new Error(`${home} is not a directory`);
    }
  } finally {
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
