/**
 * The bridge — the one place a live actor reaches the Harness.
 *
 * ## Why there is a bridge at all
 *
 * Core runs in the Tauri webview. The Harness opens sockets, reads the keychain,
 * writes files and spawns processes, none of which a renderer can do. Before
 * this module there were three answers to that in three places: a `@vite-ignore`
 * dynamic import that resolved to nothing in a browser, a lazily-constructed
 * store that needed a `process` the renderer does not have, and one hand-written
 * Tauri command. Only the third worked. This is that third one, generalised.
 *
 * ## Where the other half runs
 *
 * Two host-side halves, not one, and the split is the whole design:
 *
 *   * **`read-credential` is answered by the Rust host itself.** The value must
 *     exist in exactly one process, and that process must be the one that spawns
 *     the agent subprocess and injects the value into its environment. Handing
 *     it to a TypeScript runtime would be a second place a secret lives.
 *   * **everything else is answered by the Harness runtime**, a long-lived
 *     Node process the Rust host starts and keeps. Long-lived because the
 *     Sandbox is established once and must stay established: srt's proxies live
 *     in the process that called `initialize()`, the agent has to be a child of
 *     that process for containment to wrap the tree (ADR-0003), and the Session
 *     mirror serialises its saves through a queue that a fresh process per call
 *     would not have.
 *
 * The runtime is a Node process, not a Claude Code process, and it is not the
 * process that starts one. The agent is spawned by the Rust host, using a
 * wrapping the runtime computed — argv, an environment overlay and a working
 * directory, none of them secret — because the credential has to go into the
 * child's environment and the credential lives in Rust. The agent is inside srt
 * either way, which is what ADR-0003's last consequence requires, and no
 * credential is ever *handed out* over this bridge, which is what ADR-0008
 * requires. One crosses inbound — see below.
 *
 * ## What may cross
 *
 * **Nothing secret comes back.** There is no answer on this bridge that could
 * return a credential: a read answers with which store replied and what was in
 * it, and the answer is rebuilt here rather than forwarded, so a host that
 * volunteered the value could not have it reach the transcript or the Session
 * mirror. The one string forwarded verbatim is a *refusal's* `detail`, and
 * neither credential route can produce prose — every failure in
 * src-tauri/src/credential.rs is a `&'static str` tag.
 *
 * **One request goes the other way**, and it is the exception this paragraph
 * used to be able to do without: {@link StoreCredentialRequest} carries a value
 * a developer pasted into the window, inbound, once. It has to — the window is
 * where a person types, and the keychain is reachable only from the host. What
 * makes that safe is not that it never happens but that it is one-way and
 * answered by Rust: the value reaches `Secret` before anything else touches it,
 * the reply is `{ ok: true }`, and `route_of` refuses to forward the call to the
 * Harness runtime, which would be a second process holding a credential.
 * Nothing in Core keeps it after the call — see ./credentials.ts.
 *
 * **And one call makes a credential without either side holding it.**
 * {@link MintSubscriptionTokenRequest} asks the Rust host to run
 * `claude setup-token`; the token is read off a pty and written to the keychain
 * inside that process, so it crosses this bridge in neither direction. What
 * comes back through {@link NextMintEventRequest} is an authorize URL — an OAuth
 * request the developer's browser is about to make — and an outcome tag.
 *
 * ## Nothing here may import Node
 *
 * This module is bundled into the webview. `import type` only, and the request
 * shapes are plain data. The host-side half lives in ./runtime.ts, which Core
 * never imports.
 */

import { parseMintEvent, type MintEvent } from './mint.ts'
import type { RestoredTranscript, StoredMessage } from './session.ts'
import type { Mergeability, PendingWorktree } from './worktrees.ts'
import type { CwdHolder, MergeReport } from './merge.ts'
import {
  normaliseCommands,
  parseTurnEvent,
  type PastedImage,
  type SlashCommand,
  type TurnEvent,
} from './turn.ts'

/** Establish the Sandbox, or fail. Answers `{ ok: true }` and nothing else. */
export interface CheckSandboxRequest {
  readonly kind: 'check-sandbox'
}

/** Read the credential host-side. Answers with which store replied. */
export interface ReadCredentialRequest {
  readonly kind: 'read-credential'
}

