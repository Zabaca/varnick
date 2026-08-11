/**
 * The two inputs the dev server takes, and the one decision it makes.
 *
 * Both belong to `vite.config.ts` and neither is asserted there, because a Vite
 * config is only observable by starting a server and looking at a window. They
 * live here so `packages/core/scripts/drive.ts` can assert them headlessly —
 * the same reason the machines keep their logic out of the components.
 *
 * Nothing in this module is loaded by the application. It is imported by the
 * Vite config, by the launcher, and by the driver.
 */

import { relative, resolve } from 'node:path'

// ---------------------------------------------------------------------------
// The port
// ---------------------------------------------------------------------------

/**
 * What varnick has always bound, and what it still binds when nobody says
 * otherwise. `bun tauri dev` in a fresh checkout must be the path that changed
 * least — it is the one everybody uses.
 */
export const DEFAULT_DEV_PORT = 1420

/**
 * The variable the launcher writes and the Vite config reads: the whole URL,
 * not the port.
 *
 * That is the point. `src-tauri/tauri.conf.json`'s `devUrl` is what the window
 * loads and `server.port` is what the frontend binds, and the two disagreeing
 * is worse than either failing: a `devUrl` pointing at a port some *other*
 * varnick holds opens a window onto somebody else's frontend, with this one's
 * host behind it. So there is one string. `scripts/dev.ts` builds it once,
 * passes it to the Tauri CLI as a `--config` overlay and to the frontend as
 * this variable, and neither end computes anything.
 *
 * An environment variable for the same reason `VARNICK_CLONE_ROOT` is one: it
 * is a property of one launch, and `bun tauri dev` is `cargo run` under a CLI
 * that contests its own argv.
 */
export const DEV_URL_ENV_VAR = 'VARNICK_DEV_URL'

/** What a developer sets to ask for a second varnick. Read by the launcher. */
export const DEV_PORT_ENV_VAR = 'VARNICK_DEV_PORT'

/**
 * The URL the window loads for a frontend on this port.
 *
 * `localhost` regardless of `VARNICK_HOST`. The webview and the dev server are
 * on the same machine, and binding the server to a tailnet address so a phone
 * can reach it is not a reason to send the window the long way round.
 */
export function devUrlFor(port: number): string {
  return `http://localhost:${port}`
}

/**
 * The port a developer asked for, or a refusal that says what is wrong with it.
 *
 * Throws rather than falling back to {@link DEFAULT_DEV_PORT}, because falling
 * back is how a second varnick silently becomes a collision with the first.
 */
export function chosenDevPort(value: string | undefined): number {
  if (value === undefined || value === '') return DEFAULT_DEV_PORT

  const port = Number(value)
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(
      `${JSON.stringify(value)} is not a port. Set ${DEV_PORT_ENV_VAR} to a whole number between 1 and 65535, or leave it unset for ${DEFAULT_DEV_PORT}.`,
    )
  }

  return port
}

/**
 * The port the frontend must bind, read out of the URL the window will load.
 *
 * Deliberately not `VARNICK_DEV_PORT`. The frontend does not get to choose —
 * it is told where the window is already pointed, and reads the number back out
 * of that one string. Unset means nobody chose, which is the default and the
 * literal in `tauri.conf.json`.
 */
export function portToBind(devUrl: string | undefined): number {
  if (devUrl === undefined || devUrl === '') return DEFAULT_DEV_PORT

  let parsed: URL
  try {
    parsed = new URL(devUrl)
  } catch {
    throw new Error(
      `${DEV_URL_ENV_VAR} is ${JSON.stringify(devUrl)}, which is not a URL. It is written by the launcher and should not be set by hand — run \`bun run dev:app --port <n>\` rather than setting it.`,
    )
  }

  if (parsed.port === '') {
    throw new Error(
      `${DEV_URL_ENV_VAR} is ${JSON.stringify(devUrl)}, which names no port. The frontend binds the port the window is pointed at; a URL without one leaves nothing to bind.`,
    )
  }

  return chosenDevPort(parsed.port)
}

/** What it takes to start a varnick on a chosen port. */
export interface DevLaunch {
  /** Arguments to `bun`, so the documented `bun tauri dev` stays the shape. */
  readonly args: readonly string[]
  /** What is added to the environment the Tauri CLI and its dev command see. */
  readonly env: Readonly<Record<string, string>>
}

/**
 * One port in, one URL, both ends told the same thing.
 *
 * This function is the whole of the "cannot disagree" claim. `devUrl` reaches
 * the window through a `--config` overlay on `tauri.conf.json`, and reaches the
 * frontend through {@link DEV_URL_ENV_VAR}, and both read the same local
 * constant. There is no second place to keep in step.
 *
 * The overlay names `build.devUrl` and nothing else: `--config` merges, so
 * every other value in `tauri.conf.json` is still the file's.
 */
export function devLaunch(port: number): DevLaunch {
  const devUrl = devUrlFor(port)

  return {
    args: ['tauri', 'dev', '--config', JSON.stringify({ build: { devUrl } })],
    env: { [DEV_URL_ENV_VAR]: devUrl },
  }
}

