import { defineConfig, type Plugin } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath, URL } from 'node:url'
import { DEV_URL_ENV_VAR, hotUpdateVerdict, portToBind } from './dev-server.ts'
import { VERSION_MODULE_ID, VERSION_MODULE_RESOLVED, versionModuleSource } from './version.ts'

/*
  The clone this dev server is serving. Not `process.cwd()` — a Preview is a
  varnick launched from a Worktree (ADR-0014), and the Worktree's Core is what
  its own window reloads on.
*/
const cloneRoot = fileURLToPath(new URL('../..', import.meta.url))

/*
  The one impure line of the version's resolution: read the manifest of the
  clone being served or built, once, here, while there is still a filesystem.
  Everything it decides is `version.ts`, so `bun run drive` can assert it — and
  `drive.ts` also starts one of these servers and fetches from it, because that
  is the half a pure function cannot cover.

  At config load, which is the only place a read of this can be honest. `load`
  looks like the better home for it and is not: Vite caches a virtual module in
  the graph and nothing here invalidates it, so a read in there runs exactly
  once anyway — measured, by counting — and reading per-`load` would only mean
  claiming a freshness the module graph does not provide. One read is also what
  the change wants. Each Preview and each `bun run dev` is a fresh process, so
  "the version at launch" is the version for the life of that window, and a
  release that bumps the manifest produces a new build rather than mutating one
  that is already running.

  Failing here rather than later is the second half of that. `versionModuleSource`
  throws rather than defaulting, and at config load a throw stops `vite build`
  and `vite serve` alike — before a server binds a port, rather than at the
  first request for one module. A clone with no root manifest, or one whose
  manifest has no version, does not start.

  Deliberately not `define`. See the header of `version.ts`: under Vite 8 a user
  `define` never reaches a dev server's client environment, so that version of
  this served the renderer a bare identifier and the window came up blank.
*/
const versionSource = versionModuleSource(readFileSync(join(cloneRoot, 'package.json'), 'utf-8'))

/** The version the window shows, as the one module the renderer imports for it. */
const versionModule = (): Plugin => ({
  name: 'varnick:version',
  resolveId: (id) => (id === VERSION_MODULE_ID ? VERSION_MODULE_RESOLVED : undefined),
  load: (id) => (id === VERSION_MODULE_RESOLVED ? versionSource : undefined),
})

/**
 * Core is excluded from hot-swap: a change under `packages/core/**` reloads the
 * window rather than swapping a module.
 *
 * ADR-0005 required an explicit restart after a Core merge, because
 * hot-swapping the module that owns the Session remounts the machine holding
 * the conversation that asked for the change. ADR-0014 makes that mechanical
 * rather than a rule someone has to remember. The reload is safe because the
 * Session is durable host-side and resumes from the mirror (ADR-0009), so it
 * costs a moment and loses nothing.
 *
 * Userspace is untouched and must stay that way — "ask for a Surface and it
 * appears" is a hot update, and it is the product's main loop.
 *
 * The decision is not made here. It is {@link hotUpdateVerdict}, a pure
 * function over a path, so `bun run drive` can assert it with no dev server and
 * no browser; this hook is the one line that acts on it.
 */
const coreReloadsRatherThanSwaps = (): Plugin => ({
  name: 'varnick:core-reloads',
  handleHotUpdate(ctx) {
    if (hotUpdateVerdict(ctx.file, cloneRoot) === 'hot-swap') return

    ctx.server.hot.send({ type: 'full-reload' })
    // An empty list rather than the modules Vite found: returning them would
    // send the full reload *and* swap the modules underneath it.
    return []
  },
})

// Userspace is aliased but never statically imported from Core — see
// docs/adr/0004-core-never-statically-imports-userspace.md. Surfaces are
// discovered and loaded with dynamic import() so a broken one cannot take
// the chat down with it.
export default defineConfig({
  plugins: [react(), tailwindcss(), coreReloadsRatherThanSwaps(), versionModule()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
      '@userspace': fileURLToPath(new URL('../userspace', import.meta.url)),
    },
  },
  server: {
    /*
      Localhost by default. Set VARNICK_HOST to bind elsewhere:

        VARNICK_HOST=$(tailscale ip -4) bun run dev   # tailnet only
        VARNICK_HOST=0.0.0.0            bun run dev   # tailnet AND local wifi

      Prefer the first. 0.0.0.0 puts a dev server holding an agent session on
      every network the machine is attached to, including whatever coffee-shop
      wifi it joins next.
    */
    host: process.env.VARNICK_HOST ?? 'localhost',
    /*
      1420 unless the launcher said otherwise, and it says so by handing over
      the whole URL the window is already pointed at rather than a number this
      end could get wrong. `scripts/dev.ts` writes both from one value; see
      packages/core/dev-server.ts.
    */
    port: portToBind(process.env[DEV_URL_ENV_VAR]),
    /*
      strictPort is what makes "the port the dev server bound" the same fact as
      "the port it was configured with". Without it Vite steps to the next free
      port when 1420 is taken — which is exactly the case a second varnick
      creates — and the window would then be pointed at the first one's
      frontend.
    */
    strictPort: true,
    /*
      Vite rejects requests whose Host header it does not recognise, which is a
      DNS-rebinding protection worth keeping. A leading dot allows the subdomains
      of one suffix, so MagicDNS names resolve without opening it up generally.
    */
    allowedHosts: ['.ts.net'],
  },
})
