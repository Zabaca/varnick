import type { SnapshotFrom } from 'xstate'
import type { harnessMachine } from '../machines/harness.ts'
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
 * the two are edited for different reasons. The shape is deliberately the same
 * as `MergeReportBand`'s, because from the developer's side these are the same
 * kind of thing — something happened while you were away, here is what, here is
 * the one control.
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
  snapshot: SnapshotFrom<typeof harnessMachine>
  send: (event: { type: 'PROMOTE_RELEASE' }) => void
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

  return (
    <section
      className="max-w-[110ch] border p-3"
      style={{ background: 'var(--ground-raised)', borderColor: 'var(--rule)' }}
      aria-label="pre-release"
    >
      <div className="flex items-baseline gap-2">
        <span style={{ color: 'var(--fg)' }}>
          {region === 'promoted'
            ? `varnick v${ctx.promotedVersion ?? ''} is promoted`
            : `varnick v${pending?.version ?? ''} is waiting`}
        </span>
        {region === 'promoting' && (
          <span className="text-[12px]" style={{ color: 'var(--fg-dim)' }}>
            promoting…
          </span>
        )}
      </div>

      {/*
        The announcement, in the words the tickets used. Rendered as markdown
        for the reason the transcript renders it: it is prose somebody wrote,
        and a paragraph per ticket is the shape `announcement()` produces.

        Shown while the offer stands and while it is being accepted, and not
        after — once it is promoted it is in the transcript, and repeating it
        here would be the same text twice on one screen.
      */}
      {(region === 'pending' || region === 'promoting') && pending && (
        <div className="mt-2 text-[12px]" style={{ color: 'var(--fg-dim)' }}>
          <Markdown text={pending.announcement} />
        </div>
      )}

      {/*
        Why it did not go through, or why the developer is not yet running what
        they accepted. The same field carries both, because from this side they
        are the same sentence: something is not as you would expect, and here is
        what.
      */}
      {ctx.promotionError !== null && (
        <div className="mt-2 text-[12px]" style={{ color: 'var(--bad)' }}>
          <span aria-hidden>✗ </span>
          {ctx.promotionError}
        </div>
      )}

      {canPromote && (
        <div className="mt-2">
          <button onClick={() => send({ type: 'PROMOTE_RELEASE' })} style={{ color: 'var(--accent)' }}>
            {region === 'pending' ? 'Promote and restart' : 'Try again'}
          </button>
        </div>
      )}
    </section>
  )
}