/**
 * Write a credential into the keychain, host-side. Answers `{ ok: true }`.
 *
 * **The one request on this bridge that carries a secret, and it carries it in
 * one direction only.** A developer pastes a key or a subscription token into
 * the window, it crosses once, the Rust host writes it into the keychain item
 * for `credentialKind`, and the answer is a constant. Nothing comes back: not
 * the value, not what `security` printed, not a message with either in it — see
 * src-tauri/src/credential.rs, where every failure is a `&'static str` tag.
 *
 * Answered by the Rust host and never forwarded, which is stricter here than
 * anywhere else on this bridge: forwarding a store to the Harness runtime would
 * put a credential on a pipe to a second process, which is exactly what ADR-0008
 * exists to prevent. `route_of` asserts it.
 *
 * `credentialKind` says which *item* is written, and that is all it says. The
 * host still resolves which credential to use by what it finds on the next read
 * — ADR-0011 refuses a stored preference, and this is not one.
 */
export interface StoreCredentialRequest {
  readonly kind: 'store-credential'
  readonly credentialKind: 'api-key' | 'subscription'
  readonly value: string
}

/**
 * Mint a subscription token, host-side. Answers `{ ok: true }` and returns at
 * once.
 *
 * **The one call that creates a credential rather than moving one.** The Rust
 * host runs `claude setup-token` on a pty, reads the token out of the terminal
 * UI it draws, and writes it into the keychain — all inside that process. There
 * is no field on this request and no shape on its answer that a token could
 * travel in, because the token never travels: it is minted and stored on the
 * same side of the bridge.
 *
 * There is nothing to configure and no argument to give. The command is a
 * constant in src-tauri/src/mint.rs, which is what
 * docs/adr/0003-containment-wraps-the-process-tree.md's bounded exception is
 * written around: one argv, never `query()`, never an SDK entry point.
 *
 * It returns before the mint finishes, exactly as `run-turn` does, and for a
 * blunter reason: the middle of it is a person signing in to a website in their
 * own browser. What happens meanwhile arrives through
 * {@link NextMintEventRequest}.
 */
export interface MintSubscriptionTokenRequest {
  readonly kind: 'mint-subscription-token'
}

/**
 * Wait for the next thing the running mint has to say.
 *
 * The same shape as `next-turn-event`, and `event: null` means the same thing:
 * nothing said yet, which for a mint is most of its life. Two events matter —
 * the authorize URL, shown as a fallback for a browser that did not open, and
 * the outcome — and neither is the token.
 */
export interface NextMintEventRequest {
  readonly kind: 'next-mint-event'
}

/** Write a transcript to the host-side Session mirror. */
export interface PersistSessionRequest {
  readonly kind: 'persist-session'
  readonly sessionId: string
  readonly messages: readonly StoredMessage[]
}

/**
 * Read a transcript back out of the host-side Session mirror.
 *
 * The Session named, and only that one. The store can hold several files and
 * this is not a search: varnick runs one conversation and asks for it by name,
 * because it has no way to *choose* between conversations and inventing one
 * here would invent a concept the glossary does not have.
 */
export interface ReadSessionRequest {
  readonly kind: 'read-session'
  readonly sessionId: string
}

/**
 * Start the agent under the established Sandbox. Answers with its pid.
 *
 * Answered by the Rust host, which asks the runtime for the wrapping and adds
 * the credential to the child's environment. There is no request field for the
 * credential and no way to supply one — see src-tauri/src/agent.rs.
 */
export interface SpawnAgentRequest {
  readonly kind: 'spawn-agent'
}

/** Stop the agent's whole process tree. Answers `{ ok: true }`. */
export interface StopAgentRequest {
  readonly kind: 'stop-agent'
}

/**
 * Wait for the running agent to exit, and answer with why.
 *
 * The one call that does not return promptly: it is how the process's own exit
 * reaches the machine as `AGENT_EXIT`. A request/response seam cannot push, and
 * a poll would make `agent.running` mean "running as of a second ago", so this
 * waits instead.
 */
/**
 * Forget the conversation the agent is holding.
 *
 * The other half of `/clear`, and it carries nothing: what the confined process
 * runs is a constant in ./turn.ts, so there is no field here for a prompt.
 */
/**
 * The commands the agent last reported, out of the host-side cache.
 *
 * Asked at start-up, because the live list can only arrive stamped with a Turn
 * id — so a window that has not run a Turn has never been told what the agent
 * accepts, which is exactly when someone types `/`. Answered by the runtime,
 * the process with a filesystem; the agent host is what wrote it.
 */
export interface ReadCommandsRequest {
  readonly kind: 'read-commands'
}

export interface ClearSessionRequest {
  readonly kind: 'clear-session'
}

/**
 * Which Worktrees hold commits the live tree does not, and what changed in each.
 *
 * **Produced by running git, host-side, and never by the agent.** This is the
 * call that shows what the agent changed, so a listing the agent composed would
 * be a listing the agent could shade — see ./worktrees.ts, which runs three
 * read-only commands and nothing else.
 *
 * Answered by the Harness runtime, which is the process with a filesystem and a
 * way to spawn a subprocess. It carries no credential and touches none, which is
 * the whole reason it is not the Rust host's.
 *
 * There is no field on this request and no worktree named in it. The renderer
 * asks what is pending; it does not get to say what the answer should be about.
 */
