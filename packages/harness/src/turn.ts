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
 * Four, and each one is a decision rather than a convenience. The agent host is
 * a Claude Code session inside the Sandbox; every additional thing it can be
 * asked to do is another thing something outside the Sandbox can make it do.
 *
 * Two of them are a Turn. A third is here for the same reason, which is
 * ADR-0003's last consequence: summarising a conversation is a model call on
 * *this* session, and implemented the obvious way — `query()` on the host — it
 * would be a second Claude Code process outside `srt`, running whatever
 * `SessionStart` hook the agent last wrote into the clone. So it is a kind
 * here, or it does not happen.
 *
 * The fourth goes the other way. Every other kind asks the confined process to
 * *do* something; {@link DescribeSecretsRequest} tells it something it has no
 * way to find out — see there for why the environment could not carry it.
 *
 * There were five. `read-plan-usage` was on this channel for exactly the same
 * ADR-0003 reason as `compact`, and ticket 31 removed it — not because the
 * reasoning was wrong but because the read had no figure to return under any
 * credential varnick can hold. The channel itself is untouched and load-bearing;
 * one kind left it.
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
  /** Summarise the conversation on this session. Carries a Turn id and nothing
   *  else — there is no prompt on it to smuggle anything through, because the
   *  prompt is a constant this module owns ({@link COMPACT_COMMAND}). */
  | { readonly kind: 'compact'; readonly turnId: string }
  | DescribeSecretsRequest

/**
 * Tell the confined process which secrets exist, by name.
 *
 * ADR-0006's naming end. The agent authors code that says
 * `process.env.STRIPE_KEY`; it can only do that if it knows the name, and the
 * names live in the system keychain, which is under `$HOME` and therefore
 * unreadable from inside the Sandbox (ADR-0003's first correction). So they
 * have to be carried in, and this is the carrier.
 *
 * **Names, and there is no field here a value could ride in.** `names` is the
 * whole request. That is not a convention to be remembered: the parse below
 * rebuilds this request out of `kind` and `names` alone, so a line that
 * arrived carrying values would be a line whose values were never read.
 *
 * ## Why this is a control request and not an environment variable
 *
 * The spawn environment is the simpler carrier and it was the other candidate:
 * names are not secret, so nothing about putting them there would weaken
 * containment. It is rejected for one reason — it can only ever say what was
 * true at launch. `bun run secret add` runs in a *different* process, and a
 * developer who adds a key mid-session would have to relaunch varnick before
 * the agent could write code against it. Ticket 06 met the same problem from
 * the redaction side and answered it the same way, by re-reading the store
 * rather than trusting the snapshot taken at start-up.
 *
 * The Agent SDK settles it. `appendSystemPrompt` is part of the `initialize`
 * control request and is fixed for the life of the session — there is no
 * `setSystemPrompt`, and `reinitialize()` re-sends the request the session was
 * opened with rather than a new one. So a system prompt could carry a snapshot
 * and could never carry a list that changes, and the environment has no route
 * to anywhere better. What *can* change per Turn is a `UserPromptSubmit` hook's
 * `additionalContext`, which is what the agent host does with this — see
 * `runAgentHost` in ./agent.ts.
 */
export interface DescribeSecretsRequest {
  readonly kind: 'describe-secrets'
  /**
   * The names, in the order the Secrets Store holds them. Never a value.
   *
   * An empty list is a real answer and not a missing one: it means the store
   * was read and holds nothing, which is what a developer who has stored no
   * secrets should have the agent told.
   */
  readonly names: readonly string[]
}

/**
 * What asks the Session to summarise itself.
 *
 * The CLI's own command, sent as a prompt on the streaming input that is
 * already open. Not a second session, not a hand-written "please summarise"
 * that would be an ordinary Turn producing an ordinary answer and freeing no
 * context at all: the point of Compaction is that the *Session's* context is
 * rewritten, which only the thing holding it can do.
 */
