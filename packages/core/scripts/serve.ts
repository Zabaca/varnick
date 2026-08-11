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
 * The live tree's half has a second decision in it: **which** artifact. The
 * store records the build the window opens on and the one it opened on before
 * that, and a build that will not start is served the previous one instead,
 * with the window saying so. That is ADR-0004's argument one level out — a
 * broken Userspace module must not leave a window with no chat, and a broken
 * build must not leave a developer with no varnick to fix it in.
 *
 * See docs/adr/0020-the-main-window-serves-a-built-artifact.md for why, and
 * `packages/core/artifacts.ts` for the store's layout. Everything in this file
 * that could be wrong — which source, where the store is, what an id may be,
 * what a request path resolves to, which artifact to serve and whether that is
 * a fall back — is a pure function in one of those two modules, asserted by
 * `bun run drive` with nothing serving. This file is the listener.
 */

import { resolve } from 'node:path'
import { ARTIFACT_ENTRY, artifactPath, servedMarkerPath, servingPlan } from '../artifacts.ts'
import { assetPath } from '../artifact-assets.ts'
import {
  artifactStartFailure,
  pruneArtifacts,
  readServedMarkers,
} from '../artifact-store.ts'
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

/*
  What the store says, read once. Two one-line files: the artifact the window
  opens on, and the one it opened on before that. Neither read can throw — see
  `readServedMarkers` — because both happen before the listener binds, and an
  exception there is the Tauri CLI waiting for ever on a port nothing opened.
*/
const markers = readServedMarkers(buildRoot)

/*
  Why each artifact this launch considered will not start, by id.

  Rewritten rather than accumulated, so that an id which failed before a build
  and starts after one does not carry the stale sentence into the banner. The
  reason is wanted in two places — the terminal and, when it is a fall back, the
  window — and it is produced once, here, where the disk was actually read.
*/
const failures = new Map<string, string>()

/** Will this artifact open a window? See `artifactStartFailure` for what that means. */
function startable(id: string): boolean {
  const root = artifactPath(buildRoot, id)
  const failure = root === null ? 'it is not a usable artifact id' : artifactStartFailure(root)
  if (failure === null) {
    failures.delete(id)
    return true
  }
  failures.set(id, failure)
  return false
}

let plan = servingPlan(markers.served, markers.previous, startable)

if (plan.outcome === 'build-one') {
  /*
    Nothing has ever been served here, so build once.

    This is the fresh-clone path — `bun install && bun tauri dev` has to open a
    window, and a store nobody has written to is the ordinary state of a clone
    on its first launch. It remains the *only* time a launch builds anything,
    and that is the sentence carried across from the branch this replaced: a
    launch that rebuilt whenever it could not serve would undo a promoted
    release on the next restart, which is the one thing switching the served
    artifact is for.

    `served` naming an artifact that will not start is now a fall back and not a
    build, and the two outcomes below it are not builds either. Only an empty or
    unreadable marker gets here, because only that is a store with no choice in
    it to undo. `bun run build` writes the marker on its way out — through
    `switchServedArtifact`, so the artifact it replaces is remembered.
  */
  console.log(`nothing is served from ${servedMarkerPath(buildRoot)} — building one`)
  const built = Bun.spawn(['bun', 'run', 'build'], {
    cwd: buildRoot,
    stdio: ['inherit', 'inherit', 'inherit'],
  })
  await built.exited

  /*
    Re-read rather than assume: the build writes both markers, and a build that
    failed leaves them exactly as they were. Planned again from what is there
    now, which is how a fresh clone reaches the ordinary `served` outcome.

    A branch and not a loop. A build that failed replans to `build-one` a second
    time and nothing acts on it — control has left this block — so the window
    opens on the no-build page saying what to run. Retrying here would be the
    rebuild-every-launch this branch exists to stay clear of, with a failing
    build turning it into a rebuild-twice-every-launch.
  */
  const afterBuild = readServedMarkers(buildRoot)
  plan = servingPlan(afterBuild.served, afterBuild.previous, startable)
}