export interface ListWorktreesRequest {
  readonly kind: 'list-worktrees'
}

/**
 * Everything one pending Worktree changed, as a unified diff.
 *
 * The contents behind one row of the listing above, asked for when a developer
 * opens it. Answered by the same runtime for the same reasons, and produced by
 * git rather than by the agent for a sharper version of the same one: a listing
 * the agent could shade hides a branch, and a diff the agent could shade hides a
 * widening inside a branch somebody is about to merge.
 *
 * **This is the one call on the review path that carries a field**, and the
 * field is a selector rather than an argument. `path` is compared against what
 * `git worktree list` reported and the ref that reaches git's argv is the one
 * git printed; a path matching no pending worktree produces no diff command at
 * all. See ./worktrees.ts.
 */
export interface ReadWorktreeDiffRequest {
  readonly kind: 'read-worktree-diff'
  /** The absolute path of a pending worktree, as the listing reported it. */
  readonly path: string
}

/**
 * Land one pending Worktree on the live tree.
 *
 * **The one call on this bridge that writes the developer's clone**, and it is
 * on the bridge at all because the merge is the gate ADR-0014 rests on: a Core
 * change becomes running code when a human merges it, and the human is looking
 * at the diff in the window when they decide. The agent cannot ask for this —
 * nothing the agent says reaches the renderer's event stream, and the control
 * that sends it is in `packages/core/**`, which `denyWrite` refuses it.
 *
 * `path` is the same selector the diff's is: compared against what
 * `git worktree list` reported, never handed to git as an argument.
 *
 * Answered by the Harness runtime, for the reason the listing is — it is the
 * process with git in reach — and it carries no credential.
 */
export interface MergeWorktreeRequest {
  readonly kind: 'merge-worktree'
  /** The absolute path of a pending worktree, as the listing reported it. */
  readonly path: string
}

/**
 * Replace this process with a new one, having torn down what it holds.
 *
 * Asked for at exactly one moment: a merge has landed, so the window is now
 * running the code from *before* the change it just accepted. It is the same
 * action as **Restart varnick** on the View menu and it goes through the same
 * teardown — the point of putting it on the bridge is that the moment a restart
 * is owed is a moment varnick knows about and the developer would otherwise
 * have to remember.
 *
 * **This call does not answer.** The process is replaced while it is in flight,
 * so the only outcome the caller can observe is a restart that *failed* to
 * happen. See `worktreeMerge.restarting` in the Harness machine.
 */
export interface RestartVarnickRequest {
  readonly kind: 'restart-varnick'
}

export interface AwaitAgentExitRequest {
  readonly kind: 'await-agent-exit'
}

/**
 * What that call answers while the agent is still there.
 *
 * The wait is bounded host-side and the caller re-asks, which is the same
 * arrangement `next-turn-event` has and was arrived at the same way: an
 * unbounded wait is issued on every entry to `agent.running`, and each one held
 * a host thread for the life of a process that can run all day. They piled up
 * across restarts until the host had none left and the window sat for ever on
 * its first call.
 *
 * Not a failure and not an absence — the process is fine, this particular wait
 * simply ran out. Named on both sides of the wire from here; `STILL_RUNNING` in
 * src-tauri/src/agent.rs is the same string, and a test asserts they agree.
 */
export const AGENT_STILL_RUNNING = 'still-running'

/**
 * Run one Turn on the Session the agent process is already holding.
 *
 * Answers `{ ok: true }` and returns at once. The answer is not the Turn's
 * answer — that arrives as events, through {@link NextTurnEventRequest} — and
 * the split is the whole of "watch the response stream": a call that returned
 * the finished text could not report anything until there was nothing left to
 * report.
 *
 * `turnId` is chosen by the caller so an interrupt can name the Turn it means
 * and a stale event can be told from a current one.
 *
 * There is no field for a credential and no session to open: the prompt goes to
 * the process the Rust host spawned, inside `srt`, which is the only Claude Code
 * process varnick ever has (ADR-0003).
 */
export interface RunTurnRequest {
  readonly kind: 'run-turn'
  readonly turnId: string
  readonly prompt: string
  readonly model: string
  readonly effort: string
  /**
   * Pictures the developer pasted into the composer.
   *
   * The first bulk payload this bridge has ever carried — everything else on it
   * is a short string this codebase composed. It is validated on the way into
   * the confined process rather than here (see `parseImages` in ./turn.ts):
   * this side is the renderer, and the check that matters is the one the
   * sandboxed half performs on what it was handed.
   */
  readonly images?: readonly PastedImage[]
}

