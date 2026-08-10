import { useMemo } from 'react'
import type { ActorRefFrom } from 'xstate'
import { toPath } from '../hooks.ts'
import { parseDiff, type DiffFile, type DiffHunk, type DiffLineKind } from '../diff.ts'
import { mergeSummary } from '../domain.ts'
import type { Mergeability, PendingWorktree } from '../domain.ts'
import type { worktreeDiffMachine } from '../machines/worktree-diff.ts'
import type { HarnessEvent } from '../machines/harness.ts'
import type { HarnessSnapshot } from './chat-surface.tsx'

/**
 * What is waiting to be merged, and what is in it.
 *
 * Two renderings of one subject: the list of Worktrees holding Core changes
 * nobody has merged, beside the conversation; and the changes themselves, in
 * the column the transcript usually has, when a developer opens one.
 *
 * ## Core, and never a Surface
 *
 * A Surface is Userspace and the agent writes Userspace freely, so a diff
 * renderer the agent could rewrite is a diff renderer that can hide its own
 * hunks — the same class of problem as a forged dialog and a worse consequence,
 * because a forged dialog asks once and a shaded diff is the only thing standing
 * between a widening and a merge. Nothing here is loaded from Userspace, and
 * nothing here can be: this file is `packages/core/**`, which `denyWrite` refuses
 * the agent in the live tree (ADR-0002, ADR-0014).
 *
 * ## Not a git client
 *
 * Pending worktree changes and nothing else. No staging, no history, no blame,
 * no commit — the developer merges with the tools they already have open, and
 * varnick's job here is to make one thing impossible to miss rather than to
 * compete in a category it cannot win.
 *
 * ## How a Fence hunk is told apart, inside the design system
 *
 * DESIGN.md is strict and this is the component that would break it by habit: a
 * second font, rounded panels, a terminal's green and red. None of that happens,
 * and the refusal is what makes the marking work.
 *
 * **The diff spends no colour on added and removed lines.** They are told apart
 * by their marker and by tone — `fg` for what arrives, `fg-faint` for what goes,
 * `fg-dim` for what stays — which is The Three Greys Rule applied to the one
 * screen most likely to argue for an exception. That leaves colour meaning
 * exactly one thing here, and it is the thing this view exists for.
 *
 * **Fence is `warn`**, the colour DESIGN.md gives to *the build admitting
 * something about itself*. A file under `packages/harness/**`, `src-tauri/**` or
 * `sandbox-policy.baseline.json` decides what the agent may do, and saying so is
 * varnick admitting what the change in front of you can reach. It is not `bad` —
 * nothing has failed — and not `accent`, which means a thing you can act on.
 *
 * It is carried three ways, at three distances, because a marking that only
 * works when the file header is on screen does not work on a four-hundred-line
 * diff: the file's border, the file's name and chip, and a 1px rule down the
 * left of every hunk in it. That last one is the load-bearing one. Every hunk in
 * the product has the same geometry — a 1px left border — and only the colour
 * differs, so a Fence hunk read in isolation, scrolled far from anything that
 * names the file, still says what it is.
 *
 * The border colour sits on the scrolling element rather than inside it, so
 * scrolling a long line sideways cannot take the marking with it.
 */

type DiffRef = ActorRefFrom<typeof worktreeDiffMachine>

/**
 * The list, above the conversation.
 *
 * ## Where it sits, and why it is not beside the chat any more
 *
 * A pending Core change is the most consequential thing on the screen: it is
 * code that will decide what the agent may do, waiting for a human to read it.
 * It spent one release in the right-hand column under the runtime panel, which
 * scrolls — so on a short window the one thing that must not be missed was
 * reachable only by scrolling past what the agent said about itself. It is a
 * full-width band above the whole surface now, outside the transcript's
 * scroller, which is the same move the diff view makes one step further on and
 * for the same reason (The Wide Measure Rule: paths and branch names must not
 * wrap).
 *
 * ## And why it is usually not there at all
 *
 * **Nothing to say, no vertical space.** Nothing pending is the state this is in
 * almost all the time, and a permanent slot for it is exactly how the panel
 * ended up below the fold: every launch and every Turn would otherwise spend a
 * band of the window saying that nothing has happened. So `review.empty`
 * renders nothing, and so does a listing in flight with no rows behind it —
 * which is what a launch is, and what the end of every Turn is once everything
 * has landed. Without that second half the band would appear and vanish on
 * every Turn, which is motion the machines did not make (The Still Surface
 * Rule).
 *
 * The rule is *have something to show*, not *be in a particular state*, and the
 * two are different in exactly one place: a refresh that failed over a list that
 * was good. Those rows stay on screen, with a line saying nobody could check
 * them — see below.
 *
 * ## Four states, still read off the machine
 *
 * `empty` and a failed *first* listing are still two answers with two sentences
 * — one says everything the agent finished has landed, the other says nobody
 * can currently tell — and the difference is still the machine's. What has
 * changed is that `empty` says its sentence by being absent, which is the
 * honest rendering of "nothing to report".
 */
