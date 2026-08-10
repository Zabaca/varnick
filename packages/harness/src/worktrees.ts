/**
 * Which Worktrees hold Core changes nobody has merged, and what changed in each.
 *
 * ## Why git, and not the agent
 *
 * This is the mechanism that shows what the agent changed. A report the agent
 * composes is a report the agent can shade — and it would not have to lie
 * outright: a worktree left out of a list nobody cross-checks is invisible in
 * exactly the way a widening wants to be. Taking it from git costs three
 * read-only commands, so there is no version of this where asking the agent is
 * the cheaper option.
 *
 * The agent cannot reach this code either. It runs in the Harness runtime — the
 * host-side Node process — and arrives in Core over the bridge as
 * `list-worktrees`, which the renderer asks for and nothing else can.
 *
 * ## The summary, then the hunks
 *
 * An entry is a branch, a path, how far ahead it is, which paths it changed and
 * whether any of them is Fence. The hunks are not in it, and that is a decision
 * rather than an omission: a list that read every diff of every branch to draw
 * a row would spend the whole of a large branch before showing anything, and the
 * list is what a developer reads to decide which branch to open.
 * {@link readPendingWorktreeDiff} reads the contents of the one they opened.
 *
 * Path names are cheap and are what makes the Fence flag auditable — a row
 * claiming Fence with no path that is one is a row nobody can check.
 *
 * ## What a caller may decide, and what it may not
 *
 * The listing takes nothing. The diff takes one path, and that path is a
 * **selector against git's own listing** rather than an argument git is handed:
 * it is compared with what `git worktree list` reported, and the ref that
 * reaches argv is the one git printed for the entry it matched. A path matching
 * no entry produces no diff command at all. That is what keeps a name composed
 * anywhere else from choosing what a host-side git reads — the same shape
 * ADR-0014 gives `launch_preview`, which validates a worktree name against what
 * git reports rather than taking a command.
 *
 * ## Nothing here runs a process
 *
 * `git` arrives as a port. This module parses and decides; ./runtime.ts owns the
 * one implementation that actually spawns anything, and every test supplies its
 * own. That is what keeps the assertions about *which questions are asked* —
 * `worktree`, `rev-list`, `diff` and `merge-tree`, and no other subcommand.
 *
 * Four of those five invocations read and nothing more. The fifth is
 * `merge-tree --write-tree`, which writes: it puts the tree it computed into the
 * object store, as a loose object nothing references. That is worth naming
 * rather than glossing, because the claim above it used to be "none of which
 * writes". What it does *not* touch is the part that would matter — no ref
 * moves, no index is taken, no file in any working tree changes — so the merge
 * this asks about still has not happened, which is the whole property the
 * question depends on. The objects it leaves behind are ordinary garbage and go
 * the way every unreferenced object goes.
 */

import { touchesFence } from './fence.ts'
// The same rule the provisioner uses to decide whether a directory is a
// Worktree at all. One definition, because a list that reviewed trees the
// provisioner would not provision would be two different meanings of the word.
import { isWorktreeOf } from './provision.ts'

/**
 * Whether a branch will land, and what stands in the way when it will not.
 *
 * **A fact carried on the entry, not a state of anything.** It is decided by
 * asking git the same way the count and the changed paths are, at the moment the
 * listing is made, and it goes stale the instant either side moves — which is
 * why the listing refreshes at the end of every Turn rather than why this is
 * modelled as something with a lifetime.
 *
 * Three of these four are the answers the ticket asked for, and they are
 * distinguished because they mean different things to whoever is reading:
 *
 *   * `fast-forward` — the branch already contains the live tree, so merging
 *     decides nothing. This is the shape `.claude/skills/change-core/SKILL.md`
 *     tells the agent to hand over, and the one a developer can take without
 *     thinking about it.
 *   * `clean` — no conflict, but the live tree has moved since the branch left
 *     it. It will merge; a commit will be composed that exists on neither side.
 *   * `conflicts` — with the file names, which are the part that makes it
 *     actionable. Nothing offers to merge one of these, and nothing here
 *     resolves it: the agent merges `main` *down* into its worktree, where it
 *     may write and where it has the context.
 *
 * The fourth is `unknown`, which the ticket did not ask for and which is here
 * for the reason every other "cannot tell" in this codebase is a state of its
 * own. `merge-tree` answers *conflict* with exit 1 and *broken* with something
 * else — a corrupt object, a ref that vanished between two commands — and the
 * two must not collapse. Reporting a probe that failed as `clean` invites a
 * merge nobody checked; reporting it as `conflicts` names no files and tells the
 * agent to fix something that may not be wrong. So it says nobody could tell,
 * carries git's reason, and offers no merge — and it is deliberately not a
 * failure of the whole listing, because one unreadable branch must not take the
 * other rows off the screen.
 */
