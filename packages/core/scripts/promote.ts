/**
 * Accept the pending pre-release. `bun run promote`.
 *
 * The other half of `bun run release`, and the same shape: everything it decides
 * is in `packages/core/release.ts`, everything it writes is in
 * `packages/core/release-promote.ts`, and what is left here is the one thing
 * that can only be known by being run — which tree this is.
 *
 * **It takes no arguments, and that is the point.** There is exactly one pending
 * pre-release, recorded in `.varnick/pending-release.json`, and a promotion
 * naming a version would be a promotion that could name a different one from the
 * one the developer was shown. The record is the offer; this accepts it.
 *
 * **It does not restart varnick.** The window that asked for this restarts
 * itself afterwards, because the restart has to happen after the announcement
 * reaches the transcript and the process that owns the transcript is the one
 * being replaced. See the `release` region in
 * `packages/core/src/machines/harness.ts`.
 *
 * A developer can run this from a terminal, and it is the fallback if the window
 * is the thing that is broken — which is the case the whole store's fallback
 * exists for. Then restart varnick by hand.
 */

import { cloneRootOfScript } from '../dev-server.ts'
import { promotePreRelease } from '../release-promote.ts'

/**
 * The same three codes `bun run release` answers with, and the same distinction.
 *
 * `1` is a refusal this made on purpose — nothing pending, a changelog that
 * disagrees, a build that will not start — and every one of them leaves the
 * clone exactly as it was. There is no `2` here: this reads three files and
 * writes three, with no build to fail and no network to be down, so a failure
 * that is not a refusal arrives as a throw and a stack trace, which is the
 * honest presentation of a bug rather than of a decision.
 */
const PROMOTED = 0
const REFUSED = 1

const cloneRoot = cloneRootOfScript(import.meta.url)
const outcome = promotePreRelease(cloneRoot, new Date().toISOString())

if (!outcome.promoted) {
  console.error(outcome.reason)
  process.exit(REFUSED)
}

console.log(`promoted v${outcome.version} — the window is served artifact ${outcome.artifact}`)
console.log(
  outcome.previous === null
    ? 'nothing is kept behind it, because nothing was being served before'
    : `${outcome.previous} is kept behind it to fall back to`,
)
console.log('restart varnick to be running it.')

process.exit(PROMOTED)
