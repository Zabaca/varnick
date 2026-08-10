/**
 * A Worktree arrives with its dependencies, instead of the agent building them.
 *
 * ## The gap this closes
 *
 * `node_modules` is gitignored and a Worktree is a fresh checkout, so every one
 * begins with nothing installed. [ADR-0014](../../../docs/adr/0014-core-is-authored-in-a-worktree.md)
 * makes a Worktree the required path for every Core change, so this is not an
 * edge: it is the first thing that happens on every Core change varnick ever
 * accepts, and until now the agent paid it by hand.
 *
 * Measured on one subagent: seventeen `ln -s` calls across three `node_modules`
 * directories, each a guess at what the next command would need, spent before it
 * touched the ticket it was given.
 *
 * ## Why install rather than link
 *
 * Linking looks cheaper and is not, in either sense. A spike ran both against
 * the real suite:
 *
 *   * Linking the root `node_modules` alone changes **nothing** — 442 of 620
 *     tests load, the same as a bare Worktree. bun's isolated layout resolves a
 *     workspace's dependencies from each package's own directory, so the four
 *     package directories are the load-bearing ones.
 *   * Linking all five loads every test and fails one: `containment.probe`'s
 *     *"a file outside the boundary is unreachable"*, because the resolved
 *     module path points into the **live tree**. Linking puts a Worktree's
 *     dependencies outside that Worktree's own Sandbox boundary, so a Preview —
 *     the whole point of ADR-0014 — cannot read them. Nothing run from the live
 *     tree would ever reveal that.
 *   * `bun install --frozen-lockfile` passes all 619, in **155ms** for 462
 *     packages, costing **12 MB** of real disk against 478 MB apparent, because
 *     APFS `clonefile` makes it copy-on-write. Faster to run than the seventeen
 *     symlinks it replaces.
 *
 * So the honest option is also the fast one, and it is the only one that leaves
 * a Worktree self-contained.
 *
 * ## Why the cache moves into the clone
 *
 * bun's cache is `~/.bun/install/cache`, and the Sandbox denies `$HOME` — so an
 * install run by the agent would fail for the same reason
 * {@link CLAUDE_CONFIG_RELATIVE_PATH} exists, and the answer is the same one:
 * put it inside the clone, where the agent can write. `registry.npmjs.org` is
 * already on the egress allowlist, so nothing about the network needs widening
 * for this — and nothing here is a reason to widen it.
 *
 * A cold cache costs a real download once; every Worktree after it is the 155ms
 * case. That is worth saying out loud rather than leaving a first run looking
 * hung.
 *
 * ## Nothing here runs a process
 *
 * Same rule as ./worktrees.ts: this module decides, and the caller spawns. What
 * that keeps testable is the part worth asserting — *which* command runs, with
 * which arguments, in which directory, and when it is skipped entirely.
 */

import { join, sep } from 'node:path'

/**
 * Where a clone's bun cache lives.
 *
 * Beside `.varnick/claude` and `.varnick/bin` and gitignored with them: one
 * machine's state, rebuilt on demand, never committed.
 */
export const BUN_CACHE_RELATIVE_PATH = '.varnick/bun-cache'

/** The variable bun reads to find it. */
export const BUN_CACHE_ENV_VAR = 'BUN_INSTALL_CACHE_DIR'

/** That cache in a given clone. */
export function bunCacheDir(cloneRoot: string): string {
  return join(cloneRoot, BUN_CACHE_RELATIVE_PATH)
}

/**
 * Where Claude Code puts a Worktree.
 *
 * varnick does not choose this and must not: `EnterWorktree` creates the
 * directory and the agent's whole worktree workflow is Claude Code's own, which
 * ADR-0014 keeps deliberately rather than replacing. This constant is a *test*
 * against what it produced, not an instruction to it.
 */
export const WORKTREE_BASE_RELATIVE_PATH = join('.claude', 'worktrees')

/**
 * Is this path a Worktree of this clone?
 *
 * A prefix test, and the trailing separator is what makes it one: without it
 * `…/worktrees-old` would match `…/worktrees`. The clone root itself is not a
 * Worktree and must answer false — provisioning the live tree from here would
 * run an install nobody asked for over the developer's own `node_modules`.
 */
export function isWorktreeOf(cloneRoot: string, path: string): boolean {
  const base = join(cloneRoot, WORKTREE_BASE_RELATIVE_PATH) + sep
  return path.startsWith(base) && path.length > base.length
}

/** What to run, where, to give a Worktree its dependencies. */
export interface ProvisionCommand {
  readonly command: 'bun'
  readonly args: readonly string[]
  readonly cwd: string
}

/**
 * The command that provisions a Worktree, or `null` when there is nothing to do.
 *
 * Two ways to be `null`, and they are different facts worth keeping separate in
 * the reading even though they return the same thing:
 *
 *   * **not a Worktree.** The live tree, or somewhere else entirely. Installing
 *     there is at best redundant and at worst destructive.
 *   * **already provisioned.** Re-entering a Worktree is ordinary, and an
 *     install on every entry would be a visible pause charged for nothing.
 *
 * `--frozen-lockfile` rather than a plain install: the lockfile is committed, a
 * Worktree is a checkout of it, and an install permitted to *change* it would
 * let entering a directory rewrite what the project depends on.
 */
export function provisionCommandFor(
  cloneRoot: string,
  path: string,
  exists: (path: string) => boolean,
): ProvisionCommand | null {
  if (!isWorktreeOf(cloneRoot, path)) return null
  if (exists(join(path, 'node_modules'))) return null
  return { command: 'bun', args: ['install', '--frozen-lockfile'], cwd: path }
}

/** How much of a failed install's output is worth putting in front of the agent. */
const PROVISION_STDERR_LIMIT = 400

/**
 * What the agent is told when provisioning fails.
 *
 * **Reported rather than fatal.** A Worktree without dependencies is exactly
 * where varnick has been all along — refusing to enter one would be a worse
 * regression than the gap this closes. But it must not be *silent*: the failure
 * mode that made ticket 58 invisible was a thing that did not run and said
 * nothing, and an agent that knows its Worktree is unprovisioned can install by
 * hand instead of reading a resolution error as a broken change.
 *
 * Quoted, like a hook's stderr and for the same reason: `error: lockfile had
 * changes` *is* the answer, and a sentence saying "provisioning failed" would
 * send the reader to a log that does not exist.
 */
export function provisionFailureMessage(cwd: string, detail: string): string {
  const trimmed = detail.trim()
  const quoted =
    trimmed.length > PROVISION_STDERR_LIMIT
      ? `${trimmed.slice(0, PROVISION_STDERR_LIMIT)}…`
      : trimmed
  const because = quoted.length > 0 ? `: ${quoted}` : '.'
  return (
    `Dependencies were not installed in ${cwd}${because}\n` +
    'Tests and typecheck will fail to resolve modules until they are. ' +
    'Run `bun install --frozen-lockfile` there, and report the error if it persists ' +
    'rather than linking node_modules from the live tree — a link puts the ' +
    "dependencies outside this Worktree's Sandbox boundary."
  )
}
