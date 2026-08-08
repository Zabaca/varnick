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
 * either way, which is what ADR-0003's last consequence requires, and the
 * credential never crosses this bridge, which is what ADR-0008 requires.
 *
 * ## What may cross
 *
 * Nothing secret, in either direction. There is no request field that could
 * carry a credential and no answer that could return one: a credential read
 * answers with which store replied and the answer is rebuilt here rather than
 * forwarded, so a host that volunteered the value could not have it reach the
 * transcript or the Session mirror. The one string that is forwarded verbatim is
 * a *refusal's* `detail`, and the credential route cannot produce prose — every
 * failure in src-tauri/src/credential.rs is a `&'static str` tag.
 *
 * ## Nothing here may import Node
 *
 * This module is bundled into the webview. `import type` only, and the request
 * shapes are plain data. The host-side half lives in ./runtime.ts, which Core
 * never imports.
 */

import type { RestoredTranscript, StoredMessage } from './session.ts'
import { PLAN_USAGE_UNAVAILABLE, parsePlanUsageAnswer, type PlanUsage } from './subscription.ts'
import { parseTurnEvent, type TurnEvent } from './turn.ts'

/** Establish the Sandbox, or fail. Answers `{ ok: true }` and nothing else. */
export interface CheckSandboxRequest {
  readonly kind: 'check-sandbox'
}

/** Read the credential host-side. Answers with which store replied. */
export interface ReadCredentialRequest {
  readonly kind: 'read-credential'
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
export interface AwaitAgentExitRequest {
  readonly kind: 'await-agent-exit'
}

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

/** Stop the Turn named, keeping what has already arrived. */
export interface InterruptTurnRequest {
  readonly kind: 'interrupt-turn'
  readonly turnId: string
}

/**
 * Ask the running agent's Session what the plan has left.
 *
 * The one call whose answer is a *measurement*, and the reason it is on this
 * list rather than answered anywhere more convenient. The figures come from the
 * SDK's `get_usage` control request, which rides a live Session — and the only
 * Session varnick has is the confined one the Rust host spawned. Opening one
 * here, or in the runtime, or in Rust, would be a Claude Code process outside
 * `srt` running whatever `SessionStart` hook the agent wrote (ADR-0003).
 *
 * So a read with no agent running is a *refusal*, and that is the whole of the
 * design rather than a limitation of it: the honest answer to "how much runway
 * is left" when there is nothing to ask is the last one that was measured, which
 * on a first run is none at all.
 *
 * `requestId` is chosen by the caller, like a Turn's, so an answer can be
 * matched to the read that asked for it rather than to whichever read is
 * waiting.
 */
export interface ReadPlanUsageRequest {
  readonly kind: 'read-plan-usage'
  readonly requestId: string
}

/**
 * Ask the Session to summarise itself, freeing the context it is holding.
 *
 * Answers `{ ok: true }` and returns at once, exactly like `run-turn`: the
 * result arrives as a `compacted` event through {@link NextTurnEventRequest},
 * because a compaction takes as long as a model call and `turn.compacting` has
 * to be a state you can watch rather than a call you wait on.
 *
 * **There is no prompt on it, and that is the design.** The command the confined
 * session is given is a constant inside the Sandbox (`COMPACT_COMMAND` in
 * ./turn.ts), so nothing on this side of the bridge decides what a Compaction
 * says to the agent. The whole request is a Turn id.
 *
 * It rides the Session the agent process is already holding, for the same
 * reason a Turn does: summarising through a `query()` on the host would be a
 * second Claude Code process outside `srt`, which ADR-0003's last consequence
 * exists to prevent — and which reads as innocuous, because the code that does
 * it does not look like it starts an agent.
 */
export interface CompactSessionRequest {
  readonly kind: 'compact-session'
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
  | PersistSessionRequest
  | ReadSessionRequest
  | SpawnAgentRequest
  | StopAgentRequest
  | AwaitAgentExitRequest
  | RunTurnRequest
  | NextTurnEventRequest
  | InterruptTurnRequest
  | ReadPlanUsageRequest
  | CompactSessionRequest

/** What each call answers with, on success. */
export interface HarnessAnswers {
  'check-sandbox': { readonly ok: true }
  'read-credential': { readonly source: 'keychain' | 'env' }
  'persist-session': { readonly ok: true }
  'read-session': RestoredTranscript
  'spawn-agent': { readonly pid: number }
  'stop-agent': { readonly ok: true }
  'await-agent-exit': { readonly reason: string }
  'run-turn': { readonly ok: true }
  'next-turn-event': { readonly event: TurnEvent | null }
  'interrupt-turn': { readonly ok: true }
  // Two figures or nothing. There is no third answer, and no shape here that
  // could carry a plausible one — see {@link planUsageAnswer}.
  'read-plan-usage': PlanUsage
  'compact-session': { readonly ok: true }
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

function credentialAnswer(answer: unknown): { source: 'keychain' | 'env' } {
  const source = (answer as { source?: unknown } | null | undefined)?.source
  if (source !== 'keychain' && source !== 'env') throw new HarnessUnavailable('malformed')
  return { source }
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
 * Read the two figures, or fail.
 *
 * Three outcomes and no fourth, which is the point of this function existing at
 * all. A reading is rebuilt field by field like every other answer. A read the
 * Session could not answer is a *refusal* carrying an authored sentence — the
 * machine's `subscription` region sends that back to `unread` with context
 * untouched, which is how "leave whatever was last known" is spelled. And an
 * answer this build cannot read is `malformed` rather than anything numeric.
 *
 * `parsePlanUsageAnswer` stamps `source` rather than reading it: everything
 * arriving here came from the plan, through the confined Session, so no host
 * can make a measurement look seeded or a seed look measured.
 */
function planUsageAnswer(requestId: string, answer: unknown): PlanUsage {
  const payload = answer as { usage?: unknown } | null | undefined
  if (payload === null || typeof payload !== 'object' || !('usage' in payload)) {
    throw new HarnessUnavailable('malformed')
  }
  const read = parsePlanUsageAnswer({ kind: 'plan-usage', requestId, usage: payload.usage })
  if (read === null) throw new HarnessUnavailable('malformed')
  // The host was reached, the read happened, and it produced no figures. That
  // is a refusal rather than a malformed answer, and it is the ordinary outcome
  // when no agent is running.
  if (read.usage === null) throw new HarnessUnavailable('refused', PLAN_USAGE_UNAVAILABLE)
  return read.usage
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
    case 'next-turn-event':
      return turnEventAnswer(answer) as HarnessAnswers[R['kind']]
    case 'read-plan-usage':
      return planUsageAnswer(request.requestId, answer) as HarnessAnswers[R['kind']]
    case 'check-sandbox':
    case 'persist-session':
    case 'stop-agent':
    case 'run-turn':
    case 'interrupt-turn':
    case 'compact-session':
      return okAnswer(answer) as HarnessAnswers[R['kind']]
  }
}