const servedRoot = plan.serve === null ? null : artifactPath(buildRoot, plan.serve)
const serving = plan.serve !== null && servedRoot !== null ? { id: plan.serve, root: servedRoot } : null

/*
  Keeping the previous build is a promise to hold a second copy of a frontend
  for ever unless something removes the third, and a launch is where that is
  paid: it is the moment the store has just been switched and the only moment
  nothing is reading out of it. What is being served and what is behind it are
  named as kept, and so is whatever `served` points at even when that is the
  artifact that just failed — removing the evidence would make the next launch a
  launch with no problem in it.
*/
const pruned = pruneArtifacts(buildRoot, [markers.served, markers.previous, plan.serve])
if (pruned.length > 0) console.log(`pruned ${pruned.length} old artifact(s): ${pruned.join(', ')}`)

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
const page = (title: string, body: string): Response =>
  new Response(
    `<!doctype html><meta charset="utf-8"><title>varnick — ${asText(title)}</title>
<style>
  :root {
    --ground: #1a1b26;
    --rule: #2c2e40;
    --fg: #c0caf5;
    --fg-dim: #8b8fa3;
    --accent: #7dcfff;
    --bad: #f7768e;
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
  em { color: var(--bad); font-style: normal }
  pre {
    max-width: 110ch;
    margin: 0 0 12px;
    padding: 6px 12px;
    border: 1px solid var(--rule);
    color: var(--fg);
    overflow-x: auto;
  }
</style>
${body}`,
    { headers: { 'content-type': 'text/html;charset=utf-8' } },
  )

/** Nothing in the store, and nothing named. A clone nobody has built. */
const nothingServed = (): Response =>
  page(
    'no build',
    `<h1>No build to serve</h1>
<p>varnick's window is served from a built artifact under
<code>.varnick/builds/</code>, and there is none in
<code>${asText(buildRoot)}</code> that <code>served</code> points at.</p>
<p>Build one:</p>
<pre><code>bun run build</code></pre>
<p>Then restart varnick. See
<code>docs/adr/0020-the-main-window-serves-a-built-artifact.md</code>.</p>`,
  )

/**
 * `served` names a build that will not start, and there is no previous one.
 *
 * Its own page rather than the one above, because the two say different things
 * and only one of them is answered by building. This state has a choice
 * recorded in it — somebody promoted something — so the page names what failed
 * and why, and offers `bun run build` as what the developer does about it
 * rather than as what the launch already did. A launch that rebuilt here would
 * replace the promoted artifact with a build of the working tree and move
 * `served` onto it, which presents as the build reverting on its own.
 */
const willNotStart = (failed: string, why: string): Response =>
  page(
    'build will not start',
    `<h1>The build this window is served from will not start</h1>
<p><code>served</code> names <em>${asText(failed)}</em> and <em>${asText(why)}</em>.
There is no previous build in <code>${asText(buildRoot)}</code> to fall back to,
so nothing was changed and nothing was rebuilt — the artifact you chose is still
the one <code>served</code> names.</p>
<p>Build this tree, which switches the window onto it:</p>
<pre><code>bun run build</code></pre>
<p>Or edit <code>${asText(servedMarkerPath(buildRoot))}</code> to name a build that
is there. See <code>docs/adr/0020-the-main-window-serves-a-built-artifact.md</code>.</p>`,
  )

