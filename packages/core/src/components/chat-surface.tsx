import { useEffect, useRef, useState, type ComponentType } from 'react'
import type { ActorRefFrom, SnapshotFrom } from 'xstate'
import { useChildRevision, toPath } from '../hooks.ts'
import { VARNICK_VERSION_LABEL } from '../version.ts'
import { seededDetail, type ActorMode } from '../actors/index.ts'
import type { surfaceMachine } from '../machines/surface.ts'
import { ClaudeHeader } from './brainless/claude/claude-header.tsx'
import { ClaudeMessage } from './brainless/claude/claude-message.tsx'
import { Markdown } from './markdown.tsx'
import { ClaudeThinking } from './brainless/claude/claude-thinking.tsx'
import { ClaudeToolCall } from './brainless/claude/claude-tool-call.tsx'
import { ClaudePrompt } from './brainless/claude/claude-prompt.tsx'
import { SlashMenu } from './slash-menu.tsx'
import { RuntimePanel } from './runtime-panel.tsx'
import { RunningTasks } from './running-tasks.tsx'
import {
  MergeReportBand,
  ReapReportBand,
  ReviewPanel,
  WorktreeDiffView,
} from './worktree-review.tsx'
import {
  agentCanAnswer,
  commandLabel,
  commandArgument,
  commandQuery,
  invokedCommand,
  matchCommands,
  mergeCommands,
  signatureFor,
  completionFor,
  wordBoundaryBackward,
  wordBoundaryForward,
  type MenuCommand,
  formatContext,
  CONTEXT_WINDOW,
  EFFORTS,
  MODELS,
} from '../domain.ts'
import { IMAGE_MEDIA_TYPES, imageMarker, type PastedImage } from '@varnick/harness/turn'
import { CREDENTIAL_SHAPE_PROBE, credentialShapeProblem } from '@varnick/harness/credentials'
import type { harnessMachine, HarnessEvent } from '../machines/harness.ts'
import type { SessionEvent } from '../machines/session.ts'

/**
 * The chat surface: a Claude Code session, rendered with brainless.
 *
 * A pure function of `(snapshot, send)` — ADR-0001. It holds no machine of its
 * own, which is what lets the live app and the states page render the same
 * component rather than two copies that drift. Start-up, retry policy and mode
 * selection belong to whoever owns the actor.
 *
 * Every control is filtered through `snapshot.can()`.
 *
 * Harness state is silent while it holds. It appears only when something is
 * wrong, because a permanent row of green dots reporting on seeded actors is a
 * claim the product cannot currently back. `#/states` is where the full machine
 * state is on screen at all times, one card per state; that is what it is for.
 */

/**
 * The effort chip's glyph, filling as effort rises.
 *
 * Taken from brainless's own table rather than invented — the status line moved
 * out of its component and the look should not move with it. Kept here because
 * that component no longer renders this, and a constant nothing reads would be
 * worse than a duplicate that does.
 */
const EFFORT_GLYPH: Record<string, string> = {
  low: '○',
  medium: '◐',
  high: '●',
  xhigh: '◉',
  max: '◈',
}

export type HarnessSnapshot = SnapshotFrom<typeof harnessMachine>

export interface ChatSurfaceProps {
  snapshot: HarnessSnapshot
  send: (event: HarnessEvent) => void
  mode: ActorMode
  /**
   * Whether this conversation was restored from the mirror with something
   * redacted out of it.
   *
   * A prop rather than machine context, for the same reason `mode` is one: it
   * is a fact about how this run started, and start-up belongs to whoever owns
   * the actor. The machines stay unchanged by resume — a restored Session is
   * `turn.idle` with messages, which is a state that already existed.
   */
  restoredRedacted?: boolean
  /** Called before a recovery event, so the owner can re-arm its start-up. */
  onRecover?: () => void
  /**
   * What a loaded Surface renders, looked up by module path.
   *
   * A prop rather than a lookup this component does for itself, for the same
   * reason `mode` is one: the loader is a module that scans the filesystem, and
   * ADR-0001 keeps this surface a function of its arguments. The live pages pass
   * the real loader's record; `#/states` passes nothing, because Userspace
   * content is not Core's to invent and a card that faked one would be the mock
   * the states page exists to avoid.
   */
  resolveSurface?: (modulePath: string) => ComponentType | undefined
}

/** The formats a paste may be — the same allowlist the control channel keeps. */
const IMAGE_TYPES: readonly string[] = [...IMAGE_MEDIA_TYPES]

/**
 * A clipboard file, as the two fields that cross into the Sandbox.
 *
 * Base64 rather than a blob URL or a path. A blob URL is a handle inside this
 * webview and means nothing in another process; a path points into `$HOME`,
 * which the Sandbox denies, so an agent handed one would be handed something it
 * cannot open. The bytes themselves are the only form that travels.
 */
async function asPastedImage(file: File): Promise<PastedImage> {
  const buffer = new Uint8Array(await file.arrayBuffer())
  // Chunked, because `String.fromCharCode(...array)` on a few megabytes is a
  // spread of millions of arguments and throws a stack overflow — which would
  // make a large screenshot fail in a way that reads as the paste being ignored.
  let binary = ''
  for (let i = 0; i < buffer.length; i += 8192) {
    binary += String.fromCharCode(...buffer.subarray(i, i + 8192))
  }
  return { mediaType: file.type as PastedImage['mediaType'], data: btoa(binary) }
}

/** Base64 is 4 characters per 3 bytes; near enough for a chip. */
function sizeOf(base64: string): string {
  const bytes = Math.floor((base64.length * 3) / 4)
  return bytes < 1024 * 1024
    ? `${Math.max(1, Math.round(bytes / 1024))}kB`
    : `${(bytes / (1024 * 1024)).toFixed(1)}MB`
}

