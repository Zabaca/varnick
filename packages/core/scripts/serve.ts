/**
 * What puts a frontend behind varnick's window. `tauri.conf.json`'s
 * `beforeDevCommand` is this file.
 *
 * It used to be the Vite dev server, unconditionally. Now there are two answers
 * and one line decides between them — {@link windowSource} in
 * `packages/core/dev-server.ts`:
 *
 *   * the **live tree** is served a built artifact out of `.varnick/builds/`,
 *     as files, with nothing watching the frontend — `tauri dev`'s own watcher
 *     on `src-tauri/**` is untouched and is the one exception, named in
 *     ADR-0020;
 *   * a **Worktree** — a Preview — runs the Vite dev server exactly as before,
 *     `core-reloads` plugin and all, because a Preview exists so a change can be
 *     used before it is merged and hot reloading is what makes that worth doing.
 *
 * See docs/adr/0020-the-main-window-serves-a-built-artifact.md for why, and
 * `packages/core/artifacts.ts` for the store's layout. Everything in this file
 * that could be wrong — which source, where the store is, what an id may be,
 * what a request path resolves to — is a pure function in one of those two
 * modules, asserted by `bun run drive` with nothing serving. This file is the
 * listener.
 */

import { existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { ARTIFACT_ENTRY, artifactPath, servedArtifactId, servedMarkerPath } from '../artifacts.ts'
import { assetPath } from '../artifact-assets.ts'
import {
  DEV_URL_ENV_VAR,
  cloneRootOfScript,
  portToBind,
  windowSource,
} from '../dev-server.ts'

/*
  The tree this frontend would come from, taken from where this file is rather
  than from `process.cwd()`. A Preview is launched in its Worktree and this file
  is the Worktree's copy, which is exactly what makes the one-line decision
  below work.
*/
const buildRoot = cloneRootOfScript(import.meta.url)

const port = portToBind(process.env[DEV_URL_ENV_VAR])

// ---------------------------------------------------------------------------
// A Worktree: the dev server, unchanged
// ---------------------------------------------------------------------------

if (windowSource(buildRoot) === 'dev-server') {
  console.log(`preview: vite on ${port} — ${buildRoot}`)
  /*
    The exact command `beforeDevCommand` used to be, spawned rather than
    reimplemented, so a Preview runs the dev server it always ran. Vite reads
    its own port back out of `VARNICK_DEV_URL`, which is already in this
    process's environment, so the child is handed the same one string both ends
    of a launch are handed and nothing here recomputes it.

    **This adds no layer to what the Tauri CLI has to take down.** That was
    checked rather than assumed, because it is the plausible way an indirection
    like this breaks something: a Vite left standing holds the port, and with
    `strictPort` on, the next launch of that Preview refuses outright rather
    than quietly moving. `bun run --filter` was *already* a wrapper around Vite,
    and a SIGTERM to it already left Vite running — measured, at this commit,
    against both arrangements, with the same result. So whatever the CLI does to
    end this command it did to the previous one, and forwarding signals here
    would reach `bun run` and not the Vite behind it. Nothing about the teardown
    is improved and nothing is made worse; it is left as it was found.
  */
  const vite = Bun.spawn(['bun', 'run', '--filter', '@varnick/core', 'dev'], {
    cwd: buildRoot,
    stdio: ['inherit', 'inherit', 'inherit'],
  })
  process.exit(await vite.exited)
}

// ---------------------------------------------------------------------------
// The live tree: a built artifact
// ---------------------------------------------------------------------------

/** The artifact `served` names, if it is there. */
function servedArtifact(): { id: string; root: string } | null {
  /*
    Read inside a try, because every way this can fail means the same thing and
    none of them may throw. `served` could be a directory, could be unreadable,
    could vanish between the check and the read — and a throw here happens
    before the listener binds, so the Tauri CLI waits on a port that never opens
    and the developer gets a terminal saying "waiting for your frontend dev
    server" with no window and no reason. Nothing served is a state this file
    has a page for; an unreadable marker is that state.
  */
  let marker: string | undefined
  try {
    marker = readFileSync(servedMarkerPath(buildRoot), 'utf-8')
  } catch {
    marker = undefined
  }

  const id = servedArtifactId(marker)
  if (id === null) return null
  const root = artifactPath(buildRoot, id)
  // A marker naming an artifact that is not there is *not* the same as no
  // marker, and it is reported as itself below rather than folded into one
  // "nothing to serve". Ticket 07 is what turns this case into a fall back to
  // the previous build; until then it is a sentence, not a guess.
  if (root === null || !existsSync(resolve(root, ARTIFACT_ENTRY))) return null
  return { id, root }
}

let artifact = servedArtifact()

if (artifact === null) {
  /*
    Nothing to serve, so build once.

    This is the fresh-clone path — `bun install && bun tauri dev` has to open a
    window, and a store nobody has written to is the ordinary state of a clone
    on its first launch. It is deliberately the *only* time a launch builds
    anything: a launch that rebuilt every time would undo a promoted release on
    the next restart, which is the one thing switching the served artifact is
    for.

    It writes `served`, because something that resolves to nothing is not a
    choice anybody made. Cutting a pre-release must not do that — see ticket 06,
    which writes an artifact and leaves this file alone.

    **Ticket 07 replaces this branch with a fall back to the previous build, and
    the sentence above is the one to carry across.** Falling back is a better
    answer than building for the case 07 is about — an artifact that will not
    start — but neither answer may become "rebuild on every launch", because
    that quietly undoes a promotion the developer made and presents as the build
    reverting on its own. Whatever replaces this must still leave a resolvable
    `served` alone.
  */
  console.log(`nothing is served from ${servedMarkerPath(buildRoot)} — building one`)
  const built = Bun.spawn(['bun', 'run', 'build'], {
    cwd: buildRoot,
    stdio: ['inherit', 'inherit', 'inherit'],
  })
  await built.exited
  artifact = servedArtifact()
}

/**
 * Anything going into that page as text rather than as markup.
 *
 * There is exactly one interpolation — a filesystem path — and a path may
 * contain `<`, `&` or a quote. This is a file whose entire job is serving, so
 * an unescaped interpolation is not a thing to leave in it whatever today's
 * value happens to be.
 */
const asText = (value: string): string =>
  value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')

/**
 * What the window gets when there is no artifact behind it.
 *
 * A page rather than a refusal, and a listener that answers rather than one
 * that never binds. `tauri dev` waits for this port before it opens anything,
 * so a launch that failed to build would otherwise be a terminal printing
 * "waiting for your frontend dev server" for ever, with no window and no
 * reason given.
 *
 * `200` and not a `503`, for that same reason and against the semantics: the
 * Tauri CLI's wait is the only thing that reads this status, and a window that
 * opens saying what to run beats a correct status code nobody sees.
 *
 * **It is drawn to DESIGN.md, and the reflex to exempt it is wrong.** This
 * renders in varnick's own window and is the first thing a developer sees when
 * a build is missing, which makes it more of a product surface than most —
 * DESIGN.md enumerates its exceptions and a pre-boot page is not among them. So
 * 13px and no larger (The Quiet Chrome Rule), square corners (The Square Corner
 * Rule), and `ground`/`fg`/`fg-dim`/`rule`/`accent` rather than the browser's
 * white (The Inherited Palette Rule).
 *
 * The values are inlined rather than imported, and that is the one concession:
 * this page exists precisely when there is no bundle to take `app.css` from. It
 * is the only copy of those tokens in the repository, and it is here because the
 * alternative is a page that cannot be styled at all.
 */
const nothingServed = (): Response =>
  new Response(
    `<!doctype html><meta charset="utf-8"><title>varnick — no build</title>
<style>
  :root {
    --ground: #1a1b26;
    --rule: #2c2e40;
    --fg: #c0caf5;
    --fg-dim: #8b8fa3;
    --accent: #7dcfff;
  }
  body {
    margin: 0;
    padding: 16px 24px;
    background: var(--ground);
    color: var(--fg);
    font-family: ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 13px;
    line-height: 1.6;
  }
  h1 { font-size: 13px; font-weight: 400; margin: 0 0 16px; color: var(--fg) }
  p { max-width: 110ch; margin: 0 0 12px; color: var(--fg-dim) }
  code { color: var(--accent) }
  pre {
    max-width: 110ch;
    margin: 0 0 12px;
    padding: 6px 12px;
    border: 1px solid var(--rule);
    color: var(--fg);
    overflow-x: auto;
  }
</style>
<h1>No build to serve</h1>
<p>varnick's window is served from a built artifact under
<code>.varnick/builds/</code>, and there is none in
<code>${asText(buildRoot)}</code> that <code>served</code> points at.</p>
<p>Build one:</p>
<pre><code>bun run build</code></pre>
<p>Then restart varnick. See
<code>docs/adr/0020-the-main-window-serves-a-built-artifact.md</code>.</p>`,
    { headers: { 'content-type': 'text/html;charset=utf-8' } },
  )

const serving = artifact

if (serving === null) {
  console.error(`no artifact to serve from ${buildRoot} — the window will say so`)
} else {
  console.log(`varnick on ${port} — artifact ${serving.id} from ${serving.root}`)
}

Bun.serve({
  port,
  // Localhost, and not `VARNICK_HOST`. The dev server takes that variable so a
  // phone on a tailnet can reach a *development* frontend; a built artifact is
  // what the developer's own window loads, and there is no second audience for
  // it to be worth putting on a network for.
  hostname: 'localhost',
  async fetch(request) {
    if (serving === null) return nothingServed()

    const path = assetPath(serving.root, new URL(request.url).pathname)
    // `null` is a request that resolved outside the artifact. Answered as
    // not-found rather than as forbidden: the distinction would tell whoever
    // asked that there is something there.
    if (path === null) return new Response('not found', { status: 404 })

    const file = Bun.file(path)
    if (!(await file.exists())) return new Response('not found', { status: 404 })

    /*
      Never cached. Vite hashes every asset filename, so the only file this
      matters for is index.html — and that one is the whole of what changes
      when the served artifact is switched underneath a restart. A webview
      holding the previous one would be a promotion that appeared not to have
      happened.
    */
    return new Response(file, { headers: { 'cache-control': 'no-store' } })
  },
})