export const COMPACT_COMMAND = '/compact'

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

  const { kind, turnId, prompt, model, effort, names } = (value ?? {}) as Record<string, unknown>

  /*
    Rebuilt to `kind` and `names`, which is what makes "no value can arrive
    here" a property of this function rather than a rule someone upstream has
    to keep. A line carrying `values` alongside `names` loses them here, in the
    same way a `prompt` sent alongside a `compact` is a field that was never
    read.

    Every entry must be a non-empty string, and one that is not fails the whole
    request rather than being dropped. A partial list is worse than none: the
    agent would be told about some of the secrets, write code against those,
    and have no way to tell that it had been given less than the store holds.
  */
  if (kind === 'describe-secrets') {
    if (!Array.isArray(names)) return null
    if (names.some((name) => typeof name !== 'string' || name.length === 0)) return null
    return { kind, names: [...(names as string[])] }
  }

  if (typeof turnId !== 'string' || turnId.length === 0) return null

  if (kind === 'interrupt') return { kind, turnId }
  // Rebuilt to two fields, so a `prompt` sent alongside a compaction is not a
  // prompt at all — it is a field that was never read.
  if (kind === 'compact') return { kind, turnId }

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
  /**
   * The Session did not summarise the conversation.
   *
   * Its own tag rather than `execution`, because the two mean different things
   * to the only person reading them: a Compaction that did not happen leaves
   * the conversation exactly as it was, and saying so is the point.
   */
  'compaction',
  /**
   * The Session summarised the conversation and could not say what it now costs.
   *
   * Separate from `compaction` because the sentence differs: this one did
   * summarise. varnick declines the rewrite anyway rather than showing a meter
   * it did not measure. That rule outlived the plan-usage strip it was shared
   * with — the strip is gone (ticket 31) and the meter is still a reading or
   * nothing.
   */
  'compaction-unmeasured',
  'unknown',
] as const

export type TurnFailure = (typeof TURN_FAILURES)[number]

/**
 * What the agent's Claude Code runtime says it has, in its own words.
 *
 * **Configured is not the same as loaded, and nothing in varnick could tell the
 * two apart.** The Profile names a model, a set of tools and a permission mode;
 * every one of those is an *intention* until a process reads it. A tool dropped
 * on the way to the SDK, a model the account cannot use, a settings source that
 * did not apply — each leaves the code saying one thing and the running agent
 * doing another, with nothing on screen that disagrees.
 *
 * This is the other side: the runtime describing itself in the `init` message it
 * emits when the Session opens. Ported from forge, which built it after two
 * plugins were declared in a profile, silently dropped, and only noticed because
 * the agent happened to read its own skill list.
 *
 * Named `RuntimeReport` rather than "harness" — which is what forge calls it —
 * because `Harness` is taken in this repo, and taken for something else: Core's
 * runtime half, the thing that *confines* this process. See CONTEXT.md.
 *
 * Everything here is a name or a count. `apiKeySource` is the SDK's word for
 * which store answered — the same class of fact as Credential Source, and never
 * a credential; there is no field on this type a value could arrive in.
 */
export interface RuntimeReport {
  /**
   * The Agent SDK's own id for this conversation.
   *
   * What `resume` takes. It is the agent's continuity, and it is not the
   * varnick Session id: the mirror is keyed by `LIVE_SESSION_ID`, which varnick
   * chooses and never changes, while this is a UUID the CLI mints per
   * conversation. Two names for two things that used to be conflated in
   * conversation and never in code.
   */
  readonly sessionId: string
  /**
   * Whether this process picked up the previous conversation or started a new
   * one.
   *
   * Not on the init message — the runtime has no idea it was asked to resume.
   * varnick knows, because varnick asked, and it says so here so that the
   * window can never show a restored transcript over an agent that remembers
   * none of it without admitting the difference.
   */
  readonly resumed: boolean
  readonly claudeCodeVersion: string
  readonly model: string
  readonly permissionMode: string
  readonly outputStyle: string
  readonly cwd: string
  readonly apiKeySource: string
  readonly tools: readonly string[]
  readonly skills: readonly string[]
  readonly slashCommands: readonly string[]
  readonly agents: readonly string[]
  readonly mcpServers: readonly { readonly name: string; readonly status: string }[]
  readonly plugins: readonly { readonly name: string; readonly path: string; readonly version: string | null }[]
}

/**
 * How long a single name may be.
 *
 * A cwd is the longest honest field here and a deep clone path is well under
 * this. The cap is not about layout — it is the same rule the rest of this file
 * follows, that nothing from outside is carried into Core at whatever size it
 * arrived at.
 */
const NAME_LIMIT = 200

const name = (value: unknown): string =>
  typeof value === 'string' ? value.slice(0, NAME_LIMIT) : ''