export function ReviewPanel({
  snapshot,
  send,
}: {
  snapshot: HarnessSnapshot
  send: (event: HarnessEvent) => void
}) {
  const ctx = snapshot.context
  const state = toPath((snapshot.value as Record<string, unknown>).review)
  const failed = state === 'listFailed'
  const entries = ctx.worktrees
  const landed = entries.filter((entry) => entry.landed).length
  const waiting = entries.length - landed

  // Nothing waiting and nothing wrong: no band, no border, no height. See the
  // note above — this is the state the surface is in most of the time.
  if (entries.length === 0 && !failed) return null

  return (
    <section
      className="shrink-0 px-6 py-2"
      style={{ borderBottom: '1px solid var(--rule)', background: 'var(--ground-raised)' }}
    >
      <div className="flex items-baseline gap-3 text-[12px]">
        <h2 style={{ color: 'var(--fg)' }}>Pending Core changes</h2>
        {/*
          Two counts, because the band holds two different kinds of row and
          calling all of them "waiting for a human" was wrong in the way that
          matters: a landed Worktree is not waiting to be *decided*, it is
          waiting to be tidied. A developer reading "4 branches waiting" and
          finding that three of them are already in their tree learns to
          distrust the number.
        */}
        {waiting > 0 && (
          <span style={{ color: 'var(--fg-faint)' }}>
            <span data-numeric>{waiting}</span> branch{waiting === 1 ? '' : 'es'} waiting for a
            human
          </span>
        )}
        {landed > 0 && (
          <span style={{ color: 'var(--fg-faint)' }}>
            <span data-numeric>{landed}</span> already in, still on disk
          </span>
        )}
        {/*
          Asking again, offered wherever the machine accepts it — which is the
          three resting states and not while a listing is in flight, so this
          cannot restart the actor answering the previous ask, whether that ask
          was this button or the end of a Turn.

          It stays now that a Turn ending re-lists, because an agent is not the
          only thing that can commit: the developer has a terminal, and an
          explicit re-ask is the honest answer to "I did something outside this
          window". When the band is not on screen there is nothing to hang it
          off, so the same event is a command in the menu — see
          `varnickCommands` in chat-surface.tsx.
        */}
        {snapshot.can({ type: 'LIST_WORKTREES' }) && (
          <button
            className="ml-auto shrink-0"
            onClick={() => send({ type: 'LIST_WORKTREES' })}
            style={{ color: 'var(--fg-faint)' }}
          >
            look again
          </button>
        )}
      </div>

      {entries.length > 0 && (
        <ul className="mt-1 space-y-0.5 text-[12px]">
          {entries.map((entry) => (
            <WorktreeRow
              key={entry.path}
              entry={entry}
              canOpen={snapshot.can({ type: 'OPEN_WORKTREE', path: entry.path })}
              onOpen={() => send({ type: 'OPEN_WORKTREE', path: entry.path })}
              canReap={snapshot.can({ type: 'REAP_WORKTREE', path: entry.path })}
              onReap={() => send({ type: 'REAP_WORKTREE', path: entry.path })}
              reaping={snapshot.context.reaping === entry.path}
            />
          ))}
        </ul>
      )}

      <ConflictNote entries={entries} />

      {/*
        Two failures with two sentences, told apart by whether anything survived.

        With no rows this is the first listing of the run: nothing is known, and
        the reason is git's own — a problem line, in `bad`.

        With rows it is a refresh that could not replace a list that was good.
        The rows stay, because throwing away a working answer because the next
        question went unanswered is how a developer loses sight of a branch that
        is genuinely waiting. What is owed instead is that nobody is pretending
        this is current — `warn`, the colour of the build admitting something
        about itself, which is what a list nobody could check is.
      */}
      {failed && (
        <div className="mt-1 text-[12px]" style={{ maxWidth: 'var(--prose)' }}>
          {entries.length === 0 ? (
            <div style={{ color: 'var(--bad)' }}>
              <p>
                <span aria-hidden>✗ </span>
                {ctx.worktreeError ?? 'git would not answer.'}
              </p>
              <p style={{ color: 'var(--fg-faint)' }}>
                Nothing is known about what is pending, which is not the same as nothing being
                pending.
              </p>
            </div>
          ) : (
            <p style={{ color: 'var(--warn)' }}>
              <span aria-hidden>⚠ </span>
              Could not look again — {ctx.worktreeError ?? 'git would not answer.'} The list above
              is the last one git gave and may be out of date.
            </p>
          )}
        </div>
      )}
    </section>
  )
}

/**
 * One branch waiting.
 *
 * The Fence flag is git's, by way of the Harness's one definition — see
 * `touchesFence` on {@link PendingWorktree}. It is drawn here the same way it is
 * drawn inside the diff, so a row and the hunks it opens say the same thing in
 * the same colour.
 *
 * `open` appears because the machine would accept opening *this* row: false for
 * a path it is not holding, and false for every row while a diff is already
 * open. Presence is the state, so there is no disabled treatment to design —
 * and no "you are reading this one" marking either, because a diff takes the
 * whole surface and this list is not on screen while one is open.
 *
 * One line each, now that the list has the width of the window rather than a
 * 320px column. Rows are what a developer counts before deciding to read one,
 * so a branch that costs two lines is a band that costs twice the height for
 * the same three facts.
 */
