/**
 * Landing one pending Worktree, and clearing up after it.
 *
 * ## Why the host performs this, and why that is not a hole in the fence
 *
 * ADR-0014 rests on the merge being the gate: a Core change becomes running code
 * only when a human merges it, and the reason the agent cannot is that
 * `git merge` writes `packages/core/**` in the live tree, which the kernel
 * refuses. A button in the window does not weaken that. **The host performs the
 * merge because a human clicked**, in a surface the agent cannot write
 * (ADR-0002), on a branch whose diff is on screen beside the control. What it
 * removes is the context switch, not the decision — and a gate a developer has
 * to leave the application to pass is a gate they will pass carelessly, in a
 * terminal, without the diff in front of them.
 *
 * Nothing here is reachable from the agent. It runs in the Harness runtime and
 * is asked for over the bridge by the renderer, as `merge-worktree`.
 *
 * ## Squash, always
 *
 * One commit on the live branch per Worktree. Never a merge commit and never the
 * branch's own history: a worktree's history is a working record — a first
 * attempt, the fix, the rebase, the message rewritten when a duplicate was
 * dropped — and that is worth having while the branch exists and worth nothing
 * afterwards. What the live tree should carry is what changed and why, once.
 *
 * **The squash has a consequence the cleanup has to know.** Afterwards the
 * branch is *not* an ancestor of the live tree — git has no record that the
 * content landed, because the commit is new — so the "did this really go in"
 * check cannot be `merge-base --is-ancestor`, which is the obvious one and which
 * answers *no* for every branch this ever merges. What is asked instead is
 * whether merging again would change anything — see `contentLanded` in
 * ./worktrees.ts, which also records why the *second* obvious answer,
 * `diff <live HEAD> <branch>`, is right for a fast-forward and wrong for every
 * clean merge. It lives one module over because the listing needs the same
 * answer to know a row is done.
 *
 * ## What decides whether the directory may be removed
 *
 * **Not the lock**, which is unreliable in both directions and was measured
 * being so. A lock naming a dead pid outlives the session that took it, because
 * the lock is held by the `claude` process while the *host* outlives it and
 * resumes — reaping on "the lock's pid is dead" killed a live agent. And a
 * worktree with no lock at all is not empty either: a session that ended in a
 * restart leaves none behind while its agent is still standing in the directory.
 *
 * What decides is **whether any process has the directory as its working
 * directory**, which is a fact about the machine rather than a file git happened
 * to leave behind. That is the {@link CwdProbe} port, and a directory somebody
 * is standing in is left alone: the branch is merged, the worktree stays, and
 * the answer says who is holding it. Removing it is not recoverable by the agent
 * — the SDK treats a missing cwd as a terminal error before the agent can report
 * it, ask about it, or step back to the clone root — so the failure mode this
 * avoids is the whole conversation ending with no error in the window.
 *
 * The lock is still *cleared*, but only after that question has been answered:
 * once nothing is standing in the directory, a lock left behind is litter rather
 * than a signal, and refusing to remove because of it would strand every
 * worktree whose session ended badly.
 *
 * ## Nothing here runs a process
 *
 * `git` and the probe arrive as ports, like ./worktrees.ts. This module decides
 * and sequences; ./runtime.ts owns the one implementation that spawns anything.
 */

import {
  contentLanded,
  findPendingWorktree,
  mergeabilityOf,
  shortBranch,
  type GitAttempt,
  type GitAttemptResult,
  type GitRunner,
  type Mergeability,
} from './worktrees.ts'

/** One process standing in a directory. */
export interface CwdHolder {
  readonly pid: number
  /** The executable's name, as the operating system reports it. */
  readonly command: string
}

/**
 * Which processes have a directory — or anything under it — as their cwd.
 *
 * A port for the same reason git is one: this module decides what to do about
 * the answer and never runs anything. An implementation that cannot tell must
 * **throw** rather than answer with an empty list. "Nobody is in there" is the
 * sentence that authorises deleting the directory, and it is the one sentence a
 * probe that did not run must never produce.
 */
export type CwdProbe = (path: string) => Promise<readonly CwdHolder[]>

export interface MergeWorktreeInput {
  readonly git: GitRunner
  readonly attempt: GitAttempt
  readonly holders: CwdProbe
  /** The clone this varnick is running from, and the tree being merged *into*. */
  readonly cloneRoot: string
  /**
   * Which pending Worktree, by the absolute path the listing reported.
   *
   * A **selector against git's own listing**, never an argument git is handed —
   * see `findPendingWorktree`. This is the call where getting that wrong stops
   * being a read of the wrong tree and becomes a write to one.
   */
  readonly path: string
}

