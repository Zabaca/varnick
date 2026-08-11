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

import { writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { LOCAL_ARTIFACT_ID, servedMarkerPath, servedMarkerText } from '../artifacts.ts'
import { installArtifact } from '../artifact-store.ts'
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

/*
  One call, and the sequence behind it is `installArtifact` in
  `packages/core/artifact-store.ts` rather than four lines here.

  That placement is the point. A release writes an artifact too and has no
  reason to open this file, so a copy of the sequence written over there would
  be a copy with the `dereference` left off — and nothing would notice, because
  what it costs is a symlink inside an artifact putting a path outside it behind
  a URL. One implementation, beside the paths it uses.
*/
const artifact = installArtifact(buildRoot, LOCAL_ARTIFACT_ID, join(buildRoot, 'packages/core/dist'))

/*
  Last, and separately, because writing an artifact and choosing to serve it are
  two acts. `installArtifact` deliberately does not do this: a release performs
  only the first half, and the window a developer left open must not move
  because something was built. `bun run build` is the case where switching is
  exactly what was asked for.
*/
writeFileSync(servedMarkerPath(buildRoot), servedMarkerText(LOCAL_ARTIFACT_ID))

console.log(`artifact ${LOCAL_ARTIFACT_ID} written to ${artifact} and served`)