function WorktreeRow({
  entry,
  canOpen,
  onOpen,
  canReap,
  onReap,
  reaping,
}: {
  entry: PendingWorktree
  canOpen: boolean
  onOpen: () => void
  canReap: boolean
  onReap: () => void
  reaping: boolean
}) {
  return (
    <li className="flex items-baseline gap-3">
      <span
        className="min-w-0 truncate"
        style={{ color: entry.touchesFence ? 'var(--warn)' : 'var(--fg)' }}
        title={entry.path}
      >
        {entry.branch ?? 'detached HEAD'}
      </span>
      {entry.touchesFence && (
        <span className="shrink-0" style={{ color: 'var(--warn)' }}>
          <span aria-hidden>⚠ </span>fence
        </span>
      )}
      <span className="shrink-0" style={{ color: 'var(--fg-faint)' }} data-numeric>
        {entry.commits} commit{entry.commits === 1 ? '' : 's'} · {entry.changed.length} file
        {entry.changed.length === 1 ? '' : 's'}
      </span>
      {/*
        A landed row does not say how it would merge, and the reason is that
        git's answer is *true and useless*: after a squash the branch is nobody's
        ancestor, so `merge-tree` goes on reporting a clean merge that would
        produce nothing. Printing `merges cleanly` beside a row whose work is
        already in the tree is how a developer clicks merge and gets a `git
        commit` with nothing to commit.
      */}
      {entry.landed ? (
        <span className="shrink-0" style={{ color: 'var(--fg-faint)' }}>
          already in
        </span>
      ) : (
        <MergeBadge merge={entry.merge} />
      )}
      <span className="ml-auto flex shrink-0 items-baseline gap-3">
        {canOpen && (
          <button onClick={onOpen} style={{ color: 'var(--accent)' }}>
            open
          </button>
        )}
        {/*
          Present rather than disabled, like every other control in this band:
          the machine refuses `REAP_WORKTREE` for a row that has not landed, so
          there is no state in which this is drawn and inert.

          "clear away" rather than "delete" or "reap". What goes is a duplicate
          checkout whose commits the live tree holds — the word should not
          suggest the developer is about to lose something, because they are
          not, and it should not suggest housekeeping is free either.
        */}
        {reaping ? (
          <span style={{ color: 'var(--fg-faint)' }}>clearing…</span>
        ) : (
          canReap && (
            <button onClick={onReap} style={{ color: 'var(--accent)' }}>
              clear away
            </button>
          )
        )}
      </span>
    </li>
  )
}

/**
 * Whether the row will go in, in three or four words.
 *
 * ## Said on the row, decided in the diff
 *
 * The answer belongs here and the control does not, and the two halves of that
 * are separate decisions. A developer scanning the band is choosing what to
 * read, and "this one conflicts" changes that choice — so withholding it until
 * they have opened the branch makes them open branches to find out they cannot
 * merge them. The **control** stays with the diff, because a merge button on a
 * summary row is a way to land a Fence hunk without having looked at one, which
 * is exactly the thing ticket 50's marking exists to prevent.
 *
 * ## And in grey, except when it is not
 *
 * `fast-forward` and `clean` are `fg-faint`, beside the counts, because they are
 * ordinary — most branches merge, and a colour spent on the normal case is a
 * colour that stops meaning anything. `conflicts` and `unknown` are `warn`: the
 * build admitting something about itself, which is what "this will not go in as
 * it stands" and "nobody could work out whether it would" both are. Neither is
 * `bad` — nothing has failed, and a branch that conflicts is a branch mid-flight
 * rather than a branch that broke.
 *
 * The conflicted files are named one level down, in the panel under the list,
 * rather than on the row: a row is one line by design, and a branch that
 * conflicts in nine files would take the band apart.
 */
function MergeBadge({ merge }: { merge: Mergeability }) {
  const summary = mergeSummary(merge)
  const warn = summary.tone === 'warn'
  return (
    <span
      className="shrink-0"
      style={{ color: warn ? 'var(--warn)' : 'var(--fg-faint)' }}
      title={merge.kind === 'unknown' ? merge.reason : undefined}
    >
      {warn && <span aria-hidden>⚠ </span>}
      {summary.says}
    </span>
  )
}

/**
 * What to do about the branches that will not go in.
 *
 * Under the list rather than on the rows, and said once for all of them. Two
 * things have to be here and only one of them is the file names: the other is
 * **whose job this is**, which is the part a developer reading a conflict will
 * otherwise get wrong by reflex.
 *
 * `.claude/skills/change-core/SKILL.md` already answers it. The agent merges
 * `main` *down* into its worktree — it may write there, and it wrote the branch,
 * so it is the party with the context — and hands back a fast-forward. varnick
 * deliberately builds no conflict resolver: a developer hand-resolving somebody
 * else's branch inside a review tool is guessing at reasoning they do not have,
 * and doing it in a window whose whole job is to show them what changed.
 *
 * So this is instruction, not apology. It names the branch, names the files, and
 * says the sentence to send.
 */