/**
 * What happened, in enough detail for the window to say it and the agent to be
 * told it.
 *
 * A merge that landed and a cleanup that could not finish is a **success with
 * something left over**, not a failure: the commit is on the live branch either
 * way, and reporting it as a failure would invite a second merge of a branch
 * that has already gone in.
 */
export interface MergeReport {
  /** The branch that landed, or the commit it was on when it had no branch. */
  readonly branch: string
  /** The squash commit, abbreviated as git abbreviates it. */
  readonly commit: string
  /** How many of the branch's commits went into that one. */
  readonly squashed: number
  /** Whether the directory is gone. False when somebody is standing in it. */
  readonly worktreeRemoved: boolean
  /** Whether the branch ref is gone. Only ever true when the content was checked. */
  readonly branchDeleted: boolean
  /**
   * Who is standing in the worktree, when that is why it is still there.
   *
   * Empty when the directory was removed. Named rather than counted, because
   * "something is using it" is not something a developer can act on and
   * "`varnick` (pid 4242)" is.
   */
  readonly heldBy: readonly CwdHolder[]
  /**
   * What is left to do by hand, or `null` when nothing is.
   *
   * The window prints this verbatim. It exists because the interesting outcome
   * here is not success or failure but *success with a directory still on disk*,
   * and a report with no words for that would leave a row in the review band
   * saying something is pending when nothing is.
   */
  readonly leftOver: string | null
}

/**
 * Merge one Worktree into the live tree, then clear up after it.
 *
 * Ordered, and the order is the design. Every check that could refuse happens
 * before anything is written, and every step that writes is followed by the
 * check that decides whether the next one may run:
 *
 *  1. the live tree is clean — otherwise a merge over uncommitted work is how a
 *     developer loses something varnick never knew about;
 *  2. the path is one git itself listed as pending;
 *  3. it still merges — asked again here because the listing's answer is as old
 *     as the last Turn, and a branch that conflicts must not be squashed into a
 *     half-merged index;
 *  4. squash, and commit;
 *  5. the content actually landed;
 *  6. nobody is standing in the directory;
 *  7. remove it, and delete the branch.
 *
 * Rejects with a sentence for the developer. Everything up to step 4 rejects
 * having written nothing at all; step 4 rejects having put the tree back.
 */
export async function mergeWorktree(input: MergeWorktreeInput): Promise<MergeReport> {
  const { git, attempt, cloneRoot, path } = input

  await refuseDirtyLiveTree(git)

  const found = await findPendingWorktree({ git, cloneRoot, path })
  if (found === null) {
    throw new Error(
      `${path} is not a Worktree with unmerged commits, so there is nothing to merge from it.`,
    )
  }

  const { entry, ref } = found
  const branch = shortBranch(entry.branch) ?? ref
  refuseUnmergeable(branch, await mergeabilityOf(git, attempt, ref))

  // Read before the merge rather than after: the message is composed from the
  // branch's own commits, and `HEAD..<ref>` means something different once the
  // squash commit exists.
  const subjects = splitLines(await git(['log', '--format=%s', '--reverse', `HEAD..${ref}`]))

  const commit = await squashAndCommit({ git, attempt, ref, branch, subjects })

  /*
    Did it actually land? Nothing below this line deletes anything unless it did.
  */
  if (!(await contentLanded(git, attempt, ref))) {
    return {
      branch,
      commit,
      squashed: subjects.length,
      worktreeRemoved: false,
      branchDeleted: false,
      heldBy: [],
      leftOver: `${branch} was squashed onto ${commit}, but varnick could not confirm the branch's contents are now in the live tree, so nothing was deleted. Compare them before removing anything: git diff HEAD ${ref}`,
    }
  }

  return cleanUp({ ...input, entry, ref, branch, commit, squashed: subjects.length })
}

export interface ReapWorktreeInput {
  readonly git: GitRunner
  readonly attempt: GitAttempt
  readonly holders: CwdProbe
  /** The clone this varnick is running from — see {@link MergeWorktreeInput}. */
  readonly cloneRoot: string
  /** Which Worktree, by the absolute path the listing reported. A selector. */
  readonly path: string
}

