// Landing: fast-forwarding the Live tree to a Worktree's branch. This module
// holds everything that touches git; the states it moves through are named in
// the Machine and nowhere else (ADR-0010). Nothing here decides anything from
// more than the branch name it is given.

// Why a Landing was refused. The Machine reports one of these and nothing else.
export type RefusalReason = "dirty" | "notFastForward" | "unknownBranch" | "failed";

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

// What `checking` asks of the world: the reason this branch may not be landed,
// or nothing at all if it may. The order is the spec's (§Landing).
export async function refusalFor(
  liveTree: string,
  branch: string,
): Promise<RefusalReason | undefined> {
  // A branch, specifically: `refs/heads/` means a tag or a raw sha is as
  // unknown as a name nobody ever used, and the reason says which it was
  // rather than leaving it to be read as a divergence.
  if (
    !(await git(["rev-parse", "--verify", "--quiet", `refs/heads/${branch}^{commit}`], liveTree))
      .success
  ) {
    return "unknownBranch";
  }
  // The developer's own uncommitted work is never merged over; a `git status`
  // that cannot be read is treated as the same refusal rather than a Landing.
  const status = await git(["status", "--porcelain"], liveTree);
  if (!status.success || status.out.length > 0) return "dirty";
  // A fast-forward is exactly HEAD being an ancestor of the branch; anything
  // else is the agent's to rebase (ADR-0003).
  if (!(await git(["merge-base", "--is-ancestor", "HEAD", branch], liveTree)).success) {
    return "notFastForward";
  }
  return undefined;
}

export interface Landed {
  head: string;
}

// The Landing itself: `git merge --ff-only`, and never anything that would
// write a merge commit (ADR-0003). It can still fail — the checks above race
// anyone else writing the Live tree — so the git message is carried out.
export class LandingRefused extends Error {
  constructor(readonly reason: RefusalReason, message: string) {
    super(message);
    this.name = "LandingRefused";
  }
}

export async function landBranch(liveTree: string, branch: string): Promise<Landed> {
  const merge = await git(["merge", "--ff-only", branch], liveTree);
  if (!merge.success) {
    throw new LandingRefused("failed", merge.err || `git merge --ff-only ${branch} failed`);
  }
  const head = await git(["rev-parse", "HEAD"], liveTree);
  if (!head.success) {
    throw new LandingRefused("failed", head.err || "git rev-parse HEAD failed");
  }
  return { head: head.out };
}