// ---------------------------------------------------------------------------
// The install a fresh tree needs before any of the above can run
// ---------------------------------------------------------------------------

/**
 * The one directory whose presence decides whether this tree has been installed.
 *
 * At the root rather than in a package: bun installs a workspace as a whole, and
 * the root is where the binaries every launch reaches for end up — the Tauri
 * CLI first among them.
 */
export const INSTALL_MARKER = 'node_modules'

/**
 * What to run before starting varnick from this tree, or nothing.
 *
 * **Where a Worktree's `bun install` happens, decided rather than discovered at
 * launch.** Git does not track `node_modules`, so a fresh worktree has none —
 * and `bun tauri dev` is the Tauri CLI, which is one of the things that is not
 * there. ADR-0014 records the need; this is the answer to *where*.
 *
 * Here, in the launcher, and not in the Rust host. Three reasons, in the order
 * they mattered:
 *
 *   * this is already the one place that means "start varnick from this tree",
 *     so a Preview and a developer typing `bun run dev:app` in a fresh worktree
 *     get the same behaviour without either of them knowing about the other;
 *   * the host would otherwise own a package manager — a second spawn, a second
 *     failure mode, and a wait with no output in a process whose stdout is a
 *     protocol;
 *   * `bun install` runs `postinstall`, and `packages/userspace/package.json` is
 *     deliberately writable, so this executes unmerged agent-authored code. That
 *     is not a new hole — launching a Preview at all runs the agent's
 *     application code unconfined in the webview and the host, which is the same
 *     decision one step earlier — and it belongs beside the launch it is part
 *     of rather than hidden inside the process that holds the Credential.
 *
 * Conditional, so the path everybody uses pays nothing: an installed tree
 * answers `null` and `bun tauri dev` starts exactly as fast as it did. A tree
 * that is *partly* installed is not detected and does not need to be — bun is
 * idempotent, and the case this exists for is a directory git just created.
 */
export function bootstrapCommand(installed: boolean): readonly string[] | null {
  return installed ? null : ['bun', 'install']
}

// ---------------------------------------------------------------------------
// The build cache
// ---------------------------------------------------------------------------

/** What cargo reads to decide where its build artifacts go. */
export const CARGO_TARGET_ENV_VAR = 'CARGO_TARGET_DIR'

/**
 * Where a Worktree lives, relative to the clone that owns it.
 *
 * Duplicated from `packages/harness/src/provision.ts` rather than imported, the
 * same way the Turn stamp is duplicated across the language boundary: this
 * module is loaded by the Vite config and by the launcher, and neither should
 * pull the harness in to learn one path segment.
 */
const WORKTREE_BASE = '.claude/worktrees'

/**
 * The clone a Worktree belongs to, or null when this is not a Worktree.
 *
 * A string operation on purpose. This runs before anything is installed, in a
 * launcher whose whole virtue is that it does almost nothing.
 *
 * Exported because two decisions now turn on it and they are not the same
 * decision: where cargo builds ({@link sharedTargetDir}) and whether this
 * varnick runs a dev server at all ({@link windowSource}). One of them could be
 * written in terms of the other and should not be — they would then move
 * together, and a change to where a Worktree's Rust artifacts go would silently
 * decide what the developer's window is served from.
 */
export function worktreeOwner(cloneRoot: string): string | null {
  const root = resolve(cloneRoot)
  const marker = `/${WORKTREE_BASE}/`
  const at = root.lastIndexOf(marker)
  if (at === -1) return null
  const owner = root.slice(0, at)
  // A worktree is one directory under the base, never deeper. Anything else is
  // a path that happens to contain the segment, and guessing at it would point
  // a build somewhere nobody asked for.
  return root.slice(at + marker.length).includes('/') ? null : owner
}