/** What a reap did, or why it did nothing. */
export interface ReapReport {
  readonly path: string
  /** Short branch name, or the commit when the worktree had no branch. */
  readonly branch: string
  readonly worktreeRemoved: boolean
  readonly branchDeleted: boolean
  /** Who is standing in it, when that is why it is still there. Named, not counted. */
  readonly heldBy: readonly CwdHolder[]
  /** What is left to do by hand, or `null` when nothing is. Printed verbatim. */
  readonly leftOver: string | null
}

/**
 * Clear away a Worktree whose work is already in the live tree.
 *
 * The cleanup half of {@link mergeWorktree}, reachable on its own — because the
 * merge is asked from inside a Turn, and inside a Turn the agent host is alive
 * **by definition**. The cwd probe is therefore guaranteed to refuse a merge its
 * own cleanup, the host exits when the Turn ends, and until this existed nothing
 * ever asked again. The row stayed, the directory stayed, and the developer was
 * left with two commands to run by hand.
 *
 * Ordered like the merge, and for the same reason — every refusal happens before
 * anything is removed:
 *
 *  1. the path is one git itself listed as pending;
 *  2. **the content has actually landed** — asked here rather than trusted from
 *     the row, because the row is as old as the last listing;
 *  3. nobody is standing in the directory;
 *  4. remove it, and delete the branch.
 *
 * **Step 2 is the whole safety argument.** This ends in `worktree remove` and
 * `branch -D`, which is a force-delete; what makes the capital letter safe is
 * having proved the commits are not the only copy. A reap offered on a branch
 * still holding work is the one mistake here that costs somebody their work, so
 * it is proved rather than inherited from whatever the surface last drew.
 *
 * **Nothing is forced and nothing is killed.** Deleting a directory that is a
 * live process's working directory is permitted by the operating system and is
 * not survivable in the way it looks: the process keeps a vnode reference, so it
 * does not die and it does not notice — `process.cwd()` goes on naming a
 * directory that is gone while every relative file operation fails with an
 * ENOENT naming the *file*. Measured, not assumed. So a held directory is left
 * alone and its holders are named.
 */
export async function reapWorktree(input: ReapWorktreeInput): Promise<ReapReport> {
  const { git, attempt, holders, cloneRoot, path } = input

  const found = await findPendingWorktree({ git, cloneRoot, path })
  if (found === null) {
    throw new Error(
      `${path} is not a Worktree the review list is showing, so varnick will not remove it.`,
    )
  }

  const { entry, ref } = found
  const branch = shortBranch(entry.branch) ?? ref

  if (!(await contentLanded(git, attempt, ref))) {
    throw new Error(
      `${branch} still holds work the live tree does not have, so removing it would be the only copy going. Merge it first, or check what is in it: git diff HEAD ${ref}`,
    )
  }

  let standing: readonly CwdHolder[]
  try {
    standing = await holders(entry.path)
  } catch (error) {
    return {
      path: entry.path,
      branch,
      worktreeRemoved: false,
      branchDeleted: false,
      heldBy: [],
      leftOver: `varnick could not work out whether anything is still running in ${entry.path}, so it left the worktree alone rather than deleting a directory something may be standing in: ${reasonOf(error)}`,
    }
  }

  if (standing.length > 0) {
    return {
      path: entry.path,
      branch,
      worktreeRemoved: false,
      branchDeleted: false,
      heldBy: standing,
      /*
        The agent host is the usual answer, and it exits at the end of the Turn
        — so unlike the merge's version of this sentence, waiting is a real
        instruction here rather than a wait for a collection that never comes.
        Asking again is one press.
      */
      leftOver: `${describe(standing)} ${standing.length === 1 ? 'is' : 'are'} standing in ${entry.path}, so nothing was removed. The agent's host exits when its Turn ends — try again then, or stop ${standing.length === 1 ? 'it' : 'them'} yourself.`,
    }
  }

  const removed = await removeWorktree(attempt, entry.path)
  if (removed !== null) {
    return {
      path: entry.path,
      branch,
      worktreeRemoved: false,
      branchDeleted: false,
      heldBy: [],
      leftOver: `git would not remove the worktree at ${entry.path}: ${removed}`,
    }
  }

  // `-D` for the same reason the merge uses it: after a squash no branch this
  // ever removes is an ancestor, and the content check above is what makes the
  // capital letter a fact rather than a claim.
  const deleted = await attempt(['branch', '-D', branch])
  return {
    path: entry.path,
    branch,
    worktreeRemoved: true,
    branchDeleted: deleted.code === 0,
    heldBy: [],
    leftOver:
      deleted.code === 0
        ? null
        : `The worktree at ${entry.path} is gone, but the branch ref ${branch} is still there: ${said(deleted.stderr, deleted.stdout) ?? `branch -D exited ${deleted.code}`}`,
  }
}