export function ChatSurface({
  snapshot,
  send,
  mode,
  restoredRedacted,
  onRecover,
  resolveSurface,
}: ChatSurfaceProps) {
  const scrollRef = useRef<HTMLDivElement>(null)

  const ctx = snapshot.context
  const session = ctx.session
  // Surfaces run on their own clocks, so one failing has to reach React here or
  // the panel keeps claiming `loading` for a module that gave up.
  useChildRevision([
    ...ctx.surfaces,
    ...(session ? [session] : []),
    // An open diff runs on its own clock too: without it here, a read that
    // failed would leave the column claiming to be loading a diff that gave up.
    ...(ctx.worktreeDiff ? [ctx.worktreeDiff] : []),
  ])
  const s = session?.getSnapshot()

  const agentState = toPath((snapshot.value as Record<string, unknown>).agent)
  const turn = s ? toPath((s.value as Record<string, unknown>).turn) : null
  // One check, because there is one state: a Turn is in flight or it is not.
  const working = turn?.startsWith('answering') ?? false
  const sessionCan = (e: SessionEvent) => Boolean(s?.can(e))

  /*
    The draft lives in the machine, not beside it.

    A local mirror was the earlier arrangement and it gave the composer two
    sources of truth — MENU_COMPLETE writes the draft, so the mirror had to be
    written twice on every path. It also made a seeded composer unrenderable,
    which is precisely what the states page needs.
  */
  const draft = s?.context.draft ?? ''

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: 'smooth' })
  }, [s?.context.messages.length, s?.context.partial, turn])

  /*
    Two lists, one menu.

    **varnick's own commands are events the machines accept**, gated by `can()`
    like every other control here, so the menu cannot advertise a capability the
    product does not have. That rule is unchanged and applies to these rows only.

    **The agent's commands are text the Session runs.** They come from the
    runtime — the CLI's own, plus every skill and plugin it loaded — and until
    now none of them had ever appeared here: the menu was thirteen entries
    varnick wrote about itself, in a window whose whole subject is an agent with
    dozens. Executing them already worked, because a message whose text is
    `/foo` is handed to the SDK like any other and the CLI runs it. What did not
    exist was any way to know they were there.

    So they are offered rather than run: picking one completes it into the
    composer and Enter sends it. The send path is untouched, which is what keeps
    this a discovery feature rather than a second way to run things.
  */
  /*
    `available` is local to this list and never leaves it: a command that cannot
    run is not offered, so the filter below is what turns these into menu rows
    rather than a flag the menu has to remember to check.
  */
  const varnickCommands: (MenuCommand & { available: boolean })[] = [
    /*
      `/clear` and `/compact` are the agent's now, not varnick's.

      Each of ours did the thing *and* updated varnick's copy of it — the
      transcript, the token meter. That covered the times varnick was asked and
      no others. The CLI has both commands and they went round the outside, and
      a compaction needs no command at all: the window fills and the agent
      summarises itself. Every one of those left one half holding a conversation
      the other had already replaced.

      varnick listens instead — for `conversation_reset` and for the summary the
      `PostCompact` hook reports — which covers however it was asked for,
      including when nobody asked.
    */
    /*
      `/retry`, `/interrupt` and `/restart` were here and are not commands.

      Each already has a control where the thing it acts on is: a failed Turn
      renders its own retry, a crashed agent renders its own restart, and an
      answer in flight is stopped with Escape. A menu row for each was a third
      copy of an affordance that was already on screen twice — and it put
      varnick's plumbing in a list whose subject is what the *agent* can do.

      What is left here is what the agent has no version of, or has a version
      of that would leave the two halves disagreeing.
    */
    /*
      One row each, taking a value.

      They were one row per value, on the argument that a command with an
      argument needs parsing and a command per value does not. That was true and
      it stopped being worth it: five efforts and three models is eight of the
      thirteen rows in the menu, so a list whose job is finding things spent
      most of itself describing two settings.

      What replaced the parsing is the signature bar. `argumentHint` lists the
      values, and it stays on screen for exactly as long as the argument is
      blank — so an unrecognised value is answered by the surface rather than by
      an error this would otherwise have to invent.
    */
    {
      name: 'effort',
      description: `Current: ${s?.context.effort ?? '—'}`,
      argumentHint: EFFORTS.join('|'),
      source: 'varnick' as const,
      available: Boolean(session),
      run: (argument: string) => {
        const effort = EFFORTS.find((e) => e === argument)
        if (effort) session?.send({ type: 'SET_EFFORT', effort })
      },
    },
    {
      name: 'model',
      description: `Current: ${MODELS.find((m) => m.id === s?.context.model)?.label ?? '—'}`,
      argumentHint: MODELS.map((m) => m.label).join('|'),
      source: 'varnick' as const,
      available: Boolean(session),
      run: (argument: string) => {
        const model = MODELS.find((m) => m.label === argument)
        if (model) session?.send({ type: 'SET_MODEL', model: model.id })
      },
    },
    /*
      *look again*, for the moments the band that carries it is not on screen.

      The rule for this list is that varnick's own commands are for what the
      agent has no version of, and that an affordance already visible beside the
      thing it acts on does not get a second copy here — which is why `/retry`,
      `/interrupt` and `/restart` were removed. This one is the case that rule
      leaves out: `review.empty` renders nothing, deliberately and for most of
      the run, so the control has nowhere to live in exactly the state a
      developer who has just committed from a terminal is looking at.

      The end of a Turn covers the agent's own commits and does not cover
      theirs, so the explicit re-ask has to stay reachable. Gated by `can()`
      like everything else: it disappears while a listing is in flight rather
      than queueing a second one.
    */
    {
      name: 'pending',
      description: 'Ask git again what is waiting to be merged',
      argumentHint: '',
      source: 'varnick' as const,
      available: snapshot.can({ type: 'LIST_WORKTREES' }),
      run: () => send({ type: 'LIST_WORKTREES' }),
    },
  ].filter((c) => c.available)

  /*
    varnick's first, so a collision would resolve its way. Nothing collides
    today — every command in this menu is the agent's — and the ordering is
    kept because it is the rule, not because anything currently needs it. See
    `mergeCommands`, which also merges the duplicate the runtime reports for
    anything that is both a command and a skill.
  */
  const allCommands = mergeCommands([
    ...varnickCommands,
    ...ctx.commands.map((c) => ({ ...c, source: 'agent' as const })),
  ])

  const query = commandQuery(draft)
  const commands = matchCommands(allCommands, query.startsWith('/') ? query.slice(1) : query)
  const availableNames = allCommands.map(commandLabel)
  const menuOpen = Boolean(s?.context.menuOpen)
  const menuIndex = Math.min(s?.context.menuIndex ?? 0, Math.max(commands.length - 1, 0))
  /*
    What the command in the draft takes, once the menu has closed over it.

    Accepting `/agents` settles the command and closes the list, which is the
    moment its `[name]` stops being visible anywhere — so it is shown here
    instead, above the composer, for exactly as long as the arguments are blank.
  */
  const signature = signatureFor(allCommands, draft)

  // The machine derives menu state from the names, so they have to stay current
  // as availability changes.
  const nameKey = availableNames.join('\u0000')
  useEffect(() => {
    session?.send({ type: 'SET_COMMANDS', names: nameKey ? nameKey.split('\u0000') : [] })
  }, [nameKey, session])

  /** Tab, or a click: put the command in the draft and stop there. */
  const complete = (i: number) => {
    const c = commands[i]
    if (!c) return
    // `completionFor` decides the trailing space: a command that takes an
    // argument leaves you mid-sentence, one that does not is finished.
    session?.send({ type: 'MENU_COMPLETE', name: completionFor(c).trimEnd() })
  }

  /** Enter: send. A draft that names a command runs it instead of posting it. */
  const submit = () => {
    const name = invokedCommand(draft, allCommands.map(commandLabel))
    const command = name ? allCommands.find((c) => commandLabel(c) === name) : undefined
    /*
      Only varnick's commands are run here. An agent command has no `run` and is
      deliberately not given one: it is sent, as text, and the CLI executes it —
      which is how it worked before this menu could name them, and the path this
      change was careful not to touch.
    */
    if (command?.run) {
      command.run(commandArgument(draft, name ?? ''))
      session?.send({ type: 'EDIT_DRAFT', text: '' })
      return
    }
    /*
      And nothing is sent when there is nothing to send it to.

      The draft stays in the composer, which is what makes this a refusal rather
      than a loss: press send again once the agent is up. What it prevents is the
      case measured behind ticket 56 — an agent host that exited while the Tauri
      host and the Harness runtime stayed alive, so a message typed afterwards
      was appended to the transcript and written to the mirror with no process
      that had ever received it. `agentCanAnswer` is the rule; the line under the
      composer is what says so.
    */
    if (!agentCanAnswer(agentState)) return
    if (sessionCan({ type: 'SEND' })) session?.send({ type: 'SEND' })
  }

  // One label, read by the welcome box and by the composer, so the two cannot
  // disagree about what the next turn runs on.
  const modelLabel = MODELS.find((m) => m.id === s?.context.model)?.label ?? 'opus-5'

  /*
    Whether the runtime panel has been put away, read once for the two places
    that answer to it: the toggle in the status line and the column itself.

    The Session's, not this component's — ADR-0001, and the reason a `useState`
    here would be worse than indirection: the states page renders this same
    function with a frozen actor, so a reading held beside the machine is a
    reading no card could park in and `drive.ts` could never reach. The fallback
    is the shown reading, which is what a window with no Session yet should
    look like: on first run there is no conversation and the panel describing
    the agent is the most useful thing in the window.
  */
  const runtimeHidden = s?.context.runtimeHidden ?? false

  // Only what is actually wrong, and only while it is wrong.
  const problem = harnessProblem(ctx, agentState)
  /*
    Whether first-run setup is on screen, asked of the machine.

    Read here as well as inside {@link CredentialSetup} because "Starting the
    agent…" must not sit above a screen that says nothing has started. Same
    question, same probe, one answer.
  */
  const settingUp = snapshot.can({ type: 'STORE_CREDENTIAL', kind: ctx.storingKind, value: 'x' })
  const credentialState = toPath((snapshot.value as Record<string, unknown>).credential)
  const storing = credentialState === 'storing'
  // A mint is the same moment as a store from the surface's side — first-run
  // setup, in flight — and a different wait: it takes minutes and it is waiting
  // on the developer rather than on the keychain.
  const minting = credentialState === 'minting'
  const starting = !session && !problem && !settingUp && !storing && !minting

  /*
    First run takes the whole surface, and that is the honest rendering rather
    than a stylistic preference.

    It was a panel above the composer for one build, and the composer under it
    did nothing: the Session is spawned on `agent.running` (see harness.ts), so
    with no credential `session` is null and every `session?.send(...)` below is
    a no-op. A control that silently does nothing is exactly the affordance this
    project keeps ruling against — the state has no handler, so there should be
    no button rather than a dead one. The welcome box has the same problem one
    step further on: it greets a developer as though something had started.

    The sandbox problem line stays, because it is the one thing that can be
    wrong while setup is on screen and pasting a credential will not fix it.
  */
  if (settingUp || storing || minting) {
    return (
      <div className="flex h-full flex-col" style={{ background: 'var(--ground)' }}>
        <div className="min-h-0 flex-1 overflow-y-auto px-6 py-4">
          <div className="space-y-3" style={{ maxWidth: 'var(--prose)' }}>
            <CredentialSetup snapshot={snapshot} send={send} />

            <CredentialWaiting snapshot={snapshot} send={send} />

            {problem && (
              <div style={{ color: 'var(--bad)' }}>
                <span aria-hidden>✗ </span>
                {problem.text}{' '}
                {problem.event && (
                  <button
                    onClick={() => {
                      onRecover?.()
                      send(problem.event!)
                    }}
                    style={{ color: 'var(--accent)' }}
                  >
                    {problem.action}
                  </button>
                )}
              </div>
            )}
          </div>
        </div>
      </div>
    )
  }

  /*
    Reading a Worktree's changes takes the whole surface, for the reason first-run
    setup does above it rather than as a second answer to the same question.

    A diff is what The Wide Measure Rule is written about — prose caps at 110ch
    and a diff must not wrap at all — so it takes the widest thing on screen, and
    a large diff is the normal case here rather than the edge case. Reading four
    hundred lines of one in the 320px panel beside the chat is not reading it.

    Nothing is lost while it is open. The Session, the agent and the listing are
    machines this does not touch, so `close` brings the conversation back exactly
    as it was — which is also why this is a branch in the render rather than a
    route: a route would be a second place the window can be, and this is one
    thing a developer is doing with the window they are already in.
  */
  if (ctx.worktreeDiff) {
    return (
      <div className="flex h-full flex-col" style={{ background: 'var(--ground)' }}>
        {/* The admission stays. A seeded run invents this diff too. */}
        <SeededStrip mode={mode} />
        {/*
          And so does the merge report, which is the one band that has to be on
          both screens. A merge is started from *this* view, and the branch it
          was about is gone by the time it lands — so a report only the chat
          could show would appear behind a diff of a worktree that no longer
          exists, with nothing on screen to say what happened.
        */}
        <MergeReportBand snapshot={snapshot} send={send} />
        <ReapReportBand snapshot={snapshot} send={send} />
        <WorktreeDiffView diff={ctx.worktreeDiff} snapshot={snapshot} send={send} />
      </div>
    )
  }

  return (
    <div className="flex h-full flex-col" style={{ background: 'var(--ground)' }}>
      {/*
        The seeded warning, on a strip of its own.

        It used to ride the plan-usage strip, which is how cutting that strip
        nearly took the build's only admission that it is not measuring anything
        with it. That coupling was never deliberate: the marker gates on `mode`
        and on nothing else, so it belongs to the whole surface rather than to
        one row of figures — and a strip that only appeared under a subscription
        meant an API-key run in seeded mode said nothing at all.

        Rendered here rather than hidden, so a DOM snapshot agrees with what
        is on screen. In a live run the component returns null and the row is
        not in the document.
      */}
      <SeededStrip mode={mode} />

      {/*
        What is waiting to be merged, above everything it is about.

        It was in the right-hand column under the runtime panel, which scrolls,
        so the most consequential thing on the screen — code that will decide
        what the agent may do, waiting for a human — was reachable only by
        scrolling past a description of the agent. Here it is outside the
        transcript's scroller and above it, so it cannot be scrolled away from,
        and it is full width because branch names and paths must not wrap (The
        Wide Measure Rule).

        It renders nothing at all when there is nothing waiting, which is what
        makes a permanent slot affordable: see ReviewPanel, where that decision
        and the reason a listing in flight is also silent are written down.
      */}
      {/*
        And what the last merge did, above that.

        Above rather than below, because the two say different kinds of thing:
        the list is work waiting, and this is something that already happened to
        the tree the window is running from. Both are silent when they have
        nothing to say, so in the ordinary case neither band exists.
      */}
      <MergeReportBand snapshot={snapshot} send={send} />
      <ReapReportBand snapshot={snapshot} send={send} />

      <ReviewPanel snapshot={snapshot} send={send} />

      <div className="flex min-h-0 flex-1">
        <div className="flex min-w-0 flex-1 flex-col">
          <div ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto px-6 py-4">
            {/*
              The transcript runs to the width of the window, and is the one
              block on the surface that is not capped.

              It was capped at `var(--prose)` with everything else, which on a
              wide window drew the conversation into a 110ch strip on the left
              and left the rest of the screen empty. That is not what the cap
              is for: The Wide Measure Rule exists so that tool output, diffs
              and absolute paths are not wrapped, and a transcript is mostly
              those. The prompt rows made it plainest — `ClaudeMessage` draws a
              user turn as a full-width bar, and a full-width bar that stops in
              the middle of the window reads as a layout that failed rather
              than as a measure that was chosen.

              A terminal does the same thing: the text is as wide as the window
              the developer sized. The cap stays everywhere it is genuinely
              prose — first-run setup, the report bands, `#/states` — which are
              paragraphs someone reads rather than a stream they scan.
            */}
            <div className="space-y-3">
              {/*
                Every prop is passed explicitly. The component's defaults carry
                another project's user, org and release notes, and PRODUCT.md is
                clear that nothing fabricated ships.

                `cwd` and `org` are empty for the same reason, one step further
                on: a stranger's clone is not the author's. This surface is a
                pure function of `(snapshot, send)` — ADR-0001 — so it has no
                filesystem to ask and nothing true to put here. An invented path
                would be a lie on the first frame of a fresh clone, which is
                exactly what it used to be.

                The model is read from the Session rather than written down, so
                the welcome box and the composer cannot disagree about what the
                next turn runs on.

                The version is read the same way, one step further out: it is
                the root manifest's, resolved when this renderer was served or
                built. It was a literal, and a literal made a release a change
                to Core — a number that could disagree with the manifest, in a
                file that has to typecheck. `#/states` and the live chat both
                render this component, so there is no second place for it to be
                wrong.
              */}
              <ClaudeHeader
                cwd=""
                model={modelLabel}
                user="you"
                org=""
                version={VARNICK_VERSION_LABEL}
                tips={['Describe what you want built and the agent goes and builds it']}
                whatsNew={[]}
              />

              {starting && <div style={{ color: 'var(--fg-faint)' }}>Starting the agent…</div>}

              {/*
                First-run setup, before anything else on the screen. It is not a
                problem line and it is not an error: it is what a stranger who
                just cloned this sees, and the only thing they can usefully do.
              */}
              <CredentialSetup snapshot={snapshot} send={send} />

              <CredentialWaiting snapshot={snapshot} send={send} />

              {problem && (
                <div style={{ color: 'var(--bad)' }}>
                  <span aria-hidden>✗ </span>
                  {problem.text}{' '}
                  {problem.event && (
                    <button
                      onClick={() => {
                        onRecover?.()
                        send(problem.event!)
                      }}
                      style={{ color: 'var(--accent)' }}
                    >
                      {problem.action}
                    </button>
                  )}
                </div>
              )}

              {/*
                The one thing a restored conversation owes the developer.

                The mirror is redacted on the way in, so a message can read
                `[redacted]` where a secret value was. That is not undone —
                reading a secret back onto the screen after deliberately keeping
                it off disk would defeat the redaction, and a second unredacted
                copy would be a durable plaintext secret store kept for looks.
                What is owed is that the developer can tell they are reading the
                record rather than what they typed. Said once, above the
                transcript it is about, in the same shape as every other thing
                this surface admits — and gone once the transcript is.
              */}
              {restoredRedacted && (s?.context.messages.length ?? 0) > 0 && (
                <div style={{ color: 'var(--warn)' }}>
                  <span aria-hidden>⚠ </span>
                  Restored from the Session mirror — secret values are kept off disk, so{' '}
                  <span style={{ color: 'var(--fg-dim)' }}>[redacted]</span> stands where one was.
                </div>
              )}

              {/*
                The agent writes Markdown and always has. Until it was rendered,
                the transcript showed `**Blocked:**` and a fenced diff as the
                characters they are made of — the developer was reading the
                source of an answer rather than the answer.

                Only the agent's half. A user message is what the developer
                typed and is shown as typed: rendering it would mean a prompt
                about `*` displaying something other than what was sent, and the
                one thing this surface owes is that both halves say what was
                actually said.
              */}
              {(s?.context.messages ?? []).map((m) =>
                /*
                  A tool call is a fact, and it is rendered as one.

                  It used to arrive as the line `⚙ Read(/x)` inside the answer's
                  Markdown, which meant the transcript could not tell a tool the
                  agent *called* from a tool the agent *wrote about* — and what
                  a tool returned was nowhere at all, because the Turn dropped
                  the half of the stream carrying it.

                  `ClaudeToolCall` is brainless's own, vendored like the message
                  and header components around it, and it keeps Claude Code's
                  ⏺ / ⎿ grammar with a real disclosure: expandable by keyboard,
                  announced to screen readers. It is given the detail as
                  children only when there is detail, so a call whose whole
                  answer is one line renders as a fact rather than as a
                  disclosure that opens onto nothing.
                */
                m.tool ? (
                  <ClaudeToolCall
                    key={m.id}
                    tool={m.tool.name}
                    arg={m.tool.argument}
                    // A call that has not answered yet says so. This is the
                    // four-minute case: the tool is working, and the alternative
                    // to saying that is a window that looks hung.
                    result={m.tool.result ?? 'running…'}
                    status={m.tool.status}
                  >
                    {m.tool.detail}
                  </ClaudeToolCall>
                ) : m.role === 'user' ? (
                  <ClaudeMessage key={m.id} role="user">
                    {m.text}
                    {/* The record has to say a picture went, or a message
                        reading "what is wrong here?" is a transcript that lies
                        about the conversation. A count, because the mirror
                        keeps no bytes — see Message in domain.ts. */}
                    {m.attachments ? (
                      <span style={{ color: 'var(--fg-faint)' }}>
                        {m.text ? '  ' : ''}⧉ {m.attachments} image
                        {m.attachments === 1 ? '' : 's'}
                      </span>
                    ) : null}
                  </ClaudeMessage>
                ) : (
                  <div key={m.id}>
                    {/* Why the agent started talking, when nobody asked it to.

                        Without this the answer appears in the scrollback with
                        no visible cause, which reads as the agent talking to
                        itself — and a developer who cannot tell why it started
                        cannot tell whether to trust it. The text is the
                        runtime's own, read off the message stream host-side;
                        Core renders it and does not compose it. */}
                    {m.cause && (
                      <div
                        className="mb-1 flex items-center gap-2 text-[11.5px]"
                        style={{ color: 'var(--fg-faint)' }}
                      >
                        <span aria-hidden className="h-px w-4" style={{ background: 'var(--fg-faint)' }} />
                        <span>{m.cause}</span>
                        <span aria-hidden className="h-px min-w-0 flex-1" style={{ background: 'var(--fg-faint)' }} />
                      </div>
                    )}
                    <ClaudeMessage role="assistant">
                      <Markdown text={m.text} />
                    </ClaudeMessage>
                  </div>
                ),
              )}

              {/* Rendered while it streams, for the same reason it is rendered
                  when it lands: a half-arrived answer is the one being read
                  most closely. The parser runs an unterminated fence to the end
                  of what has arrived rather than failing on it. */}
              {s?.context.partial && (
                <ClaudeMessage>
                  <Markdown text={s.context.partial} />
                </ClaudeMessage>
              )}

              {working && <ClaudeThinking running showTokens={false} />}

              {/* What the working line cannot say: that four subagents are
                  running and how far along each is. A Turn that spawns them
                  looked exactly like a Turn that was hung, and the only way to
                  tell was reading the SDK's transcripts off disk.

                  A sibling of ClaudeThinking rather than a prop on it: that is a
                  brainless component and this is varnick's fact. Rendered
                  whenever the list is non-empty rather than gated on `working`,
                  so a backgrounded task does not vanish between Turns. */}
              {(s?.context.tasks.length ?? 0) > 0 && <RunningTasks tasks={s!.context.tasks} />}

              {turn === 'failed' && s?.context.turnError && (
                <div className="flex flex-wrap items-baseline gap-x-3" style={{ color: 'var(--bad)' }}>
                  <span>
                    <span aria-hidden>✗ </span>
                    {s.context.turnError}
                  </span>
                  {sessionCan({ type: 'RETRY_TURN' }) && (
                    <button onClick={() => session?.send({ type: 'RETRY_TURN' })} style={{ color: 'var(--accent)' }}>
                      retry
                    </button>
                  )}
                  {sessionCan({ type: 'DISMISS_TURN_ERROR' }) && (
                    <button
                      onClick={() => session?.send({ type: 'DISMISS_TURN_ERROR' })}
                      style={{ color: 'var(--fg-dim)' }}
                    >
                      dismiss
                    </button>
                  )}
                </div>
              )}

              {s?.context.saveError && (
                <div className="flex flex-wrap items-baseline gap-x-3" style={{ color: 'var(--warn)' }}>
                  <span>
                    <span aria-hidden>⚠ </span>
                    Not saved — {s.context.saveError}
                  </span>
                  {sessionCan({ type: 'RETRY_SAVE' }) && (
                    <button onClick={() => session?.send({ type: 'RETRY_SAVE' })} style={{ color: 'var(--accent)' }}>
                      retry
                    </button>
                  )}
                </div>
              )}
            </div>
          </div>

          {/*
            The composer, which may not grow past the window.

            `shrink-0` keeps it from being squashed by the transcript above;
            `min-w-0` and the menu's own height cap keep it from doing the
            squashing. Without the cap, a ninety-row menu grew this column until
            the row it sits in outgrew the viewport — and the Surface panel
            beside it was pushed off the side and rendered blank.
          */}
          <div className="min-w-0 shrink-0 px-6 pb-4">
            {menuOpen && (
              <SlashMenu
                commands={commands}
                activeIndex={menuIndex}
                onHover={(i) => session?.send({ type: 'MENU_MOVE', delta: i - menuIndex, count: commands.length })}
                onPick={complete}
              />
            )}
            {/*
              What the accepted command takes, in the gap the menu leaves.

              Accepting `/model` settles the command and closes the list, which
              is the moment its values stop being visible anywhere — so they are
              here instead, for exactly as long as the argument is blank. Once
              you have typed one you are answering the question rather than
              asking it, and the bar goes.

              This is also the only place the hint appears now. In a row it
              made the name column ragged and told you about ninety commands you
              had not chosen; here it is about the one you did.
            */}
            {!menuOpen && signature !== null && (
              <div
                /*
                  The same surface the menu has, because it occupies the same
                  slot: the bar appears exactly where the list was standing a
                  keystroke earlier. On the chat's own background it read as a
                  line of the conversation rather than as part of the composer.
                */
                /*
                  Flush against the composer, with no gap. It is about the line
                  you are typing, and a space between them made it read as a
                  note about the conversation instead.
                */
                className="flex items-baseline gap-2 px-2 py-1 text-[11.5px]"
                style={{
                  color: 'var(--fg-faint)',
                  background: 'var(--ground-raised)',
                  border: '1px solid var(--rule)',
                }}
              >
                <span style={{ color: 'var(--accent)' }}>{commandLabel(signature)}</span>
                <span style={{ color: 'var(--fg-dim)' }}>{signature.argumentHint}</span>
                {signature.description && (
                  <span className="min-w-0 flex-1 truncate">{signature.description}</span>
                )}
              </div>
            )}
            {/*
              What is going with the next message, and a way to take it back.

              Above the composer rather than inside it, because the field is a
              textarea and a picture is not text. Square, hairline, no preview —
              a thumbnail would be the first image in the product and DESIGN.md
              has no vocabulary for one; the developer knows what they just
              pasted, and what they need is confirmation it was taken and a way
              to undo it.
            */}
            {(s?.context.pending.length ?? 0) > 0 && (
              <div className="flex flex-wrap gap-2 pb-1 text-[12px]">
                {(s?.context.pending ?? []).map((image, i) => (
                  <span
                    key={i}
                    className="flex items-baseline gap-2 px-1.5 py-0.5"
                    style={{ border: '1px solid var(--rule)', color: 'var(--fg-dim)' }}
                  >
                    <span aria-hidden>⧉</span>
                    {/* Numbered to match the marker in the draft: the chip and
                        the text are the same picture, and a developer editing
                        the sentence needs to know which one they are moving. */}
                    {imageMarker(i)} · {image.mediaType.replace('image/', '')} ·{' '}
                    {sizeOf(image.data)}
                    <button
                      aria-label={`Remove attachment ${i + 1}`}
                      style={{ color: 'var(--accent)' }}
                      onClick={() => session?.send({ type: 'DETACH_IMAGE', index: i })}
                    >
                      remove
                    </button>
                  </span>
                ))}
              </div>
            )}

            <ClaudePrompt
              value={draft}
              /*
                Three things the field can be for, and the third is the one
                worth having: with no agent running, the placeholder says so
                where a developer is already looking. Typing still works and the
                draft is kept — what does not happen is a message going into the
                transcript with nothing alive to answer it.
              */
              placeholder={
                !agentCanAnswer(agentState)
                  ? 'no agent is running — nothing would answer this'
                  : working
                    ? 'working — esc to interrupt'
                    : 'What should the agent build?  /  for commands'
              }
              /*
                Both status lines off, and the status moved below.

                brainless renders the effort chip *above* the input, which put
                it between the signature bar and the field the bar is about —
                so the one line explaining what you are typing was separated
                from where you type it. The facts are the same; they are now a
                footer under the composer, which is also where every terminal
                client puts them.

                `mode` was already off: varnick has no mode cycling, so the
                line would describe a control that does not exist.
              */
              effort={false}
              model={undefined}
              mode={false}
              /*
                A screenshot is a paste, which is the only way most of them are
                ever moved. `clipboardData.items` is where an image arrives —
                `getData('text')` is empty for one, which is why a paste that
                looked like it did nothing did exactly nothing before this.

                Read as base64 and never as a path. The clipboard holds bytes,
                and the file a screenshot came from is on the developer's disk
                under `$HOME`, which the Sandbox denies — an agent handed a path
                would be handed something it cannot open.
              */
              onPaste={(e) => {
                const files = [...e.clipboardData.items]
                  .filter((item) => item.kind === 'file' && IMAGE_TYPES.includes(item.type))
                  .map((item) => item.getAsFile())
                  .filter((file): file is File => file !== null)
                if (files.length === 0) return
                // Only once there is something to attach: a text paste must
                // still reach the field, and preventing it here would break
                // pasting a path or a stack trace, which is most pastes.
                e.preventDefault()
                /*
                  The marker goes in at the cursor, which is what makes several
                  screenshots a conversation rather than a pile.

                  Read before the await, because `currentTarget` is pooled and
                  the caret will have moved by the time the bytes are ready. The
                  numbering continues from what is already attached, so a second
                  paste is [Image #2] rather than a second [Image #1].
                */
                const field = e.currentTarget
                const caret = field.selectionStart ?? draft.length
                const already = s?.context.pending.length ?? 0
                const markers = files.map((_, i) => imageMarker(already + i)).join(' ')
                void Promise.all(files.map(asPastedImage)).then((images) => {
                  session?.send({ type: 'ATTACH_IMAGES', images })
                  session?.send({
                    type: 'EDIT_DRAFT',
                    text: `${draft.slice(0, caret)}${markers} ${draft.slice(caret)}`,
                  })
                })
              }}
              onChange={(e) => session?.send({ type: 'EDIT_DRAFT', text: e.target.value })}
              onKeyDown={(e) => {
                /*
                  Word motion, and it is the first thing in this handler on
                  purpose.

                  It matches on `e.code` — the physical key — rather than on
                  `e.key`, because by the time this runs `e.key` is already `ƒ`
                  or `∫`: the Option key composes those on a US layout, and a
                  binding written against them would be a binding for one
                  keyboard. `preventDefault` is unconditional on a match, and
                  that is the whole of what stops the glyph reaching the draft;
                  it is the failure this fixes, and it was found after sending
                  rather than while typing.

                  Above the slash-menu branch, so a menu that has no use for
                  these motions does not swallow them: ⌥f while `/mod` is
                  filtering the list moves the caret and leaves the list exactly
                  where it was.

                  Every index here comes from `domain.ts` (ADR-0001). What is
                  left is reading the keystroke, calling the function and
                  assigning the selection, which is what makes it acceptable
                  that this branch is the one part of the change `drive.ts`
                  cannot reach.
                */
                if (e.altKey && (e.code === 'KeyF' || e.code === 'KeyB')) {
                  e.preventDefault()
                  const field = e.currentTarget
                  /*
                    The head is the end that travels and the anchor is the end
                    that stays, and which is which is the only thing
                    `selectionDirection` is for. Without it, ⇧⌥b followed by ⇧⌥f
                    would grow the selection at both ends instead of shrinking
                    it back, because the anchor would silently become whichever
                    end happened to be the smaller number.
                  */
                  const backwards = field.selectionDirection === 'backward'
                  const start = field.selectionStart ?? 0
                  const end = field.selectionEnd ?? start
                  const head = backwards ? start : end
                  const anchor = backwards ? end : start
                  const moved =
                    e.code === 'KeyF'
                      ? wordBoundaryForward(field.value, head)
                      : wordBoundaryBackward(field.value, head)
                  /*
                    One call rather than two assignments. `selectionStart` and
                    `selectionEnd` clamp against each other as they are written,
                    so setting a start past the current end collapses the
                    selection on the way through and the second write has
                    nothing left to extend. `setSelectionRange` sets both and
                    the direction together, and it is also the only way to say
                    which end moved.
                  */
                  if (e.shiftKey) {
                    field.setSelectionRange(
                      Math.min(anchor, moved),
                      Math.max(anchor, moved),
                      moved < anchor ? 'backward' : 'forward',
                    )
                  } else {
                    field.setSelectionRange(moved, moved)
                  }
                  return
                }
                if (menuOpen) {
                  // While the menu is open the keyboard belongs to it. SEND is
                  // already refused by the machine's guard; this is the rest.
                  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
                    e.preventDefault()
                    session?.send({
                      type: 'MENU_MOVE',
                      delta: e.key === 'ArrowDown' ? 1 : -1,
                      count: commands.length,
                    })
                    return
                  }
                  if (e.key === 'Tab') {
                    e.preventDefault()
                    complete(menuIndex)
                    return
                  }
                  if (e.key === 'Escape') {
                    e.preventDefault()
                    session?.send({ type: 'MENU_DISMISS' })
                    return
                  }
                }
                // Enter sends; shift+Enter is how a second line is typed. The
                // field is a textarea now (see claude-prompt.tsx), and one
                // whose Enter always submits is an input with extra steps.
                if (e.key === 'Enter' && !e.shiftKey) {
                  e.preventDefault()
                  submit()
                }
                if (e.key === 'Escape' && sessionCan({ type: 'INTERRUPT' })) {
                  session?.send({ type: 'INTERRUPT' })
                }
              }}
            />

            {/*
              What this Session is set to, under the thing it is set on.

              Order is what you change most often first: the model, then the
              effort, then how full the window is — which is a reading rather
              than a setting and belongs at the end. The `/effort` hint that
              used to ride the chip is gone: it named a command in a status
              line, and the menu is where commands are found.
            */}
            <div
              className="mt-1.5 flex items-baseline gap-2 px-1 text-[11.5px]"
              style={{ color: 'var(--fg-faint)' }}
            >
              <span style={{ color: 'var(--fg-dim)' }}>{modelLabel}</span>
              <span aria-hidden>·</span>
              <span>{EFFORT_GLYPH[s?.context.effort ?? 'xhigh']} {s?.context.effort ?? 'xhigh'}</span>
              <span aria-hidden>·</span>
              <span data-numeric>
                {formatContext(
                  s?.context.tokensUsed ?? 0,
                  CONTEXT_WINDOW[s?.context.model ?? 'claude-opus-5'],
                )}
              </span>
              {/*
                And the one control on this line, which is here because the
                thing it controls can be gone.

                The obvious place for it is the runtime panel's own header, and
                that place is unusable: the panel is what is being hidden, so a
                control inside it leaves with it and the only way back would be
                a menu item or a keystroke nobody was told about. This status
                line is the one piece of chrome on the surface that is on screen
                whatever the panel and the Surfaces are doing, which makes it
                the only honest home for a control that has to survive its own
                subject.

                Last on the line rather than first, because the three readings
                before it are what the *next Turn* runs on and this is not about
                the conversation at all.

                Rendered only when the machine would take the event, like every
                other control here — with no credential there is no Session,
                every `session?.send` below it is a no-op, and a word that does
                nothing when clicked is the affordance this file keeps ruling
                against. Once a Session exists the event is accepted at the
                root, so from the developer's side it is simply always there.
              */}
              {sessionCan({ type: 'TOGGLE_RUNTIME' }) && (
                <>
                  <span aria-hidden>·</span>
                  {/*
                    A toggle button rather than two words that swap. `runtime`
                    stays put and `aria-pressed` carries the reading — pressed
                    means the panel is up — so a screen reader hears one control
                    changing state rather than a control appearing and another
                    vanishing. Sighted readers get the same fact as colour: the
                    selected/unselected treatment DESIGN.md gives choice buttons,
                    said with the only two properties a bare word has.
                  */}
                  <button
                    aria-label="Runtime panel"
                    aria-pressed={!runtimeHidden}
                    onClick={() => session?.send({ type: 'TOGGLE_RUNTIME' })}
                    style={{ color: runtimeHidden ? 'var(--fg-dim)' : 'var(--accent)' }}
                  >
                    runtime
                  </button>
                </>
              )}
            </div>
          </div>
        </div>

        {/*
          The Surfaces, beside the conversation that built them.

          Stacked in the order discovery found them, and that is the whole of the
          arrangement — a way to place several is a layout system, which is what
          a fork builds. What must be true here is narrower and load-bearing: one
          Surface failing leaves its siblings rendered and the chat on the left
          untouched (ADR-0004).

          The column no longer appears only once a Surface exists: the runtime
          panel above them is Core's own, and it is worth most in a clone with no
          Surfaces at all — which is every clone on its first launch, and the one
          where "what is this agent, actually" is hardest to answer from
          anywhere else.

          It does have to go when there is nothing left to put in it, and that
          is why the condition is written out rather than being the panel's own
          `hidden`. 320px of border and empty scroll area is not a smaller cost
          than the panel — the transcript is uncapped and takes whatever this
          column leaves it, so every pixel held here is a pixel a diff does not
          get, and a gutter kept for a panel that is not there would give the
          developer nothing back for the click. Hiding Core's panel must still
          leave Userspace's output
          exactly where it was (ADR-0004), which is why the two halves of this
          condition are separate and why a loaded Surface keeps the column
          standing on its own.
        */}
        {(!runtimeHidden || ctx.surfaces.length > 0) && (
          <aside
            className="min-h-0 w-[320px] shrink-0 overflow-y-auto"
            style={{ borderLeft: '1px solid var(--rule)' }}
          >
            {!runtimeHidden && <RuntimePanel report={ctx.runtime} agentState={agentState} />}
            {/*
              The pending list was here, under the runtime panel, and it has moved
              above the conversation.

              The argument for putting it here was that Core's own panels belong
              together and a clone with no Surfaces would still have something in
              this column. Both are still true and neither survived contact with
              the column scrolling: *nothing the agent finished should wait
              unnoticed* is not a claim you can make from below the fold. The
              runtime panel stays, because what the agent is can wait to be
              scrolled to.
            */}
            {ctx.surfaces.map((ref) => (
              <SurfacePanel
                key={ref.id}
                surface={ref}
                resolveSurface={resolveSurface}
                onUnload={(id) => send({ type: 'UNLOAD_SURFACE', id })}
              />
            ))}
          </aside>
        )}
      </div>
    </div>
  )
}

