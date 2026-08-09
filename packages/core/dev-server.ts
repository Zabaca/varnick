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
