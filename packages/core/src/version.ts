/*
  Generated, not on disk. `virtual:varnick-version` is answered by the
  `varnick:version` plugin in `vite.config.ts`, which reads the root manifest
  and returns a module exporting the number it found — the same `resolveId` and
  `load` pair in serve and in build, so a dev server and a shipped artifact
  cannot disagree about how the version arrives.

  An import rather than a substituted identifier. The first version of this read
  a free identifier set up by Vite's `define`, which never reaches a dev
  server's client environment under Vite 8: the renderer was served the
  identifier itself and threw on load. `version.ts`'s header has the mechanism
  and names it; `drive.ts` has the assertion that catches it, and that assertion
  reads this file, so the dead name is deliberately not written here.
*/
import { VARNICK_VERSION } from 'virtual:varnick-version'
import { displayedVersion } from '../version.ts'

/**
 * The version this build is, exactly as the root manifest spells it. The single
 * source of the number for anything in Core that needs it.
 *
 * Re-exported rather than kept private even though {@link
 * VARNICK_VERSION_LABEL} is its only reader in the tree today: the release
 * chain is the other one. It compares the running version against the
 * pre-release it is offering and puts the number in the changelog entry, and
 * neither wants the `v` — so the raw number is the thing, and the label is one
 * presentation of it.
 */
export { VARNICK_VERSION }

/** The same number as the window shows it. */
export const VARNICK_VERSION_LABEL: string = displayedVersion(VARNICK_VERSION)
