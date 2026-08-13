/**
 * The gate on the agent's landing, and the whole of what decides it.
 *
 * The agent asks for a Worktree to be landed (./unattended.ts); this is what the
 * host does about it. It is the second caller of `unattendedLanding` — the first
 * is `bun run landable`, which prints an answer for a person — and it is the one
 * that actually merges, so everything the CLI learned the hard way is asserted
 * here again rather than assumed to carry over.
 *
 * ## Why this exists rather than a shorter `denyWrite`
 *
 * The obvious way to let an agent land its own work is to stop denying it the
 * paths a merge writes. That gives away ADR-0014's entire mechanism: `denyWrite`
 * is what stops the agent writing Core *in the live tree at all*, on no branch,
 * in no diff, reviewed by nobody. So `denyWrite` is untouched and this is a
 * second, narrower door — the host performs the write, on the agent's request,
 * gated here. See docs/adr/0023-a-second-door-rather-than-a-wider-one.md, which
 * argues that once for this and for the release beside it.
 *
 * ## What the agent's request contributes, and what it cannot
 *
 * One name, resolved against `git worktree list` by the Rust host before this is
 * called, and compared again here against git's own listing by
 * `findPendingWorktree`. Everything else this decides on comes from git:
 *
 *   * **the changed paths**, from `git diff` against the merge base — never from
 *     the request, which has no field for them;
 *   * **the manifest's lifecycle scripts**, read out of both revisions with
 *     `git show`;
 *   * **whether the live tree is clean**, and **whether the branch merges**.
 *
 * That is the property to keep: there is nothing an agent can say that changes
 * what the predicate is asked about. A tool that took a path list would be a
 * tool that lands `src-tauri/**` by omitting it.
 *
 * ## Nothing here runs a process
 *
 * `git` and the cwd probe arrive as ports, like ./merge.ts and ./worktrees.ts.
 * ./runtime.ts owns the one implementation that spawns anything, which is what
 * lets every refusal below be proved with no repository at all.
 */

import { landingVerdict } from './landing-verdict.ts'
import {
  liveTreeIsDirty,
  mergeBriefing,
  mergeWorktree,
  RESTART_STILL_OWED,
  type CwdProbe,
} from './merge.ts'
import type { LandingAnswer } from './unattended.ts'
import {
  findPendingWorktree,
  mergeabilityOf,
  shortBranch,
  type GitAttempt,
  type GitRunner,
} from './worktrees.ts'

export interface LandWorktreeInput {
  readonly git: GitRunner
  readonly attempt: GitAttempt
  readonly holders: CwdProbe
  /** The clone this varnick is running from, and the tree being merged *into*. */
  readonly cloneRoot: string
  /**
   * Which Worktree, by the absolute path git listed it at.
   *
   * A **selector against git's own listing**, exactly as ./merge.ts's is. The
   * Rust host produced it by looking the agent's name up in a table git built —
   * see `resolve_worktree` in src-tauri/src/preview.rs — and it is looked up a
   * second time here, because the two processes are asking git at two different
   * moments and this is the one where the answer becomes a write.
   */
  readonly path: string
}

/**
 * Land one Worktree, if the protected-path predicate says it may.
 *
 * Ordered, and the order is the design — every question that can refuse is asked
 * before anything is written, and the cheapest and most specific ones first:
 *
 *  1. the path is one git itself listed as pending, with commits on it;
 *  2. the live tree is clean, because a merge over uncommitted work is how a
 *     developer loses something varnick never knew about;
 *  3. the branch merges — asked here so a refusal is a sentence rather than a
 *     half-merged index;
 *  4. **what the branch changed, out of git**, and what the root manifest's
 *     install lifecycle scripts were on both sides of it;
 *  5. `unattendedLanding`, which is the gate this whole module exists to put in
 *     front of step 6;
 *  6. the merge, which is ./merge.ts's and is the same one a human's click
 *     performs.
 *
 * **Answers rather than throws.** Every outcome here is something to tell the
 * agent, and a rejected promise would reach it as a failed tool call — which is
 * the shape that says *try again*. A protected branch is finished work waiting
 * for a person, and it must not read as an error the agent should route around.
 */