/**
 * One Surface, in whichever of its states it is in.
 *
 * Every branch is the machine's, read rather than inferred, and `retry` appears
 * because `failed` accepts `RETRY` — the same rule as every other control here.
 * A loaded Surface has no retry button because the state has no handler.
 */
function SurfacePanel({
  surface,
  resolveSurface,
  onUnload,
}: {
  surface: ActorRefFrom<typeof surfaceMachine>
  resolveSurface?: (modulePath: string) => ComponentType | undefined
  onUnload: (id: string) => void
}) {
  const snap = surface.getSnapshot()
  const { descriptor, error, attempts } = snap.context
  const state = toPath(snap.value)
  const View = state === 'loaded' ? resolveSurface?.(descriptor.modulePath) : undefined

  return (
    <section className="px-4 py-3" style={{ borderBottom: '1px solid var(--rule)' }}>
      <div className="flex items-baseline gap-2 text-[12px]">
        <h2 style={{ color: 'var(--fg)' }}>{descriptor.name}</h2>
        <code style={{ color: 'var(--fg-faint)' }}>{state}</code>
        {/*
          UNLOAD_SURFACE to the parent, not UNLOAD to the child. The child event
          drives the Surface to `unloaded`, which is final — but the parent keeps
          the ref, so the id stays in the set discovery treats as already known
          and the panel can never come back. One dead panel until relaunch.
        */}
        {snap.can({ type: 'UNLOAD' }) && (
          <button
            className="ml-auto"
            onClick={() => onUnload(descriptor.id)}
            style={{ color: 'var(--fg-faint)' }}
          >
            unload
          </button>
        )}
      </div>

      <div className="mt-2">
        {state === 'loading' && (
          <p className="text-[12px]" style={{ color: 'var(--fg-faint)' }}>
            Loading {descriptor.modulePath}
            {attempts > 1 ? ` — attempt ${attempts}` : ''}…
          </p>
        )}

        {/*
          What a module that does not compile looks like: the reason, in full,
          against the Surface it belongs to. Not a toast and not a console line —
          the failure has a place on screen because the Surface does, and the
          chat is still there to ask about it.
        */}
        {state === 'failed' && (
          <div className="text-[12px]" style={{ color: 'var(--bad)' }}>
            <p>
              <span aria-hidden>✗ </span>
              {error ?? 'The module did not load.'}
            </p>
            {/*
              Which attempt this was. A retry that lands back on the same
              sentence is indistinguishable from a button that did nothing, and
              "did the retry run?" is the first thing a developer asks when the
              module they just fixed still will not load.
            */}
            {attempts > 1 && (
              <p style={{ color: 'var(--fg-faint)' }}>attempt {attempts}</p>
            )}
            {snap.can({ type: 'RETRY' }) && (
              <button
                className="mt-1.5"
                onClick={() => surface.send({ type: 'RETRY' })}
                style={{ color: 'var(--accent)' }}
              >
                retry
              </button>
            )}
          </div>
        )}

        {/*
          Userspace's code, running in Core's window. `View` is whatever the
          module default-exported; if this build never imported one there is
          nothing here to draw, and nothing is drawn.
        */}
        {View && <View />}
      </div>
    </section>
  )
}

