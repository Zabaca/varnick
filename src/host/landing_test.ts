// Headless tests that drive a real Host through the Door against a temp git
// repo (ADR-0006, spec Testing Decisions). Nothing here imports a Machine; the
// Door is the only way in, and the Live tree under test is always a throwaway.
import { type HostOptions, startHost } from "./main.ts";

const FIXTURE_SECRETS = new URL("./testdata/secrets.yaml", import.meta.url).pathname;
const FIXTURE_AGE_KEY = new URL("./testdata/test-age-key.txt", import.meta.url).pathname;

// Landing needs git, and a launch needs sops. Without either the tests skip
// with a message rather than failing for a reason that is not the code's.
const MISSING = await (async () => {
  const missing: string[] = [];
  const probes: [string, string[]][] = [["git", ["--version"]], ["sops", ["--version"]]];
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

function landingTest(name: string, fn: () => Promise<void>) {
  Deno.test({
    name: MISSING.length === 0 ? name : `${name} (skipped: ${MISSING.join(", ")} not installed)`,
    ignore: MISSING.length > 0,
    fn,
  });
}

async function git(args: string[], cwd: string): Promise<string> {
  const { success, stdout, stderr } = await new Deno.Command("git", {
    args,
    cwd,
    stdout: "piped",
    stderr: "piped",
  }).output();
  const decoder = new TextDecoder();
  if (!success) {
    throw new Error(`git ${args.join(" ")}: ${decoder.decode(stderr).trim()}`);
  }
  return decoder.decode(stdout).trim();
}

// A Live tree to launch a Host against: a git repo on `main` with one commit.
async function makeLiveTree(): Promise<string> {
  const tree = await Deno.makeTempDir({ prefix: "varnick-live-" });
  await git(["init", "-b", "main", "."], tree);
  await git(["config", "user.name", "Test Developer"], tree);
  await git(["config", "user.email", "test@example.com"], tree);
  await Deno.writeTextFile(`${tree}/README.md`, "live tree\n");
  await git(["add", "."], tree);
  await git(["commit", "-m", "first"], tree);
  return tree;
}

// A branch one commit ahead of `main`, made without leaving `main` checked out,
// so the Live tree stays clean and on the branch Landing will move.
async function commitOnBranch(tree: string, branch: string, file: string): Promise<string> {
  await git(["worktree", "add", "-b", branch, `${tree}/.work/${branch}`], tree);
  const work = `${tree}/.work/${branch}`;
  await Deno.writeTextFile(`${work}/${file}`, `${file}\n`);
  await git(["add", "."], work);
  await git(["commit", "-m", `add ${file}`], work);
  const tip = await git(["rev-parse", "HEAD"], work);
  await git(["worktree", "remove", work], tree);
  return tip;
}

function startTestHost(options: HostOptions) {
  return startHost({
    headless: true,
    port: 0,
    secretsFile: FIXTURE_SECRETS,
    ageKeyFile: FIXTURE_AGE_KEY,
    ...options,
  });
}

interface LandingSnapshot {
  value: string;
  context: { branch?: string; reason?: string; head?: string; error?: string };
}

async function readLanding(doorUrl: string): Promise<LandingSnapshot> {
  const res = await fetch(`${doorUrl}/actors/landing`);
  if (res.status !== 200) throw new Error(`GET /actors/landing: expected 200, got ${res.status}`);
  return await res.json();
}

async function land(doorUrl: string, branch: string): Promise<void> {
  const res = await fetch(`${doorUrl}/actors/landing/events`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    // The Event carries the branch name and nothing else; the Host decides
    // everything from it (spec §Machines).
    body: JSON.stringify({ type: "LAND", branch }),
  });
  if (res.status !== 200) {
    throw new Error(`LAND: expected 200, got ${res.status} ${await res.text()}`);
  }
  await res.body?.cancel();
}

// Poll until Landing settles out of its in-flight states.
async function waitForSettled(doorUrl: string): Promise<LandingSnapshot> {
  const deadline = Date.now() + 30_000;
  let last: LandingSnapshot | undefined;
  while (Date.now() < deadline) {
    last = await readLanding(doorUrl);
    if (last.value === "landed" || last.value === "refused") return last;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`Landing never settled: ${JSON.stringify(last)}`);
}

landingTest("a branch one commit ahead of a clean Live tree lands and HEAD moves", async () => {
  const liveTree = await makeLiveTree();
  const tip = await commitOnBranch(liveTree, "feature", "one.txt");
  const host = await startTestHost({ liveTree });
  try {
    await land(host.url, "feature");
    const snapshot = await waitForSettled(host.url);

    if (snapshot.value !== "landed") {
      throw new Error(`expected "landed", got ${JSON.stringify(snapshot)}`);
    }
    // The expected HEAD is the branch tip read before the Landing, not
    // something asked of the code that performed it.
    const head = await git(["rev-parse", "HEAD"], liveTree);
    if (head !== tip) {
      throw new Error(`the Live tree HEAD is ${head}, not the branch tip ${tip}`);
    }
    if (snapshot.context.branch !== "feature" || snapshot.context.head !== tip) {
      throw new Error(`expected branch "feature" at ${tip} in context, got ${JSON.stringify(snapshot)}`);
    }
  } finally {
    await host.stop();
  }
});

landingTest("a dirty Live tree refuses with the reason dirty", async () => {
  const liveTree = await makeLiveTree();
  const tip = await commitOnBranch(liveTree, "feature", "one.txt");
  const before = await git(["rev-parse", "HEAD"], liveTree);
  // The developer's own uncommitted work, which Landing must never merge over.
  await Deno.writeTextFile(`${liveTree}/README.md`, "edited by the developer\n");
  const host = await startTestHost({ liveTree });
  try {
    await land(host.url, "feature");
    const snapshot = await waitForSettled(host.url);

    if (snapshot.value !== "refused" || snapshot.context.reason !== "dirty") {
      throw new Error(`expected refused/dirty, got ${JSON.stringify(snapshot)}`);
    }
    const head = await git(["rev-parse", "HEAD"], liveTree);
    if (head !== before || head === tip) {
      throw new Error(`the Live tree moved to ${head} despite the refusal`);
    }
  } finally {
    await host.stop();
  }
});

landingTest("a branch that is not a fast-forward refuses with notFastForward", async () => {
  const liveTree = await makeLiveTree();
  // The branch leaves `main`, and then `main` moves on: neither is an ancestor
  // of the other, so the fast-forward is not there to be had. Rebasing that is
  // the agent's job (ADR-0003).
  await commitOnBranch(liveTree, "feature", "theirs.txt");
  await Deno.writeTextFile(`${liveTree}/mine.txt`, "mine\n");
  await git(["add", "."], liveTree);
  await git(["commit", "-m", "mine"], liveTree);
  const before = await git(["rev-parse", "HEAD"], liveTree);

  const host = await startTestHost({ liveTree });
  try {
    await land(host.url, "feature");
    const snapshot = await waitForSettled(host.url);

    if (snapshot.value !== "refused" || snapshot.context.reason !== "notFastForward") {
      throw new Error(`expected refused/notFastForward, got ${JSON.stringify(snapshot)}`);
    }
    const head = await git(["rev-parse", "HEAD"], liveTree);
    if (head !== before) {
      throw new Error(`the Live tree moved to ${head} despite the refusal`);
    }
  } finally {
    await host.stop();
  }
});

landingTest("a branch that does not exist refuses with unknownBranch", async () => {
  const liveTree = await makeLiveTree();
  const before = await git(["rev-parse", "HEAD"], liveTree);
  const host = await startTestHost({ liveTree });
  try {
    await land(host.url, "no-such-branch");
    const snapshot = await waitForSettled(host.url);

    if (snapshot.value !== "refused" || snapshot.context.reason !== "unknownBranch") {
      throw new Error(`expected refused/unknownBranch, got ${JSON.stringify(snapshot)}`);
    }
    const head = await git(["rev-parse", "HEAD"], liveTree);
    if (head !== before) {
      throw new Error(`the Live tree moved to ${head} despite the refusal`);
    }
  } finally {
    await host.stop();
  }
});

landingTest("nothing but the branch name is read from the Event", async () => {
  const liveTree = await makeLiveTree();
  const tip = await commitOnBranch(liveTree, "feature", "one.txt");
  const decoy = await Deno.makeTempDir({ prefix: "varnick-decoy-" });
  const host = await startTestHost({ liveTree });
  try {
    // Fields the Snapshot happens to have names for, sent by an Event that has
    // no business setting them. The Host decides everything from the branch
    // name alone (spec §Machines), so all of these must be ignored.
    const res = await fetch(`${host.url}/actors/landing/events`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        type: "LAND",
        branch: "feature",
        liveTree: decoy,
        reason: "dirty",
        head: "0000000000000000000000000000000000000000",
      }),
    });
    if (res.status !== 200) throw new Error(`LAND: expected 200, got ${res.status}`);
    await res.body?.cancel();

    const snapshot = await waitForSettled(host.url);
    if (snapshot.value !== "landed" || snapshot.context.reason !== undefined) {
      throw new Error(`the Event's extra fields were read: ${JSON.stringify(snapshot)}`);
    }
    // The Live tree named at launch is the one that moved, not the decoy.
    const head = await git(["rev-parse", "HEAD"], liveTree);
    if (head !== tip || snapshot.context.head !== tip) {
      throw new Error(`expected HEAD ${tip}, got ${head} / ${JSON.stringify(snapshot.context)}`);
    }
  } finally {
    await host.stop();
  }
});