/**
 * Refuse to merge onto a tree with uncommitted work in it.
 *
 * It is also what makes the recovery in {@link squashAndCommit} safe: a tree
 * with nothing in it has nothing to lose when it is reset.
 */
async function refuseDirtyLiveTree(git: GitRunner): Promise<void> {
  const dirty = await uncommittedPaths(git)
  if (dirty.length === 0) return

  const shown = dirty.slice(0, 5).map((line) => line.slice(3))
  const rest = dirty.length > shown.length ? `, and ${dirty.length - shown.length} more` : ''
  throw new Error(
    `The live tree has uncommitted work in ${shown.join(', ')}${rest}. A merge over it is how a change nobody knew about is lost, so varnick will not do one. Commit or set that work aside first.`,
  )
}

/**
 * What the agent is told when one of its branches lands.
 *
 * **The agent is told because it is the author.** It wrote the branch and it is
 * the only party in the conversation that does not otherwise find out — so it
 * goes on offering to preview a Worktree that no longer exists, and reasoning
 * about a fix it believes is running.
 *
 * Composed here rather than by the Rust host that delivers it, for the reason
 * `describeSecretsForAgent` is composed here: the host relays a sentence and
 * never writes one. It is also composed rather than assembled from the report
 * field by field on the agent's side, because two of the things it has to say
 * are *absences* — the worktree is gone, the branch is gone — and an absence is
 * not something a list of fields conveys.
 *
 * Five facts, and the last is the one that matters most: **a restart is still
 * owed.** Until it happens the running varnick is the build from before this
 * change, which is exactly the state an agent will otherwise reason itself out
 * of — it merged, therefore it is live.
 *
 * A report, not a command. Nothing here asks the agent to do anything.
 */
export function mergeBriefing(report: MergeReport): string {
  const lines = [
    `varnick merged ${report.branch} into the live tree.`,
    report.squashed === 1
      ? `Its commit is now ${report.commit} on the live branch.`
      : `Its ${report.squashed} commits were squashed into ${report.commit} on the live branch.`,
  ]

  if (report.worktreeRemoved && report.branchDeleted) {
    lines.push('The worktree and the branch are both gone, so neither can be previewed or entered.')
  } else if (report.worktreeRemoved) {
    lines.push('The worktree is gone. The branch ref is still there.')
  } else {
    lines.push(
      `The worktree is still on disk${report.heldBy.length > 0 ? ` because ${report.heldBy.map((holder) => `${holder.command} (pid ${holder.pid})`).join(', ')} ${report.heldBy.length === 1 ? 'has' : 'have'} it as a working directory` : ''}. Its contents have already landed, so nothing in it is unmerged work.`,
    )
  }

  if (report.leftOver !== null) lines.push(report.leftOver)
  return lines.join(' ')
}

/**
 * The clause that is true only until varnick restarts.
 *
 * ## Why it is not part of the Briefing
 *
 * **A Briefing outlives the process that composed it, and this sentence does
 * not.** The ordinary sequence is merge, then restart — the band says a restart
 * is owed and offers the button — and a restart kills the agent host before the
 * next Turn, which is the only thing that drains a Briefing. So a Briefing has
 * to survive to the session after the restart, and by the time it is read there,
 * *"varnick has not restarted"* is false.
 *
 * Split rather than rewritten at delivery. The alternative is the agent host
 * editing the sentence, and the agent host is the confined process — the whole
 * reason this text is composed here and relayed untouched is that a process
 * inside the Sandbox must not author a report about the tree it cannot write.
 * Two strings, both composed here, and the *host* picks which apply: it knows
 * whether it is the process that received them, which is a fact about itself
 * rather than a judgement about the merge.
 */
export const RESTART_STILL_OWED =
  'varnick has not restarted, so it is still running the code from before this change. Do not assume the change is live.'

/**
 * Whether the live tree has uncommitted work in it.
 *
 * The same question {@link mergeWorktree} refuses on, asked a second time and
 * much earlier: it rides along with the listing so the surface can say *why*
 * there is no merge control rather than offering one that fails.
 *
 * Two askers and one definition, which is the whole reason this is exported
 * rather than written twice. Neither is the other's excuse — this one is the
 * affordance and the one inside the merge is the rule, and the rule has to be
 * asked again because a tree can be dirtied between a listing and a click.
 */