/*
  A `PlanUsage` strip was here, above the chat: `plan usage · 5h n% · week n%`,
  gated on the credential being a subscription.

  It is gone because it never had a number to show. Ticket 23 made it absent
  under an API key rather than permanently empty, which was correct and was not
  the thing standing between the developer and a figure — under the only
  subscription varnick can hold, a `claude setup-token` credential, the session
  reports `rate_limits_available: false` and does not even identify itself as a
  subscription. Four routes to the windows were measured and all four are
  closed; the one credential that answers is the interactive OAuth login, which
  ADR-0011 refuses to hold. See ticket 31.

  It was never rendered against a live figure, only a seeded one — which is
  exactly the shape `SeededMarker` exists to keep honest, and exactly the reason
  it survived this long without anyone noticing it could not populate.
*/

/**
 * The row the seeded marker sits on.
 *
 * Its own component because the marker was previously reachable only through
 * the plan-usage strip, and one gate — the credential's kind — was silently
 * deciding both "are there figures" and "does this build admit it is seeded".
 * Those are unrelated questions and only one of them survives.
 */
function SeededStrip({ mode }: { mode: ActorMode }) {
  if (mode === 'live') return null
  return (
    <div
      className="flex items-center px-6 py-1.5 text-[11.5px]"
      style={{ borderBottom: '1px solid var(--rule)', color: 'var(--fg-faint)' }}
    >
      <SeededMarker mode={mode} />
    </div>
  )
}

