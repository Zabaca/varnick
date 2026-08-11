/**
 * The Fence, and what may not be landed without a human.
 *
 * `packages/harness/**` generates the Sandbox policy, `src-tauri/**` holds the
 * Credential and enforces the boundary, and `sandbox-policy.baseline.json` is
 * how a widening is told from varnick's own work. See CONTEXT.md and
 * docs/adr/0014-core-is-authored-in-a-worktree.md.
 *
 * ## Why this is one function
 *
 * Three separate mechanisms ask the same question of a changed path: the
 * pending-worktree list says whether a worktree touches the Fence, the Preview
 * dialog decides from it whether to raise a native prompt, and the diff view
 * renders Fence hunks distinctly. Three answers written three times is three
 * glob lists that drift, and the drift is invisible: each caller keeps working,
 * and the one that fell behind stops raising a dialog for a file the other two
 * still colour. So the list is here, once, and the callers ask.
 *
 * ## Distinct from Core, which is larger
 *
 * `packages/core/**`, `vite.config.*` and `package.json` are Core and are not
 * Fence. They are denied so a broken edit cannot take the conversation down,
 * not because they decide the boundary — and a dialog on every Core preview is
 * a dialog nobody reads by the second week.
 *
 * ## Two lists, deliberately, and neither derived from the other
 *
 * {@link PROTECTED_PATHS} lives beside {@link FENCE_PATHS} and answers a
 * different question: not *what raises a dialog before a Preview* but *what a
 * night's unattended run may not merge*. It is larger than the Fence and smaller
 * than the Sandbox's `denyWrite`, and the three move independently — see
 * {@link unattendedLanding} and docs/adr/0018-three-lists-three-questions.md.
 *
 * The one thing that would undo all of it is a gate that reuses `isFencePath`,
 * because that gate looks correct and silently lands `scripts/**` and
 * `sandbox-policy.json`. Hence a separate name, a separate list, and an
 * invariant test in `fence.test.ts` rather than a comment here saying they
 * relate.
 *
 * ## Nothing here imports anything
 *
 * A pure function over a string, so every caller can have it: the host-side
 * worktree listing, the Rust host by way of the answer it is given, and Core's
 * diff view, which runs in the webview and cannot load a Node built-in.
 *
 * That is also why the paths below are literals rather than the constants
 * `sandbox.ts` already holds for them. Importing that module would put
 * `node:path` behind every caller of this one. `fence.test.ts` asserts the
 * literals against those constants, which is the same trade `FENCE_PATHS`
 * already made for the baseline filename.
 */

/**
 * The Fence, as paths relative to the clone root.
 *
 * Two forms, and no glob engine: `<dir>/**` matches that directory and
 * everything under it, and anything else is one exact file. That is the whole
 * of the syntax, because it is the whole of what the list needs — and a real
 * matcher here would be a second implementation of the semantics srt already
 * has for the same strings.
 *
 * Written in the form `denyWrite` uses them, joined onto the clone root, so the
 * two lists can be compared entry by entry. `fence.test.ts` does exactly that
 * against the generated policy.
 */
export const FENCE_PATHS = [
  'packages/harness/**',
  'src-tauri/**',
  'sandbox-policy.baseline.json',
] as const

/**
 * Whether one changed path is Fence.
 *
 * `path` is repository-relative, as `git diff --name-only` reports it: forward
 * slashes, no leading slash, no `..`. A leading `./` is tolerated because a
 * caller composing paths by hand produces them.
 *
 * **Compared without case.** macOS filesystems are case-insensitive by default,
 * so `Src-Tauri/lib.rs` and `src-tauri/lib.rs` are one file on the disk being
 * written to. The error a case-insensitive comparison can make is a dialog
 * nobody needed; the error the other one makes is a widening that launched
 * unconfined without one.
 */
export function isFencePath(path: string): boolean {
  return matchedEntry(path, FENCE_PATHS) !== null
}

/** Whether any of a worktree's changed paths is Fence. */
export function touchesFence(paths: readonly string[]): boolean {
  return paths.some(isFencePath)
}