export type Mergeability =
  | { readonly kind: 'fast-forward' }
  | { readonly kind: 'clean' }
  | { readonly kind: 'conflicts'; readonly files: readonly string[] }
  | { readonly kind: 'unknown'; readonly reason: string }

/**
 * One worktree with unmerged commits in it.
 *
 * Serialisable and nothing more: this crosses the bridge into the webview, so
 * every field is a string, a number, a boolean, an array of strings, or the
 * tagged object above — which is the same rule one level down.
 */
export interface PendingWorktree {
  /** Absolute, as git reports it. */
  readonly path: string
  /** Short branch name, or `null` for a detached HEAD. */
  readonly branch: string | null
  /**
   * Commits this worktree has that the live tree does not.
   *
   * Always at least one. A worktree at zero is not pending — it is an agent
   * that has started rather than one that has finished — and it is left out of
   * the list rather than shown with a zero on it.
   */
  readonly commits: number
  /** Repository-relative paths changed since the branch diverged. Names only. */
  readonly changed: readonly string[]
  /** Whether any changed path is Fence — see ./fence.ts. */
  readonly touchesFence: boolean
  /** Whether it will land, and what stands in the way — see {@link Mergeability}. */
  readonly merge: Mergeability
  /**
   * Whether this work is **already in the live tree** — see {@link contentLanded}.
   *
   * A row that is landed is not waiting to be merged; it is a directory waiting
   * to be cleared away, and merging it again would squash a branch with nothing
   * left in it. It stays on the list rather than being filtered out of it,
   * because dropping the row would leave a full checkout on disk that nothing in
   * the product ever mentions again.
   *
   * `commits` is still whatever ancestry says, and for a landed Worktree that
   * number is a fact about git's graph rather than about work outstanding. The
   * surface says *landed*; it does not say *six commits*.
   */
  readonly landed: boolean
}

/**
 * A git invocation, run host-side.
 *
 * Resolves with stdout, rejects with why. A rejection is what reaches
 * `review.listFailed`: a listing that could not be made is a different problem
 * from a listing that found nothing, and this port must never turn the first
 * into the second by answering with an empty string.
 */
export type GitRunner = (args: readonly string[]) => Promise<string>

/** What a git invocation did, when the exit code is part of the answer. */
export interface GitAttemptResult {
  readonly code: number
  readonly stdout: string
  readonly stderr: string
}

/**
 * A git invocation whose **exit code is an answer rather than a failure**.
 *
 * A second port beside {@link GitRunner} rather than an option on it, because
 * the two ask genuinely different questions. Every command the runner makes has
 * one correct outcome and any other is a git that would not answer, so
 * rejecting is right. `merge-tree` is the one command here whose non-zero exit
 * *is* the thing being asked: 0 means the branches merge, 1 means they conflict,
 * and a runner that rejected on 1 would turn the interesting answer into an
 * error and lose the file names with it.
 *
 * Resolving with a non-zero code is therefore not a swallowed failure. What
 * distinguishes "conflict" from "broken" is which non-zero code it is, and that
 * distinction is made by the caller — see {@link Mergeability}'s `unknown`.
 */
export type GitAttempt = (args: readonly string[]) => Promise<GitAttemptResult>

/** One block of `git worktree list --porcelain`, before anything is decided. */
export interface WorktreeEntry {
  readonly path: string
  readonly head: string | null
  /** The full ref, `refs/heads/…`, or `null` when HEAD is detached. */
  readonly branch: string | null
  readonly bare: boolean
}

/**
 * Read `git worktree list --porcelain`.
 *
 * Blocks separated by a blank line, `key value` per line, with `bare` and
 * `detached` carrying no value. The value is the rest of the line rather than
 * the next token, because a path may contain spaces.
 */