/**
 * The `CARGO_TARGET_DIR` a varnick started from `cloneRoot` should build into,
 * or null to leave cargo alone.
 *
 * ## What this is for
 *
 * **The first Preview of a Worktree compiled 348 crates while the developer
 * waited** — `tao`, `wry`, `objc2-app-kit`, the lot — because a tree git just
 * created has its own empty `src-tauri/target`. Minutes, every time, for every
 * new Worktree, and paid *after* the Fence dialog was approved: read the hunks,
 * decide, then stare at nothing.
 *
 * ADR-0014 argues a Preview exists so that reviewing a change means using it
 * rather than reading a diff. A four-minute wall in front of that is not a slow
 * feature, it is the feature going unused — the developer reads the diff
 * instead, which is the outcome the Preview was built to improve on.
 *
 * Pointed at the owning clone's target directory, every Worktree shares one
 * build cache, and a Worktree that changed no Rust — most of them, since most
 * Core changes are TypeScript — links against what is already there.
 *
 * ## Why sharing this directory is not a boundary question
 *
 * It looks like one. A path shared between a Worktree and the live tree is
 * exactly the shape ADR-0014's `denyWrite` is about, and the reflex is right in
 * general.
 *
 * It does not apply here, for a reason worth stating rather than assuming:
 * **`target/` is a build artifact, not source.** Nothing in it is reviewed,
 * nothing in it is merged, it is gitignored, and it is reproducible from the
 * sources on either side. The Fence exists so that code the agent wrote cannot
 * become code the host runs without a human reading it — and a Preview already
 * runs the agent's unmerged code, deliberately, which is the whole point of a
 * Preview. Sharing the cache changes nothing about what is read or what is run.
 *
 * ## Concurrency
 *
 * Cargo takes a lock on the target directory, so two Previews building at once
 * **serialise** rather than corrupt: the second prints `Blocking waiting for
 * file lock on build directory` and proceeds when the first is done. That is
 * accepted — waiting for a build that is already running beats running it
 * twice, which is what separate directories would do.
 *
 * ## What it does not do
 *
 * A Worktree that *does* change `src-tauri` still pays a rebuild, and should:
 * cargo's fingerprinting decides that, not this. Nothing here suppresses a
 * build; it only says where the artifacts already are.
 *
 * Null for the live tree, which must behave exactly as it did — and null is
 * also what an explicit `CARGO_TARGET_DIR` gets, since a developer who set one
 * has already answered this question.
 */
export function sharedTargetDir(cloneRoot: string, existing?: string | undefined): string | null {
  if (existing !== undefined && existing !== '') return null
  const owner = worktreeOwner(cloneRoot)
  return owner === null ? null : `${owner}/src-tauri/target`
}

// ---------------------------------------------------------------------------
// Whether there is a dev server at all
// ---------------------------------------------------------------------------

/** What puts a frontend behind the window. */
export type WindowSource =
  /** A built frontend out of `.varnick/builds/`, served as files. Nothing watches. */
  | 'artifact'
  /** Vite, watching this tree, with the `core-reloads` plugin on it. */
  | 'dev-server'

/**
 * What serves the window of a varnick running from `buildRoot`.
 *
 * **The live tree gets a build; a Worktree gets the dev server.** One rule, and
 * it is the same distinction ADR-0014 already draws — a varnick running from a
 * Worktree is a **Preview**, and a Preview exists so a change can be *used*
 * before it is merged. Hot reloading is what makes that worth doing.
 *
 * The live tree is the other case, and it changed. Work now lands in it while
 * nobody is watching, so a dev server on the live tree sends a full reload to
 * whatever window the developer left open, at whatever hour the merge happened.
 * `hotUpdateVerdict` was right about that reload and still is — a hot swap of
 * Core remounts the machine holding the conversation — which is why the fix is
 * not to change the verdict but to stop there being a watcher to ask it. See
 * docs/adr/0020-the-main-window-serves-a-built-artifact.md.
 *
 * Keyed on the **build root** — the tree the frontend would come from — and not
 * on `VARNICK_CLONE_ROOT`, which is the tree the *agent* works in. They are the
 * same directory for a Preview and need not be in general, and the question
 * here is about the frontend.
 *
 * The consequence is stated rather than hidden: a developer editing Core in the
 * live tree sees nothing until they build. `bun run dev` is still Vite in a
 * browser, and a Worktree is still the place Core is authored.
 */
export function windowSource(buildRoot: string): WindowSource {
  return worktreeOwner(buildRoot) === null ? 'artifact' : 'dev-server'
}

// ---------------------------------------------------------------------------
// The reload
// ---------------------------------------------------------------------------

/** What a changed file does to the window. */
export type HotUpdateVerdict = 'reload' | 'hot-swap'

/** Relative to the root, in the root, or `undefined` for outside it. */
function within(root: string, file: string): string | undefined {
  const path = relative(resolve(root), resolve(file))
  if (path === '' || path.startsWith('..')) return undefined
  return path
}

/**
 * What Vite should do about a change to `file`, for a varnick running from
 * `cloneRoot`.
 *
 * `packages/core/**` reloads and everything else hot-swaps. Both halves matter
 * and they fail differently.
 *
 * A hot swap of Core remounts the machine that owns the Session, which loses
 * the conversation that asked for the change — the exact thing ADR-0005 made a
 * rule about and ADR-0014 made mechanical. A reload of Userspace breaks "ask
 * for a Surface and it appears", which is the product's main loop.
 *
 * Relative to a root rather than matched on the string, because a Worktree's
 * Core is Core — a Preview running from `.claude/worktrees/x` reloads on its
 * own `packages/core/**` and not on the live tree's, and both are true of the
 * same rule. It also keeps `packages/userspace/packages/core/` on the right
 * side, which a substring match would not.
 */
export function hotUpdateVerdict(file: string, cloneRoot: string): HotUpdateVerdict {
  const path = within(cloneRoot, file)
  if (path === undefined) return 'hot-swap'
  return path === 'packages/core' || path.startsWith('packages/core/') ? 'reload' : 'hot-swap'
}
