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

import { cpSync, mkdirSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  LOCAL_ARTIFACT_ID,
  artifactPath,
  artifactStore,
  incomingArtifactPath,
  servedMarkerPath,
  servedMarkerText,
} from '../artifacts.ts'
import { cloneRootOfScript } from '../dev-server.ts'

const buildRoot = cloneRootOfScript(import.meta.url)

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
const incoming = incomingArtifactPath(buildRoot, LOCAL_ARTIFACT_ID)
if (artifact === null || incoming === null) {
  throw new Error(`${LOCAL_ARTIFACT_ID} is not a usable artifact id`)
}

mkdirSync(artifactStore(buildRoot), { recursive: true })

/*
  Assembled beside its final place and renamed into it, so an artifact appears
  whole or not at all — see `incomingArtifactPath`. A copy straight into the
  served directory leaves a window in which the store holds half a build that
  `served` already points at, and a launch inside that window opens on a page
  whose script is not there.

  `dereference` so what lands is a tree of ordinary files. Vite's output has no
  symlinks in it today; an artifact that did would put a path outside itself
  behind a URL, which `assetPath` cannot see because it resolves lexically. The
  cheap place to close that is here, where the tree is written, rather than in
  the request path where it would cost a `realpath` per file.
*/
rmSync(incoming, { recursive: true, force: true })
cpSync(dist, incoming, { recursive: true, dereference: true })
rmSync(artifact, { recursive: true, force: true })
renameSync(incoming, artifact)

// Last, and only once the artifact is whole: this is the line that points a
// window at it.
writeFileSync(servedMarkerPath(buildRoot), servedMarkerText(LOCAL_ARTIFACT_ID))

console.log(`artifact ${LOCAL_ARTIFACT_ID} written to ${artifact} and served`)
