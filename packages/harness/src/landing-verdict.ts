/**
 * May this change land unattended — asked of a repository, about one commit.
 *
 * The impure half of `unattendedLanding`: it runs git, reads two manifests, and
 * hands the pure predicate in ./fence.ts exactly what it needs. Everything that
 * *decides* anything is still over there, and is asserted headlessly with no
 * repository at all.
 *
 * ## Why this is one function and not two
 *
 * There are two callers and there must never be two answers. `bun run landable`
 * asks before a night starts, so a run is not spent authoring work that cannot be
 * delivered; `land_worktree` asks at the moment of merging. An orchestrator asks
 * the first and then the second, and two different answers about one branch is
 * worse than either answer on its own.
 *
 * They were written twice, briefly, and the duplication was not the argv alone —
 * it was the three flags *and* the twenty lines justifying them, the NUL
 * splitting, the `isRootManifest` gate, the merge base, and the rule for a
 * manifest that could not be read. `installLifecycleOf` had already been
 * extracted for exactly this reason and the extraction stopped one layer too
 * early. The flags are the worst possible thing to leave in two copies: ticket 02
 * shipped without `-z` and `--no-renames`, review added them, and a fourth flag
 * added to one copy and not the other is that failure again with nobody watching.
 *
 * The obstacle was real and is one adapter wide: `landing-cli.ts` runs git with
 * `Bun.spawnSync` and the runtime runs it with `execFile`. So git arrives here as
 * an **async port** and the CLI wraps its synchronous call in one — see
 * {@link LandingVerdictInput.git}.
 *
 * ## A commit, never a ref
 *
 * {@link LandingVerdictInput.commit} is a resolved object name and the callers
 * resolve it once. That is not tidiness; it is the whole correctness of the
 * arrangement — see {@link landingVerdict}.
 */

import {
  installLifecycleOf,
  isRootManifest,
  ROOT_MANIFEST,
  unattendedLanding,
  type InstallLifecycle,
  type UnattendedLanding,
} from './fence.ts'
import type { GitRunner } from './worktrees.ts'

export interface LandingVerdictInput {
  /**
   * A git that resolves with stdout and **rejects** when git would not answer.
   *
   * Async so the two callers can share this, and rejecting rather than answering
   * with an empty string because every read below is one whose absence changes
   * the verdict. A port that turned a failure into `''` would report a branch
   * that changed nothing, which is the answer that lands everything.
   */
  readonly git: GitRunner
  /** The revision being merged *into*: `HEAD` for the live tree, or a named base. */
  readonly base: string
  /**
   * The exact commit being judged, as a resolved object name.
   *
   * **Never a branch name.** See {@link landingVerdict}.
   */
  readonly commit: string
}

/**
 * What the predicate says about one commit, asked from git rather than from
 * anybody's account of it.
 *
 * ## The commit is pinned, and that is the point
 *
 * This takes a resolved SHA because a branch name is a *moving* answer. The
 * caller that merges resolves the ref once, asks this, and then merges — and
 * between those two steps the agent can add a commit to its own Worktree, which
 * it may write freely and can run git in from a background `Bash`. A verdict
 * computed from `refs/heads/x` and a merge performed on `refs/heads/x` are then
 * two different trees, and the gate has checked something that is not what
 * landed.
 *
 * That is a time-of-check-to-time-of-use gap in the one function whose entire job
 * is that the check binds the use, so the type refuses to take a ref at all. The
 * binding is completed on the other side by ./merge.ts, which refuses to merge a
 * ref that no longer points where it was checked.
 *
 * ## What is asked of git, and why each flag is there
 *
 * Three flags, and every one of them closed a hole that produced *may land* for a
 * protected path. Measured against real git in ticket 02 rather than reasoned
 * about:
 *
 * `<base>...<commit>` is the diff against the merge base rather than against the
 * tip of the base, so work that landed on the base since this branch forked is
 * not reported as something this branch changed. It is also the base the merge
 * will actually use.
 *
 * `-z` because the default `core.quotePath=true` prints a non-ASCII path *with
 * its quotes*: `scripts/café.sh` arrives as `"scripts/caf\303\251.sh"`, whose
 * leading `"` matches no entry in `PROTECTED_PATHS`. `-z` emits raw bytes
 * separated by NUL and never quotes. It also removes the other reason to split on
 * newlines, which is that a newline is a legal character in a POSIX filename.
 *
 * `--no-renames` because rename detection reports **only the destination**:
 * `sandbox-policy.baseline.json -> baseline.json` prints as `baseline.json`, so a
 * branch could delete the baseline or move `src-tauri/*` out of the protected
 * tree and land unattended. Without detection the same change is a delete of the
 * old path and an add of the new, so both sides are checked — which also refuses
 * a rename *into* a protected path, and should.
 *
 * Rejects only when git does. Every other outcome is a verdict.
 */
