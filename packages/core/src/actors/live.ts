import { fromPromise } from 'xstate'
import { AGENT_STILL_RUNNING, callHarness } from '@varnick/harness/bridge'
import {
  CREDENTIAL_REJECTED_DETAIL,
  mintSubscriptionToken as mintSubscriptionTokenOnHost,
  readCredential as readCredentialFromHost,
  storeCredential as storeCredentialOnHost,
  type MintObserver,
} from '@varnick/harness/credentials'
import {
  isCredentialRejection,
  turnFailureMessage,
  type PastedImage,
  UNPROMPTED_CAUSE_UNKNOWN,
  type RuntimeReport,
  type RunningTask,
  type SlashCommand,
} from '@varnick/harness/turn'
import type {
  CredentialKind,
  CredentialReading,
  Effort,
  MergeReport,
  Message,
  ModelId,
  PendingWorktree,
  SandboxPolicy,
} from '../domain.ts'
import type { SessionInput } from '../machines/session.ts'

/*
  The real implementations.

  Every actor the machines declare has one now, which is why
  LIVE_NOT_IMPLEMENTED below is empty and why live is the default mode. While it
  was not, each missing actor was a function that threw at the moment it was
  invoked, so switching to live mode failed loudly at the actor that was missing
  rather than appearing to work — which is what a silent stub does, and what a
  missing `provide()` entry did once already in this project. Those functions
  went with the last entry; the list stayed, because it is read.

  The list is not what decides whether the seeded-data marker shows. That is
  `mode`, and deliberately: in seeded mode the warning is true whatever the list
  says, and a list-driven marker would go quiet on the last wiring while the
  surface was still rendering seeded numbers.

  How a live actor reaches the Harness: one seam, `callHarness`, and nothing
  below it. This module is bundled into the webview, so it imports no Node — the
  kernel, the keychain and the filesystem are all behind the bridge, in the
  host. A call with no host reaches the actor's own failure state carrying the
  reason; see @varnick/harness/bridge for where that answer comes from and why a
  missing host is a value rather than an exception.

  A block comment rather than a doc comment, because it describes the module and
  not whatever declaration follows it. Half of it was a doc comment on
  `notImplemented`, and that helper is gone.
*/

/**
 * Actors with no live implementation. Empty, and `drive.ts` fails if it is not.
 *
 * Reached from Core as `UNIMPLEMENTED` — see ./index.ts, which is what the
 * seeded-data marker names.
 */
export const LIVE_NOT_IMPLEMENTED = [] as const

/**
 * What a running Turn says that is not its result.
 *
 * Two things reach the machines from inside a Turn without being the Turn's
 * answer, and neither of them can travel back through the actor's promise: an
 * actor resolves once, and both of these happen while it is still running.
 *
 * They are also addressed to two different machines — a delta to the Session, a
 * rejected credential to the Harness — which is the deeper reason this is a
 * port rather than a return value. It is the same shape `AGENT_EXIT` already
 * uses: something the world did, delivered as an event by whoever owns the
 * machine. See hooks.ts, which is where both are sent.
 */