export function parseWorktreeList(porcelain: string): WorktreeEntry[] {
  const entries: WorktreeEntry[] = []

  for (const block of porcelain.split('\n\n')) {
    let path: string | null = null
    let head: string | null = null
    let branch: string | null = null
    let bare = false

    for (const line of block.split('\n')) {
      const separator = line.indexOf(' ')
      const key = separator === -1 ? line : line.slice(0, separator)
      const value = separator === -1 ? '' : line.slice(separator + 1)
      if (key === 'worktree') path = value
      else if (key === 'HEAD') head = value
      else if (key === 'branch') branch = value
      else if (key === 'bare') bare = true
    }

    if (path !== null) entries.push({ path, head, branch, bare })
  }

  return entries
}

export interface ListPendingInput {
  readonly git: GitRunner
  /**
   * The same git, for the one question whose exit code is the answer.
   *
   * Required rather than optional, and that is deliberate: an optional probe is
   * a listing that quietly stops saying whether anything merges the moment a
   * caller forgets to pass one, and every row would then read `unknown` with
   * nothing wrong. A caller that has a `git` has this one too — ./runtime.ts
   * builds both out of the same `execFile`.
   */
  readonly attempt: GitAttempt
  /** The clone this varnick is running from — see the exclusions below. */
  readonly cloneRoot: string
}

/**
 * Every worktree holding commits the live tree does not have.
 *
 * Two are always excluded, for two different reasons. The **first** entry is
 * git's main worktree, which is the tree everything else is measured against —
 * `HEAD` in the commands below is its HEAD. The **clone root** is this
 * varnick's own tree, which matters when varnick is itself a Preview running
 * from a worktree: without it, a Preview would list the worktree it is running
 * in as work waiting to be merged.
 *
 * Location is deliberately not a filter. CONTEXT.md defines a Worktree as one
 * under `.claude/worktrees/`, and that is where the agent's go — but a
 * developer's own worktree elsewhere holding Core commits is exactly as
 * unmerged, and a review surface that hides work because of where it sits is a
 * review surface with a blind spot in it.
 */
export async function listPendingWorktrees(input: ListPendingInput): Promise<PendingWorktree[]> {
  const entries = parseWorktreeList(await input.git(['worktree', 'list', '--porcelain']))
  const pending: PendingWorktree[] = []

  for (const { entry, ref } of reviewable(entries, input.cloneRoot)) {
    const commits = await commitsAhead(input.git, ref)
    if (commits === null) continue

    const changed = splitNulTerminated(
      // Three dots: everything on the branch since it diverged, rather than
      // every difference between two trees. A worktree branched a week ago is
      // not responsible for what the live tree did in the meantime.
      await input.git(['diff', '--name-only', '-z', `HEAD...${ref}`]),
    )

    const merge = await mergeabilityOf(input.git, input.attempt, ref)

    pending.push({
      path: entry.path,
      branch: shortBranch(entry.branch),
      commits,
      changed,
      touchesFence: touchesFence(changed),
      merge,
      /*
        **A fast-forward is never landed, and asking would cost a merge a row.**
        Fast-forward means `rev-list --count <ref>..HEAD` is zero — the live tree
        holds nothing the branch does not — while `commits` says the branch
        holds something the live tree does not. So the two trees differ and the
        answer is free.

        That is not a micro-optimisation, it is the common case: an agent
        branches from the live tree, the live tree does not move, and every row
        in the band is a fast-forward until something lands. `mergeabilityOf`
        already refuses to compute a merge for these, and a listing that probed
        anyway would pay for one merge per row per Turn to learn what a count
        already said.

        And it costs nothing where it matters. A Worktree that has *been*
        merged is by construction not a fast-forward — the squash commit is on
        the live tree and not on the branch, so `behind` is at least one — which
        is exactly the row this field exists to identify.

        What it gives up is a branch whose commits net out to no change at all:
        ancestry says ahead, content says landed, and this reports it as
        mergeable. Merging one is a fast-forward that changes nothing, so the
        surface is wrong about a row that is harmless either way.
      */
      landed:
        merge.kind === 'fast-forward'
          ? false
          : await contentLanded(input.git, input.attempt, ref),
    })
  }

  return pending
}

export interface ReadDiffInput {
  readonly git: GitRunner
  /** The clone this varnick is running from — see {@link listPendingWorktrees}. */
  readonly cloneRoot: string
  /**
   * Which pending worktree, by the absolute path the listing reported.
   *
   * The only field on the review path a caller decides, and it decides *which
   * of git's own entries* rather than what git is asked. It is compared, never
   * passed: see the module header.
   */
  readonly path: string
}

