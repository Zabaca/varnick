/**
 * Where built frontends live, and which one the window is served from.
 *
 * This module is the **convention**: where an artifact goes, what an artifact
 * may be called, and which file records the choice. Every export is a total,
 * deterministic function over strings, it imports `node:path` and nothing else,
 * and `packages/core/scripts/drive.ts` asserts all of it with nothing built and
 * nothing serving.
 *
 * Two neighbours hold what this deliberately does not, and each is its own file
 * for its own reason:
 *
 *   * `artifact-store.ts` **writes** the store — one function, the only impure
 *     step in the set. Two callers write artifacts (`bun run build` today, a
 *     release next) and the sequence carries a `dereference` that is the whole
 *     of why a symlink in a build cannot put a path outside the artifact behind
 *     a URL, so it must exist once. It is there rather than here so that this
 *     file stays a thing you can reason about by reading it — the arrangement
 *     `dev-server.ts` has, and what ADR-0013 argues for.
 *   * `artifact-assets.ts` decides what a **request** may reach inside an
 *     artifact. That is a boundary rather than a convention, and this file is
 *     what tickets 06 and 07 edit next; a boundary sitting next to churn is one
 *     that gets moved by somebody who was doing something else.
 *
 * Both depend on this one and it depends on neither, which is what makes the
 * split hold rather than being three files by preference.
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
 * <clone>/.varnick/builds/previous    one line: the id it was served from before
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
 * The file naming the artifact the window was served from before this one.
 *
 * Same shape as {@link SERVED_MARKER} and written at the same moment, by
 * `switchServedArtifact` — which is the whole reason it can be trusted. "The
 * previous build" is not something a launch can work out from what it finds on
 * disk: modification times say when a directory was *written*, and an artifact
 * can be written weeks before anything serves it. So the fact is recorded by
 * whoever switches, in a second one-line file, and a launch reads it.
 *
 * Absent means there has never been a switch — a clone that has only ever
 * served one build has nothing to fall back to, and that is the honest answer
 * rather than a directory the store happens to still hold.
 */
export const PREVIOUS_MARKER = 'previous'

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

