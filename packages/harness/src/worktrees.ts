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
 * own. That is what keeps the assertions about *which questions are asked* — no
 * subcommand but `worktree`, `rev-list` and `diff`, none of which writes.
 */

import { touchesFence } from './fence.ts'

/**
 * One worktree with unmerged commits in it.
 *
 * Serialisable and nothing more: this crosses the bridge into the webview, so
 * every field is a string, a number, a boolean or an array of strings.
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

    pending.push({
      path: entry.path,
      branch: shortBranch(entry.branch),
      commits,
      changed,
      touchesFence: touchesFence(changed),
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
interface Reviewable {
  readonly entry: WorktreeEntry
  readonly ref: string
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

const HEADS = 'refs/heads/'

function shortBranch(ref: string | null): string | null {
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
