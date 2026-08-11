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
 * it wanted to. `vite.config.ts` reads the file once and {@link versionDefine}
 * turns the answer into the substitution the bundler performs, so what ships is
 * a literal that was true when it was built.
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
 * The identifier the bundler replaces. Free in the renderer's source, a string
 * literal in its output; declared where it is read so nothing else in Core can
 * reach for it by accident.
 */
export const VERSION_IDENTIFIER = '__VARNICK_VERSION__'

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
 * The substitution, ready for Vite's `define`.
 *
 * Values there are source text rather than strings, which is why the version is
 * JSON-encoded: `define` splices what it is given straight into the module.
 * Built here rather than spelled out in the config so the wiring is a thing
 * `drive.ts` can check, instead of a thing you find out by opening the window.
 */
export function versionDefine(manifestText: string): Record<string, string> {
  return { [VERSION_IDENTIFIER]: JSON.stringify(versionFromManifest(manifestText)) }
}
