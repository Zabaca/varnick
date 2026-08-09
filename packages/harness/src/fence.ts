/**
 * The Fence: which paths decide what the agent may do.
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
 * ## Nothing here imports anything
 *
 * A pure function over a string, so every caller can have it: the host-side
 * worktree listing, the Rust host by way of the answer it is given, and Core's
 * diff view, which runs in the webview and cannot load a Node built-in.
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
  const subject = normalise(path)
  if (subject === '') return false

  return FENCE_PATHS.some((entry) => {
    const pattern = normalise(entry)
    if (!pattern.endsWith('/**')) return subject === pattern
    const directory = pattern.slice(0, -'/**'.length)
    // The directory itself counts, and the separator is what stops
    // `src-tauri-notes/plan.md` from counting: a prefix test alone would call
    // every sibling whose name starts the same way part of the Fence.
    return subject === directory || subject.startsWith(`${directory}/`)
  })
}

/** Whether any of a worktree's changed paths is Fence. */
export function touchesFence(paths: readonly string[]): boolean {
  return paths.some(isFencePath)
}

function normalise(path: string): string {
  const trimmed = path.startsWith('./') ? path.slice(2) : path
  return trimmed.toLowerCase()
}