const names = (value: unknown): readonly string[] =>
  Array.isArray(value)
    ? value.filter((one): one is string => typeof one === 'string').map((one) => one.slice(0, NAME_LIMIT))
    : []

/**
 * Read the runtime's self-report out of the SDK's `init` message.
 *
 * Every field optional on the way in and defaulted to empty: a panel describing
 * the agent must never be able to fail the Turn it describes. A report with
 * nothing in it is still a true statement — the runtime said nothing this
 * understands — and renders as a row of dashes rather than as an error.
 *
 * The SDK's own keys, which are half snake_case and half camelCase because the
 * init message is assembled from two sides. Mirrored deliberately rather than
 * normalised upstream: this is the one place that shape is known.
 */
export function runtimeReportFrom(message: unknown, resumed = false): RuntimeReport {
  const init = (message ?? {}) as Record<string, unknown>
  return {
    sessionId: name(init['session_id']),
    // An argument rather than a field of the message, because the runtime does
    // not know: `resume` is something varnick asked for on the way in, and the
    // init message reports the session it ended up with either way.
    resumed,
    claudeCodeVersion: name(init['claude_code_version']),
    model: name(init['model']),
    permissionMode: name(init['permissionMode']),
    outputStyle: name(init['output_style']),
    cwd: name(init['cwd']),
    apiKeySource: name(init['apiKeySource']),
    tools: names(init['tools']),
    skills: names(init['skills']),
    slashCommands: names(init['slash_commands']),
    agents: names(init['agents']),
    mcpServers: Array.isArray(init['mcp_servers'])
      ? init['mcp_servers'].map((one) => {
          const server = (one ?? {}) as Record<string, unknown>
          return { name: name(server['name']), status: name(server['status']) }
        })
      : [],
    plugins: Array.isArray(init['plugins'])
      ? init['plugins'].map((one) => {
          const plugin = (one ?? {}) as Record<string, unknown>
          return {
            name: name(plugin['name']),
            path: name(plugin['path']),
            version: typeof plugin['version'] === 'string' ? name(plugin['version']) : null,
          }
        })
      : [],
  }
}

/**
 * The same report, read back off the wire.
 *
 * Rebuilt field by field for the reason {@link parseTurnEvent} gives — a field
 * nobody agreed to must not ride into the machine's context — and it is the same
 * rebuild as {@link runtimeReportFrom} against this type's own key names rather
 * than the SDK's.
 */
function parseRuntimeReport(value: unknown): RuntimeReport | null {
  if (value === null || typeof value !== 'object') return null
  const report = value as Record<string, unknown>
  return {
    sessionId: name(report['sessionId']),
    resumed: report['resumed'] === true,
    claudeCodeVersion: name(report['claudeCodeVersion']),
    model: name(report['model']),
    permissionMode: name(report['permissionMode']),
    outputStyle: name(report['outputStyle']),
    cwd: name(report['cwd']),
    apiKeySource: name(report['apiKeySource']),
    tools: names(report['tools']),
    skills: names(report['skills']),
    slashCommands: names(report['slashCommands']),
    agents: names(report['agents']),
    mcpServers: Array.isArray(report['mcpServers'])
      ? report['mcpServers'].map((one) => {
          const server = (one ?? {}) as Record<string, unknown>
          return { name: name(server['name']), status: name(server['status']) }
        })
      : [],
    plugins: Array.isArray(report['plugins'])
      ? report['plugins'].map((one) => {
          const plugin = (one ?? {}) as Record<string, unknown>
          return {
            name: name(plugin['name']),
            path: name(plugin['path']),
            version: typeof plugin['version'] === 'string' ? name(plugin['version']) : null,
          }
        })
      : [],
  }
}

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
  /**
   * The Session summarised itself. The `compactSession` actor's output, in part.
   *
   * `summary` is the text the Session produced, not text this module composed,
   * and `tokensUsed` is what the context now measures rather than what a
   * summary was assumed to cost. Core turns the two into the replacement
   * transcript and the meter — see packages/core/src/actors/live.ts.
   */
  | { readonly kind: 'compacted'; readonly summary: string; readonly tokensUsed: number }
  /**
   * What the runtime says it is, reported once per Session.
   *
   * The one update here that is not about the Turn. It rides this channel
   * because the channel already exists and the fact arrives on the same stream —
   * adding a second pipe from inside the Sandbox to carry one message would be a
   * second thing to secure for no gain. It is stamped with whichever Turn was
   * running when it was read, and Core drops the Turn and keeps the report.
   */
  | { readonly kind: 'runtime'; readonly report: RuntimeReport }

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
    case 'compaction':
      return 'The conversation was not summarised, so nothing about it changed.'
    case 'compaction-unmeasured':
      return 'The conversation was summarised, but how much context it now occupies could not be read — so the conversation was left exactly as it was rather than shown against a figure nobody measured.'
    case 'unknown':
      return 'The turn failed for a reason the Agent SDK did not name.'
  }
}