/** The file naming the artifact served before that one, for a clone. */
export function previousMarkerPath(cloneRoot: string): string {
  return resolve(artifactStore(cloneRoot), PREVIOUS_MARKER)
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
 * **Nothing ever observes half an artifact.** Copying a build directly into its
 * final place leaves a window — measured in seconds for a frontend, longer for
 * anything bigger — in which the store holds part of an artifact that `served`
 * may already be pointing at. A launch during that window opens on a page whose
 * script is not there yet, and the developer's way out of a window that will not
 * open is the window.
 *
 * So a build is copied here, and then renamed into place: a rename within one
 * directory is atomic, and the failure mode becomes a directory left behind
 * rather than a broken artifact. What remains is a moment where the id names
 * *nothing* — see {@link installArtifact}, which is where that window is argued.
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
 * The id a one-line marker names, or `null` for nothing usable.
 *
 * Both {@link SERVED_MARKER} and {@link PREVIOUS_MARKER} are read through this
 * — they are the same file format holding the same kind of answer, and it was
 * called `servedArtifactId` while there was only one of them. A marker is a
 * marker; which question it answers is the path it was read from.
 *
 * Takes the file's whole contents rather than a line, because the caller's job
 * is to read a file and this one's is to decide what it said. `undefined` is
 * the file not being there, which is the ordinary state of a clone nobody has
 * built yet.
 *
 * A file that says something that is not an id answers `null` rather than
 * throwing: the honest reading of a marker nobody can parse is that nothing is
 * named, and the server has a page for that.
 */
export function markedArtifactId(marker: string | undefined | null): string | null {
  if (marker === undefined || marker === null) return null
  const first = marker.split('\n')[0]?.trim() ?? ''
  return isArtifactId(first) ? first : null
}

/** What to write into a marker for an id. */
export function servedMarkerText(id: string): string {
  return `${id}\n`
}

// ---------------------------------------------------------------------------
// Which one to serve
// ---------------------------------------------------------------------------

/**
 * The `src` of every script an entry document loads out of its own artifact.
 *
 * This is what "the artifact will not start" is decided from, and it is a
 * parse rather than a guess for that reason. A Vite build writes exactly one
 * `<script type="module" src="/assets/index-HASH.js">` into `index.html`, and
 * an artifact whose `index.html` names a file the artifact does not contain is
 * a window that opens on nothing — certainly, before anything runs, with no
 * browser needed to find out.
 *
 * **Every judgement here is biased toward returning nothing**, and that is the
 * whole shape of the function. A source returned in error is a *false positive*
 * — the host falls back over a build the developer deliberately promoted, which
 * is worse than the failure the fallback exists to prevent. A source missed is
 * a fallback that does not happen, which leaves the developer exactly where
 * they were. The two errors are not symmetric, so neither is the parse.
 *
 * Which is why it is stricter than "find `src=`", in four ways that were each
 * found by trying them rather than reasoned about:
 *
 *   * **Comments are removed first.** varnick's own `index.html` ships a long
 *     design brief as an HTML comment and Vite keeps it in the built output, so
 *     a brief that ever quoted a `<script>` tag would have taken the window down
 *     to a fallback. A script inside a comment is not loaded by anything.
 *   * **`<noscript>` blocks are removed with them**, for the same reason one
 *     step on: its contents load precisely when scripts do not.
 *   * **Attributes are walked in order rather than searched for.** `src=` inside
 *     *another* attribute's quoted value is a value, not an attribute — a lazy
 *     search finds the impostor and misses the real one.
 *   * **The attribute is `src` and not something ending in it.** `data-src` and
 *     `x-src` are lazy-loading conventions, and a word boundary treats the
 *     hyphen as the start of a new word.
 *
 * Only sources this artifact could answer itself are returned. A scheme
 * (`https:`, `data:`) or a protocol-relative `//host/x` is somebody else's to
 * serve and its absence says nothing about this build; a query or a fragment is
 * dropped, because the file on disk is the part before them.
 *
 * **Scripts and not stylesheets.** A missing stylesheet is an artifact that is
 * also broken, and it is not one that fails to *start* — an unstyled varnick is
 * still a varnick a developer can fix things with, and falling back from one
 * would be the host overruling a build on a signal that is not the question
 * being asked.
 *
 * A known and accepted limit, stated rather than left to be found: a `<script>`
 * inside a `<template>` is not executed and is still returned. Recognising it
 * needs nesting, this is a regex, and Vite emits no templates into an entry
 * document. If one ever appears there, this is the function to teach about it.
 */
export function entryScriptSources(html: string): string[] {
  // Neither a comment nor a `<noscript>` body is loaded by a window that opens,
  // so neither can be a reason one did not.
  const loaded = html.replace(/<!--[\s\S]*?-->/g, '').replace(/<noscript\b[^>]*>[\s\S]*?<\/noscript\s*>/gi, '')

  const found: string[] = []
  for (const tag of loaded.matchAll(/<script\b([^>]*)>/gi)) {
    /*
      Attribute by attribute, in order. A quoted value is *consumed* as a value
      here, which is what stops `data-note="a src=/fake.js b"` from answering
      `/fake.js` — a search for `src=` reads that as an attribute, because it
      has no idea it is standing inside one.
    */
    const attributes = (tag[1] ?? '').matchAll(
      /([a-zA-Z_:][-a-zA-Z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]*)))?/g,
    )
    for (const attribute of attributes) {
      if ((attribute[1] ?? '').toLowerCase() !== 'src') continue

      const raw = (attribute[2] ?? attribute[3] ?? attribute[4] ?? '').trim()
      // The file is what comes before a query or a fragment; neither reaches disk.
      const source = raw.split(/[?#]/)[0] ?? ''
      if (source === '') continue
      // Somebody else's to serve, so its absence is not this artifact's failure.
      if (source.startsWith('//') || /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(source)) continue
      found.push(source)
    }
  }
  return found
}

/** What a launch does about the store it found. */
export type ServingOutcome =
  /** `served` names an artifact and it will start. The ordinary case. */
  | 'served'
  /** It will not start, and the one before it will. */
  | 'fell-back'
  /** Nothing has ever been served here, so build one. A fresh clone. */
  | 'build-one'
  /** `served` names something that will not start and there is nothing behind it. */
  | 'nothing-startable'

/** Which artifact a launch serves, and what it has to say about it. */
export interface ServingPlan {
  readonly outcome: ServingOutcome
  /** The artifact to serve, or `null` when there is none. */
  readonly serve: string | null
  /** The artifact `served` names, when that is not the one being served. */
  readonly failed: string | null
}

/**
 * Which artifact the window opens on, given what the store says and which
 * artifacts will start.
 *
 * **The decision, entire.** It is a pure function over two ids and a predicate
 * so that every branch of it is assertable with nothing built and nothing
 * serving — ADR-0013 — and because the branch it replaces was four lines of
 * launch script that could only be observed by launching.
 *
 * The four outcomes are four different things for the caller to do, which is
 * why they are four and not a boolean:
 *
 *   * **`served`** — serve it, say nothing beyond which one it is.
 *   * **`fell-back`** — serve `previous`, and say so loudly in both places a
 *     developer will be looking: the terminal and the window. `served` is left
 *     naming the artifact that failed, because rewriting it would erase the
 *     evidence and turn the next launch into a launch with no problem in it.
 *   * **`build-one`** — the fresh-clone path, and the *only* one that builds.
 *     `bun install && bun tauri dev` has to open a window.
 *   * **`nothing-startable`** — `served` names something that will not start
 *     and there is nothing behind it. This deliberately does **not** build.
 *
 * That last refusal is the constraint ADR-0020 wrote down and this function is
 * where it now lives: a launch that rebuilt whenever the served artifact was
 * unusable would quietly undo a promotion — the developer promoted a release,
 * it did not come up, and the next restart replaces it with a build of whatever
 * happens to be in the tree while `served` moves to `local`. That presents as
 * the build reverting on its own. Only a store with no choice recorded in it at
 * all is a store with nothing to undo.
 *
 * `previous === served` is not a fallback. It cannot happen through
 * {@link servedSwitch}, and if a hand-edited marker makes it happen, serving
 * the same broken artifact twice under a banner saying it was fallen back to is
 * worse than saying there is nothing.
 */
export function servingPlan(
  served: string | null,
  previous: string | null,
  startable: (id: string) => boolean,
): ServingPlan {
  if (served === null) return { outcome: 'build-one', serve: null, failed: null }
  if (startable(served)) return { outcome: 'served', serve: served, failed: null }
  if (previous !== null && previous !== served && startable(previous)) {
    return { outcome: 'fell-back', serve: previous, failed: served }
  }
  return { outcome: 'nothing-startable', serve: null, failed: served }
}

/**
 * What the two markers say after the window is switched onto `to`.
 *
 * One function because two things switch — `bun run build` today, a promotion
 * next — and "remember what was there" is exactly the step a second
 * implementation leaves out. It would leave it out silently: nothing is
 * different until the day a build does not start, which is the day the
 * remembering was for.
 *
 * Switching onto what is already served moves nothing. That is not a
 * degenerate case, it is the common one — `bun run build` writes `local` over
 * `local` all day — and recording `local` as its own previous would make the
 * fallback resolve to the artifact that just failed. An earlier `previous`
 * survives it, so a developer who promoted a release and then built over it
 * still has the release to fall back to.
 */
export function servedSwitch(
  served: string | null,
  previous: string | null,
  to: string,
): { readonly served: string; readonly previous: string | null } {
  if (to === served) return { served: to, previous }
  return { served: to, previous: served ?? previous }
}

// ---------------------------------------------------------------------------
// How many to keep
// ---------------------------------------------------------------------------

/**
 * How many artifacts the store holds before a launch starts removing them.
 *
 * Four, and the number is chosen against what has to fit rather than by taste:
 * the served build, the one behind it, a pre-release that has been cut and not
 * yet promoted, and one spare so that a night's work does not evict the release
 * the developer is running. A frontend build is tens of megabytes; a clone that
 * kept every one of them would grow for the life of the clone, which is the
 * cost this ticket's "keep the previous one" would otherwise sign up for
 * indefinitely.
 */
export const ARTIFACTS_KEPT = 4

/**
 * Which artifacts a launch removes, newest-first with the named ones spared.
 *
 * Recency is by modification time and it is the *only* thing time is used for
 * — which one is previous is a fact the store records rather than one a launch
 * infers. Here it is answering a different question, "which of these is nobody
 * likely to want", and for that it is the right instrument and the only one
 * available: an artifact nothing points at has no other order to it.
 *
 * **`keep` wins over the limit, always.** A pre-release cut last night is the
 * newest thing in the store and survives on recency; the served artifact and
 * the one behind it may be neither, and removing either is the whole failure
 * this function exists inside a ticket about preventing.
 *
 * Anything that is not an artifact id comes back out of the list, so a caller
 * handed a directory name off a disk can never be handed one to delete that the
 * store does not own. `null` entries in `keep` are the ordinary shape of "there
 * is no previous", passed straight through rather than filtered at the call
 * site.
 */
export function artifactsToPrune(
  present: readonly { readonly id: string; readonly modified: number }[],
  keep: readonly (string | null)[],
  limit: number = ARTIFACTS_KEPT,
): string[] {
  const spared = new Set(keep.filter((id): id is string => id !== null))
  const newestFirst = [...present]
    .filter((entry) => isArtifactId(entry.id))
    // Ties broken by id so two artifacts written in the same millisecond — one
    // `cp -r` of a store, one fast test — do not order differently per run.
    .sort((a, b) => b.modified - a.modified || a.id.localeCompare(b.id))

  return newestFirst
    .slice(Math.max(limit, 0))
    .map((entry) => entry.id)
    .filter((id) => !spared.has(id))
}
