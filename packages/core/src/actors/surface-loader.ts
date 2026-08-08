import type { ComponentType } from 'react'
import { discoverFrom, importSurface } from '../surfaces.ts'
import type { SurfaceDescriptor } from '../domain.ts'

/**
 * Where Core meets the filesystem.
 *
 * The only module in Core that knows Userspace exists, and it names it in a
 * glob rather than in an import. `import.meta.glob` is a filesystem scan Vite
 * performs at transform time and rewrites into a record of path to
 * `() => import(path)` — lazy, so every value is a *dynamic* import and this
 * file still statically imports nothing from Userspace (ADR-0004). A Surface
 * that does not compile therefore fails at its own `import()`, inside the
 * try/catch in surfaces.ts, rather than at bundle time with the chat in it.
 *
 * Adding a Surface is creating a file. There is no list here to append to, and
 * there could not be: the list would live in Core and the agent cannot write
 * Core (ADR-0002). Vite watches the pattern, so a directory created while
 * varnick is running is discovered on the next scan.
 *
 * Browser-only, and nothing under `scripts/` may import it: `import.meta.glob`
 * is a Vite construct and is `undefined` under bun. The half that can be tested
 * headlessly is in surfaces.ts, which is why that file takes the record as an
 * argument instead of reaching for one.
 */
const FOUND = discoverFrom(
  import.meta.glob('../../../userspace/surfaces/*/index.tsx') as Record<
    string,
    () => Promise<unknown>
  >,
)

/**
 * What loaded, by module path.
 *
 * The machine's `loadSurface` contract answers `{ ok: true }` — whether the
 * module loaded, which is the fact `surface.loaded` is about. The component
 * itself is not machine state and is not put in context: a React component in
 * machine context is a value nothing can compare, log, or serialise, and
 * ADR-0001 keeps the view layer out of the machines in the other direction for
 * the same reason. So the loader records it here and the view asks by path.
 * One import, one answer, and the view can never render a Surface the machine
 * did not load.
 */
const loaded = new Map<string, ComponentType>()

/** Every Surface on disk right now. */
export function discoverSurfaces(): SurfaceDescriptor[] {
  return FOUND.descriptors
}

/**
 * Load one Surface's module and keep what it exported.
 *
 * Throws with a sentence the failed Surface shows. Records nothing on failure,
 * so `RETRY` re-runs the import — see importSurface.
 *
 * ## No secret resolution here, and that is the decision rather than the gap
 *
 * `importSurface` takes a `SecretResolution` as its third argument and this call
 * does not supply one. There is nothing to supply: a resolution binds names into
 * a `process.env`, this module runs in a webview, and the only way a value could
 * get here is across the bridge — which ticket 15 closed in both directions, for
 * a reason that has held up. A renderer holding every secret the developer owns
 * is reachable over HTTP the moment `VARNICK_HOST` binds the dev server to
 * anything but localhost, and `vite.config.ts` documents doing exactly that.
 *
 * So resolution lives where the host runs Userspace code with a process around
 * it, and a Surface rendered in the window is not that. What a Surface can do
 * today is show what an integration produced; what it cannot do is hold the key
 * the integration used. That line is worth knowing before designing against it —
 * see the finding recorded on ticket 12.
 */
export async function loadUserspaceSurface(modulePath: string): Promise<void> {
  const view = await importSurface(modulePath, FOUND.importers)
  loaded.set(modulePath, view as ComponentType)
}

/** What a loaded Surface renders, or undefined if nothing has loaded it. */
export function loadedSurface(modulePath: string): ComponentType | undefined {
  return loaded.get(modulePath)
}