export async function landWorktree(input: LandWorktreeInput): Promise<LandingAnswer> {
  const { git, attempt, cloneRoot, path } = input

  try {
    const found = await findPendingWorktree({ git, cloneRoot, path })
    if (found === null) return { outcome: 'unknown-worktree', detail: null }

    const { entry, ref } = found
    const branch = shortBranch(entry.branch) ?? ref

    /*
      Before the mergeability probe rather than after it, because a dirty tree is
      the one refusal here that is about the *developer's* tree rather than the
      agent's branch, and it is true of every branch at once. Told apart in the
      answer for the same reason: an agent that read "dirty live tree" as
      "unmergeable" would merge main down into a worktree to fix something that
      is not on its side of the fence.
    */
    if (await liveTreeIsDirty(git)) return { outcome: 'dirty-live-tree', detail: null }

    /*
      **The commit, resolved once, and everything below is about that commit.**

      A ref name is a moving answer. The agent may write its own Worktree freely
      and can run git in it from a background `Bash`, so a commit added between
      the check and the merge would merge paths the predicate never saw — a
      time-of-check-to-time-of-use gap in the one function whose whole job is
      that the check binds the use.

      Resolving here is half of the binding. The other half is at the merge,
      which refuses if the ref has moved off this commit since — see
      `expectedCommit` in ./merge.ts. Both halves are needed and neither is
      redundant: this one is what makes the *verdict* be about a fixed tree, and
      that one is what makes the *merge* be about the same tree.
    */
    const commit = (await git(['rev-parse', ref])).trim()

    const merge = await mergeabilityOf(git, attempt, commit)
    if (merge.kind === 'conflicts') {
      return {
        outcome: 'unmergeable',
        detail: `${branch} conflicts with the live tree in ${merge.files.join(', ')}.`,
      }
    }
    if (merge.kind === 'unknown') {
      return {
        outcome: 'unmergeable',
        detail: `git could not say whether ${branch} merges: ${merge.reason}`,
      }
    }

    /*
      The gate. Every path it decides on comes out of git — see ./landing-verdict.ts,
      which is shared with `bun run landable` so the answer before a night starts
      and the answer at the merge cannot differ.
    */
    const verdict = await landingVerdict({ git, base: 'HEAD', commit })
    if (!verdict.mayLand) return { outcome: 'refused', detail: verdict.reason }

    /*
      Asked again, immediately before the write, and this is not the binding —
      ./merge.ts's `expectedCommit` is. This exists so the *common* case has a
      sentence the agent can act on: a branch that grew a commit while it was
      being checked is not a broken machine, it is a race with the agent's own
      background work, and the answer is to ask again rather than to stop.
    */
    const nowAt = (await git(['rev-parse', ref])).trim()
    if (nowAt !== commit) {
      return {
        outcome: 'branch-moved',
        detail: `${branch} was at ${commit.slice(0, 7)} when it was checked and is at ${nowAt.slice(0, 7)} now, so nothing was merged.`,
      }
    }

    /*
      The same merge a human's click performs, with the same ports. Nothing about
      it is relaxed because an agent asked: it re-reads the live tree's
      cleanliness and the branch's mergeability, it refuses to delete a directory
      anything is standing in, and it proves the content landed before it deletes
      anything at all.

      `expectedCommit` is the one thing added, and it is what makes the merge
      merge the tree the predicate judged.
    */
    const report = await mergeWorktree({ ...input, expectedCommit: commit })
    return {
      outcome: 'landed',
      // Both sentences are ./merge.ts's, and both are true of the agent that
      // asked: it is the author of the branch, and it is running inside the
      // varnick that has not restarted. There is no `report-merge` for this one
      // — the agent is holding the answer to its own question, and telling it
      // again on the next Turn would be varnick announcing a merge the agent
      // asked for as though somebody else had done it.
      detail: `${mergeBriefing(report)} ${RESTART_STILL_OWED}`,
    }
  } catch (error) {
    /*
      Everything above either answers or throws, and a throw here means a
      question could not be put: git would not run, the listing could not be
      read, the merge itself refused. None of those is a decision about the
      branch, so none of them may read as one — `no-landing` is the tag an
      orchestrator is told not to retry, and it is deliberately not `refused`.

      The message is forwarded because every one of them was composed in this
      package or by git, about a repository. Nothing on this path holds a
      credential.
    */
    return { outcome: 'no-landing', detail: reasonOf(error) }
  }
}

function reasonOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
