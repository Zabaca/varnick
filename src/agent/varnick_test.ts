// The `varnick` command as the agent gets it: the executable the Host installs
// on the Session's PATH, run as a subprocess with nothing but `VARNICK_DOOR`
// and `VARNICK_BRANCH` in its environment, against a real headless Host. That
// binary is the only seam here — nothing in this file imports the CLI — and
// the Door is the only way it reaches the Host (ADR-0006).
import {
  answers,
  hostTest,
  makeLiveTree,
  makePreviewLauncher,
  makeStubClaude,
  run,
  sessionTest,
  startTestHost,
} from "../host/test_support.ts";
import { installAgentBin } from "../host/sessions.ts";

async function git(args: string[], cwd: string): Promise<string> {
  const { success, out, err } = await run("git", args, cwd);
  if (!success) throw new Error(`git ${args.join(" ")}: ${err.trim()}`);
  return out.trim();
}

// A branch one commit ahead of `main`, made without leaving `main` checked out,
// so the Live tree stays clean and on the branch a Landing will move.
async function commitOnBranch(tree: string, branch: string, file: string): Promise<string> {
  const work = `${tree}/.work/${branch}`;
  await git(["worktree", "add", "-b", branch, work], tree);
  await Deno.writeTextFile(`${work}/${file}`, `${file}\n`);
  await git(["add", "."], work);
  await git(["commit", "-m", `add ${file}`], work);
  const tip = await git(["rev-parse", "HEAD"], work);
  await git(["worktree", "remove", work], tree);
  return tip;
}

interface PreviewView {
  url: string;
  pid: number;
}

interface Ran {
  code: number;
  out: string;
  err: string;
}

// Running the command the way a Session's shell would: by its name, found on
// the PATH the Host built, with the Session's own environment and nothing else.
async function varnick(
  bin: string,
  args: string[],
  env: Record<string, string>,
): Promise<Ran> {
  const { code, stdout, stderr } = await new Deno.Command("varnick", {
    args,
    env: { PATH: bin, ...env },
    clearEnv: true,
    stdout: "piped",
    stderr: "piped",
  }).output();
  const decoder = new TextDecoder();
  return { code, out: decoder.decode(stdout), err: decoder.decode(stderr) };
}

function parse(ran: Ran): { value: unknown; context: Record<string, unknown> } {
  try {
    return JSON.parse(ran.out);
  } catch {
    throw new Error(
      `expected a Snapshot as JSON on stdout, got ${JSON.stringify(ran.out)} (stderr: ${ran.err})`,
    );
  }
}

hostTest("`varnick snapshot` prints an actor's Snapshot as JSON", async () => {
  const liveTree = await makeLiveTree();
  const bin = await installAgentBin(liveTree);
  const host = await startTestHost({ liveTree, claudePath: "/bin/false" });
  try {
    const ran = await varnick(bin, ["snapshot", "host"], { VARNICK_DOOR: host.url });
    if (ran.code !== 0) throw new Error(`expected exit 0, got ${ran.code}: ${ran.err}`);
    // The `host` actor's Snapshot names the tree it runs from (spec §Preview),
    // which is the one thing about it this test already knows independently.
    if (parse(ran).context.tree !== liveTree) {
      throw new Error(`expected the Snapshot to name ${liveTree}, got ${ran.out}`);
    }
  } finally {
    await host.stop();
  }
});

hostTest("`varnick snapshot` of an actor that is not there fails", async () => {
  const liveTree = await makeLiveTree();
  const bin = await installAgentBin(liveTree);
  const host = await startTestHost({ liveTree, claudePath: "/bin/false" });
  try {
    const ran = await varnick(bin, ["snapshot", "nobody"], { VARNICK_DOOR: host.url });
    if (ran.code === 0) throw new Error(`expected a non-zero exit, got 0: ${ran.out}`);
    if (!ran.err.includes("nobody")) {
      throw new Error(`expected the actor's name in the reason, got ${JSON.stringify(ran.err)}`);
    }
  } finally {
    await host.stop();
  }
});

