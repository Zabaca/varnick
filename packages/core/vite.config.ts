import { defineConfig, type Plugin } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { fileURLToPath, URL } from 'node:url'
import { DEV_URL_ENV_VAR, hotUpdateVerdict, portToBind } from './dev-server.ts'

/*
  The clone this dev server is serving. Not `process.cwd()` — a Preview is a
  varnick launched from a Worktree (ADR-0014), and the Worktree's Core is what
  its own window reloads on.
*/
const cloneRoot = fileURLToPath(new URL('../..', import.meta.url))

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
 *
 * **This runs where there is a dev server, which is no longer everywhere.** The
 * live tree's window is served from a built artifact and watches nothing, so
 * the two places this hook fires are a Preview and `bun run dev` in a browser.
 * The verdict is unchanged; what changed is what asks it. See
 * docs/adr/0020-the-main-window-serves-a-built-artifact.md.
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
  plugins: [react(), tailwindcss(), coreReloadsRatherThanSwaps()],
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
