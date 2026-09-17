// A Preview is a second Host launched from a Worktree (ADR-0008). Every test
// here drives a real headless Host through the Door and enters the Preview by
// its own Door, and nothing else (ADR-0006).
import {
  makeLiveTree,
  makePreviewLauncher,
  makeStubClaude,
  newSession,
  run,
  sessionTest,
  startTestHost,
  waitForSettled,
} from "./test_support.ts";

interface PreviewView {
  url: string;
  pid: number;
}

interface HostSnapshot {
  value: unknown;
  context: {
    tree: string;
    previews?: Record<string, PreviewView>;
    previewError?: string;
  };
}

async function readHost(doorUrl: string): Promise<HostSnapshot> {
  const res = await fetch(`${doorUrl}/actors/host`);
  if (res.status !== 200) throw new Error(`GET /actors/host: expected 200, got ${res.status}`);
  return await res.json();
}

sessionTest("a Host's Snapshot names the tree it runs from", async () => {
  const liveTree = await makeLiveTree();
  const host = await startTestHost({ liveTree, claudePath: "/bin/false" });
  try {
    const snapshot = await readHost(host.url);
    if (snapshot.context.tree !== liveTree) {
      throw new Error(
        `expected the Snapshot to name ${liveTree} as its tree, got ${
          JSON.stringify(snapshot.context.tree)
        }`,
      );
    }
  } finally {
    await host.stop();
  }
});

async function sendHost(doorUrl: string, event: Record<string, unknown>): Promise<HostSnapshot> {
  const res = await fetch(`${doorUrl}/actors/host/events`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(event),
  });
  if (res.status !== 200) {
    throw new Error(`${event.type}: expected 200, got ${res.status} ${await res.text()}`);
  }
  return await res.json();
}

// PREVIEW is answered as soon as the launch is under way; the Snapshot says
// where the Preview is once its Door answers, and that is what is waited for.
async function waitForPreview(doorUrl: string, branch: string): Promise<PreviewView> {
  const deadline = Date.now() + 60_000;
  let last: HostSnapshot | undefined;
  while (Date.now() < deadline) {
    last = await readHost(doorUrl);
    const preview = last.context.previews?.[branch];
    if (preview) return preview;
    if (last.context.previewError) {
      throw new Error(`the Preview was refused: ${last.context.previewError}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`no Preview of "${branch}" appeared: ${JSON.stringify(last)}`);
}

function reapPreview(preview: PreviewView | undefined) {
  if (!preview) return;
  try {
    Deno.kill(preview.pid, "SIGTERM");
  } catch {
    // already gone
  }
}

sessionTest("PREVIEW launches a second Host from the Worktree on its own port", async () => {
  const liveTree = await makeLiveTree();
  const claudePath = await makeStubClaude(`${liveTree}/stub-record.txt`);
  const branch = `agent-${crypto.randomUUID().slice(0, 8)}`;

  const host = await startTestHost({
    liveTree,
    claudePath,
    previewCommand: await makePreviewLauncher(claudePath),
  });
  let preview: PreviewView | undefined;
  let ttydPid: number | undefined;
  try {
    await newSession(host.url, branch);
    const session = await waitForSettled(host.url, branch);
    if (session.state !== "running") {
      throw new Error(`the Session did not open: ${JSON.stringify(session)}`);
    }
    ttydPid = session.ttydPid;

    await sendHost(host.url, { type: "PREVIEW", branch });
    preview = await waitForPreview(host.url, branch);

    if (new URL(preview.url).port === String(host.port)) {
      throw new Error(`the Preview took the launching Host's port ${host.port}`);
    }

    // The Preview is entered by its own Door and says which tree it runs from.
    const snapshot = await readHost(preview.url);
    const worktree = `${liveTree}/.claude/worktrees/${branch}`;
    if (snapshot.context.tree !== worktree) {
      throw new Error(
        `expected the Preview to run from ${worktree}, its Snapshot says ${
          JSON.stringify(snapshot.context.tree)
        }`,
      );
    }
  } finally {
    reapPreview(preview);
    await host.stop();
    if (ttydPid) {
      try {
        Deno.kill(ttydPid, "SIGTERM");
      } catch {
        // already gone
      }
    }
    await run("zmx", ["kill", branch, "--force"]);
  }
});

