// Landing: fast-forwarding the Live tree to a Worktree's branch. This module
// holds everything that touches git; the states it moves through are named in
// the Machine and nowhere else (ADR-0010). Nothing here decides anything from
// more than the branch name it is given.

// Why a Landing was refused. The first three are the spec's, and are judgements
// about the branch and the tree; `failed` is git itself not answering, kept in
// the same union so a refusal always has a reason rather than a state of its own.
export type RefusalReason = "dirty" | "notFastForward" | "unknownBranch" | "failed";

// A branch is only ever reached by its full ref, so a tag or a remote of the
// same name can never be what is checked and something else be what is merged.
function refFor(branch: string): string {
  return `refs/heads/${branch}`;
}

async function git(
  args: string[],
  cwd: string,
): Promise<{ success: boolean; out: string; err: string }> {
  const { success, stdout, stderr } = await new Deno.Command("git", {
    args,
    cwd,
    stdout: "piped",
    stderr: "piped",
  }).output();
  const decoder = new TextDecoder();
  return {
    success,
    out: decoder.decode(stdout).trim(),
    err: decoder.decode(stderr).trim(),
  };
}

// What the check asks of the world: the reason this branch may not be landed,
// or nothing at all if it may. The dirty tree is asked about first, which is
// the spec's order (§Landing); the branch has to be known to exist before it
// can be asked whether it is ahead, or a name nobody used would read as a
// divergence.
export async function refusalFor(
  liveTree: string,
  branch: string,
): Promise<RefusalReason | undefined> {
  // The developer's own uncommitted work is never merged over. A `git status`
  // that cannot be run says nothing about the tree, so it is not called dirty.
  const status = await git(["status", "--porcelain"], liveTree);
  if (!status.success) return "failed";
  if (status.out.length > 0) return "dirty";

  if (
    !(await git(["rev-parse", "--verify", "--quiet", `${refFor(branch)}^{commit}`], liveTree))
      .success
  ) {
    return "unknownBranch";
  }
  // A fast-forward is exactly HEAD being an ancestor of the branch; anything
  // else is the agent's to rebase (ADR-0003).
  if (!(await git(["merge-base", "--is-ancestor", "HEAD", refFor(branch)], liveTree)).success) {
    return "notFastForward";
  }
  return undefined;
}

export interface Landed {
  head: string;
}

// What git said, when a refusal has more to say than its reason.
export class LandingRefused extends Error {
  constructor(readonly reason: RefusalReason, message: string) {
    super(message);
    this.name = "LandingRefused";
  }
}

// The Landing itself: `git merge --ff-only`, and never anything that would
// write a merge commit (ADR-0003). It can still fail — the checks above race
// anyone else writing the Live tree — so the git message is carried out.
export async function landBranch(liveTree: string, branch: string): Promise<Landed> {
  const merge = await git(["merge", "--ff-only", refFor(branch)], liveTree);
  if (!merge.success) {
    throw new LandingRefused("failed", merge.err || `git merge --ff-only ${branch} failed`);
  }
  const head = await git(["rev-parse", "HEAD"], liveTree);
  if (!head.success) {
    throw new LandingRefused("failed", head.err || "git rev-parse HEAD failed");
  }
  return { head: head.out };
}