// ---------------------------------------------------------------------------
// What may not be landed without a human
// ---------------------------------------------------------------------------

/**
 * The paths an unattended run may not merge, relative to the clone root.
 *
 * Same two forms as {@link FENCE_PATHS}, and **a separate list on purpose.**
 * The Fence answers "would previewing this unconfined be an escalation"; this
 * answers "may a night's run land this while nobody is watching". Those are
 * different questions and their answers have already diverged in three places:
 *
 * - `sandbox-policy.json` is not Fence — it is the generated output, and a
 *   worktree that changes only it changes nothing the next launch will believe,
 *   because the launch regenerates from the generator and compares to the
 *   baseline. It is on *this* list because the launch that would do that
 *   comparison is the developer's, hours later, and until then the file on disk
 *   is what a merge left there.
 * - `scripts/**` is not Fence either — it decides nothing about the Sandbox. It
 *   is here because `package.json`'s `postinstall` reads `sh scripts/…`, so the
 *   file the developer's next `bun install` executes is chosen here. See
 *   `HOST_INVOKED_SCRIPTS` in ./sandbox.ts, which denies it for the same reason.
 * - `.githooks/**` is the tracked hooks directory, which the agent writes freely
 *   and a human reads in a diff. That argument is exactly an argument about the
 *   merge, so it holds only while the merge has a human in it.
 *
 * Not here, and each absence is a decision rather than an oversight:
 *
 * - `packages/core/**` and `vite.config.*` — the whole point of the feature.
 *   They are denied in the live tree so a broken edit cannot take the
 *   conversation down, which is a reason to review a change and not a reason to
 *   need a person awake for it.
 * - `package.json` as a path. Dependencies land; the fields that execute on the
 *   developer's machine do not, and that is {@link INSTALL_LIFECYCLE_FIELDS}
 *   rather than the file.
 * - `.git/hooks/**` and `.git/config*`. They are denied in the live tree and
 *   they are on no branch, so there is no diff for a merge to carry — a landing
 *   rule cannot reach them and must not pretend to. ADR-0016.
 */
export const PROTECTED_PATHS = [
  'packages/harness/**',
  'src-tauri/**',
  'sandbox-policy.baseline.json',
  'sandbox-policy.json',
  'scripts/**',
  '.githooks/**',
] as const

/** The root manifest, whose diff is read rather than refused outright. */
export const ROOT_MANIFEST = 'package.json'

/**
 * The `package.json` fields that run a command on the developer's machine when
 * they install.
 *
 * npm and bun both run `preinstall` before resolution, `postinstall` after it,
 * and `prepare` after both — so all three are code execution outside the
 * Sandbox, triggered by a command the developer types for an unrelated reason.
 * Everything else in the manifest is data or a script somebody has to invoke by
 * name, and both of those land.
 */
export const INSTALL_LIFECYCLE_FIELDS = ['preinstall', 'postinstall', 'prepare'] as const

export type InstallLifecycleField = (typeof INSTALL_LIFECYCLE_FIELDS)[number]

/**
 * The install lifecycle half of one root manifest, at one revision.
 *
 * A field that is absent is a field the manifest does not have. An empty object
 * is a manifest with no lifecycle scripts in it, which is a real and different
 * thing from not having read the manifest at all — see {@link unattendedLanding}.
 */
export type InstallLifecycle = Readonly<Partial<Record<InstallLifecycleField, string>>>

/** Which rule refused, for a report that has to say more than "no". */
export type LandingRefusal = 'protected-path' | 'install-lifecycle-script' | 'manifest-not-read'

/**
 * Whether a change may land unattended, and if not, why not.
 *
 * `reason` is one printable sentence, so a run report prints the answer rather
 * than reconstructing it from the rule and the subject.
 */
export type UnattendedLanding =
  | { readonly mayLand: true }
  | {
      readonly mayLand: false
      readonly refusal: LandingRefusal
      /** The changed path, or the manifest field, that the rule refused. */
      readonly subject: string
      readonly reason: string
    }

