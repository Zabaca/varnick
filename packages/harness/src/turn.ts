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
 * Two of them are a Turn. The third goes the other way: every other kind asks
 * the confined process to *do* something, and {@link DescribeSecretsRequest}
 * tells it something it has no way to find out — see there for why the
 * environment could not carry it.
 *
 * There were five. `read-plan-usage` left in ticket 31, because the read had no
 * figure to return under any credential varnick can hold. `compact` left later,
 * for a different reason: the CLI compacts on its own and varnick has to hear
 * about it either way, and once it hears, asking is a second way to do
 * something that already happens. Both departures shrank the channel without
 * touching it; it is still the only way in.
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
      /** Images pasted into the composer. Empty for almost every Turn. */
      readonly images: readonly PastedImage[]
    }
  | { readonly kind: 'interrupt'; readonly turnId: string }
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
 * What a picture may be, crossing into the Sandbox.
 *
 * The control channel is the one way into the confined process, and until now
 * every field on it was a short string this codebase composed. This is the
 * first that carries bulk data from outside, so it is the narrowest shape that
 * can be a picture: a media type from a fixed list, and base64.
 *
 * **No filename, no path, no `data:` URL.** A name is metadata the model does
 * not need and a path is a thing the agent might try to open; a `data:` prefix
 * is a place to put a second media type that disagrees with the first. The
 * request is rebuilt out of these two fields, so anything sent beside them is a
 * field that was never read — the same rule `describe-secrets` follows.
 */
export interface PastedImage {
  readonly mediaType: ImageMediaType
  /** Base64, with no `data:` prefix and no whitespace. */
  readonly data: string
}

/**
 * The formats a paste may be.
 *
 * An allowlist rather than a pattern: `image/*` would accept `image/svg+xml`,
 * and SVG is a document with script in it rather than a picture. These four are
 * what a screenshot actually arrives as.
 */
export const IMAGE_MEDIA_TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'] as const
export type ImageMediaType = (typeof IMAGE_MEDIA_TYPES)[number]

/**
 * How much picture one Turn may carry, in base64 characters.
 *
 * Roughly 8MB of image across the whole request. The channel is newline-framed
 * and a line is read into memory whole by both halves, so an unbounded paste is
 * an unbounded allocation in the host *and* in the confined process. A cap is
 * cheaper than either discovering that in production.
 */
export const MAX_IMAGE_BYTES = 8 * 1024 * 1024

const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/

/**
 * Read a list of images, or refuse the whole request.
 *
 * All-or-nothing on purpose, and it is the same argument `describe-secrets`
 * makes about names: a partial list is worse than none. A developer who pasted
 * three screenshots and had one silently dropped is asking the agent about a
 * picture it cannot see.
 */
export function parseImages(value: unknown): readonly PastedImage[] | null {
  if (value === undefined) return []
  if (!Array.isArray(value)) return null

  const images: PastedImage[] = []
  let total = 0
  for (const entry of value) {
    if (entry === null || typeof entry !== 'object') return null
    const { mediaType, data } = entry as Record<string, unknown>
    if (typeof mediaType !== 'string' || typeof data !== 'string') return null
    if (!(IMAGE_MEDIA_TYPES as readonly string[]).includes(mediaType)) return null
    // Base64 and nothing else. A newline inside the payload would split the
    // request across two lines of a newline-framed channel, which is the one
    // way a value on this wire could become a request.
    if (data.length === 0 || !BASE64.test(data)) return null
    total += data.length
    if (total > MAX_IMAGE_BYTES) return null
    images.push({ mediaType: mediaType as ImageMediaType, data })
  }
  return images
}

/*
  `CLEAR_COMMAND` and `COMPACT_COMMAND` were here, each with a control request
  to carry it.

  They existed so varnick could own a `/clear` and a `/compact` of its own,
  because the transcript and the token meter are varnick's copies of state the
  Session also holds, and a clear or a compaction that varnick did not perform
  left the two disagreeing. Asking covered the times varnick was asked and no
  others: the CLI has both commands, an auto-compaction has no command at all,
  and every one of those went round the outside.

  Both are gone, replaced by the same move. `conversation_reset` says the agent
  forgot; `PostCompact` says it summarised. Listening covers however it was
  asked for — including nobody asking — which is what asking could never do.
*/

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

  const { kind, turnId, prompt, model, effort, names, images } = (value ?? {}) as Record<
    string,
    unknown
  >

  /*
    Rebuilt to `kind` and `names`, which is what makes "no value can arrive
    here" a property of this function rather than a rule someone upstream has
    to keep. A line carrying `values` alongside `names` loses them here, in the
    same way a `prompt` sent alongside an `interrupt` is a field that was never
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

  if (kind === 'run-turn') {
    if (typeof prompt !== 'string' || typeof model !== 'string' || typeof effort !== 'string') {
      return null
    }
    // Rebuilt like every other field, and a malformed picture fails the Turn
    // rather than being dropped from it — see parseImages.
    const parsed = parseImages(images)
    if (parsed === null) return null
    return { kind, turnId, prompt, model, effort, images: parsed }
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
  /*
    `compaction` and `compaction-unmeasured` were here, for the Compaction
    varnick used to ask for. A compaction is something the Session does to
    itself now and varnick only hears about it, so there is no varnick-side act
    left to fail: one that does not happen leaves the transcript exactly as it
    was, which is what the window is already showing.
  */
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
 * One slash command the runtime will accept.
 *
 * Mirrors the SDK's `SlashCommand` rather than importing it — this type is
 * bundled into the webview, and the SDK is a host-side module that reads a
 * credential when it loads.
 *
 * `argumentHint` is a string upstream and stays one: empty means the command
 * takes nothing, which is a different fact from "we do not know". Both it and
 * `description` come from the command's own frontmatter, which is why they are
 * worth carrying at all — the init message's `slash_commands` is names only, and
 * a menu of thirty bare names is a list rather than a way to find anything.
 */