// The environment the stub `claude` recorded, as the agent actually got it.
async function recordedEnvironment(path: string): Promise<Record<string, string>> {
  const text = await Deno.readTextFile(path);
  const env: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const at = line.indexOf("=");
    if (at > 0) env[line.slice(0, at)] = line.slice(at + 1);
  }
  return env;
}

sessionTest("a Session opened through a Preview's Door is driven by that Preview", async () => {
  const liveTree = await makeLiveTree();
  const claudePath = await makeStubClaude(`${liveTree}/live-record.txt`);
  // The Preview runs its own agent, so its Sessions record somewhere of their
  // own; what the launching Host's Session saw must not be read for this.
  const previewRecord = `${liveTree}/preview-record.txt`;
  const previewClaude = await makeStubClaude(previewRecord);
  const branch = `agent-${crypto.randomUUID().slice(0, 8)}`;
  const inPreview = `agent-${crypto.randomUUID().slice(0, 8)}`;

  const host = await startTestHost({
    liveTree,
    claudePath,
    previewCommand: await makePreviewLauncher(previewClaude),
  });
  let preview: PreviewView | undefined;
  const ttydPids: (number | undefined)[] = [];
  try {
    await newSession(host.url, branch);
    ttydPids.push((await waitForSettled(host.url, branch)).ttydPid);

    await sendHost(host.url, { type: "PREVIEW", branch });
    preview = await waitForPreview(host.url, branch);

    // A Session asked of the Preview, through the Preview's own Door.
    await newSession(preview.url, inPreview);
    const session = await waitForSettled(preview.url, inPreview);
    if (session.state !== "running") {
      throw new Error(`the Preview's Session did not open: ${JSON.stringify(session)}`);
    }
    ttydPids.push(session.ttydPid);

    const env = await recordedEnvironment(previewRecord);
    if (env.VARNICK_DOOR === host.url) {
      throw new Error(`the Preview's Session was pointed at the launching Host at ${host.url}`);
    }
    if (env.VARNICK_DOOR !== preview.url) {
      throw new Error(
        `expected VARNICK_DOOR to be the Preview at ${preview.url}, the agent got ${
          JSON.stringify(env.VARNICK_DOOR)
        }`,
      );
    }
  } finally {
    reapPreview(preview);
    await host.stop();
    for (const pid of ttydPids) {
      if (!pid) continue;
      try {
        Deno.kill(pid, "SIGTERM");
      } catch {
        // already gone
      }
    }
    await run("zmx", ["kill", branch, "--force"]);
    await run("zmx", ["kill", inPreview, "--force"]);
  }
});

sessionTest("PREVIEW of a branch with no Worktree is refused and leaves the Host running", async () => {
  const liveTree = await makeLiveTree();
  // A directory where the Worktree would be, but no Worktree: whatever is in
  // it, it is not a branch the agent was given to work in (ADR-0003), and a
  // Host must not be launched from it.
  await Deno.mkdir(`${liveTree}/.claude/worktrees/never-opened`, { recursive: true });
  const host = await startTestHost({
    liveTree,
    claudePath: "/bin/false",
    // Nothing should be launched, so the command is one that would be noticed:
    // it writes a file and this test says there must be none.
    previewCommand: ["/bin/sh", "-c", `printf spawned > ${liveTree}/spawned.txt`],
  });
  try {
    await sendHost(host.url, { type: "PREVIEW", branch: "never-opened" });

    const deadline = Date.now() + 10_000;
    let snapshot = await readHost(host.url);
    while (Date.now() < deadline && snapshot.value !== "running") {
      await new Promise((resolve) => setTimeout(resolve, 100));
      snapshot = await readHost(host.url);
    }
    if (snapshot.value !== "running") {
      throw new Error(`the Host stayed in ${JSON.stringify(snapshot.value)} after the refusal`);
    }
    if (!snapshot.context.previewError) {
      throw new Error(`the Snapshot gave no reason: ${JSON.stringify(snapshot.context)}`);
    }
    if (snapshot.context.previews?.["never-opened"]) {
      throw new Error(`a Preview was recorded for a branch with no Worktree`);
    }
    if (await Deno.stat(`${liveTree}/spawned.txt`).then(() => true, () => false)) {
      throw new Error("the Preview command was run for a branch with no Worktree");
    }
  } finally {
    await host.stop();
  }
});