/**
 * Everything one pending Worktree changed, as a unified diff.
 *
 * The contents behind one row of the list, read when a developer opens it. Git
 * produces it — this is the mechanism that shows what the agent changed, and a
 * diff the agent composed is a diff the agent can shade, which is a sharper
 * problem here than in the list: a shaded row is a branch nobody looked at, and
 * a shaded hunk is a widening somebody approved.
 *
 * **Refuses anything that is not a Worktree with unmerged commits**, by the same
 * three rules the list applies — not the main worktree, not the tree varnick is
 * running from, not a branch that is level with HEAD. The refusal is what keeps
 * the one argument on this path from being able to name a tree.
 *
 * Rejects with git's own reason, which reaches `worktreeDiff.failed`. An empty
 * diff is an empty string and not a rejection: a commit that changed nothing
 * tracked is a real answer, and a surface that turned it into a failure would
 * report a git that answered as a git that would not.
 */
export async function readPendingWorktreeDiff(input: ReadDiffInput): Promise<string> {
  const entries = parseWorktreeList(await input.git(['worktree', 'list', '--porcelain']))
  const wanted = withoutTrailingSlash(input.path)

  for (const { entry, ref } of reviewable(entries, input.cloneRoot)) {
    if (withoutTrailingSlash(entry.path) !== wanted) continue
    if ((await commitsAhead(input.git, ref)) === null) break

    // `--no-color`, because a developer's own `color.ui = always` would
    // otherwise put terminal escapes through the bridge and into a renderer
    // that draws its own — and the one colour in that view means Fence.
    return input.git(['diff', '--no-color', `HEAD...${ref}`])
  }

  throw new Error(
    `${input.path} is not a worktree with unmerged commits, so there is nothing to review in it.`,
  )
}

/** One worktree the review path will consider, with the ref git named for it. */
export interface Reviewable {
  readonly entry: WorktreeEntry
  readonly ref: string
}

/**
 * The one pending Worktree at this path, or `null`.
 *
 * The **selector rule**, written once and used by everything that takes a path
 * from outside: the listing, the diff, and ./merge.ts. A caller says which of
 * git's own entries it means; it does not say what git is asked. Nothing a
 * caller supplied ever reaches argv — the ref returned here is the one git
 * printed for the entry that matched.
 *
 * Extracted when the merge arrived, because the merge is the call where getting
 * this wrong stops being a read of the wrong tree and becomes a write to one.
 * A third copy of the comparison would have been three chances to disagree
 * about a trailing slash.
 */
export async function findPendingWorktree(input: {
  readonly git: GitRunner
  readonly cloneRoot: string
  readonly path: string
}): Promise<Reviewable | null> {
  const entries = parseWorktreeList(await input.git(['worktree', 'list', '--porcelain']))
  const wanted = withoutTrailingSlash(input.path)

  for (const found of reviewable(entries, input.cloneRoot)) {
    if (withoutTrailingSlash(found.entry.path) !== wanted) continue
    return (await commitsAhead(input.git, found.ref)) === null ? null : found
  }
  return null
}


/**
 * The worktrees a review is about, before anything has asked how far ahead they
 * are.
 *
 * Written once and read by both callers, because the two must agree about what
 * is reviewable: a diff view that could open a tree the list refuses to show
 * would be a way to read something the surface declined to mention, and a list
 * showing a row that could not be opened is a row that does nothing.
 *
 * The `ref` is git's own — the branch when there is one, the commit when there
 * is not — so nothing a caller supplied ever becomes an argument.
 */
function reviewable(entries: readonly WorktreeEntry[], cloneRoot: string): Reviewable[] {
  const root = withoutTrailingSlash(cloneRoot)
  const found: Reviewable[] = []

  for (const [index, entry] of entries.entries()) {
    if (index === 0 || entry.bare) continue
    if (withoutTrailingSlash(entry.path) === root) continue
    /*
      **A Worktree, not merely a worktree.** `CONTEXT.md` defines the term as one
      under `.claude/worktrees/`, and that is what this surface is about: trees
      the agent made, holding work the agent authored, which a human reviews and
      lands.

      A developer's own linked worktree — a spike, a long-lived release branch,
      anything they made themselves with `git worktree add` somewhere else — is
      not that, and it used to cost nothing to include one: this list was
      read-only, so the worst case was a row nobody wanted. It stopped being
      free when a merge control appeared beside every row. Squashing somebody's
      branch, removing their directory and `branch -D`-ing their ref is not a
      surprising row, it is losing their work — and the button would sit under a
      panel headed with a term that says it will not.
    */
    if (!isWorktreeOf(cloneRoot, entry.path)) continue
    const ref = entry.branch ?? entry.head
    if (ref === null) continue
    found.push({ entry, ref })
  }

  return found
}