/**
 * The one place the build admits what it is.
 *
 * It gates on `mode`, and only on `mode`. A seeded run invents every number on
 * this screen — plausibly and deliberately — so the warning is true whatever
 * else is wired, and it goes away when a run stops being seeded rather than when
 * some list empties.
 *
 * The unimplemented list is read for the tooltip and for nothing else. This was
 * written the other way round once, and driving it showed the difference: a
 * list-driven marker goes quiet on the last wiring while a seeded surface is
 * still rendering seeded figures, which is the exact claim it exists to stop
 * anyone making.
 *
 * What the tooltip *says* comes from `seededDetail`, because the list emptied
 * and the copy did not: it named an empty list and then advised appending
 * `?actors=live`, which is the default and names no actor it could fail on. The
 * branch lives in actors/index.ts so `drive.ts` can reach it — this component
 * cannot be imported outside Vite.
 */
function SeededMarker({ mode }: { mode: ActorMode }) {
  const [open, setOpen] = useState(false)
  const detail = seededDetail()
  if (mode === 'live') return null
  return (
    <span className="relative ml-auto">
      <button
        onClick={() => setOpen((o) => !o)}
        style={{ color: 'var(--warn)' }}
        aria-expanded={open}
      >
        seeded data — nothing here is measured
      </button>
      {open && (
        <span
          className="absolute right-0 z-10 mt-1 block w-[380px] p-3 text-left leading-relaxed"
          style={{
            background: 'var(--ground-raised)',
            border: '1px solid var(--rule)',
            color: 'var(--fg-dim)',
          }}
        >
          {detail.lead}
          {detail.names.length > 0 && (
            <span className="mt-1.5 block" style={{ color: 'var(--fg-faint)' }}>
              {detail.names.join(', ')}
            </span>
          )}
          <span className="mt-2 block">
            Machines, states and refusals are real; the services behind them are
            stubs. {detail.exit}
          </span>
        </span>
      )}
    </span>
  )
}