function ConflictNote({ entries }: { entries: readonly PendingWorktree[] }) {
  const stuck = entries
    .map((entry) => ({ entry, summary: mergeSummary(entry.merge) }))
    .filter(({ summary }) => summary.advice !== null)
  if (stuck.length === 0) return null

  return (
    <div className="mt-1 space-y-0.5 text-[12px]" style={{ maxWidth: 'var(--prose)' }}>
      {stuck.map(({ entry, summary }) => (
        <p key={entry.path} style={{ color: 'var(--warn)' }}>
          <span aria-hidden>⚠ </span>
          <span style={{ color: 'var(--fg)' }}>{entry.branch ?? 'detached HEAD'}</span>{' '}
          {summary.advice}
        </p>
      ))}
    </div>
  )
}

/**
 * The changes themselves, taking the surface the conversation usually has.
 *
 * Full width rather than beside the chat, because a diff is what The Wide
 * Measure Rule is written about: prose caps at 110ch and a diff must not wrap at
 * all, so it takes the widest thing on screen. The conversation is not lost —
 * the machines are untouched and `close` brings it straight back. See the branch
 * in chat-surface.tsx, which is where first-run setup makes the same move for
 * the same reason.
 */
export function WorktreeDiffView({
  diff,
  snapshot,
  send,
}: {
  diff: DiffRef
  snapshot: HarnessSnapshot
  send: (event: HarnessEvent) => void
}) {
  const snap = diff.getSnapshot()
  const { worktree, error, attempts } = snap.context
  const state = toPath(snap.value)

  // Parsed here rather than in the machine, and memoised because a large diff is
  // the normal case: the machine holds what git printed, so nothing between git
  // and this screen can drop a hunk while still answering the call.
  const files = useMemo(() => parseDiff(snap.context.diff ?? ''), [snap.context.diff])
  const fenced = files.filter((file) => file.fence).length

  return (
    // `min-h-0` is what makes the body below scroll rather than growing the
    // window: without it a flex child sizes to its content, and a large diff —
    // which is the normal case — pushes the header off the top.
    <div className="flex min-h-0 min-w-0 flex-1 flex-col">
      <header className="shrink-0 px-6 py-3" style={{ borderBottom: '1px solid var(--rule)' }}>
        <div className="flex items-baseline gap-3">
          <h2 className="min-w-0 truncate" style={{ color: 'var(--fg)' }}>
            {worktree.branch ?? 'detached HEAD'}
          </h2>
          <span className="shrink-0 text-[11.5px]" style={{ color: 'var(--fg-faint)' }}>
            <span data-numeric>{worktree.commits}</span> commit
            {worktree.commits === 1 ? '' : 's'} ahead
          </span>
          {snapshot.can({ type: 'CLOSE_WORKTREE' }) && (
            <button
              className="ml-auto shrink-0"
              onClick={() => send({ type: 'CLOSE_WORKTREE' })}
              style={{ color: 'var(--accent)' }}
            >
              close
            </button>
          )}
        </div>
        <div className="truncate text-[11.5px]" style={{ color: 'var(--fg-faint)' }}>
          {worktree.path}
        </div>

        <MergeControl worktree={worktree} snapshot={snapshot} send={send} />

        {/*
          Said once, at the top, so the marking below is a marking rather than a
          decoration nobody was told the meaning of. Only when there is one:
          a line reading "0 files" would be the surface reporting on itself.
        */}
        {state === 'loaded' && fenced > 0 && (
          <p className="mt-1.5 text-[12px]" style={{ color: 'var(--warn)' }}>
            <span aria-hidden>⚠ </span>
            <span data-numeric>{fenced}</span> of <span data-numeric>{files.length}</span> file
            {files.length === 1 ? '' : 's'} here decide what the agent may do — marked below.
          </p>
        )}
      </header>

      <div className="min-h-0 flex-1 overflow-y-auto px-6 py-4">
        {state === 'loading' && (
          <p style={{ color: 'var(--fg-faint)' }}>
            Reading what changed{attempts > 1 ? ` — attempt ${attempts}` : ''}…
          </p>
        )}

        {/*
          What git said, and the way back. The retry is here because `failed`
          accepts `RETRY`; a loaded diff has no retry because that state has no
          handler, not because a control was hidden.
        */}
        {state === 'failed' && (
          <div className="flex flex-wrap items-baseline gap-x-3" style={{ color: 'var(--bad)' }}>
            <span style={{ maxWidth: 'var(--prose)' }}>
              <span aria-hidden>✗ </span>
              {error ?? 'The diff could not be read.'}
            </span>
            {snap.can({ type: 'RETRY' }) && (
              <button onClick={() => diff.send({ type: 'RETRY' })} style={{ color: 'var(--accent)' }}>
                try again
              </button>
            )}
            {attempts > 1 && <span style={{ color: 'var(--fg-faint)' }}>attempt {attempts}</span>}
          </div>
        )}

        {state === 'loaded' && (
          <DiffBody diff={snap.context.diff ?? ''} files={files} commits={worktree.commits} />
        )}
      </div>
    </div>
  )
}