export interface TurnObserver {
  /**
   * Answer text or a tool call, as it arrives. Sent to the Session as
   * `STREAM_DELTA`, which is what puts it in `partial` — and therefore in the
   * message an interrupt keeps.
   */
  delta(text: string): void
  /**
   * The API refused the credential during a Turn.
   *
   * Sent to the Harness as `CREDENTIAL_REJECTED`. It is not enough for this to
   * fail the Turn: a refused credential is a fact about the credential, and a
   * developer who retries the Turn instead of fixing the key is retrying the
   * wrong thing.
   */
  credentialRejected(detail: string): void
  /**
   * The runtime described itself, at the start of a Turn.
   *
   * Sent to the Harness as `RUNTIME_REPORTED`. Addressed there rather than to
   * the Session for the same reason `credentialRejected` is: it is a fact about
   * the agent process, not about the conversation, and it outlives the Turn it
   * happened to arrive during.
   */
  runtimeReported(report: RuntimeReport): void
  /**
   * The runtime said which commands it accepts.
   *
   * Sent to the Harness as `COMMANDS_REPORTED`, beside the report and for the
   * same reason: it is a fact about the agent process rather than about the
   * conversation, and it outlives the Turn it happened to arrive during.
   */
  commandsReported(commands: readonly SlashCommand[]): void
  /**
   * The agent forgot the conversation.
   *
   * Sent to the Session as `CLEAR`, and it is the *only* thing that sends it
   * now. varnick used to own a `/clear` that emptied the transcript and told
   * the agent; the two could still disagree, because the CLI's own `/clear`
   * went round the outside. Listening for the fact covers both, and there is
   * only one way the transcript can empty.
   */
  conversationReset(): void
  /**
   * The agent summarised the conversation, and here is what it kept.
   *
   * Sent to the Session as `COMPACTED`, and — like {@link conversationReset} —
   * it is the only thing that sends it. varnick used to own a `/compact` that
   * asked for a summarisation and rewrote the transcript with the answer. That
   * covered the compactions varnick was asked for and no others: the CLI has
   * its own `/compact`, and an **auto-compaction has no command at all**, so a
   * full context window rewrote the agent and left the window showing a
   * conversation the agent no longer held.
   *
   * `tokensUsed` is what the Session measured afterwards, never what a summary
   * was assumed to cost — and `null` when it could not be measured, which
   * leaves the meter alone rather than replacing it with a figure nobody took.
   * The transcript follows either way.
   */
  conversationCompacted(summary: string, tokensUsed: number | null): void
  /**
   * Which subagents are running right now.
   *
   * Sent to the Session as `TASKS_REPORTED`. Addressed to the Session rather
   * than the Harness — unlike the report and the command list — because this
   * one **does not** outlive its Turn: it describes work the Turn started, and
   * when the Turn ends there is nothing left running to describe.
   *
   * A replacement each time, never a merge. What arrives is the whole set as of
   * that moment, already folded host-side; the empty array is the ordinary way
   * a panel empties.
   */
  tasksReported(tasks: readonly RunningTask[]): void
  /**
   * The agent said something nobody asked it for.
   *
   * Sent to the Session as `UNPROMPTED_ANSWER`, which appends it to the
   * transcript under what caused it and saves. A whole message rather than a
   * stream: it belongs to no Turn, and two answers accumulating into one
   * `partial` would produce a message that is neither.
   *
   * The cause is read off the message stream host-side and passed through
   * unchanged. Core does not compose one — a divider naming the wrong cause
   * would be a transcript that lies in a second way.
   */
  unpromptedAnswer(text: string, cause: string): void
}

/** An observer that drops everything. What a run with no owner gets. */
const silentObserver: TurnObserver = {
  delta: () => {},
  credentialRejected: () => {},
  runtimeReported: () => {},
  commandsReported: () => {},
  conversationReset: () => {},
  conversationCompacted: () => {},
  tasksReported: () => {},
  unpromptedAnswer: () => {},
}

/**
 * What a running mint says that is not its result.
 *
 * The same shape as {@link TurnObserver} and for the same reason: the URL to
 * sign in at arrives while the actor is still running, and an actor resolves
 * once. It is addressed to the Harness, which is also the machine that invoked
 * the actor — so unlike a delta this one could in principle have come back
 * another way, and it still cannot: by the time the promise settles the sign-in
 * is over and the link is of no use to anybody.
 *
 * Re-exported from the Harness rather than declared here, so the port the actor
 * is written against and the port the host's caller takes are one type.
 */
export type { MintObserver }

/** A mint nobody is watching. What a run with no owner gets. */
const silentMint: MintObserver = { authorizing: () => {} }