/**
 * Wait for the next thing the running Turn has to say.
 *
 * The second call that does not return promptly, for the same reason as
 * `await-agent-exit`: a request/response seam cannot push, and a poll would make
 * a streamed answer arrive in whatever rhythm the poll had rather than the
 * rhythm the agent produced it in.
 *
 * It waits with a limit rather than for ever, and `event: null` is what running
 * out of patience looks like. That is not a failure — a Turn that is thinking is
 * a working Turn — and it is what lets an abandoned wait end instead of holding
 * a host thread for the life of the process.
 */
export interface NextTurnEventRequest {
  readonly kind: 'next-turn-event'
}

/**
 * The next thing the agent said that nobody asked it for.
 *
 * A second queue rather than a filter over the one above, and the separation is
 * the whole point. A Turn drains the prompted queue while it runs; this is
 * drained by a pump that runs for the life of the agent — so an answer the
 * developer did not prompt reaches the window **when it happens**, instead of
 * waiting for whenever a Turn next happens to drain the wire.
 *
 * Two readers on one queue would race: a wait here lasts up to fifteen seconds
 * host-side, and one already in flight when a Turn starts could swallow that
 * Turn's first event. Sorted on the way in, that window does not exist.
 */
export interface NextUnpromptedEventRequest {
  readonly kind: 'next-unprompted-event'
}

/** Stop the Turn named, keeping what has already arrived. */
export interface InterruptTurnRequest {
  readonly kind: 'interrupt-turn'
  readonly turnId: string
}


/**
 * Every call the bridge carries.
 *
 * A closed union rather than a name and a payload: an actor cannot ask for
 * something the host has not agreed to answer, and adding a capability is a
 * change both halves see at compile time.
 *
 * `wrap-agent-command` is deliberately absent. It is a host-internal call from
 * Rust to the runtime, and putting it here would let the renderer ask for the
 * wrapping — harmless in itself, and one more thing that could be asked for.
 */
export type HarnessRequest =
  | CheckSandboxRequest
  | ReadCredentialRequest
  | StoreCredentialRequest
  | MintSubscriptionTokenRequest
  | NextMintEventRequest
  | PersistSessionRequest
  | ReadSessionRequest
  | SpawnAgentRequest
  | StopAgentRequest
  | AwaitAgentExitRequest
  | RunTurnRequest
  | NextTurnEventRequest
  | NextUnpromptedEventRequest
  | InterruptTurnRequest
  | ReadCommandsRequest
  | ListWorktreesRequest
  | ReadWorktreeDiffRequest
  | MergeWorktreeRequest
  | RestartVarnickRequest

/** What each call answers with, on success. */
export interface HarnessAnswers {
  'check-sandbox': { readonly ok: true }
  // Which store answered, and what was in it. Spelled out rather than imported
  // from ./credentials.ts, which imports this module.
  'read-credential': {
    readonly source: 'keychain' | 'env'
    readonly kind: 'api-key' | 'subscription'
  }
  // A constant. A store has nothing to report and no shape to report it in.
  'store-credential': { readonly ok: true }
  // A constant too, and for a sharper reason: the mint it starts produces a
  // credential, and this answer is what a credential would ride back in if
  // there were anywhere for it to sit.
  'mint-subscription-token': { readonly ok: true }
  // What the mint said, or that it has said nothing yet. Never the token.
  'next-mint-event': { readonly event: MintEvent | null }
  'persist-session': { readonly ok: true }
  'read-session': RestoredTranscript
  'spawn-agent': { readonly pid: number }
  'stop-agent': { readonly ok: true }
  'await-agent-exit': { readonly reason: string }
  'run-turn': { readonly ok: true }
  'next-turn-event': { readonly event: TurnEvent | null }
  // The same shape, from the other queue. Rebuilt by the same function: an
  // event is an event, and where it was waiting says nothing about its fields.
  'next-unprompted-event': { readonly event: TurnEvent | null }
  'interrupt-turn': { readonly ok: true }
  'read-commands': { readonly commands: readonly SlashCommand[] }
  // Summaries, never hunks. The diff of one worktree is fetched when a
  // developer opens it; a list that carried every hunk of every branch would
  // read the whole of a large branch before it could draw a row.
  'list-worktrees': {
    readonly worktrees: readonly PendingWorktree[]
    // A fact about the tree they would be merged into, answered in the same
    // call because it is a fact about the same moment. It decides whether a
    // merge control appears; the merge asks again on facts that are current.
    readonly liveTreeDirty: boolean
  }
  // The hunks of one of them, as git printed them. A string rather than a
  // parsed shape: what crosses is what git said, and Core parses it for the
  // view — so nothing between git and the screen can drop a hunk while still
  // answering the call.
  'read-worktree-diff': { readonly diff: string }
  // What landed, and what is left over. A merge that went in and a cleanup that
  // could not finish is a success with something to say, not a failure — see
  // `MergeReport` in ./merge.ts.
  'merge-worktree': MergeReport
  // A constant, and one the caller will almost never see: the process is
  // replaced while the call is in flight. What it is *for* is the case where
  // that does not happen.
  'restart-varnick': { readonly ok: true }
}