/**
 * Landing the branch, from the screen showing what is in it.
 *
 * ## Here, and deliberately not on the row
 *
 * Ticket 50 marks Fence hunks at three distances so that nobody merges one
 * without having seen it. A merge button on a summary row would make that
 * marking optional — you would land a Fence change having looked at a line
 * saying "⚠ fence", which is a warning rather than the thing it warns about.
 * The control is in the header of the diff, so the hunks are the page it is on.
 *
 * The machine agrees rather than being trusted to: `mergeable` refuses
 * `MERGE_WORKTREE` unless a diff is open, so this is not a convention the view
 * is keeping on its own.
 *
 * ## Four things it can say, and only one of them is a button
 *
 * A merge that is offered is one control and no prose. Everything else is a
 * sentence saying why there is no control, because a disabled button explains
 * nothing and an absent one explains nothing either:
 *
 *   * the branch conflicts, or nobody could tell — `mergeSummary`'s advice,
 *     which names the files and says to ask the agent to merge `main` down;
 *   * the live tree is dirty — the one refusal that is about neither the branch
 *     nor this window, and the one a developer can clear in ten seconds if they
 *     are told;
 *   * a merge is already running, here or on another branch.
 *
 * The dirty-tree sentence is `warn` rather than `bad` for the reason the whole
 * of this file uses `warn`: nothing has failed. It is the build declining to
 * write over work it cannot see.
 */
function MergeControl({
  worktree,
  snapshot,
  send,
}: {
  worktree: PendingWorktree
  snapshot: HarnessSnapshot
  send: (event: HarnessEvent) => void
}) {
  const summary = mergeSummary(worktree.merge)
  const merging = toPath((snapshot.value as Record<string, unknown>).worktreeMerge) === 'merging'
  const canMerge = snapshot.can({ type: 'MERGE_WORKTREE', path: worktree.path })

  if (merging) {
    return (
      <p className="mt-1.5 text-[12px]" style={{ color: 'var(--fg-faint)' }}>
        Merging {snapshot.context.merging === worktree.path ? 'this branch' : 'another branch'}…
      </p>
    )
  }

  if (canMerge) {
    return (
      <div className="mt-1.5 flex flex-wrap items-baseline gap-x-3 text-[12px]">
        <button
          onClick={() => send({ type: 'MERGE_WORKTREE', path: worktree.path })}
          style={{ color: 'var(--accent)' }}
        >
          merge into the live tree
        </button>
        {/*
          What merging will do, said before it is done rather than after. The
          squash is not an implementation detail from where the developer is
          standing: it is the difference between the live branch gaining one
          commit and gaining this branch's whole working record.
        */}
        <span style={{ color: 'var(--fg-faint)' }}>
          squashed into one commit — {summary.says}, and the worktree is removed
          afterwards
        </span>
      </div>
    )
  }

  if (snapshot.context.liveTreeDirty) {
    return (
      <p className="mt-1.5 text-[12px]" style={{ color: 'var(--warn)', maxWidth: 'var(--prose)' }}>
        <span aria-hidden>⚠ </span>
        The live tree has uncommitted work in it, so varnick will not merge onto it — a merge over
        it is how a change nobody knew about is lost. Commit or set that work aside, then look
        again.
      </p>
    )
  }

  if (summary.advice !== null) {
    return (
      <p className="mt-1.5 text-[12px]" style={{ color: 'var(--warn)', maxWidth: 'var(--prose)' }}>
        <span aria-hidden>⚠ </span>
        {summary.advice}
      </p>
    )
  }

  /*
    A mergeable row while the region is elsewhere — `merged`, `mergeFailed`,
    `restarting`. `canMerge` is false because the guard is region-scoped, and
    there is nothing wrong with the branch, so none of the warnings above apply
    and every one of them would be a lie.

    It still says something. A row that offers a merge, then silently offers
    nothing the moment another branch is merged, reads as the row having gone
    wrong — which is the same complaint this component's own header makes about
    a disabled button that explains nothing. What is true is short: the control
    is busy elsewhere, and it comes back.
  */
  if (worktree.merge.kind === 'fast-forward' || worktree.merge.kind === 'clean') {
    return (
      <p className="mt-1.5 text-[12px]" style={{ color: 'var(--fg-faint)' }}>
        {summary.says} — mergeable, once the last merge has been put away.
      </p>
    )
  }

  return null
}