export async function landingVerdict(input: LandingVerdictInput): Promise<UnattendedLanding> {
  const { git, base, commit } = input

  const changedPaths = splitNulTerminated(
    await git(['diff', '-z', '--no-renames', '--name-only', `${base}...${commit}`]),
  )

  /*
    `isRootManifest` rather than `includes(ROOT_MANIFEST)`: the pure half owns
    what counts as the root manifest, and a string compare here disagreed with it
    on `./package.json` — reporting `manifest-not-read` for a manifest that reads
    perfectly well.

    Read only when the answer can turn on it, so an ordinary branch costs two git
    invocations rather than four.
  */
  if (!changedPaths.some(isRootManifest)) return unattendedLanding({ changedPaths })

  // The merge base, so "before" is the manifest the branch actually started from.
  // The base's tip would compare against a tree that may have moved on and report
  // somebody else's landed lifecycle change as this branch's.
  const mergeBase = (await git(['merge-base', base, commit])).trim()

  return unattendedLanding({
    changedPaths,
    rootManifestBefore: await lifecycleAt(git, mergeBase),
    rootManifestAfter: await lifecycleAt(git, commit),
  })
}

/**
 * One revision's install lifecycle fields, or `undefined` when they could not be
 * read.
 *
 * **A read that failed is `undefined`, never `{}`.** This is the rule the whole
 * function exists for and it was wrong once, in a way that opened the gate:
 * treating a failed `git show` as "there is no manifest at that revision" makes a
 * failure indistinguishable from an absence, and the two produce opposite
 * answers. With the base side holding no lifecycle fields — a manifest with no
 * `postinstall`, which is an ordinary thing for a manifest to be — a failed read
 * on the branch side made both sides `{}`, the diff showed no change, and a
 * branch that **added** a `postinstall` landed unattended. That is precisely the
 * outcome `installLifecycleOf`'s throw exists to prevent, arriving through the
 * caller that merges.
 *
 * It was not reachable in this repository on the day it was written, and that is
 * the part worth keeping in mind rather than the bug: `package.json` here has a
 * `postinstall`, so the base side had fields and a branch-side failure refused as
 * *removes postinstall*. The hole was closed by a fact about a file's current
 * contents rather than by this code. One human-merged branch dropping that field
 * would have opened it, with nothing failing.
 *
 * So absence is not inferred from failure. `undefined` reaches
 * {@link unattendedLanding} as `manifest-not-read`, which is a refusal that
 * already exists and already says the right sentence — the same direction
 * `isReadablePath` takes about a path it cannot normalise, and the same one
 * ticket 02 took about a caller that supplied nothing.
 *
 * **What it costs**, stated so the next reader does not think it an oversight: a
 * branch that adds the root manifest to a revision that genuinely has none is
 * refused rather than landed. That branch is a new `package.json` — the file
 * whose `postinstall` runs on the developer's next install — so a human reading
 * it is the right outcome, and in a repository whose root manifest has existed
 * since its first commit it is unreachable anyway.
 */
async function lifecycleAt(git: GitRunner, revision: string): Promise<InstallLifecycle | undefined> {
  let source: string
  try {
    source = await git(['show', `${revision}:${ROOT_MANIFEST}`])
  } catch {
    return undefined
  }

  try {
    return installLifecycleOf(source)
  } catch {
    // Not read, rather than read as empty, for the reason above. The parser's
    // complaint is not forwarded: the predicate's own `manifest-not-read`
    // sentence says the thing that matters, and a parse error about a
    // developer's manifest is not an answer about a branch.
    return undefined
  }
}

/** `-z` terminates every entry, so the last split is an empty string. */
function splitNulTerminated(output: string): string[] {
  return output.split('\0').filter((entry) => entry.length > 0)
}