/**
 * The line the window carries when it is not running what `served` names.
 *
 * **A fall back that nobody is told about is a build that reverted on its
 * own.** The developer promoted something, went to bed, and comes back to a
 * varnick that looks exactly as it did — which is the failure this whole ticket
 * is about, arriving through the mechanism meant to prevent it. So it is said
 * in both places a developer will be: the terminal, and the window.
 *
 * **Appended to the entry document rather than fetched by the app**, and that
 * is the decision worth reading twice. The artifact being served in this state
 * is by definition the *older* build — it was built before whatever is running
 * now, and quite possibly before this code existed. Anything that asked the
 * frontend to render the notice would be silent in exactly the case it is for.
 * Injection works for every artifact the store has ever held, including the
 * ones already on disk.
 *
 * It is the only thing that is ever added to what an artifact serves, it is
 * added only on this path and only to `index.html`, and it appends rather than
 * rewrites: the artifact's own bytes are served unchanged and this follows
 * them. Nothing here defines a custom property, so an app whose `:root` carries
 * the real palette is untouched — the values are literals for the same reason
 * the pages above inline them, and they are the same values.
 *
 * Dismissible, because it is fixed over a window whose top edge belongs to the
 * product, and because a developer who has read it needs the pixels back to fix
 * the thing it is about. It comes back on the next launch: this response is
 * `no-store`, and the state that produced it is on disk rather than in a
 * cookie.
 */
const fellBackNotice = (from: string, why: string, running: string): string =>
  `<style>
  #varnick-fell-back {
    position: fixed;
    inset: 0 0 auto 0;
    z-index: 2147483646;
    display: flex;
    gap: 16px;
    align-items: baseline;
    padding: 6px 12px;
    border-bottom: 1px solid #f7768e;
    background: #1a1b26;
    color: #c0caf5;
    font-family: ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 12px;
    line-height: 1.5;
  }
  #varnick-fell-back b { color: #f7768e; font-weight: 400 }
  #varnick-fell-back i { color: #8b8fa3; font-style: normal }
  #varnick-fell-back button {
    margin-left: auto;
    border: 0;
    padding: 0;
    background: none;
    color: #7dcfff;
    font: inherit;
    cursor: pointer;
  }
</style>
<div id="varnick-fell-back" role="status">
  <span>fell back to <b>${asText(running)}</b> — <i>${asText(from)}: ${asText(why)}</i></span>
  <button onclick="this.parentNode.remove()">dismiss</button>
</div>`

/** Why an artifact would not start, in the sentence the disk produced. */
const whyNot = (id: string): string => failures.get(id) ?? 'it will not start'

/*
  Said in the terminal as well as in the window, because the two developers who
  need it are the same person at different moments: the one watching a launch,
  and the one who walked away and came back to a window.
*/
if (plan.failed !== null) {
  console.error(`artifact ${plan.failed} will not start: ${whyNot(plan.failed)}`)
  console.error(
    serving === null
      ? `and there is nothing to fall back to — nothing was rebuilt, and the window will say so`
      : `falling back to ${serving.id} — \`served\` still names ${plan.failed}`,
  )
} else if (serving === null) {
  console.error(`no artifact to serve from ${buildRoot} — the window will say so`)
}

if (serving !== null) console.log(`varnick on ${port} — artifact ${serving.id} from ${serving.root}`)

/** The entry document, which is the one file the notice is appended to. */
const entry = serving === null ? null : resolve(serving.root, ARTIFACT_ENTRY)

/** The notice this launch adds to that document, composed once. */
const notice =
  plan.outcome === 'fell-back' && serving !== null && plan.failed !== null
    ? fellBackNotice(plan.failed, whyNot(plan.failed), serving.id)
    : null

Bun.serve({
  port,
  // Localhost, and not `VARNICK_HOST`. The dev server takes that variable so a
  // phone on a tailnet can reach a *development* frontend; a built artifact is
  // what the developer's own window loads, and there is no second audience for
  // it to be worth putting on a network for.
  hostname: 'localhost',
  async fetch(request) {
    if (serving === null) {
      return plan.failed === null ? nothingServed() : willNotStart(plan.failed, whyNot(plan.failed))
    }

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
    const headers = { 'cache-control': 'no-store' }

    if (notice !== null && path === entry) {
      return new Response(`${await file.text()}${notice}`, {
        headers: { ...headers, 'content-type': 'text/html;charset=utf-8' },
      })
    }

    return new Response(file, { headers })
  },
})