/**
 * What the last merge did, across the top of the window.
 *
 * ## Why it is a band and not a line in the transcript
 *
 * The only thing a developer must not miss here is that **this window is now
 * running the code from before the change it just accepted**, and a note in a
 * scrolling conversation is a note that scrolls. It sits where the review band
 * sits, for the reason the review band sits there (ticket 55): the consequential
 * thing goes above the fold.
 *
 * It is also the one surface in varnick that outlives its subject. The branch is
 * gone, the worktree is gone, the row it came from will not be in the next
 * listing — this is the only trace, and dismissing it is the developer saying
 * they have read it rather than the fact ceasing to be true.
 *
 * ## `leftOver` is printed verbatim
 *
 * The host composes that sentence because the host is what knows: which pid is
 * standing in the directory, what git said when it would not delete a ref,
 * whether the squash carried. Nothing is reworded here — a surface that
 * paraphrased would be inventing detail about a filesystem it cannot see.
 */
export function MergeReportBand({
  snapshot,
  send,
}: {
  snapshot: HarnessSnapshot
  send: (event: HarnessEvent) => void
}) {
  const state = toPath((snapshot.value as Record<string, unknown>).worktreeMerge)
  const { mergeReport, mergeError } = snapshot.context

  if (state === 'merging') {
    return (
      <Band>
        <p style={{ color: 'var(--fg-faint)' }}>Merging, and clearing up after it…</p>
      </Band>
    )
  }

  if (state === 'restarting') {
    return (
      <Band>
        <p style={{ color: 'var(--fg-faint)' }}>Restarting varnick…</p>
      </Band>
    )
  }

  if (state === 'mergeFailed') {
    return (
      <Band>
        <div className="flex flex-wrap items-baseline gap-x-3" style={{ color: 'var(--bad)' }}>
          <span style={{ maxWidth: 'var(--prose)' }}>
            <span aria-hidden>✗ </span>
            {mergeError ?? 'The merge did not happen.'}
          </span>
          {/*
            Nothing was written, and saying so is the point. A failed merge is
            the one failure in this feature where the developer's next question
            is "what state is my tree in", and every refusal happens before
            anything is written — see packages/harness/src/merge.ts.
          */}
          <span style={{ color: 'var(--fg-faint)' }}>Nothing was merged.</span>
          {/*
            The retry, where the failure is.

            Ticket 56 asks that this state "carries git's reason and offers a
            retry", and the retry existed only on the row's own control, behind
            the diff — so the band said what went wrong and the way to act on it
            was somewhere else. Worse where it matters most: the commonest
            failure is a dirty live tree, which the developer fixes in a terminal
            and comes straight back to this band.

            Drawn from `can()` like every other control here, so it is absent
            rather than inert when the merge is not on offer — the branch may
            have stopped being mergeable while the reason was being read.
          */}
          {snapshot.context.worktreeOpen !== null &&
            snapshot.can({ type: 'MERGE_WORKTREE', path: snapshot.context.worktreeOpen }) && (
              <button
                onClick={() =>
                  send({ type: 'MERGE_WORKTREE', path: snapshot.context.worktreeOpen as string })
                }
                style={{ color: 'var(--accent)' }}
              >
                try again
              </button>
            )}
          {snapshot.can({ type: 'DISMISS_MERGE' }) && (
            <button onClick={() => send({ type: 'DISMISS_MERGE' })} style={{ color: 'var(--accent)' }}>
              dismiss
            </button>
          )}
        </div>
      </Band>
    )
  }

  if (state !== 'merged' || mergeReport === null) return null

  return (
    <Band>
      <div className="text-[12px]" style={{ maxWidth: 'var(--prose)' }}>
        <p style={{ color: 'var(--fg)' }}>
          <span style={{ color: 'var(--fg)' }}>{mergeReport.branch}</span> landed as{' '}
          <span data-numeric>{mergeReport.commit}</span>
          {mergeReport.squashed > 1 && (
            <>
              , squashing <span data-numeric>{mergeReport.squashed}</span> commits into one
            </>
          )}
          .
        </p>
        {/*
          The sentence this whole region exists for. Until the restart, the
          window is running the code from before the change it just accepted,
          and an agent reasoning about a fix it believes is live is worse off
          than one that knows it is not.
        */}
        <p style={{ color: 'var(--warn)' }}>
          <span aria-hidden>⚠ </span>
          varnick is still running the code from before this change. A restart is what makes it
          live.
        </p>
        {mergeReport.leftOver !== null && (
          <p style={{ color: 'var(--warn)' }}>
            <span aria-hidden>⚠ </span>
            {mergeReport.leftOver}
          </p>
        )}
        {mergeError !== null && (
          <p style={{ color: 'var(--bad)' }}>
            <span aria-hidden>✗ </span>
            {mergeError}
          </p>
        )}
        <div className="mt-1 flex flex-wrap items-baseline gap-x-3">
          {snapshot.can({ type: 'RESTART_VARNICK' }) && (
            <button
              onClick={() => send({ type: 'RESTART_VARNICK' })}
              style={{ color: 'var(--accent)' }}
            >
              restart varnick
            </button>
          )}
          {snapshot.can({ type: 'DISMISS_MERGE' }) && (
            <button onClick={() => send({ type: 'DISMISS_MERGE' })} style={{ color: 'var(--fg-faint)' }}>
              not now
            </button>
          )}
        </div>
      </div>
    </Band>
  )
}