export interface UnattendedLandingInput {
  /** Repository-relative, as `git diff --name-only` reports them. */
  readonly changedPaths: readonly string[]
  /** The root manifest's lifecycle fields at the base revision. */
  readonly rootManifestBefore?: InstallLifecycle | undefined
  /** The same fields on the branch. */
  readonly rootManifestAfter?: InstallLifecycle | undefined
}

/**
 * May this change be merged with nobody watching?
 *
 * Two rules, and a third that exists because the first two can be evaded by a
 * caller doing nothing.
 *
 * **A protected path.** Any changed path matching {@link PROTECTED_PATHS}
 * refuses the whole change. There is no partial landing: a branch is one commit
 * and the paths arrive together.
 *
 * **An install lifecycle script.** The root manifest may change — dependencies
 * land, that is most of what a manifest diff is — but a difference in any of
 * {@link INSTALL_LIFECYCLE_FIELDS} refuses. **Including a removal**, which is
 * not symmetry for its own sake: `postinstall` is what points git at the tracked
 * hooks directory, so deleting it is a weakening dressed as a tidy-up.
 *
 * **A manifest that was not read.** If the root manifest is among the changed
 * paths and either revision's fields were not supplied, this refuses. The
 * alternative is an API whose safe answer requires the caller to have done
 * something, and every caller that forgets gets a landing rather than an error.
 * A branch that does not touch the manifest needs neither argument.
 *
 * Deterministic: the changed paths are checked in the order given, so the same
 * input always names the same first offender, and a report is stable across
 * runs.
 */
export function unattendedLanding(input: UnattendedLandingInput): UnattendedLanding {
  for (const path of input.changedPaths) {
    const entry = matchedEntry(path, PROTECTED_PATHS)
    if (entry !== null) {
      return {
        mayLand: false,
        refusal: 'protected-path',
        subject: path,
        reason: `${path} is protected — ${entry} may not be landed without a human.`,
      }
    }
  }

  if (!input.changedPaths.some((path) => normalise(path) === ROOT_MANIFEST)) {
    return { mayLand: true }
  }

  const { rootManifestBefore: before, rootManifestAfter: after } = input
  if (before === undefined || after === undefined) {
    return {
      mayLand: false,
      refusal: 'manifest-not-read',
      subject: ROOT_MANIFEST,
      reason: `${ROOT_MANIFEST} changed and its install lifecycle fields were not read, so nothing here can say whether it changed one.`,
    }
  }

  for (const field of INSTALL_LIFECYCLE_FIELDS) {
    const was = before[field]
    const now = after[field]
    if (was === now) continue
    return {
      mayLand: false,
      refusal: 'install-lifecycle-script',
      subject: field,
      reason: `${ROOT_MANIFEST} ${verb(was, now)} "${field}", which runs on the developer's machine at install time.`,
    }
  }

  return { mayLand: true }
}

/** Whether one changed path is on the unattended-landing list. */
export function isProtectedPath(path: string): boolean {
  return matchedEntry(path, PROTECTED_PATHS) !== null
}

function verb(was: string | undefined, now: string | undefined): string {
  if (was === undefined) return 'adds'
  if (now === undefined) return 'removes'
  return 'changes'
}

/**
 * Which entry of a list a path matches, or null.
 *
 * The matcher is shared and the lists are not, which is the distinction the
 * whole file turns on. Two copies of these six lines would be two readings of
 * `<dir>/**`, and the one that drifted would be the one nobody ran.
 */
function matchedEntry(path: string, entries: readonly string[]): string | null {
  const subject = normalise(path)
  if (subject === '') return null

  for (const entry of entries) {
    const pattern = normalise(entry)
    if (!pattern.endsWith('/**')) {
      if (subject === pattern) return entry
      continue
    }
    const directory = pattern.slice(0, -'/**'.length)
    // The directory itself counts, and the separator is what stops
    // `src-tauri-notes/plan.md` from counting: a prefix test alone would call
    // every sibling whose name starts the same way part of the list.
    if (subject === directory || subject.startsWith(`${directory}/`)) return entry
  }
  return null
}

function normalise(path: string): string {
  const trimmed = path.startsWith('./') ? path.slice(2) : path
  return trimmed.toLowerCase()
}
