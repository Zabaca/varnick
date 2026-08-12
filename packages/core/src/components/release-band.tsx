import type { HarnessEvent } from '../machines/harness.ts'
import type { HarnessSnapshot } from './chat-surface.tsx'
import { Band } from './worktree-review.tsx'
import { Markdown } from './markdown.tsx'

/**
 * The band that offers a pre-release, and reports on accepting one.
 *
 * A function of `(snapshot, send)` and nothing else — ADR-0001 — which is what
 * lets `#/states` draw all five of its states without a release existing.
 *
 * **It is its own file rather than a third band in `worktree-review.tsx`.**
 * That file is about Worktrees: what is pending, what merged, what was cleared
 * away. A release is not a Worktree, it is what a night of them produced, and
 * the two are edited for different reasons.
 *
 * **It shares that file's `Band` shell rather than drawing its own box**, which
 * is the half of the precedent that matters. An earlier version claimed to
 * follow `MergeReportBand` and did not — its own border, its own padding, and a
 * headline at the transcript's 13px where every other band steps down to 12.
 * Three chances to disagree with the two bands beside it about what a band
 * looks like. `Band` is where Quiet Chrome, the Hairline and Tonal Depth are
 * decided once for all of them.
 *
 * **Silent when there is nothing.** `release.idle` renders `null`, not an empty
 * container: a permanent slot saying "no pre-release" is how the conversation
 * ends up below the fold, which is the reason the ticket gives for this being a
 * band at all.
 */
export function ReleaseBand({
  snapshot,
  send,
}: {
  snapshot: HarnessSnapshot
  send: (event: HarnessEvent) => void
}) {
  const region = snapshot.value.release
  const ctx = snapshot.context
  if (region === 'idle' || region === 'routing') return null

  /*
    Drawn only when the machine accepts it, never disabled. ADR-0007's rule: a
    refused start is a state rather than a greyed-out button, and a control the
    machine will not take is a control that is not there. `promoting` is the
    state where this is false, which is what stops a second press queueing a
    second promotion.
  */
  const canPromote = snapshot.can({ type: 'PROMOTE_RELEASE' })
  const pending = ctx.pendingRelease
  const version = region === 'promoted' ? ctx.promotedVersion : pending?.version

  return (
    <Band>
      <div className="flex items-baseline gap-2">
        <span style={{ color: 'var(--fg)' }}>
          {region === 'promoted' ? 'promoted' : 'pre-release'}{' '}
          {/* A version is a figure a developer compares, so it is tabular like
              every other number varnick draws. */}
          <span data-numeric style={{ color: 'var(--fg)' }}>
            v{version ?? ''}
          </span>
        </span>
        {region === 'promoting' && <span style={{ color: 'var(--fg-dim)' }}>promoting…</span>}
        {region === 'promoted' && (
          <span style={{ color: 'var(--fg-dim)' }}>restart to be running it</span>
        )}
      </div>

      {/*
        The announcement, in the words the tickets used. Rendered as markdown
        for the reason the transcript renders it: it is prose somebody wrote,
        and a paragraph per ticket is the shape `announcement()` produces.

        Capped per prose block rather than on the band, which is the Wide
        Measure Rule as DESIGN.md states it — the cap belongs to the paragraphs
        somebody reads, not to the container around them.

        Shown while the offer stands and while it is being accepted, and not
        after: once it is promoted it is in the transcript, and repeating it
        here would be the same text twice on one screen.
      */}
      {(region === 'pending' || region === 'promoting') && pending && (
        <div className="mt-1 max-w-[110ch]" style={{ color: 'var(--fg-dim)' }}>
          <Markdown text={pending.announcement} />
        </div>
      )}

      {/*
        Why it did not go through, or why the developer is not yet running what
        they accepted. One field carries both, because from this side they are
        the same sentence: something is not as you would expect, and here is
        what.
      */}
      {ctx.promotionError !== null && (
        <div className="mt-1 max-w-[110ch]" style={{ color: 'var(--bad)' }}>
          <span aria-hidden>✗ </span>
          {ctx.promotionError}
        </div>
      )}

      {canPromote && (
        <div className="mt-1">
          <button onClick={() => send({ type: 'PROMOTE_RELEASE' })} style={{ color: 'var(--accent)' }}>
            {/*
              Three states, three labels, and the middle one is the finding this
              replaced. From `promoted` the control asks for the restart again —
              the region re-enters itself — so calling it "try again" described
              a promotion that is not what happens and cannot happen: there is
              nothing left to promote.
            */}
            {region === 'pending'
              ? 'promote and restart'
              : region === 'promoted'
                ? 'restart varnick'
                : 'try again'}
          </button>
        </div>
      )}
    </Band>
  )
}