type Problem = { text: string; action?: string; event?: HarnessEvent }

/**
 * Nothing while the harness holds. A named problem and its recovery when it does not.
 *
 * Having no credential is deliberately not on this list. It used to be — one red
 * line telling a stranger with a fresh clone to go and run two `security`
 * commands in a terminal — and it is now {@link CredentialSetup}, because "you
 * cannot use this yet" is a screen rather than an error. Whatever went wrong on
 * the way there is rendered inside that screen, next to the field that fixes it.
 */
function harnessProblem(ctx: HarnessSnapshot['context'], agentState: string): Problem | null {
  if (ctx.sandboxState === 'unavailable') {
    return {
      text: `The sandbox could not be established${ctx.sandboxError ? ` — ${ctx.sandboxError}` : ''}. The agent will not run unconfined.`,
      action: 'try again',
      event: { type: 'CHECK_SANDBOX' },
    }
  }
  if (ctx.credentialState === 'rejected') {
    return { text: 'The stored credential was rejected.', action: 'try again', event: { type: 'READ_CREDENTIAL' } }
  }
  if (agentState === 'crashed') {
    return {
      text: `The agent stopped${ctx.agentError ? ` — ${ctx.agentError}` : ''}.`,
      action: 'restart',
      event: { type: 'RESTART' },
    }
  }
  return null
}