/**
 * How far ahead of the live tree a ref is, or `null` for "not pending".
 *
 * A count that did not parse is not a zero. Both answers leave the worktree
 * out rather than showing it, because a row saying `NaN commits` is worse than
 * a row nobody drew — and a worktree at zero is an agent that has started
 * rather than one that has finished.
 */
async function commitsAhead(git: GitRunner, ref: string): Promise<number | null> {
  const commits = Number.parseInt(await git(['rev-list', '--count', `HEAD..${ref}`]), 10)
  return Number.isFinite(commits) && commits > 0 ? commits : null
}

/**
 * Whether the branch's contents are already in the live tree.
 *
 * ## Two checks that look right and are not
 *
 * **`merge-base --is-ancestor`** answers *no* for every branch varnick merges: a
 * squash commit is new, so git has no record that the content landed. That one
 * is obvious once stated, and it is nevertheless what {@link commitsAhead} asks
 * — which is why a landed Worktree used to sit on the review list forever.
 *
 * **`diff <live HEAD> <branch>`** is the one that had to be measured, because it
 * is right for exactly the case anybody tries by hand and wrong for the case
 * that ships. A `fast-forward` branch already contains everything the live tree
 * has, so after the squash the two trees are identical and the diff is empty. A
 * `clean` branch is *by definition* one the live tree holds commits ahead of —
 * that is what {@link mergeabilityOf} measures — so afterwards HEAD carries both
 * sides and the branch carries only its own, and the diff is **never** empty.
 * Every clean merge would report itself as not having landed, and nothing would
 * ever be cleaned up.
 *
 * Measured both ways in a scratch repository rather than reasoned about, because
 * the previous answer here was a correct observation of a fast-forward promoted
 * to a rule:
 *
 *     main ahead by one, feature behind it, squash, then:
 *       git diff --quiet HEAD feature      exit 1   ("still differ")
 *       merge-tree --write-tree HEAD feature == HEAD^{tree}   (landed)
 *     and with the squash's own file dropped before committing:
 *       merge-tree --write-tree HEAD feature != HEAD^{tree}   (correctly refuses)
 *
 * ## What is asked instead
 *
 * *Would merging this branch again change anything?* `merge-tree --write-tree`
 * answers it: the tree a merge would produce, without touching the index or the
 * working tree. Equal to HEAD's tree means the branch has nothing left to give,
 * which is the question both the cleanup and the listing actually depend on, and
 * is true regardless of how far the live tree has moved on its own side.
 *
 * The same command {@link mergeabilityOf} already trusts, read the other way
 * round — it asks whether a merge *would* conflict, this asks whether one would
 * be a no-op.
 *
 * **False on anything unclear.** A conflict (exit 1), a git that would not run
 * it, an unparseable answer: all of them mean the caller does not proceed. This
 * gates a `worktree remove` and a `branch -D`, so the only safe direction to be
 * wrong in is "leave it alone".
 *
 * Lives here rather than beside the merge that first needed it because the
 * listing needs the same answer, and ./merge.ts already imports this module —
 * the other direction would be a cycle.
 */
export async function contentLanded(
  git: GitRunner,
  attempt: GitAttempt,
  ref: string,
): Promise<boolean> {
  let merged: GitAttemptResult
  try {
    merged = await attempt(['merge-tree', '--write-tree', 'HEAD', ref])
  } catch {
    return false
  }
  // Exit 1 is a conflict, which here means the branch still holds something the
  // live tree does not. Anything else non-zero is a probe that did not run.
  if (merged.code !== 0) return false

  const produced = merged.stdout.trim().split('\n')[0]?.trim() ?? ''
  if (produced.length === 0) return false

  let head: string
  try {
    head = (await git(['rev-parse', 'HEAD^{tree}'])).trim()
  } catch {
    return false
  }
  return head.length > 0 && produced === head
}

