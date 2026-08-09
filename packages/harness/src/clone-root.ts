/**
 * Where the agent works, and why.
 *
 * ## The one thing this module exists to stop
 *
 * The clone root used to arrive by accident. `src-tauri/src/bridge.rs` spawned
 * the runtime with `.current_dir(project_root())`, where `project_root()` was
 * `env!("CARGO_MANIFEST_DIR")` — a compile-time macro, so the path was a
 * literal frozen into the binary when `cargo build` ran. It appeared twice in
 * `src-tauri/target/debug/varnick`. From there nothing passed it: `runtime.ts`
 * called `establishSandbox()` with no argument and `sandbox.ts` fell back to
 * `process.cwd()`, which was the directory the host had just set.
 *
 * Four hops, no name, and the two ends only agreed because `bun tauri dev` is
 * `cargo run` — it recompiles in the checkout every time, so the build path and
 * the working directory were never different. Launch that binary from anywhere
 * else and it still named the machine it was built on.
 *
 * So the root is now an input with a name, and it travels as an argument rather
 * than as a working directory. `VARNICK_CLONE_ROOT` chooses it; the path the
 * binary was built from is what it defaults to, so a developer running
 * `bun tauri dev` in a checkout sees exactly what they saw before. See
 * docs/adr/0012-the-clone-root-is-an-input.md.
 *
 * ## Why an environment variable
 *
 * The same reason `VARNICK_HOST`, `VARNICK_HARNESS_ENTRY` and
 * `VARNICK_INHERIT_CLAUDE_CONFIG` are, written out once in `agent.ts` and true
 * here: it is a property of one launch, it has to be readable before anything is
 * rendered, and **a setting stored in the clone would be a setting the agent can
 * write**. A root the agent can choose is a fence the agent can move.
 *
 * ## Two gates, and why they are not the same gate
 *
 * {@link requireCloneRoot} is the library gate. It asks only what the Sandbox
 * needs to be true — an absolute path to a directory that is there — and
 * `establishSandbox` calls it before anything else, so a root that does not
 * exist is a refusal naming the path rather than a Sandbox established for a
 * missing directory.
 *
 * {@link cloneRootFromLaunch} is the launch gate, and it asks for one thing
 * more: that the directory is a varnick clone. It can, because it runs where a
 * developer's own `VARNICK_CLONE_ROOT` is read, and it must, because the agent
 * host varnick starts is `<root>/packages/harness/src/agent.ts` — a root without
 * one produces an interpreter error naming a file the developer never chose.
 * The library gate deliberately does not ask this: the Sandbox is established
 * for temporary directories by every probe in this package, and they are roots
 * without being clones.
 */

import { statSync } from 'node:fs'
import { isAbsolute, join } from 'node:path'
import { AGENT_ENTRY_RELATIVE_PATH } from './agent.ts'

/**
 * The variable that chooses the root.
 *
 * Read in exactly one place — `clone_root` in src-tauri/src/bridge.rs, which
 * resolves it and hands the answer to the runtime as an argument. The runtime
 * does not read it a second time: two readers of one variable is two answers
 * waiting to disagree, and the argument is the one the Sandbox is established
 * for. Mirrored there as `CLONE_ROOT_VAR`, because Rust cannot read this one.
 */
export const CLONE_ROOT_ENV_VAR = 'VARNICK_CLONE_ROOT'

/** The filesystem facts a root is judged on. Injected so tests need no disk. */
export interface CloneRootChecks {
  /** Is there a directory at this path? */
  readonly isDirectory?: (path: string) => boolean
  /** Is there a file at this path? */
  readonly isFile?: (path: string) => boolean
}

const directoryOnDisk = (path: string): boolean => {
  try {
    return statSync(path).isDirectory()
  } catch {
    return false
  }
}

const fileOnDisk = (path: string): boolean => {
  try {
    return statSync(path).isFile()
  } catch {
    return false
  }
}

/**
 * The root, or a refusal that names what is wrong with it.
 *
 * Three checks, in the order a developer meets them:
 *
 *   * **absolute** — a relative root would be resolved against the working
 *     directory, which is the implicitness this whole module removes. A root
 *     that means something different depending on where varnick was launched is
 *     not a named root.
 *   * **it is there** — the ticket's own criterion. Moving a checkout after
 *     building used to produce a Sandbox established for a directory that no
 *     longer existed, and the failure said nothing about the root.
 *   * **it is a directory** — a file at that path fails later, in `mkdir`, with
 *     an error about a path nobody typed.
 *
 * Throws rather than returning null. There is no weaker Sandbox to fall back to
 * and no root to guess, so the only honest end of this road is a stop.
 */
export function requireCloneRoot(candidate: string, checks: CloneRootChecks = {}): string {
  const isDirectory = checks.isDirectory ?? directoryOnDisk

  if (candidate === '') {
    throw new Error(
      `varnick was given an empty clone root. Set ${CLONE_ROOT_ENV_VAR} to the absolute path of the clone the agent should work in, or leave it unset to use the one varnick was built from.`,
    )
  }

  if (!isAbsolute(candidate)) {
    throw new Error(
      `The clone root ${JSON.stringify(candidate)} is not an absolute path. varnick will not resolve it against a working directory — that is how the root used to arrive unnamed. Set ${CLONE_ROOT_ENV_VAR} to an absolute path.`,
    )
  }

  if (!isDirectory(candidate)) {
    throw new Error(
      `There is no directory at ${candidate}, so there is nothing for the agent to work in and no Sandbox to establish around it. Check ${CLONE_ROOT_ENV_VAR}, or — if it is unset — that the clone varnick was built from has not been moved or deleted.`,
    )
  }

  return candidate
}

/**
 * The root as the launch seam resolves it: given, checked, and a clone.
 *
 * `argument` is what the host passed on the command line. It is never absent in
 * a real launch — src-tauri/src/bridge.rs always supplies it — so a missing one
 * means the runtime was started by hand, and saying that is more useful than
 * quietly falling back to `process.cwd()` and reintroducing the defect this
 * module was written to remove.
 */
export function cloneRootFromLaunch(
  argument: string | undefined,
  checks: CloneRootChecks = {},
): string {
  if (argument === undefined) {
    throw new Error(
      `The Harness runtime was started without a clone root. The Tauri host always passes one as its first argument; running the runtime by hand means passing it too — \`bun packages/harness/src/serve.ts <clone-root>\`. It is not inherited from the working directory, on purpose.`,
    )
  }

  const root = requireCloneRoot(argument, checks)
  const isFile = checks.isFile ?? fileOnDisk

  if (!isFile(join(root, AGENT_ENTRY_RELATIVE_PATH))) {
    throw new Error(
      `${root} is a directory, but not a varnick clone: it has no ${AGENT_ENTRY_RELATIVE_PATH}. That file is the agent host varnick starts inside the Sandbox, so a root without one cannot run an agent. Point ${CLONE_ROOT_ENV_VAR} at a clone of varnick.`,
    )
  }

  return root
}