/**
 * Why a call produced no answer.
 *
 * Five, kept apart because each has a different single next action — the same
 * reason `CredentialAbsence` has three. `refused` is the only one that means the
 * Harness was reached and said no; the other four are all "the call never got
 * there", which is a different problem with a different fix.
 */
export const HARNESS_FAILURES = [
  /** No Tauri IPC. A browser tab is not a desktop app. */
  'no-host',
  /** There is a host, and it has no Harness runtime it could start. */
  'no-runtime',
  /** There was a runtime and it stopped answering mid-call. */
  'runtime-lost',
  /** The host answered with something this module cannot read. */
  'malformed',
  /** The Harness was reached, did the work, and it did not succeed. */
  'refused',
] as const

export type HarnessFailure = (typeof HARNESS_FAILURES)[number]

/**
 * What to do about a failure, in one sentence.
 *
 * Every message is authored here and selected by the tag. Nothing a host said is
 * interpolated into one except a refusal's `detail`, which is the Harness's own
 * reason for saying no and is the string `sandbox.unavailable` has always shown.
 */
export function harnessGuidance(failure: HarnessFailure, detail: string | null): string {
  switch (failure) {
    case 'no-host':
      return 'There is no host process here to run the Harness. varnick reaches the Harness through the desktop app — run `bun tauri dev` rather than opening the dev server in a browser.'
    case 'no-runtime':
      return 'The host could not start the Harness runtime. The Harness runs as a host-side process; check that `bun` is on the PATH the app was launched with.'
    case 'runtime-lost':
      return 'The Harness runtime stopped answering. It is started again on the next call, so trying again is the next step.'
    case 'malformed':
      return 'The host answered with something this build does not recognise. The app and the Harness are probably not the same version.'
    case 'refused':
      return detail ?? 'The Harness could not do it, and did not say why.'
  }
}

/**
 * A call that produced no answer, carrying which failure it was.
 *
 * `message` is the guidance verbatim, because every machine's `onError` records
 * `error.message` and the surface renders that string. This is the legibility
 * ticket 02 established for `no-host`, applied to the whole seam.
 */
export class HarnessUnavailable extends Error {
  readonly failure: HarnessFailure
  readonly detail: string | null

  constructor(failure: HarnessFailure, detail: string | null = null) {
    super(harnessGuidance(failure, detail))
    this.name = 'HarnessUnavailable'
    this.failure = failure
    this.detail = detail
  }
}

/**
 * The thing that carries a call to the host.
 *
 * An interface rather than a direct `invoke` so a test supplies its own. No test
 * may spawn a runtime, establish a sandbox or touch the real keychain, and this
 * is the seam that makes that structural instead of aspirational.
 */
export interface HarnessBridge {
  /** Resolves with whatever the host command returned; rejects with its `Err`. */
  call(request: HarnessRequest): Promise<unknown>
}

interface TauriInternals {
  invoke(command: string, payload?: unknown): Promise<unknown>
}

/** The Tauri command name. Mirrored in src-tauri/src/bridge.rs. */
const CALL_COMMAND = 'harness_call'

/**
 * The Tauri bridge, or `null` when there is not one.
 *
 * The dev server runs at a tailnet address in a plain browser, where Tauri IPC
 * does not exist. That is a real first-run path, not an edge case, so it is a
 * value to branch on rather than an exception to catch — and each actor reaches
 * its own failure state with the reason, like any other failed call.
 */
export function tauriHarnessBridge(): HarnessBridge | null {
  const internals = (globalThis as { __TAURI_INTERNALS__?: TauriInternals }).__TAURI_INTERNALS__
  if (!internals || typeof internals.invoke !== 'function') return null
  return { call: (request) => internals.invoke(CALL_COMMAND, { request }) }
}

/** Pull a failure out of whatever the host rejected with, without quoting it. */
function failureOf(rejection: unknown): HarnessUnavailable {
  const payload = rejection as { failure?: unknown; detail?: unknown } | null | undefined
  const named = payload?.failure
  if (typeof named !== 'string' || !(HARNESS_FAILURES as readonly string[]).includes(named)) {
    // A panic, a serialisation change, a bare string. Deliberately not reported
    // verbatim: an unrecognised payload is exactly the payload nobody has
    // checked for a secret.
    return new HarnessUnavailable('malformed')
  }
  const failure = named as HarnessFailure
  const detail = payload?.detail
  return new HarnessUnavailable(failure, typeof detail === 'string' ? detail : null)
}