/**
 * What the last reap did, when it did not simply work.
 *
 * **Its own band rather than lines inside the merge's**, for the reason the
 * region is its own region: a developer is often looking at both. A merge lands
 * and reports that the directory could not be removed; the reap that finally
 * removes it happens after the Turn ends, and the merge's sentence — *restart,
 * you are running old code* — is still true while it does.
 *
 * ## The success is quiet, and the refusal is not
 *
 * A reap that removed the directory says one line and offers dismissal. Nothing
 * is owed: the row is gone from the next listing, and a band congratulating a
 * developer on a deletion they asked for is a band in the way.
 *
 * A reap that removed *nothing* is the interesting one, and it is not a failure.
 * The usual cause is the agent's own host standing in the directory, which
 * inside a Turn it always is — so the answer is a sentence naming the process
 * and an invitation to come back, which is what `leftOver` carries. Printed
 * verbatim, like the merge's, because the host is what knows which pid.
 */
export function ReapReportBand({
  snapshot,
  send,
}: {
  snapshot: HarnessSnapshot
  send: (event: HarnessEvent) => void
}) {
  const state = toPath((snapshot.value as Record<string, unknown>).worktreeReap)
  const { reapReport, reapError } = snapshot.context

  if (state === 'reaping') {
    return (
      <Band>
        <p style={{ color: 'var(--fg-faint)' }}>Clearing the worktree away…</p>
      </Band>
    )
  }

  if (state === 'reapFailed') {
    return (
      <Band>
        <div className="flex flex-wrap items-baseline gap-x-3" style={{ color: 'var(--bad)' }}>
          <span style={{ maxWidth: 'var(--prose)' }}>
            <span aria-hidden>✗ </span>
            {reapError ?? 'Nothing was removed.'}
          </span>
          {/*
            Said separately from the reason, exactly as the merge's failure says
            it. The developer's next question after a refusal is what state
            their disk is in, and every check here happens before anything is
            removed — see `reapWorktree` in packages/harness/src/merge.ts.
          */}
          <span style={{ color: 'var(--fg-faint)' }}>Nothing was removed.</span>
          {snapshot.can({ type: 'DISMISS_REAP' }) && (
            <button onClick={() => send({ type: 'DISMISS_REAP' })} style={{ color: 'var(--accent)' }}>
              dismiss
            </button>
          )}
        </div>
      </Band>
    )
  }

  if (state !== 'reaped' || reapReport === null) return null

  return (
    <Band>
      <div className="text-[12px]" style={{ maxWidth: 'var(--prose)' }}>
        {reapReport.worktreeRemoved ? (
          <p style={{ color: 'var(--fg-faint)' }}>
            <span style={{ color: 'var(--fg)' }}>{reapReport.branch}</span>
            {reapReport.branchDeleted
              ? ' and its worktree are gone.'
              : ' — the worktree is gone.'}
          </p>
        ) : (
          <p style={{ color: 'var(--warn)' }}>
            <span aria-hidden>⚠ </span>
            Nothing was removed.
          </p>
        )}
        {reapReport.leftOver !== null && (
          <p style={{ color: reapReport.worktreeRemoved ? 'var(--warn)' : 'var(--fg-faint)' }}>
            {reapReport.leftOver}
          </p>
        )}
        {snapshot.can({ type: 'DISMISS_REAP' }) && (
          <div className="mt-1">
            <button onClick={() => send({ type: 'DISMISS_REAP' })} style={{ color: 'var(--fg-faint)' }}>
              dismiss
            </button>
          </div>
        )}
      </div>
    </Band>
  )
}

/** The same full-width slot the review list uses, so the two stack. */
function Band({ children }: { children: React.ReactNode }) {
  return (
    <section
      className="shrink-0 px-6 py-2 text-[12px]"
      style={{ borderBottom: '1px solid var(--rule)', background: 'var(--ground-raised)' }}
    >
      {children}
    </section>
  )
}

/**
 * The files, or the honest thing to say when there are none.
 *
 * Two ways there can be no files and they are not the same. git printing nothing
 * is a branch that changed nothing tracked, which is rare and real. git printing
 * something this parser found no file in is a parser that is behind, and the
 * answer to that is to show what git said rather than to report that the branch
 * about to be merged is empty — the one sentence this view must never produce
 * when it is not true.
 */
function DiffBody({
  diff,
  files,
  commits,
}: {
  diff: string
  files: readonly DiffFile[]
  commits: number
}) {
  if (files.length === 0 && diff.trim().length === 0) {
    return (
      <p style={{ color: 'var(--fg-dim)', maxWidth: 'var(--prose)' }}>
        <span data-numeric>{commits}</span> commit{commits === 1 ? '' : 's'} ahead, and nothing
        tracked was changed.
      </p>
    )
  }

  if (files.length === 0) {
    return (
      <div className="space-y-2">
        <p style={{ color: 'var(--warn)', maxWidth: 'var(--prose)' }}>
          <span aria-hidden>⚠ </span>
          git printed something this build could not read as files. It is below, unchanged.
        </p>
        <pre
          className="overflow-x-auto whitespace-pre p-2 text-[13px]"
          style={{ background: 'var(--ground-raised)', border: '1px solid var(--rule)' }}
        >
          <code>{diff}</code>
        </pre>
      </div>
    )
  }

  return (
    <div className="space-y-3">
      {files.map((file) => (
        <FileBlock key={file.path} file={file} />
      ))}
    </div>
  )
}