/**
 * What each kind means for the person choosing, in one sentence.
 *
 * Written from the developer's side rather than the machine's: the difference
 * that matters at this moment is what it costs them, not which environment
 * variable it becomes.
 *
 * `claude setup-token` used to be named here as the one step varnick did not do
 * for them. It does it now — the host runs that command itself, on a pty, and
 * the token goes from the terminal into the keychain without being shown to
 * anybody (ticket 25, and the bounded exception in ADR-0003). The command is
 * still named because minting it yourself and pasting the result still works,
 * and is what a developer does when the button fails.
 */
const CREDENTIAL_CHOICES = [
  {
    kind: 'subscription' as const,
    label: 'Claude subscription',
    note: 'Uses the plan you already pay for. varnick can get a long-lived token for you — you sign in, and the token goes straight into the keychain without ever being shown. If you would rather mint it yourself, `claude setup-token` prints one to paste here.',
    placeholder: 'Paste the token from `claude setup-token`',
  },
  {
    kind: 'api-key' as const,
    label: 'Anthropic API key',
    note: 'Bills each request to your Anthropic account. Paste a key from console.anthropic.com.',
    placeholder: 'Paste your API key',
  },
]

/**
 * Setup, while something it started is still running.
 *
 * Two waits with one thing in common — a credential is on its way into the
 * keychain and there is nothing for the developer to do here — and one
 * difference that decides how each reads. A store is a keychain write: seconds,
 * and the machine is the only actor. A mint is a person signing in to a website
 * in another window: minutes, and *they* are the actor, so this has to say what
 * they are waiting on and where to do it.
 *
 * Read off the machine's own state rather than from a prop, so a card at
 * `#/states` parked in either one shows this component and not a picture of it.
 *
 * The URL is rendered as text to copy rather than as a link, and that is the
 * honest control rather than a missing one: this is a webview, a bare `href`
 * navigates *it* rather than a browser, and a window that replaced varnick with
 * an authorization page would be a worse failure than the one this is the
 * fallback for.
 */