export async function liveTreeIsDirty(git: GitRunner): Promise<boolean> {
  return (await uncommittedPaths(git)).length > 0
}

/**
 * `git status --porcelain`, as lines.
 *
 * Untracked files count, and that is not over-strict: a merge that would write
 * a path somebody has an unsaved new file at is exactly the collision this is
 * about.
 */
async function uncommittedPaths(git: GitRunner): Promise<string[]> {
  return splitLines(await git(['status', '--porcelain']))
}

/** A branch that will not go in is not a merge to attempt badly. */
function refuseUnmergeable(branch: string, merge: Mergeability): void {
  if (merge.kind === 'fast-forward' || merge.kind === 'clean') return

  if (merge.kind === 'conflicts') {
    throw new Error(
      `${branch} conflicts with the live tree in ${merge.files.join(', ')}. varnick does not resolve someone else's branch: ask the agent to merge main down into that worktree, where it may write and where it knows what it meant, and hand back a fast-forward.`,
    )
  }
  throw new Error(
    `git could not say whether ${branch} merges, so varnick will not merge it: ${merge.reason}`,
  )
}

/**
 * The squash and the commit, as one step that either happens or is undone.
 *
 * `merge --squash` stages the result and writes no commit, so a failure between
 * the two leaves a staged merge in a tree the developer never asked to change.
 * That is what the reset is for, and it is `--hard` because
 * {@link refuseDirtyLiveTree} has already established the tree had nothing in it
 * — a reset that can only lose a merge this function just made is not a reset
 * that can lose work.
 *
 * Untracked files are deliberately not cleaned. If the branch added one and the
 * commit then failed, leaving it costs a stray file and deleting it costs
 * whatever else happened to be untracked between the check and here.
 */
async function squashAndCommit(input: {
  git: GitRunner
  attempt: GitAttempt
  ref: string
  branch: string
  subjects: readonly string[]
}): Promise<string> {
  const { git, attempt, ref, branch, subjects } = input

  const merged = await attempt(['merge', '--squash', ref])
  if (merged.code !== 0) {
    await attempt(['reset', '--hard', 'HEAD'])
    throw new Error(
      `git would not squash ${branch} onto the live tree: ${said(merged.stderr, merged.stdout) ?? `merge --squash exited ${merged.code}`}`,
    )
  }

  const [subject, body] = commitMessage(branch, subjects)
  const committed = await attempt(['commit', '-m', subject, '-m', body])
  if (committed.code !== 0) {
    await attempt(['reset', '--hard', 'HEAD'])
    throw new Error(
      `${branch} squashed cleanly and the commit was refused, so the live tree was put back: ${said(committed.stderr, committed.stdout) ?? `commit exited ${committed.code}`}`,
    )
  }

  return (await git(['rev-parse', '--short', 'HEAD'])).trim()
}

/**
 * What the one commit says.
 *
 * A branch with a single commit keeps that commit's subject: squashing one
 * commit and renaming it to the branch would lose the sentence its author
 * wrote for no gain. A branch with several gets the branch name and the
 * subjects underneath, in the order they were written — which is the working
 * record compressed rather than discarded.
 *
 * The trailer names the branch in both cases, because the branch is about to be
 * deleted and this commit is the only place its name will survive.
 */
export function commitMessage(branch: string, subjects: readonly string[]): [string, string] {
  const trailer = `Squashed from ${branch}.`
  if (subjects.length === 1) return [subjects[0] as string, trailer]
  if (subjects.length === 0) return [`Merge ${branch}`, trailer]
  return [`Merge ${branch}`, `${subjects.map((line) => `* ${line}`).join('\n')}\n\n${trailer}`]
}

/**
 * Remove the directory and delete the branch, or say why neither happened.
 *
 * The probe comes first and it is the only thing that authorises the removal.
 * A probe that **throws** is a probe that did not run, and this leaves
 * everything alone rather than treating silence as permission.
 */