/**
 * The same failures, as the sentence a *Compaction* is reported inside.
 *
 * A second table rather than a second use of {@link turnFailureMessage}, and
 * the reason is what the surface does with it: `turn.failed` renders a Turn's
 * sentence on its own, while a failed Compaction is rendered inside one the
 * surface owns — *Could not compact — {this}. The conversation is unchanged.*
 * Feeding a full sentence into that produces two full stops and says "the
 * conversation is unchanged" twice.
 *
 * So these are clauses: lower case, no full stop. Same rule as everywhere else
 * — every one is authored here and selected by the tag, and nothing the API
 * said is interpolated into one. `compact_error` from the CLI is read as a
 * fact and never as prose, for the same reason a 401 body is.
 */
export function compactionFailureMessage(failure: TurnFailure): string {
  switch (failure) {
    case 'authentication':
      return 'the API refused the credential'
    case 'org-not-allowed':
      return 'this organisation is not allowed to use the credential'
    case 'billing':
      return 'the account has a billing problem'
    case 'rate-limit':
      return 'the rate limit was reached'
    case 'overloaded':
      return 'the API was overloaded'
    case 'invalid-request':
      return 'the API refused the request as invalid, which is a bug in varnick'
    case 'model-not-found':
      return 'the selected model is not available to this account'
    case 'server-error':
      return 'the API failed on its side'
    case 'max-output-tokens':
      return 'the summary hit the model’s output limit'
    case 'execution':
      return 'it ended with an error before it finished'
    case 'max-turns':
      return 'the agent reached its limit on how many steps one turn may take'
    case 'budget':
      return 'it reached its spending limit'
    case 'structured-output':
      return 'the agent could not produce an answer in the shape that was asked for'
    case 'agent-ended':
      return 'the agent process ended while it was running'
    case 'compaction':
      return 'the conversation was not summarised'
    case 'compaction-unmeasured':
      return 'the summary arrived but the context it freed could not be measured'
    case 'unknown':
      return 'the Agent SDK did not say why'
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
  const { kind, turnId, text, summary, tokensUsed, failure, report } = (value ?? {}) as Record<
    string,
    unknown
  >
  if (typeof turnId !== 'string' || turnId.length === 0) return null

  switch (kind) {
    case 'delta':
    case 'tool':
      return typeof text === 'string' ? { kind, turnId, text } : null
    case 'done':
      return typeof text === 'string' && typeof tokensUsed === 'number' && Number.isFinite(tokensUsed)
        ? { kind, turnId, text, tokensUsed }
        : null
    case 'compacted':
      // Both fields required. A compaction with no figure would leave the meter
      // saying whatever it said before over a conversation that has been
      // replaced, and a compaction with no summary would replace it with
      // nothing at all.
      return typeof summary === 'string' &&
        summary.length > 0 &&
        typeof tokensUsed === 'number' &&
        Number.isFinite(tokensUsed)
        ? { kind, turnId, summary, tokensUsed }
        : null
    case 'failed':
      return typeof failure === 'string' && (TURN_FAILURES as readonly string[]).includes(failure)
        ? { kind, turnId, failure: failure as TurnFailure }
        : null
    case 'runtime': {
      // An object or nothing. Every field inside it is optional and defaulted,
      // so a report the SDK filled in half of arrives half full rather than not
      // at all — but a `runtime` event carrying no report is a malformed line.
      const parsed = parseRuntimeReport(report)
      return parsed === null ? null : { kind, turnId, report: parsed }
    }
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

/**
 * What a Compaction became.
 *
 * `postTokens` is the figure the Session's own boundary reported, and `null`
 * means it reported none — not that it reported zero. Turning that into an
 * event is {@link ServeTurnsInput}'s job, because the fallback is a question
 * for the Session and this module never asks anything.
 */
export type CompactionSettlement =
  | {
      readonly kind: 'compacted'
      readonly summary: string
      readonly postTokens: number | null
    }
  | { readonly kind: 'failed'; readonly failure: TurnFailure }

/**
 * A Compaction in progress.
 *
 * The counterpart of {@link TurnRun}, and shaped differently on purpose: a Turn
 * emits as it goes, because watching an answer arrive is the point. A
 * Compaction emits nothing until it is whole, because a half-observed
 * compaction is the failure this ticket exists to prevent.
 *
 * It needs two facts from two places, and neither arrives first reliably:
 *
 *   * the **boundary** — the Session's own `compact_boundary` message, which is
 *     the only proof that its context was actually rewritten. Without it,
 *     whatever else happened was an ordinary Turn.
 *   * the **summary** — the text the compaction produced, which reaches the
 *     agent host through the SDK's `PostCompact` hook rather than on the
 *     message stream. {@link summarised} is where it comes in.
 *
 * Missing either one is a failed Compaction. That is the conservative side of
 * the only decision here that can lose work: a Compaction that fails costs a
 * full context window, and a Compaction that half-succeeds costs the
 * conversation. `CONTEXT.md` says the same thing about the word itself —
 * *Avoid: truncate, prune (both lose the fact that nothing is discarded
 * blindly)*.
 */
export interface CompactionRun {
  /** Which Turn this is. Its events are stamped with it like any other. */
  readonly turnId: string
  /** The summary the compaction produced, from the `PostCompact` hook. */
  summarised(summary: string): void
  /** What this Session message means for the Compaction. */
  accept(message: unknown): void
  /** What it became, or `null` while it is still running. */
  readonly settled: CompactionSettlement | null
}

export function beginCompaction(turnId: string): CompactionRun {
  let summary: string | null = null
  let boundary = false
  let postTokens: number | null = null
  let settlement: CompactionSettlement | null = null

  /** First answer wins. A failure is never talked back into a success. */
  const fail = (failure: TurnFailure) => {
    settlement ??= { kind: 'failed', failure }
  }

  const conclude = () => {
    if (settlement !== null || !boundary || summary === null) return
    settlement = { kind: 'compacted', summary, postTokens }
  }

  return {
    turnId,

    get settled() {
      return settlement
    },

    summarised(text: string) {
      if (settlement !== null || summary !== null) return
      // Whitespace is not a summary. A transcript replaced by one would be a
      // transcript discarded, reported as a success.
      if (typeof text !== 'string' || text.trim().length === 0) return
      summary = text
      conclude()
    },

    accept(message: unknown) {
      if (settlement !== null) return
      const sdk = message as Partial<SDKMessage> & Record<string, unknown>
      if (sdk === null || typeof sdk !== 'object') return

      switch (sdk.type) {
        case 'system': {
          if (sdk.subtype === 'compact_boundary') {
            boundary = true
            const metadata = sdk.compact_metadata as Record<string, unknown> | undefined
            const post = metadata?.post_tokens
            // A figure or nothing. `post_tokens` is optional on the SDK's own
            // type, and a missing one must not read as a context of zero.
            postTokens =
              typeof post === 'number' && Number.isFinite(post) && post >= 0 ? post : null
            conclude()
            return
          }
          // The CLI's verdict on the compaction it was asked for. `compact_error`
          // sits beside this and is deliberately not read: it is prose from the
          // API, which is where a credential would be.
          if (sdk.subtype === 'status' && sdk.compact_result === 'failed') fail('compaction')
          return
        }

        // The same two failure sources a Turn reads, for the same reason: a
        // Compaction is a model call, and it fails the ways a model call fails.
        case 'assistant': {
          if (typeof sdk.error === 'string') fail(failureOfAssistantError(sdk.error))
          return
        }

        case 'result': {
          if (sdk.subtype !== 'success' || sdk.is_error === true) {
            fail(failureOfResultSubtype(sdk.subtype))
            return
          }
          // The Session has stopped talking. Whatever has not arrived by now is
          // not going to, so a Compaction still missing a half is a failure
          // rather than a wait with no end.
          conclude()
          if (settlement === null) fail('compaction')
          return
        }

        default:
          return
      }
    },
  }
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
