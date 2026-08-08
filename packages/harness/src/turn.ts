/**
 * One Turn, as the thing that reads a Session's messages.
 *
 * ## Why this is a module and not a loop inside the agent host
 *
 * The Turn is the only part of the Harness whose input is a live Claude Code
 * process, and it is the part most worth testing. So the process is not in here.
 * {@link beginTurn} takes SDK messages one at a time and answers with what the
 * machine should be told; the agent host is the twenty lines that feed it. That
 * split is not a testing convenience — a test that opened a session to exercise
 * this would put a Claude Code process on the machine outside `srt`, which
 * ADR-0003's last consequence says never happens, not even to ask a question.
 *
 * ## Nothing the API said is ever quoted
 *
 * A failed Turn reports a {@link TurnFailure} tag and the prose is authored in
 * {@link turnFailureMessage}, selected by that tag. This is the same rule as
 * `harnessGuidance` and `credentialGuidance`, and here it is load-bearing rather
 * than stylistic: an authentication failure is the error most likely to echo the
 * credential back, and `turn.failed` renders its message on screen. There is no
 * field on a {@link TurnEvent} that an API response body could travel in.
 *
 * ## No Node, no SDK at run time, and nothing else either
 *
 * The types come from the Agent SDK through `import type`, which erases, so this
 * module is safe to import from the bundle that runs in the webview — which
 * ./bridge.ts does, to read the events back off the wire.
 *
 * It imports nothing at all beyond that, and that is load-bearing rather than
 * tidy. ./bridge.ts needs it, ./credentials.ts imports ./bridge.ts, and a Turn
 * reaching back for the credential module's classifier would close the ring —
 * an import cycle that happens to work because everything in it is called
 * rather than read at load. The classification a Turn does need lives in
 * ./agent.ts, which is a leaf and can import both.
 */

import type { NonNullableUsage, SDKMessage } from '@anthropic-ai/claude-agent-sdk'

// ---------------------------------------------------------------------------
// What the agent host is asked to do
// ---------------------------------------------------------------------------

/**
 * A control request, as one line on the agent host's stdin.
 *
 * Three, and each one is a decision rather than a convenience. The agent host is
 * a Claude Code session inside the Sandbox; every additional thing it can be
 * asked to do is another thing something outside the Sandbox can make it do.
 *
 * Two of them are a Turn. The third is a plan-usage read, and it is here rather
 * than anywhere else because of ADR-0003's last consequence: the SDK's
 * `get_usage` control request rides a live session, and the only session varnick
 * ever has is the confined one this channel reaches. A read that opened its own
 * would be a Claude Code process on the host, outside `srt`, running whatever
 * `SessionStart` hook the agent last wrote into the clone. So it is a kind here,
 * or it does not happen.
 *
 * The type is no longer called `TurnControl` for that reason: the channel
 * carries control requests, of which a Turn is two.
 */
export type ControlRequest =
  | {
      readonly kind: 'run-turn'
      readonly turnId: string
      readonly prompt: string
      readonly model: string
      readonly effort: string
    }
  | { readonly kind: 'interrupt'; readonly turnId: string }
  /**
   * Ask the session this process is holding what the plan has left.
   *
   * `requestId` rather than `turnId` because it is not a Turn and never becomes
   * one — nothing about it reaches the transcript. It is required for the same
   * reason a Turn's id is: an answer nobody can match to a read is an answer
   * that could be handed to a different read, and a stale figure that looks
   * fresh is exactly what this ticket rules out.
   */
  | { readonly kind: 'read-plan-usage'; readonly requestId: string }

/**
 * Read a control request, or refuse it.
 *
 * Rebuilt field by field rather than parsed and passed on: the agent host runs
 * confined, and a request shape it accepts loosely is a request shape something
 * can put an extra field on.
 */
