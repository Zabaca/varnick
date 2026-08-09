import { useMemo } from 'react'
import type { ActorRefFrom } from 'xstate'
import { toPath } from '../hooks.ts'
import { parseDiff, type DiffFile, type DiffHunk, type DiffLineKind } from '../diff.ts'
import type { PendingWorktree } from '../domain.ts'
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
 * The list, beside the conversation.
 *
 * Four states and four sentences, read off the machine rather than inferred from
 * the length of a list: `empty` says everything the agent finished has landed,
 * and `listFailed` says nobody can currently tell. A view branching on
 * `worktrees.length === 0` would have to invent that difference back, and the
 * branch it invents eventually says "nothing is waiting" over a git that never
 * answered.
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

  return (
    <section className="px-4 py-3" style={{ borderBottom: '1px solid var(--rule)' }}>
      <div className="flex items-baseline gap-2 text-[12px]">
        <h2 style={{ color: 'var(--fg)' }}>Pending Core changes</h2>
        {/*
          Asking again, offered wherever the machine accepts it — which is the
          three resting states and not while a listing is in flight, so this
          cannot restart the actor answering the previous ask.
        */}
        {snapshot.can({ type: 'LIST_WORKTREES' }) && (
          <button
            className="ml-auto"
            onClick={() => send({ type: 'LIST_WORKTREES' })}
            style={{ color: 'var(--fg-faint)' }}
          >
            look again
          </button>
        )}
      </div>

      <div className="mt-2 text-[12px]">
        {state === 'listing' && (
          <p style={{ color: 'var(--fg-faint)' }}>Asking git what is waiting to be merged…</p>
        )}

        {state === 'empty' && (
          <p style={{ color: 'var(--fg-dim)' }}>
            Nothing is waiting — everything the agent finished has landed.
          </p>
        )}

        {/*
          A different problem with different copy. Not "nothing is waiting":
          this says nobody can currently tell, and the reason is git's own.
        */}
        {state === 'listFailed' && (
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
        )}

        {state === 'listed' && (
          <ul className="space-y-1.5">
            {ctx.worktrees.map((entry) => (
              <WorktreeRow
                key={entry.path}
                entry={entry}
                canOpen={snapshot.can({ type: 'OPEN_WORKTREE', path: entry.path })}
                onOpen={() => send({ type: 'OPEN_WORKTREE', path: entry.path })}
              />
            ))}
          </ul>
        )}
      </div>
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
 */
function WorktreeRow({
  entry,
  canOpen,
  onOpen,
}: {
  entry: PendingWorktree
  canOpen: boolean
  onOpen: () => void
}) {
  return (
    <li>
      <div className="flex items-baseline gap-2">
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
      </div>
      <div className="flex items-baseline gap-2" style={{ color: 'var(--fg-faint)' }}>
        <span data-numeric>
          {entry.commits} commit{entry.commits === 1 ? '' : 's'} · {entry.changed.length} file
          {entry.changed.length === 1 ? '' : 's'}
        </span>
        {canOpen && (
          <button className="ml-auto" onClick={onOpen} style={{ color: 'var(--accent)' }}>
            open
          </button>
        )}
      </div>
    </li>
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
