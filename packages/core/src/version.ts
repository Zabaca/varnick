import { displayedVersion } from '../version.ts'

/*
  Substituted by the bundler — see `versionDefine` in `../version.ts`. Declared
  in this module rather than globally so this is the only file in Core that can
  read it: the renderer has one place the number enters, and everything else
  imports from here.

  A `declare const` erases to nothing, which leaves the identifier free for
  `define` to replace. If the substitution were ever missing this module would
  throw on load rather than render `vundefined` — but it cannot be missing,
  because the config that sets it up refuses to build without a version.
*/
declare const __VARNICK_VERSION__: string

/**
 * The version this build is, exactly as the root manifest spells it. The single
 * source of the number for anything in Core that needs it.
 *
 * Exported rather than kept private even though {@link VARNICK_VERSION_LABEL}
 * is its only reader in the tree today: the release chain is the other one. It
 * compares the running version against the pre-release it is offering and puts
 * the number in the changelog entry, and neither wants the `v` — so the raw
 * number is the thing, and the label is one presentation of it.
 */
export const VARNICK_VERSION: string = __VARNICK_VERSION__

/** The same number as the window shows it. */
export const VARNICK_VERSION_LABEL: string = displayedVersion(VARNICK_VERSION)
