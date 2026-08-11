/**
 * Putting a built directory into the store.
 *
 * One function, and it is the only impure step in the artifact set — which is
 * why it is a file of its own rather than a thirteenth export of
 * `artifacts.ts`. That module decides names and paths, imports `node:path` and
 * nothing else, and can be reasoned about by reading it; this one touches the
 * filesystem. Keeping them apart is the arrangement `dev-server.ts` already has
 * and what [ADR-0013](../../docs/adr/0013-behaviour-is-proved-headlessly.md)
 * argues for: pure decisions where a driver can assert them, with the thin
 * impure caller beside.
 *
 * **It is one function rather than four lines at a call site**, and that part is
 * not stylistic. Two things write artifacts — `bun run build` today, and
 * whatever cuts a pre-release next — and the second has no reason to open the
 * first's file. Two implementations of this sequence is one implementation with
 * the `dereference` left off, which silently reopens a hole nothing would
 * notice.
 *
 * Nothing here is loaded by the application. It is imported by the build, by
 * whatever writes a release, and by the driver.
 */

import { cpSync, mkdirSync, renameSync, rmSync } from 'node:fs'
import { artifactPath, artifactStore, incomingArtifactPath } from './artifacts.ts'

/**
 * Make a built directory into the artifact `id`, and answer where it landed.
 *
 * The two properties an artifact must have are held here, by construction:
 *
 *   * **it is a tree of ordinary files** — `dereference`, which is what closes
 *     the symlink case at the moment the tree is written rather than costing a
 *     `realpath` on every request. `assetPath` resolves lexically and
 *     `Bun.file` follows links, so a link inside an artifact would put a path
 *     outside it behind a URL;
 *   * **it is never half of one** — assembled in {@link incomingArtifactPath}
 *     and renamed in, so nothing ever observes a partial copy under the id.
 *
 * **Whole or absent, not whole or previous.** POSIX `rename` will not replace a
 * non-empty directory, so the old artifact is removed first and there is a
 * moment when the id names nothing. That is a real window and it is the one the
 * design accepts: a launch inside it reads *nothing served*, which is a state
 * the artifact server already has a page and a rebuild for, whereas a partial
 * copy is a window that opens on a page whose script is not there. Closing the
 * gap entirely means swapping a symlink — the one operation that is atomic
 * against a live path — and ADR-0020 turned symlinks down for a different
 * reason worth keeping: `cat served` says what is running.
 *
 * **It does not touch `served`.** Writing an artifact and choosing to serve it
 * are two acts, and a release performs only the first — that is ticket 06's
 * "without switching what is currently served", and making it the default here
 * is what keeps a caller from having to remember it.
 */
export function installArtifact(cloneRoot: string, id: string, from: string): string {
  const artifact = artifactPath(cloneRoot, id)
  const incoming = incomingArtifactPath(cloneRoot, id)
  if (artifact === null || incoming === null) {
    throw new Error(`${JSON.stringify(id)} is not a usable artifact id`)
  }

  mkdirSync(artifactStore(cloneRoot), { recursive: true })
  rmSync(incoming, { recursive: true, force: true })
  cpSync(from, incoming, { recursive: true, dereference: true })
  rmSync(artifact, { recursive: true, force: true })
  renameSync(incoming, artifact)

  return artifact
}
