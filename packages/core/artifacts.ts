/**
 * Where built frontends live, and which one the window is served from.
 *
 * This module is the **convention**: where an artifact goes, what an artifact
 * may be called, and which file records the choice — all of it as pure
 * functions over strings, so `packages/core/scripts/drive.ts` can assert every
 * one with nothing built and nothing serving.
 *
 * What a *request* may reach inside an artifact is deliberately not here. That
 * is `artifact-assets.ts`, and it is a boundary rather than a convention: this
 * file is what tickets 06 and 07 edit next, and a boundary sitting next to churn
 * is a boundary that gets moved by somebody who was doing something else.
 *
 * Nothing here is loaded by the application. It is imported by the artifact
 * server, by the build, and by the driver — the same arrangement
 * `dev-server.ts` has, and for the same reason: a launch path is only
 * observable by launching, unless the decisions inside it are lifted out.
 *
 * ## The layout
 *
 * ```
 * <clone>/.varnick/builds/            the store
 * <clone>/.varnick/builds/<id>/       one artifact, with index.html at its root
 * <clone>/.varnick/builds/served      one line: the id the window is served from
 * ```
 *
 * `.varnick/` because that is already what varnick's own per-clone machine
 * state is called — `.varnick/claude`, `.varnick/bin` and `.varnick/tmp` are
 * there — and because it is already gitignored. An artifact is a build of one
 * clone on one machine; it is not history and must never be committed.
 *
 * ## Why a directory per id and a file naming one
 *
 * Three later tickets need exactly this shape and no less:
 *
 *   * a pre-release is **written without being served** — which needs a second
 *     directory, so the artifact currently under the developer's window is not
 *     the one being replaced;
 *   * promoting one **switches which is served** — which needs the choice to be
 *     a fact on disk rather than a path baked into a launch;
 *   * a build that will not start **falls back to the previous one** — which
 *     needs the previous one still to exist, and needs "which one" to be
 *     rewritable by the host without a rebuild.
 *
 * A single `dist` directory answers none of the three. Symlinks would answer
 * all three and are worse to read: `cat served` says what is running, and a
 * developer looking at a broken window can fix it with a text editor.
 */

import { resolve } from 'node:path'

// ---------------------------------------------------------------------------
// Where
// ---------------------------------------------------------------------------

/** The store, relative to the clone that owns it. */
export const ARTIFACT_STORE_RELATIVE_PATH = '.varnick/builds'

/**
 * The file inside the store that names the artifact the window is served from.
 *
 * One line, one id, no JSON. It is read by a launch and written by a release,
 * and the two are in different languages at different times — the least that
 * can be got wrong between them is a string with a newline after it.
 *
 * Absent is a real answer and means *nothing is served*: a fresh clone has no
 * store at all, and the artifact server says so rather than guessing at a
 * directory it happens to find.
 */
export const SERVED_MARKER = 'served'

/**
 * What `bun run build` writes, and the only id varnick makes up for itself.
 *
 * A developer's own build of the tree in front of them. Release artifacts are
 * named for their version by whatever cuts them, which is why this is a literal
 * rather than a scheme: two things write into this store and only one of them
 * has a version to name a build after.
 */
export const LOCAL_ARTIFACT_ID = 'local'

/**
 * The file at an artifact's root — what a request for `/` is answered with, and
 * what having one is the test of whether an artifact is there at all.
 *
 * Read by `artifact-assets.ts` too, which is the one direction of dependency
 * between the two: the boundary asks the convention what a directory means, and
 * the convention never asks the boundary anything.
 */
export const ARTIFACT_ENTRY = 'index.html'

/** The store for a clone. */
export function artifactStore(cloneRoot: string): string {
  return resolve(cloneRoot, ARTIFACT_STORE_RELATIVE_PATH)
}

/** The file naming the served artifact, for a clone. */
export function servedMarkerPath(cloneRoot: string): string {
  return resolve(artifactStore(cloneRoot), SERVED_MARKER)
}

/**
 * Is this a bare artifact name, rather than a path, a flag, or nothing?
 *
 * Deliberately the same shape as `is_plain_worktree_name` in
 * `src-tauri/src/preview.rs`, and deliberately not shared with it: both answer
 * "may this string be one path component under a directory varnick owns", and
 * both are read by something that then joins it onto a root. An id arrives from
 * a file on disk that a release wrote, which is not agent input today and is
 * one feature away from being it — the release machinery is Core, and Core is
 * what an unattended run lands.
 *
 * `+` is allowed on top of the worktree rule, because a semantic version can
 * carry build metadata and an id is going to be a version.
 */
export function isArtifactId(id: string): boolean {
  return (
    id.length > 0 &&
    id.length <= 100 &&
    id !== '.' &&
    id !== '..' &&
    !id.startsWith('-') &&
    !id.startsWith('.') &&
    /^[A-Za-z0-9._+-]+$/.test(id)
  )
}

/**
 * Where one artifact lives, or `null` for a name that may not be one.
 *
 * The refusal is the point. This is the one function that turns a string read
 * off the disk into a directory something will serve files out of, so a name
 * that is not a name resolves to nothing rather than to a path above the store.
 */
export function artifactPath(cloneRoot: string, id: string): string | null {
  if (!isArtifactId(id)) return null
  return resolve(artifactStore(cloneRoot), id)
}

/**
 * Where an artifact is assembled before it becomes one.
 *
 * **An artifact appears whole or not at all.** Copying a build directly into
 * its final place leaves a window — measured in seconds for a frontend, longer
 * for anything bigger — in which the store holds half an artifact that `served`
 * may already be pointing at. A launch during that window opens on a page whose
 * script is not there yet, and the developer's way out of a window that will not
 * open is the window.
 *
 * So a build is copied here, and then renamed into place: a rename within one
 * directory is atomic, and the failure mode becomes a directory left behind
 * rather than a broken artifact.
 *
 * The leading dot is doing work. {@link isArtifactId} refuses a name that starts
 * with one, so an assembly directory can never be *served* however it is
 * reached — `served` naming it resolves to nothing. That is a property of the
 * name rather than a rule the writer has to keep.
 */
export function incomingArtifactPath(cloneRoot: string, id: string): string | null {
  if (!isArtifactId(id)) return null
  return resolve(artifactStore(cloneRoot), `.${id}.incoming`)
}

/**
 * The id a `served` file names, or `null` for nothing usable.
 *
 * Takes the file's whole contents rather than a line, because the caller's job
 * is to read a file and this one's is to decide what it said. `undefined` is
 * the file not being there, which is the ordinary state of a clone nobody has
 * built yet.
 *
 * A file that says something that is not an id answers `null` rather than
 * throwing: the honest reading of a marker nobody can parse is that nothing is
 * served, and the server has a page for that.
 */
export function servedArtifactId(marker: string | undefined | null): string | null {
  if (marker === undefined || marker === null) return null
  const first = marker.split('\n')[0]?.trim() ?? ''
  return isArtifactId(first) ? first : null
}

/** What to write into {@link SERVED_MARKER} for an id. */
export function servedMarkerText(id: string): string {
  return `${id}\n`
}