/**
 * A name for one Turn, unique within this window.
 *
 * A counter rather than `crypto.randomUUID`, which is only defined in a secure
 * context: the dev server runs at a tailnet address over plain HTTP, and that is
 * a real first-run path this codebase already branches on elsewhere. A Turn id
 * that threw there would fail the Turn with a `TypeError` instead of with the
 * missing host, which is the wrong problem to report.
 *
 * Uniqueness is only ever needed against the Turns this window has run — it
 * tells this Turn's events from an abandoned one's — so a counter is not a
 * weaker id, it is the right one.
 */
let turnsStarted = 0
const nextTurnId = () => `turn-${++turnsStarted}`

export function liveActors(
  observer: TurnObserver = silentObserver,
  mint: MintObserver = silentMint,
) {
  return {
    /*
      Establishes the real srt policy scoped to the clone, or fails.

      The Harness runtime does the work; this side only asks. There is no third
      branch here, by design: nothing in this actor can return ok without srt
      having said so, and a renderer with no host behind it reaches
      `sandbox.unavailable` carrying that reason rather than pretending.
    */
    checkSandbox: fromPromise<{ ok: true }, { policy: SandboxPolicy }>(() =>
      callHarness({ kind: 'check-sandbox' }),
    ),

    // Real. The Tauri host reads the credential and answers with which store
    // replied and what was in it — an API key or a subscription token. The
    // value never crosses the IPC boundary, so Core has no field that could
    // hold it. No host — a browser tab at the dev server — is a failed read
    // with a reason, not an unhandled rejection.
    readCredential: fromPromise<CredentialReading, Record<string, never>>(() =>
      readCredentialFromHost(),
    ),

    /*
      Real. The Tauri host writes the keychain item for the kind the developer
      chose, and answers with nothing.

      This is the only actor in the system whose input is secret, and the value
      goes exactly one way: into this call, across the bridge once, into the
      keychain. Nothing comes back — `storeCredential` returns `void`, so there
      is no shape here for a value to arrive in even by accident — and nothing on
      this side keeps a reference once the promise settles.

      Which item is written is the developer's choice. Which credential varnick
      *uses* is not: the machine follows a store with a read, and the host
      resolves the kind from what it finds. ADR-0011 is a rule about resolution
      and this does not touch it.
    */
    storeCredential: fromPromise<void, { kind: CredentialKind; value: string }>(({ input }) =>
      storeCredentialOnHost({ kind: input.kind, value: input.value }),
    ),

    /*
      Real. The host runs `claude setup-token` on a pty, reads the token out of
      the terminal UI it draws, and writes it into the keychain — all in the one
      process that may hold a credential.

      This actor is the strictest of the three credential actors and the reason
      is worth stating rather than assumed: a read answers with two facts, a
      store carries a value one way, and a mint carries nothing at all. There is
      no input, because the command is a constant on the host; there is no
      output, because the token is stored on the far side; and the one string
      that comes back — the URL to sign in at — is an OAuth request the
      developer's browser is about to make.

      Running a Claude Code process on the host is what ADR-0003's last
      consequence is about, and this is its one bounded exception, recorded
      there. The concern that rule exists for is that a *session* runs
      `SessionStart` hooks out of the clone, which the agent can write. This
      opens no session, runs a fixed argv, and is pointed at a directory outside
      the clone — so there is no such file to find. See src-tauri/src/mint.rs.
    */
    mintSubscriptionToken: fromPromise<void, Record<string, never>>(() =>
      mintSubscriptionTokenOnHost(mint),
    ),

    /*
      Real. The host asks the Harness runtime how to run the agent under the
      Sandbox it established, then spawns that with the credential in the
      child's environment — see src-tauri/src/agent.rs and ADR-0008.

      The refusal path is the important one: a runtime with no Sandbox
      established refuses to answer the wrapping, and the host returns that
      rather than spawning. So `agent.starting` reaches `agent.crashed` carrying
      the reason, and there is no state in which a process starts unconfined.
    */
    spawnAgent: fromPromise<{ pid: number }, { policy: SandboxPolicy }>(() =>
      callHarness({ kind: 'spawn-agent' }),
    ),

    /*
      Real. Everything the agent says that nobody asked it for, as it happens.

      **The defect this closes:** two complete answers were produced and never
      seen, because the only reader of the wire was a Turn — so an answer to a
      subagent finishing waited until the developer next typed something, and a
      developer who is waiting types nothing. That is the whole complaint.

      Its own queue, host-side, so it can never take an event a Turn is waiting
      for. A single queue with two readers would race: a wait lasts up to
      fifteen seconds in the host, and one already in flight when a Turn starts
      could swallow that Turn's first event.

      Runs until the state it is invoked on is left, which is when the agent
      stops. A failed call is retried rather than thrown: the pump going quiet
      would return varnick to the silence this replaced, and `callHarness`
      answers with a value rather than throwing when there is no host at all.
    */
    pumpUnprompted: fromPromise<void, Record<string, never>>(async ({ signal }) => {
      let text = ''
      let cause: string = UNPROMPTED_CAUSE_UNKNOWN
      while (!signal.aborted) {
        const answer = await callHarness({ kind: 'next-unprompted-event' }).catch(() => null)
        if (signal.aborted) return
        // No host, or a call that failed. Nothing to report and nothing to fix
        // from here; the next wait is the retry.
        if (answer === null) continue
        const event = answer.event
        // Nothing said in that window. A quiet agent is an ordinary agent.
        if (event === null) continue
        switch (event.kind) {
          case 'cause':
            cause = event.text
            break
          case 'delta':
          case 'tool':
          case 'hook':
          case 'task-line':
            text += event.text
            break
          case 'done':
            /*
              `event.text` is the run's own accumulation, tool calls included,
              so it is preferred over what was watched arriving here — the same
              rule a prompted Turn follows.

              Reset afterwards, because the next unprompted answer is a
              different answer: leaving the cause standing would put the last
              one's divider over it.
            */
            observer.unpromptedAnswer(event.text || text, cause)
            text = ''
            cause = UNPROMPTED_CAUSE_UNKNOWN
            break
          case 'failed':
            // An unprompted answer that failed is not a failed conversation.
            // Nothing was asked, so there is nothing to report as refused —
            // and the transcript is not the place to log the agent's own
            // background trouble.
            text = ''
            cause = UNPROMPTED_CAUSE_UNKNOWN
            break
          default:
            break
        }
      }
    }),

    /*
      Real. One Turn on the Session the agent process is already holding.

      Three calls, and none of them starts anything: `run-turn` puts the prompt
      on the pipe into the confined process, `next-turn-event` waits for what it
      says back, and `interrupt-turn` stops it. Opening a session here — which
      is what `query()` would do, and what this actor most obviously wants to do
      — would put a Claude Code process on the host outside srt, in a clone where
      the agent can write `.claude/settings.json`. ADR-0003's last consequence
      exists because that code does not look like it starts an agent.

      The loop is what makes the answer arrive in pieces. A call that returned
      the finished text could not report anything until there was nothing left
      to report, and "working" would be indistinguishable from "hung" for the
      whole of every turn.
    */
    runTurn: fromPromise<
      { text: string; tokensUsed: number },
      {
        sessionId: string
        prompt: string
        model: ModelId
        effort: Effort
        images: readonly PastedImage[]
      }
    >(async ({ input, signal }) => {
      // Chosen here so an interrupt can name the Turn it means and a late event
      // from an abandoned Turn can be told from this one's first word.
      const turnId = nextTurnId()

      await callHarness({
        kind: 'run-turn',
        turnId,
        prompt: input.prompt,
        model: input.model,
        effort: input.effort,
        images: input.images,
      })

      /*
        `INTERRUPT` moves the machine to `turn.interrupting`, which stops this
        actor and aborts this signal. Passing that on is what makes an interrupt
        cost seconds rather than the rest of the answer — without it the machine
        would stop listening while the agent kept working.

        The failure is swallowed on purpose: the machine has already left, and
        an interrupt that could not be delivered has no state to reach.
      */
      signal.addEventListener('abort', () => {
        void callHarness({ kind: 'interrupt-turn', turnId }).catch(() => {})
      })

      for (;;) {
        const { event } = await callHarness({ kind: 'next-turn-event' })

        // The machine stopped this actor. Whatever arrives now belongs to a Turn
        // nobody is listening to.
        if (signal.aborted) throw new Error('The turn was interrupted.')

        if (event === null) continue

        /*
          Something said by a Turn that is not this one — including an answer
          nobody asked for, which has its own reader now and must not be
          collected twice. `pumpUnprompted` above owns those, and it owns them
          from a separate queue, so nothing that reaches here belongs to it.
        */
        if (event.turnId !== turnId) continue

        switch (event.kind) {
          // A tool call is transcript, not decoration: it goes to the same
          // place the answer does, so it survives into the message an interrupt
          // keeps and into the mirror.
          case 'delta':
          case 'tool':
          // A hook that could not run is the same kind of fact as a tool call:
          // something happened beside the answer, and the transcript is where
          // it is auditable. Not a failure — the Turn answered.
          case 'hook':
          // A subagent starting or finishing, for the same reason once more:
          // the live panel is empty by the time anyone reads the answer back,
          // so the durable half has to be in the transcript.
          case 'task-line':
            observer.delta(event.text)
            break
          // Which subagents are running *now*. Ephemeral, and the only update
          // here that does not outlive its Turn.
          case 'tasks':
            observer.tasksReported(event.tasks)
            break
          // Not part of the answer, and deliberately not `break`ing into one:
          // the Turn it is stamped with is only how it got here.
          case 'runtime':
            observer.runtimeReported(event.report)
            break
          case 'commands':
            observer.commandsReported(event.commands)
            break
          case 'reset':
            observer.conversationReset()
            break
          /*
            The Session summarised itself part-way through this Turn — because
            the window filled, or because the developer typed the CLI's own
            `/compact`. Not part of the answer either, and deliberately not
            ending the Turn: the agent is still working, on a context it has
            just rewritten, and the answer that arrives belongs after the
            summary rather than instead of it.
          */
          case 'compacted':
            observer.conversationCompacted(event.summary, event.tokensUsed)
            break
          case 'done':
            return { text: event.text, tokensUsed: event.tokensUsed }
          case 'failed': {
            /*
              The one failure that is more than a failed Turn, and the two
              states it reaches say two different things on purpose:
              `turn.failed` explains why nothing was answered, and
              `credential.rejected` explains what is wrong with the credential.
              Reported before the throw, so the second is reached whether or not
              anyone ever dismisses the first.
            */
            if (isCredentialRejection(event.failure)) {
              observer.credentialRejected(CREDENTIAL_REJECTED_DETAIL)
            }
            // Authored from the tag, never from anything the API said — which
            // is where a key would be, on exactly this failure.
            throw new Error(turnFailureMessage(event.failure))
          }
        }
      }
    }),

    // The host-side mirror, alongside the Agent SDK's own persistence. One
    // JSON Lines file per Session under the app-data directory, which a
    // developer can read and back up with varnick not running. The store itself
    // lives in the Harness runtime, which is the only process with a filesystem.
    persistSession: fromPromise<
      { ok: true },
      { sessionId: string; messages: readonly Message[] }
    >(({ input }) =>
      callHarness({
        kind: 'persist-session',
        sessionId: input.sessionId,
        messages: input.messages,
      }),
    ),

    /*
      `compactSession` was here — the actor `turn.compacting` invoked, which put
      `/compact` on the Session's own input and waited for the summary to come
      back.

      It is gone with the state that invoked it. A compaction happens whether or
      not varnick asks: the CLI has the command, and a full context window needs
      no command at all. So varnick listens for the summary on the Turn channel
      instead — see the `compacted` case in `runTurn` above — which covers every
      way it can happen, including the way asking never could.

      What survives from it is the reason it was a control request rather than a
      `query()` on the host: summarising is a model call on *this* Session, and
      a summary produced by any other session frees no context at all, because
      the context that is full belongs to the agent process. Nothing here opens
      a session, which is what ADR-0003's last consequence is about.
    */

    /*
      Real. The host runs git in the clone and answers with what it said.

      The one actor whose value is that it is *not* the agent's. Everything else
      here reaches a service the agent has nothing to do with; this reaches a
      repository the agent has been writing to, and reports on it. So it is a
      bridge call rather than anything Core assembles, and the call carries no
      argument — the renderer asks what is pending, and does not get to say what
      the answer should be about. See packages/harness/src/worktrees.ts for the
      three read-only commands, and the route in src-tauri/src/bridge.rs.

      A host that is not there — a browser tab at the dev server — reaches
      `review.listFailed` with the reason, like every other call. That is the
      right state: nothing is known about what is pending, which is a different
      thing from knowing that nothing is.
    */
    listWorktrees: fromPromise<
      { worktrees: readonly PendingWorktree[]; liveTreeDirty: boolean },
      Record<string, never>
    >(() => callHarness({ kind: 'list-worktrees' })),

    /*
      Real, and the same actor one row down: git, host-side, for the one
      worktree a developer opened.

      The call carries which worktree and nothing else — no ref, no range, no
      command. The host compares that path against git's own listing and uses
      the ref git printed, so nothing composed on this side chooses what is
      read; see packages/harness/src/worktrees.ts, where that rule lives and is
      asserted.

      What comes back is the text git printed. Core parses it for the view
      (../diff.ts) rather than being handed a parsed shape, so nothing between
      git and the screen can drop a hunk while still answering the call — which
      matters more here than anywhere else on this surface, because this is the
      view a widening has to get past.
    */
    readWorktreeDiff: fromPromise<{ diff: string }, { path: string }>(({ input }) =>
      callHarness({ kind: 'read-worktree-diff', path: input.path }),
    ),

    /*
      Real, and the one actor on this whole list that **writes the developer's
      clone**.

      Everything else here reads a service or reports on a repository; this
      changes one. That is the gate ADR-0014 rests on rather than a hole in it:
      the call happens because a human clicked a control in `packages/core/**`,
      which the agent cannot write, with the branch's diff on the screen beside
      it. Nothing the agent says can produce this event.

      It carries which Worktree and nothing else — no ref, no message, no
      command — and the host resolves that path against git's own listing before
      anything is written. The refusals that matter are all on that side, on
      facts that are current: a dirty live tree, a branch that no longer merges,
      a directory somebody is standing in. See packages/harness/src/merge.ts.
    */
    mergeWorktree: fromPromise<MergeReport, { path: string }>(({ input }) =>
      callHarness({ kind: 'merge-worktree', path: input.path }),
    ),

    /*
      Real, and the only actor here that is not expected to answer.

      The host tears down what it holds and replaces its own image, so in the
      ordinary case this promise is still pending when the process it was made
      in stops existing. What it is *for* is the other case: a restart that did
      not happen leaves a developer believing they are running code they merged
      and are not, which is the failure this whole region exists to prevent.
    */
    restartVarnick: fromPromise<void, Record<string, never>>(async () => {
      await callHarness({ kind: 'restart-varnick' })
    }),

    // `loadSurface` is deliberately absent from both this list and the seeded
    // one. It has no seeded half in either mode — see actors/index.ts.
  }
}