/**
 * Whether merging this ref into the live tree would go cleanly.
 *
 * Two questions, and the first one is free. **Fast-forward is asked first**
 * because it is the common case here and because it settles the second question
 * without asking it: a branch that already contains the live tree cannot
 * conflict with it, so there is nothing for `merge-tree` to compute. It is
 * `rev-list --count <ref>..HEAD`, which is "commits the live tree has that the
 * branch does not" — zero means the branch is a superset, which is exactly what
 * makes the merge a ref moving.
 *
 * Only when the two have genuinely diverged is the merge computed, and it is
 * computed rather than performed: `merge-tree` produces the result in the object
 * store and touches no ref, no index and no working tree. See the module header
 * for what that does write.
 *
 * `--name-only` is what makes the conflicted section parseable without knowing
 * git's `ls-files -u` format, and `--no-messages` is not passed because the
 * informational block is what the blank line separates the file names *from* —
 * see {@link conflictedFiles}.
 *
 * **A count that would not parse is not a zero here**, the way it is in
 * {@link commitsAhead}, and the difference is which way the mistake falls. There
 * a bad count leaves a worktree off a list; here it would claim a merge decides
 * nothing. So an unreadable count falls through to the probe, which answers the
 * question properly or says it could not.
 */
export async function mergeabilityOf(
  git: GitRunner,
  attempt: GitAttempt,
  ref: string,
): Promise<Mergeability> {
  let behind: number
  try {
    behind = Number.parseInt(await git(['rev-list', '--count', `${ref}..HEAD`]), 10)
  } catch (error) {
    return { kind: 'unknown', reason: reasonOf(error) }
  }
  if (behind === 0) return { kind: 'fast-forward' }

  let probe: GitAttemptResult
  try {
    probe = await attempt(['merge-tree', '--write-tree', '--name-only', 'HEAD', ref])
  } catch (error) {
    return { kind: 'unknown', reason: reasonOf(error) }
  }

  if (probe.code === 0) return { kind: 'clean' }
  /*
    Exit 1 is git saying the merge conflicts, and it is the only non-zero code
    that means anything but trouble. Anything else — 128 for a bad object, 129
    for a `merge-tree` that does not take these flags, a signal — is a probe that
    did not run, and saying so is the whole reason `unknown` exists.

    A conflicted merge with no file names in it is `unknown` for the same
    reason. The names are what makes the answer actionable, and an exit code
    with nothing behind it is a claim this cannot support.
  */
  if (probe.code !== 1) {
    const said = probe.stderr.trim()
    return {
      kind: 'unknown',
      reason: said.length > 0 ? said : `git merge-tree exited ${probe.code} and said nothing.`,
    }
  }

  const files = conflictedFiles(probe.stdout)
  if (files.length === 0) {
    return {
      kind: 'unknown',
      reason: 'git reported a conflict and named no file it was in.',
    }
  }
  return { kind: 'conflicts', files }
}

/**
 * The paths `merge-tree --write-tree --name-only` could not merge.
 *
 * The output is the tree it wrote, then the conflicted names one per line, then
 * a blank line, then messages about each conflict in prose. So: take everything
 * before the first blank line, drop the first line — which is the tree object,
 * not a path — and what is left is the answer.
 *
 * A clean merge prints the tree and nothing else, which falls out of the same
 * two rules as an empty list rather than needing a case of its own. This is
 * only ever called after exit 1, so an empty answer here is git contradicting
 * itself; {@link mergeabilityOf} treats that as not knowing rather than as no
 * conflict.
 */
function conflictedFiles(stdout: string): string[] {
  const [section = ''] = stdout.split('\n\n')
  return section
    .split('\n')
    .slice(1)
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
}

function reasonOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

const HEADS = 'refs/heads/'

export function shortBranch(ref: string | null): string | null {
  if (ref === null) return null
  return ref.startsWith(HEADS) ? ref.slice(HEADS.length) : ref
}

function withoutTrailingSlash(path: string): string {
  return path.endsWith('/') ? path.slice(0, -1) : path
}

/** `-z` terminates every entry, so the last split is an empty string. */
function splitNulTerminated(output: string): string[] {
  return output.split('\0').filter((entry) => entry.length > 0)
}
