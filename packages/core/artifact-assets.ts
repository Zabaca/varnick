/**
 * What a request may reach inside an **Artifact**.
 *
 * One function, and it is a boundary rather than a convention — which is why it
 * is not in `artifacts.ts`. That module says where builds live and what they may
 * be called, and tickets 06 and 07 will be editing it; this one decides what an
 * HTTP request is allowed to resolve to, and the reason to open it is never
 * "the release chain changed". Two unrelated reasons to edit one file is how a
 * boundary ends up moved by somebody who was doing something else.
 *
 * Nothing here is loaded by the application. It is imported by the artifact
 * server and by the driver.
 */

import { isAbsolute, relative, resolve } from 'node:path'
import { ARTIFACT_ENTRY } from './artifacts.ts'

/**
 * The file a request path asks for inside an artifact, or `null` for one that
 * asks for something outside it.
 *
 * **This is the whole of what stands between an HTTP request and the disk**,
 * and it is a pure function for exactly that reason: a traversal is a thing you
 * assert about, not a thing you find out about from a running server.
 *
 * The listener binds localhost, so the requests it sees come from the webview
 * — but the webview renders Userspace, which the agent writes freely, and a
 * Surface can issue any `fetch` it likes. A path that climbed out of the
 * artifact would be that Surface reading the developer's home directory over
 * HTTP, which is precisely what the Sandbox is for and precisely the sort of
 * hole a static file server is traditionally how you open.
 *
 * Decided by resolving and then asking whether the answer is still inside,
 * rather than by rejecting `..` in the input. The second is a filter and
 * filters are a list of things somebody thought of; this is the property.
 *
 * It resolves **lexically**, which is worth knowing because it is why the build
 * dereferences symlinks: a link inside an artifact would put a path outside it
 * behind a URL and nothing here could see that. The cheap place to keep an
 * artifact a tree of ordinary files is where the tree is written — see
 * `packages/core/scripts/build.ts` — rather than a `realpath` per request.
 */
export function assetPath(artifactRoot: string, urlPath: string): string | null {
  if (!urlPath.startsWith('/')) return null

  let decoded: string
  try {
    decoded = decodeURIComponent(urlPath)
  } catch {
    // Malformed percent-encoding. Not a path, and not worth guessing at.
    return null
  }

  // A NUL truncates the path for anything that reaches a syscall with it, which
  // is how a name that passed a check becomes a different name.
  if (decoded.includes('\0')) return null

  // A directory is its entry file. `/` is the window opening; `/thing/` is a
  // Surface asking for one, and neither is a file.
  const wanted = decoded.endsWith('/') ? `${decoded}${ARTIFACT_ENTRY}` : decoded

  const root = resolve(artifactRoot)
  const path = resolve(root, `.${wanted}`)
  const inside = relative(root, path)
  if (inside === '' || inside.startsWith('..') || isAbsolute(inside)) return null
  return path
}
