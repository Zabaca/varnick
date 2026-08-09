// Surfaces, as files. No framework, no XState, no React, no filesystem.
//
// Discovery and loading are written here as functions over a record of module
// path to importer, and the record is supplied by the caller. In the app that
// record is Vite's filesystem scan (see actors/surface-loader.ts); in drive.ts it is
// a literal, which is the only way to test "a module that does not compile"
// without committing one — a broken module in the tree would fail the build,
// and the build failing is the outcome ADR-0004 exists to prevent.

import type { SurfaceDescriptor } from './domain.ts'

/**
 * Where Surfaces live, relative to a clone root.
 *
 * *Which* root is not this module's to say and never was — this half takes the
 * scan as an argument. It matters more than it used to: since ticket 28 the
 * clone the agent works in is chosen at launch, and the record of Surfaces this
 * path is joined onto is Vite's, produced at transform time from the root
 * varnick was **built** from. Those are the same directory under `bun tauri
 * dev` and need not be. See actors/surface-loader.ts, which is where the scan
 * comes from and where that limit is stated, and
 * docs/adr/0012-the-clone-root-is-an-input.md.
 */
export const SURFACES_DIR = 'packages/userspace/surfaces'

/**
 * The file inside a Surface directory that Core imports.
 *
 * One name, fixed, because the alternative is configuration — and a Surface
 * that has to be configured is a Surface that has to be registered somewhere,
 * which is the thing ADR-0002 rules out. A directory with this file in it is a
 * Surface; a directory without one is not.
 */
export const SURFACE_ENTRY = 'index.tsx'

/**
 * A Surface's component, structurally.
 *
 * Deliberately not `ComponentType`: this module is the pure half and stays free
 * of React so drive.ts can run it. The view layer casts once, where React
 * already is.
 */
export type SurfaceView = (...args: never[]) => unknown

/** What `import()` gives back — anything, until it has been checked. */
export type SurfaceImporter = () => Promise<unknown>

/**
 * The host substituting secret values while a Userspace module runs (ADR-0006).
 *
 * A port, declared here and implemented nowhere in Core — `hostSecretResolution`
 * in packages/harness/src/secret-resolution.ts is the implementation, and it
 * imports the filesystem and the keychain, neither of which belongs in this
 * file. Declaring the shape rather than importing it is the same move the
 * machines make with their actors (ADR-0001), and for the same reason: it is
 * what lets this half be run headlessly.
 *
 * Two members, and what is absent from them is the point. There is no way to ask
 * a resolution what it holds — `around` takes code and gives back what that code
 * returned, `redact` takes text and gives back less of it. A loader holding one
 * still holds no secret.
 */
export interface SecretResolution {
  /** Run `work` with every stored secret readable as `process.env.NAME`. */
  around<T>(work: () => T | Promise<T>): Promise<T>
  /** The text with every stored secret value replaced by `[redacted]`. */
  redact(text: string): string
}

/** Everything discovery found: what to show, and how to load each one. */
export interface DiscoveredSurfaces {
  readonly descriptors: SurfaceDescriptor[]
  /** Keyed by `descriptor.modulePath`, so a failure names a file you can open. */
  readonly importers: Record<string, SurfaceImporter>
}

/** The clone-relative path of a Surface's entry file. */
export function surfacePathOf(id: string): string {
  return `${SURFACES_DIR}/${id}/${SURFACE_ENTRY}`
}

/**
 * The Surface a module path belongs to, or null if it is not one.
 *
 * The id is the directory name and nothing else. A README beside the Surfaces,
 * a helper file inside one, a stray `.tsx` at the top level — none of them is a
 * Surface, and each is an ordinary thing for the agent to have written.
 */
export function surfaceIdOf(modulePath: string): string | null {
  const parts = modulePath.split('/')
  if (parts.pop() !== SURFACE_ENTRY) return null
  const id = parts.pop()
  if (id === undefined || id === '' || id.startsWith('.')) return null
  return id
}