/**
 * Read the `{ ok: true }` answers.
 *
 * Rebuilt rather than passed through — a host that volunteered extra fields
 * cannot have them forwarded into a machine's context, from where they would
 * reach the Session mirror.
 */
function okAnswer(answer: unknown): { ok: true } {
  if ((answer as { ok?: unknown } | null | undefined)?.ok !== true) {
    throw new HarnessUnavailable('malformed')
  }
  return { ok: true }
}

/**
 * A credential reading: two facts, and neither of them is the value.
 *
 * The kind is required rather than defaulted. It decides which variable the
 * agent is spawned with (ADR-0011), so filling it in here would be this side of
 * the bridge choosing an authentication method the host never resolved — and
 * the symptom would be an agent that starts and cannot authenticate.
 */
function credentialAnswer(answer: unknown): {
  source: 'keychain' | 'env'
  kind: 'api-key' | 'subscription'
} {
  const reading = answer as { source?: unknown; kind?: unknown } | null | undefined
  const source = reading?.source
  if (source !== 'keychain' && source !== 'env') throw new HarnessUnavailable('malformed')
  const kind = reading?.kind
  if (kind !== 'api-key' && kind !== 'subscription') throw new HarnessUnavailable('malformed')
  return { source, kind }
}

/** A started agent, as one number. Anything else is not a started agent. */
function spawnAnswer(answer: unknown): { pid: number } {
  const pid = (answer as { pid?: unknown } | null | undefined)?.pid
  if (typeof pid !== 'number' || !Number.isFinite(pid)) throw new HarnessUnavailable('malformed')
  return { pid }
}

/**
 * Why the process ended.
 *
 * A reason is required rather than optional: `agent.crashed` renders this
 * string, and an exit with nothing to say is the failure this seam exists to
 * turn into a legible one.
 */
function exitAnswer(answer: unknown): { reason: string } {
  const reason = (answer as { reason?: unknown } | null | undefined)?.reason
  if (typeof reason !== 'string' || reason.length === 0) {
    throw new HarnessUnavailable('malformed')
  }
  return { reason }
}

/**
 * Read a restored transcript back, message by message.
 *
 * Rebuilt like every other answer, and strict for a reason particular to this
 * one: a transcript the bridge cannot read has to be a failure rather than an
 * empty one. An empty transcript is what a first run looks like, and a Session
 * that started empty over a mirror that is not empty would replace it on the
 * next save — the loss the mirror exists to prevent.
 */
function transcriptAnswer(answer: unknown): RestoredTranscript {
  const payload = answer as { messages?: unknown; redacted?: unknown } | null | undefined
  if (!Array.isArray(payload?.messages)) throw new HarnessUnavailable('malformed')

  const messages: StoredMessage[] = []
  for (const entry of payload.messages) {
    const { id, role, text } = (entry ?? {}) as Record<string, unknown>
    if (typeof id !== 'string' || typeof text !== 'string') {
      throw new HarnessUnavailable('malformed')
    }
    if (role !== 'user' && role !== 'agent') throw new HarnessUnavailable('malformed')
    messages.push({ id, role, text })
  }

  return { messages, redacted: payload.redacted === true }
}

/**
 * Read one thing the Turn said, or that it has said nothing yet.
 *
 * Strict rather than forgiving, and the reason is particular to this answer: an
 * unreadable event skipped as if it were nothing would silently drop a `done`,
 * and the Turn would stream for ever with no failure to show for it. An absent
 * event is a different thing from an unreadable one, and only the first is a
 * value.
 */
function turnEventAnswer(answer: unknown): { event: TurnEvent | null } {
  const payload = answer as { event?: unknown } | null | undefined
  if (payload === null || typeof payload !== 'object' || !('event' in payload)) {
    throw new HarnessUnavailable('malformed')
  }
  if (payload.event === null) return { event: null }

  // Rebuilt, like every other answer. This one is written inside the Sandbox by
  // the process holding the agent, and its text lands in the transcript.
  const event = parseTurnEvent(payload.event)
  if (event === null) throw new HarnessUnavailable('malformed')
  return { event }
}

/**
 * Read one thing the mint said, or that it has said nothing yet.
 *
 * Strict for the same reason a Turn event is: an unreadable event skipped as if
 * it were nothing would drop the outcome, and the machine would sit in
 * `credential.minting` against a command that finished. An absent event is a
 * different thing from an unreadable one, and only the first is a value.
 */
