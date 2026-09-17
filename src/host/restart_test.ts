// A Restart must not cost a Session (spec user story 6). Every test here drives
// a real headless Host through the Door and nothing else (ADR-0006).
import {
  answers,
  makeLiveTree,
  makeStubClaude,
  newSession,
  reap,
  readSessions,
  run,
  sessionTest,
  startTestHost,
  waitForSettled,
} from "./test_support.ts";
import type { SessionView } from "./machines/sessions.ts";

// Poll the Snapshot until a Session appears and settles. A Host launched onto
// an existing Live tree seeds its list after the Door opens, so the branch is
// not there the instant the launch returns.
async function waitForAdopted(doorUrl: string, branch: string): Promise<SessionView> {
  const deadline = Date.now() + 30_000;
  let last: SessionView | undefined;
  while (Date.now() < deadline) {
    last = (await readSessions(doorUrl))[branch];
    if (last && last.state !== "creating") return last;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Session "${branch}" was never adopted: ${JSON.stringify(last)}`);
}

sessionTest("a Session opened before a relaunch is running with an answering terminal after it", async () => {
  const liveTree = await makeLiveTree();
  const claudePath = await makeStubClaude(`${liveTree}/stub-record.txt`);
  const branch = `agent-${crypto.randomUUID().slice(0, 8)}`;

  const before = await startTestHost({ liveTree, claudePath });
  let opened: SessionView | undefined;
  let adopted: SessionView | undefined;
  try {
    await newSession(before.url, branch);
    opened = await waitForSettled(before.url, branch);
    if (opened.state !== "running") {
      throw new Error(`the Session did not open: ${JSON.stringify(opened)}`);
    }
  } finally {
    await before.stop();
  }

  // What a Restart leaves behind: the old Host gone, zmx and ttyd untouched.
  const after = await startTestHost({ liveTree, claudePath });
  try {
    adopted = await waitForAdopted(after.url, branch);
    if (adopted.state !== "running") {
      throw new Error(`expected state "running" after the relaunch, got ${JSON.stringify(adopted)}`);
    }
    // The same ttyd, not a new one: the port the first Host recorded.
    if (adopted.terminalUrl !== opened.terminalUrl) {
      throw new Error(
        `expected the ttyd at ${opened.terminalUrl} to be adopted, got ${adopted.terminalUrl}`,
      );
    }
    if (!adopted.terminalUrl || !(await answers(adopted.terminalUrl))) {
      throw new Error(`nothing answers at ${adopted.terminalUrl}`);
    }
  } finally {
    await after.stop();
    await reap([opened, adopted], branch);
  }
});

sessionTest("a ttyd killed before the relaunch is replaced by one that answers", async () => {
  const liveTree = await makeLiveTree();
  const claudePath = await makeStubClaude(`${liveTree}/stub-record.txt`);
  const branch = `agent-${crypto.randomUUID().slice(0, 8)}`;

  const before = await startTestHost({ liveTree, claudePath });
  let opened: SessionView | undefined;
  let adopted: SessionView | undefined;
  try {
    await newSession(before.url, branch);
    opened = await waitForSettled(before.url, branch);
    if (opened.state !== "running" || !opened.ttydPid) {
      throw new Error(`the Session did not open: ${JSON.stringify(opened)}`);
    }
  } finally {
    await before.stop();
  }

  // The terminal dies while no Host is watching; the zmx session does not.
  Deno.kill(opened.ttydPid!, "SIGKILL");
  const gone = Date.now() + 10_000;
  while (Date.now() < gone && await answers(opened.terminalUrl!)) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }

  const after = await startTestHost({ liveTree, claudePath });
  try {
    adopted = await waitForAdopted(after.url, branch);
    if (adopted.state !== "running") {
      throw new Error(`expected state "running", got ${JSON.stringify(adopted)}`);
    }
    if (!adopted.terminalUrl || !(await answers(adopted.terminalUrl))) {
      throw new Error(`no terminal answers for the adopted Session: ${JSON.stringify(adopted)}`);
    }
    if (adopted.ttydPid === opened.ttydPid) {
      throw new Error(`the dead ttyd (pid ${opened.ttydPid}) was reported as alive`);
    }
    // The zmx session was never a child of either Host, so it is still there.
    const listed = await run("zmx", ["ls", "--short"]);
    if (!listed.out.split("\n").some((line) => line.trim() === branch)) {
      throw new Error(`the zmx session "${branch}" did not survive: ${listed.out}`);
    }
  } finally {
    await after.stop();
    await reap([opened, adopted], branch);
  }
});

sessionTest("RESTART runs the launch command from the Live tree and stops the old Host", async () => {
  const liveTree = await makeLiveTree();
  const marker = `${liveTree}/relaunched.txt`;
  // Stands in for the `deno desktop` line a real Live Host relaunches with: it
  // records the working directory it was given and exits.
  const launcher = `${liveTree}/relaunch.sh`;
  await Deno.writeTextFile(launcher, `#!/bin/sh\nprintf '%s\\n' "$PWD" > ${marker}\n`);
  await Deno.chmod(launcher, 0o755);

  const host = await startTestHost({
    liveTree,
    claudePath: "/bin/false",
    launchCommand: [launcher],
    // A Host under test may not take the test runner with it; everything else
    // a Restart does — releasing the ports, launching the successor — is real.
    exit: () => {},
  });
  let exited = false;
  try {
    const res = await fetch(`${host.url}/actors/host/events`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "RESTART" }),
    });
    if (res.status !== 200) {
      throw new Error(`RESTART: expected 200, got ${res.status} ${await res.text()}`);
    }
    const snapshot = await res.json();
    if (snapshot.value === "running") {
      throw new Error(`the Host stayed in ${JSON.stringify(snapshot.value)} after RESTART`);
    }

    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline && !(await Deno.stat(marker).then(() => true, () => false))) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    const cwd = (await Deno.readTextFile(marker).catch(() => "")).trim();
    if (cwd !== liveTree) {
      throw new Error(`the launch command ran in ${JSON.stringify(cwd)}, not the Live tree`);
    }

    // The old Host is gone: its Door no longer answers, so the port the new one
    // was launched on is free for it.
    const closed = Date.now() + 15_000;
    while (Date.now() < closed && await answers(host.url)) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    if (await answers(host.url)) {
      throw new Error(`the old Host is still listening at ${host.url}`);
    }
    exited = true;
  } finally {
    if (!exited) await host.stop();
  }
});