/**
 * `recent-notes` → `Recent notes`.
 *
 * Derived rather than declared. A `name` field in the module would have to be
 * read before the module loads, which is exactly the order the loader cannot
 * work in — a Surface that fails to compile still has to appear, named, with
 * its error under it.
 */
export function surfaceNameOf(id: string): string {
  const words = id.replace(/[-_]+/g, ' ').trim()
  return words.charAt(0).toUpperCase() + words.slice(1)
}

/**
 * Turn a filesystem scan into Surfaces.
 *
 * This is the whole of discovery. Adding a Surface is creating a file: nothing
 * is appended to a list, because the list would have to live in Core and the
 * agent cannot write Core (ADR-0002). Sorted by id so a window's Surfaces do
 * not reorder between runs for reasons nobody chose.
 */
export function discoverFrom(modules: Record<string, SurfaceImporter>): DiscoveredSurfaces {
  const descriptors: SurfaceDescriptor[] = []
  const importers: Record<string, SurfaceImporter> = {}

  for (const key of Object.keys(modules).sort()) {
    const id = surfaceIdOf(key)
    if (id === null || importers[surfacePathOf(id)]) continue
    const modulePath = surfacePathOf(id)
    descriptors.push({ id, name: surfaceNameOf(id), modulePath })
    importers[modulePath] = modules[key]!
  }

  descriptors.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
  return { descriptors, importers }
}

const reasonFor = (error: unknown) =>
  error instanceof Error ? error.message : String(error)

/**
 * Load one Surface module.
 *
 * The dynamic `import()` inside a try/catch that ADR-0004 asks for, with the
 * catch turning every way this can go wrong into a sentence the failed Surface
 * can show. Three of them, and they are told apart on purpose: a module that
 * did not compile, a module that compiled and exports nothing to render, and a
 * descriptor whose file is not there.
 *
 * Nothing is remembered between calls, which is what makes `RETRY` mean
 * something: a module fixed while varnick is running loads on the next attempt,
 * without a relaunch. The conversation that broke the Surface is the one that
 * fixes it, so requiring a relaunch would throw away the fix along with the
 * failure.
 *
 * ## Where a secret name becomes a value
 *
 * `resolution` is the seam ADR-0006 needs, and this is the only place it can
 * be: the agent writes `process.env.STRIPE_KEY` into a module, and the one
 * moment that name has to mean something is the moment the module is evaluated.
 * `await load()` *is* that evaluation, so the window is exactly this call and
 * shuts on the way out — a module reads what it needs at module scope, which is
 * where an integration puts `const key = process.env.STRIPE_KEY` anyway.
 *
 * Optional, and the caller that leaves it out is not being careless. Resolution
 * needs a host process — see `hostSecretResolution` — and the renderer is not
 * one; `actors/surface-loader.ts` says what follows from that.
 *
 * The catch redacts through it too. A client that rejects a request quotes what
 * it rejected, and that sentence becomes the failed Surface's message and then a
 * line in the transcript. Redacting where the sentence is *built* means no
 * caller has to remember to.
 */
export async function importSurface(
  modulePath: string,
  importers: Record<string, SurfaceImporter>,
  resolution?: SecretResolution,
): Promise<SurfaceView> {
  const load = importers[modulePath]
  if (load === undefined) {
    throw new Error(
      `No module at ${modulePath}. Surfaces are discovered from the filesystem — create ${SURFACES_DIR}/<name>/${SURFACE_ENTRY} and it appears.`,
    )
  }

  let module: unknown
  try {
    module = resolution === undefined ? await load() : await resolution.around(load)
  } catch (error) {
    const said = reasonFor(error)
    throw new Error(
      `${modulePath} did not load — ${resolution === undefined ? said : resolution.redact(said)}`,
    )
  }

  const view = (module as { default?: unknown } | null | undefined)?.default
  if (typeof view !== 'function') {
    throw new Error(
      `${modulePath} loaded but has no default export to render. A Surface default-exports a component.`,
    )
  }
  return view as SurfaceView
}