export interface SlashCommand {
  readonly name: string
  readonly description: string
  readonly argumentHint: string
  /** Other names the runtime resolves to this one — `/cost` for `/usage`. */
  readonly aliases?: readonly string[]
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
 * A command list from the runtime, normalised.
 *
 * Shared by the two ways it arrives — the `commands_changed` push and the
 * `supportedCommands()` request — so both agree on what a bad entry is. A name
 * is required and everything else is filled in: these come from plugins and
 * skills as much as from the CLI, and an entry authored badly enough to have no
 * name would otherwise draw a blank row you can select.
 *
 * How many rather than how long is the cap here. A runtime with a thousand
 * commands is a runtime this menu cannot help with anyway, and the limit exists
 * for the same reason every other one on this wire does: nothing from outside
 * arrives at whatever size it was sent at.
 */
const COMMAND_LIMIT = 400

export function normaliseCommands(list: unknown): readonly SlashCommand[] {
  if (!Array.isArray(list)) return []
  return list
    .filter(
      (one): one is Record<string, unknown> =>
        one !== null && typeof one === 'object' && typeof one['name'] === 'string' && one['name'] !== '',
    )
    .slice(0, COMMAND_LIMIT)
    .map((one) => ({
      name: name(one['name']),
      description: name(one['description']),
      argumentHint: name(one['argumentHint']),
      ...(Array.isArray(one['aliases']) ? { aliases: names(one['aliases']) } : {}),
    }))
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
   * The Session summarised itself, and varnick did not ask it to.
   *
   * `summary` is the text the Session produced, never text this module
   * composed. Core turns it into the replacement transcript — see
   * `conversationCompacted` in packages/core/src/actors/live.ts.
   *
   * **`tokensUsed` is a reading or it is `null`.** What the context now
   * measures is asked of the Session after the rewrite; a Session that will not
   * answer leaves the meter alone rather than being given a figure nobody took.
   * `0` would be the worst of those figures, because it says the conversation
   * costs nothing. The transcript follows either way: the rewrite happened, and
   * a meter varnick could not read is no reason to keep showing messages the
   * agent has thrown away.
   */
  | {
      readonly kind: 'compacted'
      readonly summary: string
      readonly tokensUsed: number | null
    }
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
  /**
   * Every command the runtime will accept, as it currently stands.
   *
   * The second update that is not about the Turn, riding this channel for the
   * reason the first one does. **A replacement, never an addition** — the SDK's
   * own `commands_changed` says clients should replace their cached list, and a
   * merge would keep offering a skill that has gone.
   */
  | { readonly kind: 'commands'; readonly commands: readonly SlashCommand[] }
  /**
   * The conversation was reset — the agent forgot everything.
   *
   * The CLI announces this after its own `/clear`, after a plan-mode exit, and
   * after anything else that starts a fresh conversation. varnick clears the
   * transcript *because of it* rather than alongside its own command, which is
   * what keeps the two halves in agreement however the clear was asked for.
   */
  | { readonly kind: 'reset' }

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
  const { kind, turnId, text, summary, tokensUsed, failure, report, commands } = (value ??
    {}) as Record<string, unknown>
  if (typeof turnId !== 'string' || turnId.length === 0) return null

  switch (kind) {
    case 'delta':
    case 'tool':
      return typeof text === 'string' ? { kind, turnId, text } : null
    case 'done':
      return typeof text === 'string' && typeof tokensUsed === 'number' && Number.isFinite(tokensUsed)
        ? { kind, turnId, text, tokensUsed }
        : null
    case 'compacted': {
      // A summary is required and may not be empty: a compaction with none
      // would replace the transcript with nothing at all. The figure is
      // required to be *present* and allowed to be `null`, which is the
      // difference between "measured nothing" and "was never measured" — a
      // missing key is a malformed event rather than an unknown size.
      if (typeof summary !== 'string' || summary.length === 0) return null
      if (tokensUsed === null) return { kind, turnId, summary, tokensUsed: null }
      return typeof tokensUsed === 'number' && Number.isFinite(tokensUsed)
        ? { kind, turnId, summary, tokensUsed }
        : null
    }
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
    case 'reset':
      // Nothing to rebuild: the event is the whole of the fact.
      return { kind, turnId }
    case 'commands':
      /*
        An array or nothing, and an *empty* array is a real answer rather than a
        malformed one: a runtime with no commands at all is what a stripped
        configuration looks like, and reading it as a bad line would leave the
        menu showing a list the agent no longer has.

        `normaliseCommands` is the same rebuild the agent host used on the way
        out. Running it again here is not redundant — this is the boundary a
        field nobody agreed to would have to cross to reach the machines.
      */
      return Array.isArray(commands)
        ? { kind, turnId, commands: normaliseCommands(commands) }
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
