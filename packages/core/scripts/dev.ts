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

import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath, URL } from 'node:url'
import {
  CARGO_TARGET_ENV_VAR,
  DEV_PORT_ENV_VAR,
  DEV_URL_ENV_VAR,
  INSTALL_MARKER,
  bootstrapCommand,
  chosenDevPort,
  devLaunch,
  sharedTargetDir,
} from '../dev-server.ts'

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

/*
  A tree git just created has no `node_modules`, and one of the things not in it
  is the Tauri CLI the next line runs.

  This is where a Worktree's `bun install` happens — the decision, not a
  discovery at launch. It is conditional, so `bun tauri dev` in an installed
  checkout pays nothing; see `bootstrapCommand` for why it is the launcher's job
  rather than the Rust host's, and for what running `postinstall` out of an
  unmerged tree does and does not cost.

  A failed install ends the launch rather than falling through to a Tauri CLI
  that is not there, because the second failure names a missing binary and this
  one names the install.
*/
const bootstrap = bootstrapCommand(existsSync(join(cloneRoot, INSTALL_MARKER)))
if (bootstrap !== null) {
  console.log(`installing ${cloneRoot} — a fresh worktree has no ${INSTALL_MARKER}`)
  const installing = Bun.spawn([...bootstrap], {
    cwd: cloneRoot,
    stdio: ['inherit', 'inherit', 'inherit'],
  })
  const code = await installing.exited
  if (code !== 0) {
    console.error(`\`${bootstrap.join(' ')}\` failed in ${cloneRoot}, so varnick was not started.`)
    process.exit(code)
  }
}

/*
  And where cargo builds, for a Worktree.

  Same class of decision as the `bun install` above and made in the same place:
  a tree git just created has an empty `src-tauri/target`, and the first Preview
  of one compiled 348 crates while the developer waited — after approving the
  Fence dialog, which is the worst possible moment for a four-minute wall.

  `sharedTargetDir` is where the reasoning lives, including why sharing a build
  directory with the live tree is not a boundary question. It answers null for
  the live tree and for a developer who set the variable themselves.
*/
const target = sharedTargetDir(cloneRoot, process.env[CARGO_TARGET_ENV_VAR])
if (target !== null) {
  console.log(`building into ${target} — a fresh worktree has no target directory`)
}

const child = Bun.spawn(['bun', ...launch.args, ...passThrough], {
  cwd: cloneRoot,
  env: {
    ...process.env,
    ...launch.env,
    ...(target === null ? {} : { [CARGO_TARGET_ENV_VAR]: target }),
  },
  stdio: ['inherit', 'inherit', 'inherit'],
})

process.exit(await child.exited)