async function cleanUp(input: {
  git: GitRunner
  attempt: GitAttempt
  holders: CwdProbe
  entry: { readonly path: string }
  ref: string
  branch: string
  commit: string
  squashed: number
}): Promise<MergeReport> {
  const { attempt, holders, entry, branch, commit, squashed } = input
  const landed = { branch, commit, squashed }

  let standing: readonly CwdHolder[]
  try {
    standing = await holders(entry.path)
  } catch (error) {
    return {
      ...landed,
      worktreeRemoved: false,
      branchDeleted: false,
      heldBy: [],
      leftOver: `${branch} landed as ${commit}. varnick could not work out whether anything is still running in ${entry.path}, so it left the worktree alone rather than deleting a directory something may be standing in: ${reasonOf(error)}`,
    }
  }

  if (standing.length > 0) {
    return {
      ...landed,
      worktreeRemoved: false,
      branchDeleted: false,
      heldBy: standing,
      /*
        Named, not counted, and the Preview is why. A second varnick launched
        from this worktree is a window, a port and its own sandboxed agent, and
        the only way to stop it correctly is to signal the *app* process — a
        signal to the launcher kills the CLI and orphans all three, which is
        exactly the process tree ADR-0003 exists to prevent. So this says which
        processes and leaves the choice to the developer.
      */
      /*
        This used to end with the two commands to run by hand, because **nothing
        reaped.** An earlier wording before that ended "leave it and it will be
        reaped next time", which named a sweep that did not exist — and telling
        a developer to wait for a collection that never comes is worse than
        telling them nothing.

        {@link reapWorktree} is that collection, so the sentence points at it.
        The row does not clear itself: `commitsAhead` is ancestry and a squash
        is not an ancestor, so the listing goes on showing the worktree — but it
        shows it as *landed* now, offering a reap rather than a merge whose
        `git commit` would find nothing to commit.
      */
      leftOver: `${branch} landed as ${commit}. The worktree at ${entry.path} is still there because ${describe(standing)} ${standing.length === 1 ? 'is' : 'are'} standing in it — the agent's host exits when its Turn ends, so clear it away from the row then.`,
    }
  }

  const removed = await removeWorktree(attempt, entry.path)
  if (removed !== null) {
    return {
      ...landed,
      worktreeRemoved: false,
      branchDeleted: false,
      heldBy: [],
      leftOver: `${branch} landed as ${commit}, and git would not remove the worktree at ${entry.path}: ${removed}`,
    }
  }

  /*
    `-D`, not `-d`, and this is the squash's consequence again: `-d` refuses a
    branch that is not an ancestor, which after a squash is every branch this
    ever merges. The content check above is what makes the capital letter safe —
    without it this would be a force-delete on a claim nobody verified.
  */
  const deleted = await attempt(['branch', '-D', branch])
  return {
    ...landed,
    worktreeRemoved: true,
    branchDeleted: deleted.code === 0,
    heldBy: [],
    leftOver:
      deleted.code === 0
        ? null
        : `${branch} landed as ${commit} and its worktree is gone, but the branch ref is still there: ${said(deleted.stderr, deleted.stdout) ?? `branch -D exited ${deleted.code}`}`,
  }
}

/**
 * `git worktree remove`, clearing a stale lock if that is what stopped it.
 *
 * The unlock is *after* the cwd probe and only ever after it. A lock is a file
 * git left behind, and once nothing is standing in the directory it is litter
 * — refusing on it would strand every worktree whose session ended in a crash
 * or a restart. What must never happen is unlocking on the strength of the lock
 * itself, which is the check that killed a live agent.
 *
 * Returns `null` when the directory is gone, or what git said when it is not.
 */
async function removeWorktree(attempt: GitAttempt, path: string): Promise<string | null> {
  const first = await attempt(['worktree', 'remove', path])
  if (first.code === 0) return null

  const complaint = said(first.stderr, first.stdout) ?? `worktree remove exited ${first.code}`
  if (!complaint.includes('locked')) return complaint

  const unlocked = await attempt(['worktree', 'unlock', path])
  if (unlocked.code !== 0) return complaint

  const second = await attempt(['worktree', 'remove', path])
  if (second.code === 0) return null
  return said(second.stderr, second.stdout) ?? `worktree remove exited ${second.code}`
}

/** "claude (pid 82876)", or a list of them. */
function describe(holders: readonly CwdHolder[]): string {
  return holders.map((holder) => `${holder.command} (pid ${holder.pid})`).join(', ')
}

function said(stderr: string, stdout: string): string | null {
  const trimmed = stderr.trim() || stdout.trim()
  return trimmed.length > 0 ? trimmed : null
}

function reasonOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function splitLines(output: string): string[] {
  return output.split('\n').filter((line) => line.trim().length > 0)
}