function mintEventAnswer(answer: unknown): { event: MintEvent | null } {
  const payload = answer as { event?: unknown } | null | undefined
  if (payload === null || typeof payload !== 'object' || !('event' in payload)) {
    throw new HarnessUnavailable('malformed')
  }
  if (payload.event === null) return { event: null }

  // Rebuilt, like every other answer, and this one is read out of the same
  // buffer a live credential is in — see ./mint.ts.
  const event = parseMintEvent(payload.event)
  if (event === null) throw new HarnessUnavailable('malformed')
  return { event }
}

/**
 * Read the pending worktrees back, entry by entry.
 *
 * Rebuilt like every other answer, and strict for two reasons of its own. A
 * listing that could not be read must be a **failure** rather than an empty
 * list: `review.empty` says nothing is waiting to be merged, which is the one
 * sentence a review surface may not produce when it does not know. And a field
 * this build does not know about is dropped rather than forwarded — the next
 * ticket fetches a diff for one worktree on demand, so a body arriving here
 * would be a list rendering something it promised not to read.
 */
function worktreesAnswer(answer: unknown): {
  worktrees: readonly PendingWorktree[]
  liveTreeDirty: boolean
} {
  const payload = answer as { worktrees?: unknown; liveTreeDirty?: unknown } | null | undefined
  if (!Array.isArray(payload?.worktrees)) throw new HarnessUnavailable('malformed')
  // Not defaulted to `false`, which is the tempting one and the wrong one: it
  // decides whether a merge control appears, so a host this build cannot read
  // would put one over a tree nobody looked at.
  if (typeof payload.liveTreeDirty !== 'boolean') throw new HarnessUnavailable('malformed')

  const worktrees: PendingWorktree[] = []
  for (const entry of payload.worktrees) {
    const { path, branch, commits, changed, touchesFence, merge } = (entry ?? {}) as Record<
      string,
      unknown
    >
    if (typeof path !== 'string' || path.length === 0) throw new HarnessUnavailable('malformed')
    // `null` is a detached HEAD, which is a worktree with no branch rather than
    // a worktree whose branch went missing.
    if (branch !== null && typeof branch !== 'string') throw new HarnessUnavailable('malformed')
    if (typeof commits !== 'number' || !Number.isFinite(commits)) {
      throw new HarnessUnavailable('malformed')
    }
    if (typeof touchesFence !== 'boolean') throw new HarnessUnavailable('malformed')
    if (!Array.isArray(changed) || changed.some((name) => typeof name !== 'string')) {
      throw new HarnessUnavailable('malformed')
    }
    worktrees.push({
      path,
      branch,
      commits,
      changed: [...(changed as string[])],
      touchesFence,
      merge: mergeabilityOf(merge),
    })
  }

  return { worktrees, liveTreeDirty: payload.liveTreeDirty }
}

/**
 * Read one entry's merge answer back.
 *
 * Strict like everything around it, and **there is deliberately no default**.
 * The tempting one is `clean` — most branches are — and it is the single worst
 * value this function could invent: it would put a merge control on a row over
 * an answer nobody gave. `unknown` as a default is safer and still wrong, for
 * the reason the listing itself is strict: a shape this build cannot read is a
 * host and a window that disagree about what they are exchanging, and that is a
 * failure rather than a row with a hedge on it.
 *
 * A conflicted answer must name at least one file. The names are the whole of
 * what makes that state actionable — the surface prints them and tells the
 * developer to ask the agent to merge `main` down — so an empty list is a shape
 * the renderer could not honour.
 */
function mergeabilityOf(merge: unknown): Mergeability {
  const kind = (merge as { kind?: unknown } | null | undefined)?.kind
  if (kind === 'fast-forward' || kind === 'clean') return { kind }

  if (kind === 'conflicts') {
    const files = (merge as { files?: unknown }).files
    if (!Array.isArray(files) || files.length === 0) throw new HarnessUnavailable('malformed')
    if (files.some((name) => typeof name !== 'string')) throw new HarnessUnavailable('malformed')
    return { kind, files: [...(files as string[])] }
  }

  if (kind === 'unknown') {
    const reason = (merge as { reason?: unknown }).reason
    if (typeof reason !== 'string') throw new HarnessUnavailable('malformed')
    return { kind, reason }
  }

  throw new HarnessUnavailable('malformed')
}

/**
 * Read one worktree's hunks back.
 *
 * Strict for the reason the listing is strict, one step along: an answer this
 * module could not read, flattened into an empty string, would reach
 * `worktreeDiff.loaded` with no files in it — a view stating that the branch
 * about to be merged changed nothing, over a read that did not happen. An empty
 * diff is a real answer and is kept as one; anything that is not a string is a
 * failure.
 */