export function parseControlRequest(line: string): ControlRequest | null {
  let value: unknown
  try {
    value = JSON.parse(line)
  } catch {
    return null
  }

  const { kind, turnId, requestId, prompt, model, effort } = (value ?? {}) as Record<string, unknown>

  // Each kind names its own id. One shared field would have made a Turn and a
  // read interchangeable to anything reading only the id.
  if (kind === 'read-plan-usage') {
    return typeof requestId === 'string' && requestId.length > 0 ? { kind, requestId } : null
  }

  if (typeof turnId !== 'string' || turnId.length === 0) return null

  if (kind === 'interrupt') return { kind, turnId }

  if (kind === 'run-turn') {
    if (typeof prompt !== 'string' || typeof model !== 'string' || typeof effort !== 'string') {
      return null
    }
    return { kind, turnId, prompt, model, effort }
  }

  return null
}

// ---------------------------------------------------------------------------
// What a Turn says
// ---------------------------------------------------------------------------

/**
 * Why a Turn did not finish.
 *
 * Tags rather than sentences, so the prose lives in one place and an API error
 * body has no way to become one. `authentication` is the one that means more
 * than a failed Turn — see {@link isCredentialRejection}.
 */
export const TURN_FAILURES = [
  'authentication',
  'org-not-allowed',
  'billing',
  'rate-limit',
  'overloaded',
  'invalid-request',
  'model-not-found',
  'server-error',
  'max-output-tokens',
  'execution',
  'max-turns',
  'budget',
  'structured-output',
  /** The process holding the Session ended while the Turn was running. */
  'agent-ended',
  'unknown',
] as const

export type TurnFailure = (typeof TURN_FAILURES)[number]

/** Everything a Turn tells the machine, before it is stamped with its Turn. */
export type TurnUpdate =
  /** Answer text, as it arrives. Reaches the machine as `STREAM_DELTA`. */
  | { readonly kind: 'delta'; readonly text: string }
  /** A tool call, as it happens. Also a `STREAM_DELTA` — it is transcript. */
  | { readonly kind: 'tool'; readonly text: string }
  /** The Turn finished. The `runTurn` actor's output, exactly. */
  | { readonly kind: 'done'; readonly text: string; readonly tokensUsed: number }
  /** The Turn did not finish. The `runTurn` actor throws this. */
  | { readonly kind: 'failed'; readonly failure: TurnFailure }

/** A {@link TurnUpdate} and the Turn it belongs to. */
export type TurnEvent = TurnUpdate & { readonly turnId: string }

/**
 * What to tell the developer about a failed Turn, in one sentence.
 *
 * Every sentence is written here and selected by the tag. Nothing the API said
 * is interpolated into one, which is what makes "the credential never enters an
 * error message" a property of the code rather than a rule to remember.
 */
export function turnFailureMessage(failure: TurnFailure): string {
  switch (failure) {
    // A Turn's sentence about a Turn. The credential's own state says what is
    // wrong with the credential — see `CREDENTIAL_REJECTED_DETAIL` — and the two
    // are deliberately different, because they are read in different places
    // about different things: this one explains why nothing was answered.
    case 'authentication':
      return 'The API refused the credential, so the turn did not run. Fixing the stored key is the next step rather than retrying.'
    case 'org-not-allowed':
      return 'The credential authenticated, but this organisation is not allowed to use it.'
    case 'billing':
      return 'The account has a billing problem, so the turn could not run.'
    case 'rate-limit':
      return 'The rate limit was reached. Waiting is the fix; the conversation is unchanged.'
    case 'overloaded':
      return 'The API was overloaded and did not run the turn. Retrying is the next step.'
    case 'invalid-request':
      return 'The API refused the request as invalid. This is a bug in varnick rather than in what you typed.'
    case 'model-not-found':
      return 'The selected model is not available to this account. Choose another with `/model`.'
    case 'server-error':
      return 'The API failed on its side. Retrying is the next step.'
    case 'max-output-tokens':
      return 'The answer hit the model’s output limit and stopped. What arrived is kept.'
    case 'execution':
      return 'The turn ended with an error before it finished.'
    case 'max-turns':
      return 'The agent reached its limit on how many steps one turn may take.'
    case 'budget':
      return 'The turn reached its spending limit and stopped.'
    case 'structured-output':
      return 'The agent could not produce an answer in the shape that was asked for.'
    case 'agent-ended':
      return 'The agent process ended while the turn was running.'
    case 'unknown':
      return 'The turn failed for a reason the Agent SDK did not name.'
  }
}