/**
 * A conversation, as a relaunch gets it back.
 *
 * `input` is the same `SessionInput` the states page uses to park a Session
 * mid-flight — the entry point already existed, and this fills it from disk
 * instead of from a literal.
 */
export interface RestoredSession {
  readonly input: SessionInput
  /**
   * Whether the mirror kept something out of this transcript.
   *
   * The surface owes the developer this. The mirror is redacted on the write
   * path, so a restored message can read `[redacted]` where a secret value was,
   * and a developer looking at their own words has to be able to tell that they
   * are reading the record rather than what they typed.
   */
  readonly redacted: boolean
}

/**
 * Read the Session back from the host-side mirror.
 *
 * **The mirror, not the Agent SDK's own store.** The two answer different
 * questions and both keep their job: the SDK's copy is what the *agent* resumes
 * from — its context, its continuity — and the mirror is what varnick
 * *displays*, because it is the one that survives a build the agent just broke.
 * That is the case resume exists for. See
 * docs/adr/0009-resume-reads-the-mirror.md.
 *
 * Not an xstate actor, because it is not invoked by a machine: the Harness
 * spawns the Session from an input it holds in context, so the transcript has
 * to be in hand before the machine is created. Start-up owns this, the same way
 * it owns reading the credential — see pages/DesignedPage.tsx.
 *
 * Rejects with a {@link HarnessUnavailable} carrying the reason, like every
 * other call across the bridge. A failed read must never be flattened into an
 * empty transcript: that is what a first run looks like, and a Session that
 * started empty over a mirror that is not empty would replace it on the next
 * save — the loss the mirror exists to prevent.
 */
