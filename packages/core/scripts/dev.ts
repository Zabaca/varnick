/**
 * Start varnick on a chosen port, so a second one can run beside the first.
 *
 *     bun run dev:app                    # the same as `bun tauri dev`
 *     bun run dev:app --port 1421        # a second varnick
 *     VARNICK_DEV_PORT=1421 bun run dev:app
 *
 * `bun tauri dev` is untouched and stays the path everyone uses: with no port
 * chosen this spawns exactly that, with an overlay that sets `devUrl` to what
 * `tauri.conf.json` already says.
 *
 * There is almost nothing here on purpose. Everything that could be wrong — the
 * port, the URL, the overlay, and the fact that the window and the frontend are
 * told the same thing — is `packages/core/dev-server.ts`, which
 * `bun run drive` asserts without spawning anything. This file is the spawn.
 *
 * A Worktree's varnick is started this way too. The clone root is the tree this
 * file is in, so running it out of `.claude/worktrees/x` runs that Worktree's
 * varnick — see docs/adr/0014-core-is-authored-in-a-worktree.md.
 */

import { fileURLToPath, URL } from 'node:url'
import { DEV_PORT_ENV_VAR, DEV_URL_ENV_VAR, chosenDevPort, devLaunch } from '../dev-server.ts'

const argv = process.argv.slice(2)
const flag = argv.indexOf('--port')
const asked = flag === -1 ? process.env[DEV_PORT_ENV_VAR] : argv[flag + 1]
const passThrough = flag === -1 ? argv : [...argv.slice(0, flag), ...argv.slice(flag + 2)]

let port: number
try {
  port = chosenDevPort(asked)
} catch (error) {
  // The refusal is the whole value of this path — a bad port that quietly
  // became 1420 would collide with the varnick already running. A stack trace
  // over the top of it helps nobody.
  console.error(error instanceof Error ? error.message : String(error))
  process.exit(1)
}

const launch = devLaunch(port)
const cloneRoot = fileURLToPath(new URL('../../..', import.meta.url)).replace(/\/$/, '')

console.log(`varnick on ${launch.env[DEV_URL_ENV_VAR]} — clone ${cloneRoot}`)

const child = Bun.spawn(['bun', ...launch.args, ...passThrough], {
  cwd: cloneRoot,
  env: { ...process.env, ...launch.env },
  stdio: ['inherit', 'inherit', 'inherit'],
})

process.exit(await child.exited)