/** One file, with everything that happened to it. */
function FileBlock({ file }: { file: DiffFile }) {
  const added = file.hunks.reduce(
    (n, hunk) => n + hunk.lines.filter((line) => line.kind === 'add').length,
    0,
  )
  const removed = file.hunks.reduce(
    (n, hunk) => n + hunk.lines.filter((line) => line.kind === 'remove').length,
    0,
  )

  return (
    <section
      style={{
        // Square, 1px, and the colour is the only thing that differs between a
        // Fence file and any other. The geometry is identical on purpose: a
        // marking that also moved things would read as a different component.
        border: `1px solid ${file.fence ? 'var(--warn)' : 'var(--rule)'}`,
        background: 'var(--ground-raised)',
      }}
    >
      <div
        className="flex flex-wrap items-baseline gap-x-3 px-3 py-1.5 text-[12px]"
        style={{ borderBottom: '1px solid var(--rule)' }}
      >
        <span
          className="min-w-0 break-all"
          style={{ color: file.fence ? 'var(--warn)' : 'var(--fg)' }}
        >
          {file.path}
        </span>
        {file.fence && (
          <span style={{ color: 'var(--warn)' }}>
            <span aria-hidden>⚠ </span>fence
          </span>
        )}
        {file.note && <span style={{ color: 'var(--fg-faint)' }}>{file.note}</span>}
        {file.hunks.length > 0 && (
          <span className="ml-auto shrink-0" style={{ color: 'var(--fg-faint)' }} data-numeric>
            +{added} −{removed}
          </span>
        )}
      </div>

      {/*
        A file git described without hunks — a binary blob, a rename, a mode
        change — still has to be on screen. An icon added under `src-tauri/` is a
        Fence change with no hunk in it, and a hunk-only renderer would leave it
        off entirely.
      */}
      {file.hunks.length === 0 && (
        <p className="px-3 py-1.5 text-[12px]" style={{ color: 'var(--fg-faint)' }}>
          No hunks — git described this file without printing lines for it.
        </p>
      )}

      {file.hunks.map((hunk, index) => (
        <HunkBlock key={index} hunk={hunk} fence={file.fence} first={index === 0} />
      ))}
    </section>
  )
}

/**
 * One hunk, scrolling sideways rather than wrapping.
 *
 * A large diff is the normal case, so the code takes its own horizontal scroll
 * and the window never widens for it — the same requirement, and the same
 * answer, as a code block in the transcript (components/markdown.tsx).
 *
 * The left rule is the Fence marking that survives distance: the border sits on
 * the scrolling element, so scrolling a long line sideways cannot take it with
 * it, and a hunk read alone in the middle of a long file still says what it is.
 */
function HunkBlock({
  hunk,
  fence,
  first,
}: {
  hunk: DiffHunk
  fence: boolean
  first: boolean
}) {
  return (
    <pre
      className="overflow-x-auto whitespace-pre py-1 text-[13px]"
      style={{
        background: 'var(--ground)',
        borderLeft: `1px solid ${fence ? 'var(--warn)' : 'var(--rule)'}`,
        borderTop: first ? undefined : '1px solid var(--rule)',
      }}
    >
      <div className="px-3" style={{ color: fence ? 'var(--warn)' : 'var(--fg-faint)' }}>
        {hunk.header}
      </div>
      {hunk.lines.map((line, index) => (
        <div key={index} className="px-3" style={{ color: TONE[line.kind] }}>
          {MARKER[line.kind]}
          {line.text}
        </div>
      ))}
    </pre>
  )
}

/**
 * What a line is, said in grey.
 *
 * No green and no red. A terminal's diff palette would be the loudest thing in
 * the product, on the screen where colour has to mean one thing — and it would
 * be a fifth and sixth colour that exists nowhere in the transcript this
 * application inherited its palette from (The Inherited Palette Rule). What
 * arrives is what you are meant to read, what goes is a ghost of what was there,
 * and what stays is supporting text: the three greys, in the order the system
 * already uses them.
 */
const TONE: Record<DiffLineKind, string> = {
  add: 'var(--fg)',
  remove: 'var(--fg-faint)',
  context: 'var(--fg-dim)',
  meta: 'var(--fg-faint)',
}

/**
 * And said in a character, because tone alone is not a signal.
 *
 * git's own markers, kept in the gutter position a monospace grid gives them for
 * free. The parser strips them from the text so a line can be styled by what it
 * is rather than by what it starts with; this puts them back.
 */
const MARKER: Record<DiffLineKind, string> = {
  add: '+',
  remove: '-',
  context: ' ',
  meta: '\\',
}