function diffAnswer(answer: unknown): { diff: string } {
  const payload = answer as { diff?: unknown } | null | undefined
  if (typeof payload?.diff !== 'string') throw new HarnessUnavailable('malformed')
  return { diff: payload.diff }
}

/**
 * Read what a merge did back.
 *
 * Strict, and this is the answer where being strict matters most on the whole
 * bridge: it describes something that has *already happened* to the developer's
 * clone. Every other validator here protects a rendering; this one protects a
 * developer's understanding of a tree that has changed underneath them.
 *
 * Which is exactly why there are no defaults and no optional fields. A missing
 * `worktreeRemoved` read as `false` would leave a row in the review band for a
 * directory that is gone; read as `true` it would drop one for a directory that
 * is still there. Both are the surface saying something confident about a
 * filesystem it did not look at, so an unreadable report is a failure and the
 * window says the merge could not be described rather than describing it wrong.
 */
function mergeAnswer(answer: unknown): MergeReport {
  const payload = (answer ?? {}) as Record<string, unknown>
  const { branch, commit, squashed, worktreeRemoved, branchDeleted, heldBy, leftOver } = payload

  if (typeof branch !== 'string' || branch.length === 0) throw new HarnessUnavailable('malformed')
  if (typeof commit !== 'string' || commit.length === 0) throw new HarnessUnavailable('malformed')
  if (typeof squashed !== 'number' || !Number.isFinite(squashed)) {
    throw new HarnessUnavailable('malformed')
  }
  if (typeof worktreeRemoved !== 'boolean') throw new HarnessUnavailable('malformed')
  if (typeof branchDeleted !== 'boolean') throw new HarnessUnavailable('malformed')
  if (leftOver !== null && typeof leftOver !== 'string') throw new HarnessUnavailable('malformed')
  if (!Array.isArray(heldBy)) throw new HarnessUnavailable('malformed')

  const holders: CwdHolder[] = []
  for (const holder of heldBy) {
    const { pid, command } = (holder ?? {}) as Record<string, unknown>
    if (typeof pid !== 'number' || !Number.isFinite(pid)) throw new HarnessUnavailable('malformed')
    if (typeof command !== 'string') throw new HarnessUnavailable('malformed')
    holders.push({ pid, command })
  }

  return { branch, commit, squashed, worktreeRemoved, branchDeleted, heldBy: holders, leftOver }
}

/**
 * Ask the host to do one thing.
 *
 * Every path out is either the declared answer or a thrown
 * {@link HarnessUnavailable}, so an actor can never reject with something its
 * machine's `onError` cannot describe.
 */
export async function callHarness<R extends HarnessRequest>(
  request: R,
  bridge: HarnessBridge | null = tauriHarnessBridge(),
): Promise<HarnessAnswers[R['kind']]> {
  if (bridge === null) throw new HarnessUnavailable('no-host')

  let answer: unknown
  try {
    answer = await bridge.call(request)
  } catch (rejection) {
    throw failureOf(rejection)
  }

  // The switch is exhaustive over the union; the cast is the price of writing
  // one function rather than three that differ only in their validator.
  switch (request.kind) {
    case 'read-credential':
      return credentialAnswer(answer) as HarnessAnswers[R['kind']]
    case 'read-session':
      return transcriptAnswer(answer) as HarnessAnswers[R['kind']]
    case 'spawn-agent':
      return spawnAnswer(answer) as HarnessAnswers[R['kind']]
    case 'await-agent-exit':
      return exitAnswer(answer) as HarnessAnswers[R['kind']]
    case 'read-commands':
      // Rebuilt like every other answer that crosses into Core.
      return { commands: normaliseCommands((answer as { commands?: unknown })?.commands) } as HarnessAnswers[R['kind']]
    case 'next-turn-event':
    case 'next-unprompted-event':
      return turnEventAnswer(answer) as HarnessAnswers[R['kind']]
    case 'next-mint-event':
      return mintEventAnswer(answer) as HarnessAnswers[R['kind']]
    case 'list-worktrees':
      return worktreesAnswer(answer) as HarnessAnswers[R['kind']]
    case 'read-worktree-diff':
      return diffAnswer(answer) as HarnessAnswers[R['kind']]
    case 'merge-worktree':
      return mergeAnswer(answer) as HarnessAnswers[R['kind']]
    case 'restart-varnick':
    case 'check-sandbox':
    case 'store-credential':
    case 'mint-subscription-token':
    case 'persist-session':
    case 'stop-agent':
    case 'run-turn':
    case 'interrupt-turn':
      return okAnswer(answer) as HarnessAnswers[R['kind']]
  }
}
