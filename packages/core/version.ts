/**
 * Where the version number comes from, and what it has to be.
 *
 * The header used to carry a string literal. That made a release a change to
 * Core: a number that could disagree with the manifest without anything
 * noticing, in a file that has to typecheck. So the number is data now — it is
 * read out of the root manifest and substituted into the renderer when the
 * renderer is built.
 *
 * Build-time and not run-time. The webview is served a bundle over http and has
 * no filesystem to ask; `package.json` is not something it could read even if
 * it wanted to. `vite.config.ts` reads the file once and {@link
 * versionModuleSource} turns the answer into a module, so what the renderer
 * imports is a literal that was true when it was resolved.
 *
 * **A module and not a `define`, and that is not a preference.** The first
 * version of this substituted a free identifier through Vite's `define`, which
 * is the obvious way and works only under `vite build`. Vite 8's `vite:define`
 * installs user defines through `applyToEnvironment`, gated on
 * `environment.config.isBundled`, and its `transform` handler opens with
 * `if (this.environment.config.consumer === "client") return`. A dev server is
 * a client environment and is not bundled, so neither path runs and the
 * renderer is served the bare identifier — a `ReferenceError` on load, and
 * because `chat-surface.tsx` imports this, a blank window rather than a broken
 * header. `drive.ts` starts a real dev server and reads what it serves, so that
 * is a failing assertion now rather than a Preview nobody can talk to.
 *
 * A virtual module has no such split. `resolveId` and `load` are how a dev
 * server answers a request and how a bundler resolves one, so there is a single
 * mechanism with a single failure mode.
 *
 * Nothing here touches the filesystem, for two reasons. It is the same reason
 * `dev-server.ts` exists — a Vite config is only observable by starting a
 * server and looking at a window, so the decisions live where
 * `scripts/drive.ts` can assert them headlessly. And `src/version.ts` imports
 * {@link displayedVersion} from here, so anything in this module is code the
 * renderer bundles: a `node:` built-in in here is a `node:` built-in in the
 * browser, and it need not be written directly — importing `dev-server.ts`
 * would bring `node:path` along with it.
 *
 * **This module imports nothing, and `drive.ts` asserts that it imports
 * nothing.** That is the whole enforcement, and it is a check rather than this
 * paragraph because `eslint.config.js` says of its own rules that the
 * alternative was a sentence in a header nothing checked, and that sentence had
 * already gone stale.
 */

/**
 * What the renderer imports. Not a file — nothing on disk has this name, and
 * the plugin in `vite.config.ts` answers for it in both serve and build.
 */
export const VERSION_MODULE_ID = 'virtual:varnick-version'

/**
 * The same module once it is resolved. The leading NUL is Rollup's convention
 * for "this id is mine, nobody else look at it"; without it Vite's own resolver
 * would try to find `virtual:varnick-version` on disk and fail.
 */
export const VERSION_MODULE_RESOLVED = `\0${VERSION_MODULE_ID}`

/**
 * The version in a manifest's text, or a refusal.
 *
 * It throws rather than falling back. A default here would be the literal
 * coming back wearing a different hat — a build that lost the version would
 * show a plausible number instead of failing, which is exactly the failure this
 * whole change is about. The build is the last moment anybody is watching.
 */
export function versionFromManifest(text: string): string {
  let manifest: unknown
  try {
    manifest = JSON.parse(text)
  } catch {
    throw new Error('the root manifest is not valid JSON, so there is no version to build with')
  }

  const version = (manifest as { version?: unknown })?.version
  if (typeof version !== 'string' || version.trim() === '') {
    throw new Error(
      'the root manifest has no "version" — the window would show a placeholder rather than what it is running',
    )
  }

  /*
    A leading `v` is presentation, and presentation is added once, below. A
    manifest that carries one would reach the window as `vv0.0.1`; it is also
    not a version npm or `bun` would accept, so refusing it here costs nothing
    a release wanted to do.
  */
  if (!/^\d/.test(version)) {
    throw new Error(
      `the root manifest's version ${JSON.stringify(version)} does not start with a number — the "v" is added when it is shown, not stored`,
    )
  }

  return version
}

/**
 * How the number is shown. One function so the states page and the live chat
 * cannot render the same version two ways, and so the `v` has a place to be
 * asserted that is not a screenshot.
 */
export function displayedVersion(version: string): string {
  return `v${version}`
}

/**
 * The whole of {@link VERSION_MODULE_ID}: the one module in the renderer whose
 * text is generated rather than written.
 *
 * It is source rather than a value, which is why the version is JSON-encoded —
 * what comes back is spliced into a module the bundler then parses. Built here
 * rather than inside the plugin so the wiring is a thing `drive.ts` can check
 * without a server, and so the refusal happens on the same call that produces
 * the text: there is no arrangement where the module exists and the version
 * does not.
 */
export function versionModuleSource(manifestText: string): string {
  return `export const VARNICK_VERSION = ${JSON.stringify(versionFromManifest(manifestText))}\n`
}
