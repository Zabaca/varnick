/**
 * Reading and writing the store: what is in it, which artifact is served,
 * whether one will start, and what gets removed.
 *
 * The impure half of the artifact set — which is why it is a file of its own
 * rather than more exports of `artifacts.ts`. That module decides names, paths
 * and *which artifact to serve*, imports `node:path` and nothing else, and can
 * be reasoned about by reading it; this one touches the filesystem. Keeping
 * them apart is the arrangement `dev-server.ts` already has and what
 * [ADR-0013](../../docs/adr/0013-behaviour-is-proved-headlessly.md) argues for:
 * pure decisions where a driver can assert them, with the thin impure caller
 * beside.
 *
 * Everything here is that thin caller. Each function reads or writes a
 * filesystem and hands what it found to a decision in `artifacts.ts`; the one
 * judgement made in this file is {@link artifactStartFailure}'s, and even there
 * what counts as a script is parsed next door.
 *
 * **{@link installArtifact} is one function rather than four lines at a call
 * site**, and that part is not stylistic. Two things write artifacts —
 * `bun run build` today, and whatever cuts a pre-release next — and the second
 * has no reason to open the first's file. Two implementations of that sequence
 * is one implementation with the `dereference` left off, which silently reopens
 * a hole nothing would notice. {@link switchServedArtifact} is on the list for
 * the same reason one step further on: the step a second copy leaves out is the
 * one that remembers what was being served, and nothing looks wrong until the
 * day a build does not start.
 *
 * Nothing here is loaded by the application. It is imported by the build, by
 * the artifact server, by whatever writes a release, and by the driver.
 */

import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { join, resolve } from 'node:path'
import {
  ARTIFACT_ENTRY,
  artifactPath,
  artifactStore,
  artifactsToPrune,
  entryScriptSources,
  incomingArtifactPath,
  markedArtifactId,
  previousMarkerPath,
  servedMarkerPath,
  servedMarkerText,
  servedSwitch,
} from './artifacts.ts'
import { assetPath } from './artifact-assets.ts'

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

// ---------------------------------------------------------------------------
// Which one is served
// ---------------------------------------------------------------------------

/** What the store's two markers say, as ids or as nothing. */
export interface ServedMarkers {
  readonly served: string | null
  readonly previous: string | null
}

/**
 * Read a marker without ever throwing.
 *
 * Every way this can fail means the same thing and none of them may be an
 * exception. A marker could be a directory, could be unreadable, could vanish
 * between the check and the read — and the only caller is a launch, which reads
 * these *before* it binds a port. A throw there is the Tauri CLI waiting on a
 * port that never opens: a terminal saying "waiting for your frontend dev
 * server", no window, and no reason given. A marker nobody can read names
 * nothing, and naming nothing is a state the server has a page for.
 */
function markerAt(path: string): string | null {
  try {
    return markedArtifactId(readFileSync(path, 'utf-8'))
  } catch {
    return null
  }
}

/** What this clone's store says it is serving, and what it served before. */
export function readServedMarkers(cloneRoot: string): ServedMarkers {
  return {
    served: markerAt(servedMarkerPath(cloneRoot)),
    previous: markerAt(previousMarkerPath(cloneRoot)),
  }
}

/**
 * Point the window at `id`, remembering what it was pointed at.
 *
 * Two files, written together, because that is the only way the second one is
 * true. `served` alone was one `writeFileSync` at the end of `bun run build`,
 * and a promotion would have been a second one somewhere else — at which point
 * "the previous build" is a fact two callers each have to remember to record
 * and neither is wrong-looking when it does not.
 *
 * What to write is {@link servedSwitch}, next door and asserted; this is the
 * write.
 */
export function switchServedArtifact(cloneRoot: string, id: string): ServedMarkers {
  const current = readServedMarkers(cloneRoot)
  const next = servedSwitch(current.served, current.previous, id)

  mkdirSync(artifactStore(cloneRoot), { recursive: true })
  if (next.previous !== null) {
    writeFileSync(previousMarkerPath(cloneRoot), servedMarkerText(next.previous))
  }
  writeFileSync(servedMarkerPath(cloneRoot), servedMarkerText(next.served))

  return next
}

// ---------------------------------------------------------------------------
// Whether one will start
// ---------------------------------------------------------------------------

/**
 * Why this artifact will not open a window, or `null` if nothing says it will
 * not.
 *
 * **What "fails to start" is allowed to mean, and what it is not.** Two things
 * are decidable here, before a port is bound and with no browser involved, and
 * both are certain rather than likely:
 *
 *   * there is no {@link ARTIFACT_ENTRY} — the id names a directory that was
 *     pruned, half-removed, or never landed;
 *   * the entry document loads a script the artifact does not contain, which is
 *     a window that opens on an empty page every time.
 *
 * Everything past that is a guess, and the ticket this function was written for
 * is explicit that a fallback on the wrong signal is worse than none. A build
 * that comes up and throws is still the build the developer chose, and at
 * launch it is indistinguishable from a build that works; a host that fell back
 * on a runtime error would be overruling a promotion on evidence it does not
 * have. So the answer is the narrow one, and it is the one that is *true*.
 *
 * It resolves each script through `assetPath` rather than joining it, so a
 * document that references its way out of the artifact fails to start rather
 * than being checked against a file outside the store.
 */
export function artifactStartFailure(artifactRoot: string): string | null {
  const entry = resolve(artifactRoot, ARTIFACT_ENTRY)

  let html: string
  try {
    html = readFileSync(entry, 'utf-8')
  } catch {
    return `there is no ${ARTIFACT_ENTRY} in it`
  }

  for (const source of entryScriptSources(html)) {
    const path = assetPath(artifactRoot, source.startsWith('/') ? source : `/${source}`)
    if (path === null) return `${ARTIFACT_ENTRY} loads ${source}, which is outside the artifact`
    if (!existsSync(path)) return `${ARTIFACT_ENTRY} loads ${source}, which is not in the artifact`
  }

  return null
}

// ---------------------------------------------------------------------------
// How many are kept
// ---------------------------------------------------------------------------

/**
 * Remove the artifacts nothing needs, and answer which ones went.
 *
 * Called by a launch, after it has decided what it is serving, because a launch
 * is the moment the store has just been switched and the only moment nothing is
 * reading out of it. Keeping the previous build is a promise to hold a second
 * copy of a frontend for ever unless something removes the third; this is that
 * something, and {@link artifactsToPrune} is the decision it acts on.
 *
 * **It cannot throw.** Removing old builds is housekeeping, and housekeeping
 * that stops a window from opening is a worse bug than a store that grew — a
 * store the launch could not read is a launch that carries on and serves.
 *
 * Assembly directories are deliberately left alone. `.<id>.incoming` is not an
 * artifact id and never appears here, and removing one would race a build that
 * is filling it: `cpSync` into a directory deleted underneath fails the build
 * that was working, to reclaim a directory the next build overwrites anyway.
 */
export function pruneArtifacts(cloneRoot: string, keep: readonly (string | null)[]): string[] {
  const removed: string[] = []
  try {
    const store = artifactStore(cloneRoot)
    const present = readdirSync(store, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => ({ id: entry.name, modified: statSync(join(store, entry.name)).mtimeMs }))

    for (const id of artifactsToPrune(present, keep)) {
      const path = artifactPath(cloneRoot, id)
      if (path === null) continue
      rmSync(path, { recursive: true, force: true })
      removed.push(id)
    }
  } catch {
    return removed
  }
  return removed
}
