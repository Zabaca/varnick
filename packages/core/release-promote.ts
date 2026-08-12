/**
 * Accepting a pre-release: the writes, in the order they have to happen.
 *
 * The impure twin of {@link promotionPlan}, and the same split `release.ts` and
 * `release-cut.ts` already have — every decision next door where `drive.ts` can
 * assert it with nothing built, and here only the sequence.
 *
 * **This is Core, not Harness.** A promotion writes the developer's clone, which
 * sounds like the Fence's business and is not: nothing here decides what the
 * agent may do. It runs because a human pressed a control in `packages/core/**`,
 * which is the same gate ADR-0014 rests on for a merge. What the Fence owns is
 * the one call that starts it — see `promote-release` in
 * `packages/harness/src/bridge.ts` — and that call carries nothing but the
 * request, so nothing composed on the window side chooses what is written.
 *
 * ## Why the order is the order
 *
 * ```
 * refuse if anything is wrong        <- nothing written yet, and most of the work
 * switchServedArtifact               <- `served` and `previous`, together
 * write the changelog                <- the durable record that it was accepted
 * clear the pending record           <- last, so a failure leaves the offer up
 * ```
 *
 * Every refusal happens before the first write, which is what makes "a promotion
 * that fails leaves the developer on the build they were already running" a
 * property of the shape rather than a rule. The three writes after it are
 * ordered so that failing part-way through is recoverable by pressing the
 * control again, and the reason that is true is worth stating because it is not
 * obvious:
 *
 *   * **a repeated switch is a no-op that keeps the fallback.**
 *     `switchServedArtifact` records the outgoing `served` as `previous` *only*
 *     when it is switching to a different id, so promoting the same artifact
 *     twice leaves `previous` naming the build the developer came from rather
 *     than naming the build they are now on. A retry cannot eat the fallback.
 *   * **the record is cleared last**, so a failure anywhere above it leaves the
 *     band still offering the pre-release, which is the "way to try again" the
 *     ticket asks for. The alternative — clearing first — turns a half-finished
 *     promotion into a release nobody can accept and nobody can see.
 *
 * ## The one writer
 *
 * `switchServedArtifact` is the only thing in the repository that writes
 * `served` or `previous`, and this file does not become the second. That
 * invariant is what the whole fallback rests on: a promotion that composed
 * marker text by hand would move `served` and leave `previous` naming a build
 * two promotions old, and nothing would look wrong until the day the fallback
 * was needed. `drive.ts` asserts the invariant directly now rather than leaving
 * it to there being one function, because this ticket is the first time a second
 * caller existed at all.
 */

import { readFileSync, writeFileSync } from 'node:fs'
import { switchServedArtifact, artifactStartFailureById } from './artifact-store.ts'
import { changelogPath, clearPendingRecord, pendingRecordPath } from './release-cut.ts'
import { parsePendingRecord, promotionPlan, type PendingPreRelease } from './release.ts'

/** What a promotion did, or why it did nothing. */
export type PromotionOutcome =
  | { readonly promoted: false; readonly reason: string }
  | {
      readonly promoted: true
      readonly version: string
      readonly artifact: string
      /** The build the developer came from, which the fallback now names. */
      readonly previous: string | null
      /** Posted into the transcript by the window that asked for this. */
      readonly announcement: string
    }

/**
 * Read a file that may not be there, without turning absence into a throw.
 *
 * The same reading `readServedMarkers` takes: a promotion is asked for by a
 * developer pressing a control, and every failure it can have should arrive as a
 * sentence on the screen rather than as a stack trace in a log nobody opens.
 */
function textAt(path: string): string | undefined {
  try {
    return readFileSync(path, 'utf-8')
  } catch {
    return undefined
  }
}

/** What is on offer in this clone, or `null`. */
export function pendingPreRelease(cloneRoot: string): PendingPreRelease | null {
  return parsePendingRecord(textAt(pendingRecordPath(cloneRoot)))
}

/**
 * Accept the pending pre-release: serve it, record it, and stop offering it.
 *
 * Answers rather than throws, for the reason above — every outcome here is
 * something the window has to render, including all of the failures.
 */
export function promotePreRelease(cloneRoot: string, now: string): PromotionOutcome {
  const record = pendingPreRelease(cloneRoot)

  /*
    Ticket 07's question, asked here rather than after the switch. It is the one
    refusal that trying again cannot fix, and asking it now is what keeps the
    developer on a build that works instead of on one that will not open.
  */
  const startFailure =
    record === null ? null : artifactStartFailureById(cloneRoot, record.artifact)

  const plan = promotionPlan({
    record,
    changelog: textAt(changelogPath(cloneRoot)),
    now,
    startFailure,
  })
  if (!plan.promote) return { promoted: false, reason: plan.reason }

  // The only writer of either marker, and this file does not become the second.
  const markers = switchServedArtifact(cloneRoot, plan.artifact)

  writeFileSync(changelogPath(cloneRoot), plan.changelog)
  clearPendingRecord(cloneRoot)

  return {
    promoted: true,
    version: plan.version,
    artifact: plan.artifact,
    previous: markers.previous,
    announcement: plan.announcement,
  }
}