hostTest("`varnick land` moves the Live tree to this Session's own branch", async () => {
  const liveTree = await makeLiveTree();
  // The branch's tip is read from git before the Host exists, so the Live
  // tree's HEAD afterwards is checked against something the command did not say.
  const tip = await commitOnBranch(liveTree, "feature", "one.txt");
  const bin = await installAgentBin(liveTree);
  const host = await startTestHost({ liveTree, claudePath: "/bin/false" });
  try {
    // No branch named: the Session's own is what a Landing is about by default.
    const ran = await varnick(bin, ["land"], {
      VARNICK_DOOR: host.url,
      VARNICK_BRANCH: "feature",
    });
    if (ran.code !== 0) throw new Error(`expected exit 0, got ${ran.code}: ${ran.err}`);
    if (parse(ran).context.head !== tip) {
      throw new Error(`expected the Snapshot to carry ${tip}, got ${ran.out}`);
    }
    if (await git(["rev-parse", "HEAD"], liveTree) !== tip) {
      throw new Error(`the Live tree did not move to ${tip}`);
    }
  } finally {
    await host.stop();
  }
});

hostTest("`varnick land` on a branch that is not a fast-forward fails", async () => {
  const liveTree = await makeLiveTree();
  // The branch leaves `main`, and then `main` moves on: neither is an ancestor
  // of the other, so there is no fast-forward to be had (ADR-0003).
  await commitOnBranch(liveTree, "feature", "theirs.txt");
  await Deno.writeTextFile(`${liveTree}/mine.txt`, "mine\n");
  await git(["add", "."], liveTree);
  await git(["commit", "-m", "mine"], liveTree);
  const before = await git(["rev-parse", "HEAD"], liveTree);

  const bin = await installAgentBin(liveTree);
  const host = await startTestHost({ liveTree, claudePath: "/bin/false" });
  try {
    const ran = await varnick(bin, ["land"], {
      VARNICK_DOOR: host.url,
      VARNICK_BRANCH: "feature",
    });
    if (ran.code === 0) throw new Error(`expected a non-zero exit, got 0: ${ran.out}`);
    // `notFastForward` is the Host's own word for it (`RefusalReason`), and it
    // is what the agent has to read to know rebasing is what is wanted.
    if (!ran.err.includes("notFastForward")) {
      throw new Error(`expected the refusal reason on stderr, got ${JSON.stringify(ran.err)}`);
    }
    if (await git(["rev-parse", "HEAD"], liveTree) !== before) {
      throw new Error("the Live tree moved despite the refusal");
    }
  } finally {
    await host.stop();
  }
});

hostTest("`varnick preview` opens a Preview of this Session's own branch", async () => {
  const liveTree = await makeLiveTree();
  await commitOnBranch(liveTree, "feature", "one.txt");
  // A Worktree at the path the Host would have made, which is what makes this
  // branch previewable (ADR-0003); no zmx session is needed to preview one.
  await git(["worktree", "add", `${liveTree}/.claude/worktrees/feature`, "feature"], liveTree);

  const bin = await installAgentBin(liveTree);
  const host = await startTestHost({
    liveTree,
    claudePath: "/bin/false",
    previewCommand: await makePreviewLauncher("/bin/false"),
  });
  let preview: PreviewView | undefined;
  try {
    const ran = await varnick(bin, ["preview"], {
      VARNICK_DOOR: host.url,
      VARNICK_BRANCH: "feature",
    });
    if (ran.code !== 0) throw new Error(`expected exit 0, got ${ran.code}: ${ran.err}`);
    const previews = parse(ran).context.previews as Record<string, PreviewView>;
    preview = previews?.feature;
    if (!preview) {
      throw new Error(`expected a Preview of "feature" in the Snapshot, got ${ran.out}`);
    }
    // The Preview is a Host of its own, so the proof it is there is its Door
    // answering — not the Snapshot repeating what it was told.
    if (!await answers(preview.url)) {
      throw new Error(`nothing answered at the Preview's Door ${preview.url}`);
    }
  } finally {
    if (preview) {
      try {
        Deno.kill(preview.pid, "SIGTERM");
      } catch {
        // already gone
      }
    }
    await host.stop();
  }
});