/**
 * Is this failure the API refusing the credential?
 *
 * The one failure that is more than a failed Turn: it also has to reach the
 * Harness's `credential.rejected`, because a Turn that failed on authentication
 * says something about the credential and not about the conversation.
 */
export function isCredentialRejection(failure: TurnFailure): boolean {
  return failure === 'authentication'
}

// ---------------------------------------------------------------------------
// The wire
// ---------------------------------------------------------------------------

/**
 * One event, as one line.
 *
 * `JSON.stringify` escapes newlines, so an answer with one in it cannot split an
 * event across two lines and desynchronise the pipe — the same framing the
 * bridge uses, for the same reason.
 */
export function encodeTurnEvent(event: TurnEvent): string {
  return `${JSON.stringify(event)}\n`
}

/**
 * Read an event back, or refuse it.
 *
 * Rebuilt rather than passed through, like every other answer that crosses into
 * Core: a field nobody agreed to cannot ride into the machine's context, from
 * where it would reach the Session mirror.
 */
export function parseTurnEvent(value: unknown): TurnEvent | null {
  const { kind, turnId, text, tokensUsed, failure } = (value ?? {}) as Record<string, unknown>
  if (typeof turnId !== 'string' || turnId.length === 0) return null

  switch (kind) {
    case 'delta':
    case 'tool':
      return typeof text === 'string' ? { kind, turnId, text } : null
    case 'done':
      return typeof text === 'string' && typeof tokensUsed === 'number' && Number.isFinite(tokensUsed)
        ? { kind, turnId, text, tokensUsed }
        : null
    case 'failed':
      return typeof failure === 'string' && (TURN_FAILURES as readonly string[]).includes(failure)
        ? { kind, turnId, failure: failure as TurnFailure }
        : null
    default:
      return null
  }
}

// ---------------------------------------------------------------------------
// Reading a Session's messages
// ---------------------------------------------------------------------------

/** How much of the context window the conversation now occupies. */
export function contextTokens(usage: unknown): number {
  const counted = usage as Partial<NonNullableUsage> | null | undefined
  const parts = [
    counted?.input_tokens,
    counted?.output_tokens,
    // Cached input occupies the window exactly like uncached input. A meter
    // that left it out would read low by most of a long conversation.
    counted?.cache_read_input_tokens,
    counted?.cache_creation_input_tokens,
  ]
  let total = 0
  for (const part of parts) {
    if (typeof part === 'number' && Number.isFinite(part)) total += part
  }
  return total
}

/** The longest an argument may be before it stops being a summary. */
const TOOL_ARGUMENT_LIMIT = 80

/**
 * A tool call, as one line of transcript.
 *
 * The name plus the one field that says what it was pointed at. Not the whole
 * input: a `Write` call carries the file it is writing, and a transcript that
 * inlined every one of those would be unreadable as an audit trail, which is the
 * only thing it is for.
 */
export function toolCallLine(name: string, input: unknown): string {
  const fields = (input ?? {}) as Record<string, unknown>
  for (const key of ['file_path', 'path', 'command', 'pattern', 'url', 'query', 'description']) {
    const value = fields[key]
    if (typeof value !== 'string' || value.length === 0) continue
    const argument =
      value.length > TOOL_ARGUMENT_LIMIT ? `${value.slice(0, TOOL_ARGUMENT_LIMIT)}…` : value
    return `⚙ ${name}(${argument})\n`
  }
  return `⚙ ${name}\n`
}

/** The SDK's own name for what went wrong, mapped onto ours. */
function failureOfAssistantError(error: string): TurnFailure {
  switch (error) {
    case 'authentication_failed':
      return 'authentication'
    case 'oauth_org_not_allowed':
      return 'org-not-allowed'
    case 'billing_error':
      return 'billing'
    case 'rate_limit':
      return 'rate-limit'
    case 'overloaded':
      return 'overloaded'
    case 'invalid_request':
      return 'invalid-request'
    case 'model_not_found':
      return 'model-not-found'
    case 'server_error':
      return 'server-error'
    case 'max_output_tokens':
      return 'max-output-tokens'
    default:
      return 'unknown'
  }
}