function CredentialWaiting({
  snapshot,
  send,
}: {
  snapshot: HarnessSnapshot
  send: (event: HarnessEvent) => void
}) {
  const ctx = snapshot.context
  const state = toPath((snapshot.value as Record<string, unknown>).credential)

  if (state === 'storing') {
    return (
      <div style={{ color: 'var(--fg-faint)', maxWidth: 'var(--prose)' }}>
        Storing your {ctx.storingKind === 'subscription' ? 'subscription token' : 'API key'} in the
        keychain…
      </div>
    )
  }

  if (state !== 'minting') return null

  return (
    <section className="space-y-2" style={{ maxWidth: 'var(--prose)' }}>
      <div style={{ color: 'var(--fg-dim)' }}>
        Waiting for you to sign in to Claude. varnick opened your browser; finish there and the
        token is written to the keychain here, without being shown to anyone.
      </div>

      {/*
        The fallback, and the reason the whole feature works from inside the
        window: the command tries to open a browser and prints this when it
        cannot. A machine with no default browser is not an edge case, and
        without this it would be a dead end with a spinner on it.
      */}
      {ctx.mintUrl && (
        <div className="space-y-1">
          <div style={{ color: 'var(--fg-faint)' }}>
            Browser didn&rsquo;t open? Copy this into one:
          </div>
          <code
            className="block break-all px-2 py-1.5 select-all"
            style={{ border: '1px solid var(--rule)', color: 'var(--fg-dim)' }}
          >
            {ctx.mintUrl}
          </code>
        </div>
      )}

      {/*
        The way out, which a sign-in needs more than most operations do: the
        thing being waited on is a person in a browser, and a person who closed
        that tab or signed in as the wrong account has changed their mind rather
        than hit an error.

        Without it the mint held its own start-refusal against the next attempt
        until the flow ended or a ten-minute watchdog fired, and the only way to
        shorten that was to find the process and kill it from a terminal.
      */}
      <button onClick={() => send({ type: 'CANCEL_MINT' })} style={{ color: 'var(--accent)' }}>
        cancel and start again
      </button>
    </section>
  )
}

/**
 * The screen a fresh clone opens on, and the whole of first-run setup.
 *
 * **Every control here comes from `can()`**, never from reading
 * `credentialState`. The screen appears because the machine would accept a
 * credential typed into it; the button appears because it would accept *this*
 * one. Those are two different questions and both are asked of the machine —
 * ADR-0001 — which is also why a card at `#/states` parked in `credential.absent`
 * shows this exact component rather than a picture of it.
 *
 * **The pasted value is the one string in Core that must not survive the
 * interaction.** It lives in a `useState` for as long as it takes to send, is
 * cleared the moment it is, and is never written into machine context, a `ref`
 * that outlives the screen, or anything the Session mirror can reach. The field
 * is `type="password"` and `autoComplete="off"` so the browser does not keep a
 * copy either.
 *
 * The kind, by contrast, *is* machine state — it is not a secret, and a radio
 * selection living in a component would be part of this surface the states page
 * could not park in.
 */
function CredentialSetup({
  snapshot,
  send,
}: {
  snapshot: HarnessSnapshot
  send: (event: HarnessEvent) => void
}) {
  const [pasted, setPasted] = useState('')
  const ctx = snapshot.context
  const kind = ctx.storingKind
  const choice = CREDENTIAL_CHOICES.find((c) => c.kind === kind) ?? CREDENTIAL_CHOICES[0]!

  /*
    Would the machine take a credential typed here at all?

    Probed with a stand-in rather than with the empty field, because the guard is
    about *this* paste and the question the screen asks is the prior one. The
    stand-in is a constant, is never sent, and is not a credential.
  */
  const accepts = snapshot.can({
    type: 'STORE_CREDENTIAL',
    kind,
    value: CREDENTIAL_SHAPE_PROBE[kind],
  })
  if (!accepts) return null

  // And would it take this one? Empty field, no button — from the machine's
  // guard rather than from a `disabled` this component decided on.
  const submittable = snapshot.can({ type: 'STORE_CREDENTIAL', kind, value: pasted })

  /*
    Why this one will not do, once there is something to say it about.

    The guard already refuses it, so this changes nothing about what the machine
    accepts — it changes what the developer is told. A disabled button beside a
    field that looks full is the shape of this failure that sent one credential
    into the keychain, an agent into a 401, and the surface into a state that had
    no way back to this field.

    Silent while the field is empty: "nothing pasted" is not news about an input
    nobody has typed in.
  */
  const problem = pasted.trim().length === 0 ? null : credentialShapeProblem(kind, pasted)

  /*
    Deliberately not an `onRecover`, which every other recovery on this surface
    calls.

    Re-arming start-up would let the owner's "read the credential once" step run
    again the moment a failed store landed back in `credential.absent` — and the
    read's own reason would overwrite the store's, so a developer whose keychain
    refused the write would be told nothing is stored instead. Nothing after a
    *successful* store needs re-arming: the agent was never started, so its
    step has not been attempted either.
  */
  const store = () => {
    if (!submittable) return
    send({ type: 'STORE_CREDENTIAL', kind, value: pasted })
    // Cleared on the way out, not on the way back: nothing that happens after
    // this needs it, and a failed store must not leave it sitting in a field.
    setPasted('')
  }

  return (
    <section className="space-y-3" style={{ maxWidth: 'var(--prose)' }}>
      <div>
        <h2 style={{ color: 'var(--fg)' }}>Connect varnick to Claude</h2>
        <p className="mt-1" style={{ color: 'var(--fg-dim)' }}>
          varnick runs a coding agent on this machine and needs your Claude credentials to do it.
          Paste one below and it goes straight into the macOS keychain — the agent it starts can
          never read it back.
        </p>
      </div>

      <div className="flex gap-2">
        {CREDENTIAL_CHOICES.map((option) => (
          <button
            key={option.kind}
            onClick={() => send({ type: 'CHOOSE_CREDENTIAL_KIND', kind: option.kind })}
            aria-pressed={option.kind === kind}
            className="px-3 py-1.5"
            style={{
              border: `1px solid ${option.kind === kind ? 'var(--accent)' : 'var(--rule)'}`,
              color: option.kind === kind ? 'var(--fg)' : 'var(--fg-dim)',
              background: option.kind === kind ? 'var(--ground-raised)' : 'transparent',
            }}
          >
            {option.label}
          </button>
        ))}
      </div>

      <p style={{ color: 'var(--fg-faint)' }}>{choice.note}</p>

      {/*
        The step that needs nothing typed, and it is offered first because it is
        the shorter path: a developer with a subscription signs in and is done.

        Two questions, both answered rather than assumed. Whether the machine
        would take a mint at all is `can()`, like every other control here.
        Whether *this* screen should offer one is the kind — a mint produces a
        subscription token, so offering it beside the API-key field would be a
        button that fills in the item the developer just said they did not want.
      */}
      {kind === 'subscription' && snapshot.can({ type: 'MINT_CREDENTIAL' }) && (
        <div className="flex flex-wrap items-baseline gap-x-3">
          <button
            onClick={() => send({ type: 'MINT_CREDENTIAL' })}
            className="px-3 py-1.5"
            style={{ color: 'var(--accent)', border: '1px solid var(--rule)' }}
          >
            sign in and get a token
          </button>
          <span style={{ color: 'var(--fg-faint)' }}>
            Opens your browser. varnick never sees the token — it goes from the command that
            printed it into the keychain.
          </span>
        </div>
      )}

      <div className="flex flex-wrap items-center gap-2">
        <input
          type="password"
          autoComplete="off"
          spellCheck={false}
          value={pasted}
          placeholder={choice.placeholder}
          onChange={(e) => setPasted(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault()
              store()
            }
          }}
          className="min-w-0 flex-1 px-2 py-1.5"
          style={{
            border: '1px solid var(--rule)',
            background: 'var(--ground)',
            color: 'var(--fg)',
          }}
        />
        {submittable && (
          <button onClick={store} className="px-3 py-1.5" style={{ color: 'var(--accent)', border: '1px solid var(--rule)' }}>
            store and continue
          </button>
        )}
      </div>

      {problem && (
        <p style={{ color: 'var(--bad)' }}>
          <span aria-hidden>✗ </span>
          {problem}
        </p>
      )}

      {/*
        Whatever went wrong last time, beside the field that fixes it. A failed
        read and a failed store both land here, because both leave the machine
        in `credential.absent` with a reason — and the reason is authored from a
        tag, so nothing a keychain printed and nothing that was pasted is in it.
      */}
      {ctx.credentialError && (
        <p style={{ color: 'var(--bad)' }}>
          <span aria-hidden>✗ </span>
          {ctx.credentialError}
        </p>
      )}

      <p style={{ color: 'var(--fg-faint)' }}>
        Prefer the terminal, or setting up a machine with no window? README.md has the `security`
        commands and the environment variables, and they still work.
      </p>
    </section>
  )
}