hostTest("`varnick preview` of a branch with no Worktree fails", async () => {
  const liveTree = await makeLiveTree();
  const bin = await installAgentBin(liveTree);
  const host = await startTestHost({ liveTree, claudePath: "/bin/false" });
  try {
    const ran = await varnick(bin, ["preview", "nowhere"], { VARNICK_DOOR: host.url });
    if (ran.code === 0) throw new Error(`expected a non-zero exit, got 0: ${ran.out}`);
    if (!ran.err.includes("nowhere")) {
      throw new Error(`expected the branch in the reason, got ${JSON.stringify(ran.err)}`);
    }
  } finally {
    await host.stop();
  }
});

// A Session outlives its Host by design (spec user story 5), so a test that
// made one takes it away itself rather than leaving it on the machine.
async function reap(view: { ttydPid?: number } | undefined, branch: string) {
  if (view?.ttydPid) {
    try {
      Deno.kill(view.ttydPid, "SIGTERM");
    } catch {
      // already gone
    }
  }
  await run("zmx", ["kill", branch, "--force"]);
}

sessionTest("`varnick session new` opens a Session on the branch it names", async () => {
  const liveTree = await makeLiveTree();
  const branch = `agent-${crypto.randomUUID().slice(0, 8)}`;
  const bin = await installAgentBin(liveTree);
  const host = await startTestHost({
    liveTree,
    claudePath: await makeStubClaude(`${liveTree}/stub-record.txt`),
  });
  let view: { ttydPid?: number; worktreePath?: string } | undefined;
  try {
    // Nothing is implied here: a Session is opened on a branch that is not the
    // one this command was run from, so the branch is the command's to name.
    const ran = await varnick(bin, ["session", "new", branch], { VARNICK_DOOR: host.url });
    if (ran.code !== 0) throw new Error(`expected exit 0, got ${ran.code}: ${ran.err}`);
    const sessions = parse(ran).context.sessions as Record<string, typeof view>;
    view = sessions?.[branch];
    if (!view) throw new Error(`expected a Session on "${branch}" in the Snapshot, got ${ran.out}`);
    // The Worktree is where the agent works and nowhere else (ADR-0003), so its
    // being on disk at the path the spec names is the proof a Session was made.
    const expected = `${liveTree}/.claude/worktrees/${branch}`;
    if (view.worktreePath !== expected) {
      throw new Error(`expected the Worktree at ${expected}, got ${view.worktreePath}`);
    }
    if (!await Deno.stat(expected).then((it) => it.isDirectory, () => false)) {
      throw new Error(`no Worktree at ${expected}`);
    }
  } finally {
    await reap(view, branch);
    await host.stop();
  }
});

sessionTest("`varnick session new` on a branch that cannot be opened fails", async () => {
  const liveTree = await makeLiveTree();
  // `..` is not a legal git branch name, so `git worktree add` refuses it.
  const branch = "not..a..branch";
  const bin = await installAgentBin(liveTree);
  const host = await startTestHost({
    liveTree,
    claudePath: await makeStubClaude(`${liveTree}/stub-record.txt`),
  });
  try {
    const ran = await varnick(bin, ["session", "new", branch], { VARNICK_DOOR: host.url });
    if (ran.code === 0) throw new Error(`expected a non-zero exit, got 0: ${ran.out}`);
    if (!ran.err.includes(branch)) {
      throw new Error(`expected the branch in the reason, got ${JSON.stringify(ran.err)}`);
    }
  } finally {
    await host.stop();
  }
});

hostTest("`varnick --help` documents the four subcommands", async () => {
  const bin = await installAgentBin(await makeLiveTree());
  // No Door: help is what the agent reads before it has asked for anything.
  const ran = await varnick(bin, ["--help"], {});
  if (ran.code !== 0) throw new Error(`expected exit 0, got ${ran.code}: ${ran.err}`);
  const documents = ["varnick land", "varnick preview", "varnick session new", "varnick snapshot"];
  for (const documented of documents) {
    if (!ran.out.includes(documented)) {
      throw new Error(`\`${documented}\` is not documented:\n${ran.out}`);
    }
  }
});