/** The subtype of a result that ended badly, mapped onto ours. */
function failureOfResultSubtype(subtype: unknown): TurnFailure {
  switch (subtype) {
    case 'error_max_turns':
      return 'max-turns'
    case 'error_max_budget_usd':
      return 'budget'
    case 'error_max_structured_output_retries':
      return 'structured-output'
    case 'error_during_execution':
      return 'execution'
    default:
      return 'unknown'
  }
}

/**
 * A Turn in progress.
 *
 * Stateful for one reason: the finished answer has to be the thing the developer
 * watched arrive. `result.result` carries the model's final text and none of the
 * tool calls, so a transcript built from it would drop the audit trail the
 * moment the Turn ended — auditable only by whoever was watching it happen.
 * So the run accumulates what it emitted and hands that back as the answer.
 */
export interface TurnRun {
  /** Which Turn this is. An interrupt has to name the Turn it means. */
  readonly turnId: string
  /** What this message means for the Turn. Empty for most of them. */
  accept(message: unknown): TurnEvent[]
  /** True once a `done` or `failed` has been emitted. Nothing follows one. */
  readonly finished: boolean
}

export function beginTurn(turnId: string): TurnRun {
  let transcript = ''
  let finished = false

  function emit(updates: readonly TurnUpdate[]): TurnEvent[] {
    const events: TurnEvent[] = []
    for (const update of updates) {
      if (update.kind === 'delta' || update.kind === 'tool') transcript += update.text
      if (update.kind === 'done' || update.kind === 'failed') finished = true
      events.push({ ...update, turnId })
    }
    return events
  }

  return {
    turnId,

    get finished() {
      return finished
    },

    accept(message: unknown): TurnEvent[] {
      if (finished) return []
      const sdk = message as Partial<SDKMessage> & Record<string, unknown>
      if (sdk === null || typeof sdk !== 'object') return []

      switch (sdk.type) {
        /*
          Streamed output. The only source of answer text: the SDK also sends
          the assembled `assistant` message when the block closes, and counting
          both would post every answer twice.
        */
        case 'stream_event': {
          const event = sdk.event as Record<string, unknown> | undefined
          if (event?.type !== 'content_block_delta') return []
          const delta = event.delta as Record<string, unknown> | undefined
          // Thinking is not an answer. Streaming it would put the model's
          // reasoning into the transcript, which is a product decision nobody
          // made.
          if (delta?.type !== 'text_delta' || typeof delta.text !== 'string') return []
          return emit([{ kind: 'delta', text: delta.text }])
        }

        /*
          The assembled message. Read for two things only — the tool calls it
          announces, and the SDK's own name for a failure. Its text is already
          on screen.
        */
        case 'assistant': {
          if (typeof sdk.error === 'string') {
            return emit([{ kind: 'failed', failure: failureOfAssistantError(sdk.error) }])
          }
          const content = (sdk.message as { content?: unknown } | undefined)?.content
          if (!Array.isArray(content)) return []
          const updates: TurnUpdate[] = []
          for (const block of content) {
            const { type, name, input } = (block ?? {}) as Record<string, unknown>
            if (type !== 'tool_use' || typeof name !== 'string') continue
            updates.push({ kind: 'tool', text: toolCallLine(name, input) })
          }
          return emit(updates)
        }

        case 'result': {
          // `is_error` is checked as well as the subtype: a result can be
          // flagged an error while still calling itself a success, and treating
          // that as an answer would post an error page as the agent's reply.
          if (sdk.subtype !== 'success' || sdk.is_error === true) {
            return emit([{ kind: 'failed', failure: failureOfResultSubtype(sdk.subtype) }])
          }
          // The accumulated transcript, not `result`: it is what was watched,
          // tool calls included. `result` is the fallback for a Turn that
          // streamed nothing — a cached or instant answer.
          const answer = transcript.length > 0 ? transcript : String(sdk.result ?? '')
          return emit([{ kind: 'done', text: answer, tokensUsed: contextTokens(sdk.usage) }])
        }

        default:
          return []
      }
    },
  }
}