export async function restoreSession(sessionId: string): Promise<RestoredSession> {
  const { messages, redacted } = await callHarness({ kind: 'read-session', sessionId })
  return { input: { sessionId, messages: [...messages] }, redacted }
}

/**
 * Wait for the agent process to end, and answer with why.
 *
 * Not an actor, because the machine has none for it: an exit is something the
 * world did, so it arrives as an event (`AGENT_EXIT`) rather than as a promise a
 * state is waiting on. Whoever owns the machine calls this on each entry to
 * `agent.running` and sends the event when it settles — see hooks.ts.
 *
 * It waits rather than polls. The host holds the exit as state and answers
 * immediately if the process has already gone, which matters more than it
 * sounds: a process that dies on startup is the common failure, and the machine
 * reaches `running` before anyone can ask.
 *
 * A reason is always a real one — how the process ended, observed by the host
 * that spawned it. Nothing the agent printed is in it.
 */
export async function liveAgentExit(): Promise<string> {
  /*
    A wait that is re-asked, not a single wait held open.

    The host bounds each one and answers `still-running` when it expires, which
    is the same arrangement `next-turn-event` has and for the same reason: this
    call is issued on every entry to `agent.running`, and an unbounded one held
    a host thread for the life of a process that may run all day. They
    accumulated across restarts and page loads until the host had no thread left
    to answer anything, and the window sat for ever on its first call.

    The loop is what keeps the *contract* unchanged: this still resolves once,
    with a real reason, so nothing about `AGENT_EXIT` or the machine moves.
  */
  for (;;) {
    const { reason } = await callHarness({ kind: 'await-agent-exit' })
    if (reason !== AGENT_STILL_RUNNING) return reason
  }
}

/**
 * Stop the agent's whole process tree.
 *
 * `STOP` is a state the machine reaches on its own; without this the process
 * behind it would keep running, which would make `agent.down` a claim about the
 * UI rather than about the machine's world.
 */
/**
 * What the agent accepted last time, before it has said anything this time.
 *
 * The menu's cold start. Everything else about the command list is live — the
 * runtime reports it, `commands_changed` replaces it — but all of that arrives
 * on a Turn, and the moment a person types `/` is usually before they have run
 * one. Empty is an ordinary answer: a first launch has no cache.
 */
export async function liveCachedCommands(): Promise<readonly SlashCommand[]> {
  const { commands } = await callHarness({ kind: 'read-commands' })
  return commands
}

/*
  `liveForgetAgentContext` was here.

  It told the agent to forget, so varnick's own `/clear` could clear both
  halves. varnick no longer has a `/clear`: the CLI's is the one in the menu,
  and the transcript is cleared by listening for `conversation_reset` instead —
  which works however the clear was asked for, including from the agent itself.
*/

export async function liveStopAgent(): Promise<void> {
  await callHarness({ kind: 'stop-agent' })
}
