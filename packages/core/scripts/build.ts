/**
 * Build the frontend and put it where the window is served from.
 *
 * `bun run build`. Two steps, and the second is the one that is new: Vite
 * writes `packages/core/dist` as it always has, and that directory is then
 * installed into this clone's artifact store as {@link LOCAL_ARTIFACT_ID} and
 * pointed at.
 *
 * **Why a copy rather than serving `dist` directly.** `dist` is one directory
 * and there has to be more than one. A pre-release is written without being
 * served, promotion switches which is served, and a build that will not start
 * falls back to the one before it — none of which is expressible while the
 * served path is a constant. See `packages/core/artifacts.ts` for the layout
 * and docs/adr/0020-the-main-window-serves-a-built-artifact.md for the
 * argument.
 *
 * This one **does** switch what is served, unlike the release that comes later:
 * a developer who typed `bun run build` asked for this tree, now. A pre-release
 * is the opposite case — it is cut while somebody is asleep and must not move
 * the ground under the window they left open.
 */

import { cpSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath, URL } from 'node:url'
import {
  LOCAL_ARTIFACT_ID,
  artifactPath,
  artifactStore,
  servedMarkerPath,
  servedMarkerText,
} from '../artifacts.ts'

const buildRoot = fileURLToPath(new URL('../../..', import.meta.url)).replace(/\/$/, '')

const built = Bun.spawn(['bun', 'run', '--filter', '@varnick/core', 'build'], {
  cwd: buildRoot,
  stdio: ['inherit', 'inherit', 'inherit'],
})
const code = await built.exited
if (code !== 0) {
  /*
    A failed build leaves the store exactly as it was, which means the window
    goes on being served whatever it was being served. That is the whole reason
    the install is a separate step from the compile: half an artifact in the
    store is a window that will not open, and the developer's way out of that
    is the window.
  */
  console.error('vite build failed — the artifact store is unchanged')
  process.exit(code)
}

const dist = join(buildRoot, 'packages/core/dist')
const artifact = artifactPath(buildRoot, LOCAL_ARTIFACT_ID)
if (artifact === null) throw new Error(`${LOCAL_ARTIFACT_ID} is not a usable artifact id`)

// Replaced rather than merged. A stale file from a previous build is a file
// nothing in this one produced, and an artifact is meant to be exactly what a
// build wrote.
rmSync(artifact, { recursive: true, force: true })
mkdirSync(artifactStore(buildRoot), { recursive: true })
cpSync(dist, artifact, { recursive: true })

writeFileSync(servedMarkerPath(buildRoot), servedMarkerText(LOCAL_ARTIFACT_ID))

console.log(`artifact ${LOCAL_ARTIFACT_ID} written to ${artifact} and served`)
