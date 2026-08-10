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
 * It imports nothing at run time beyond ./preview.ts, and that is load-bearing
 * rather than tidy. ./bridge.ts needs it, ./credentials.ts imports ./bridge.ts,
 * and a Turn reaching back for the credential module's classifier would close
 * the ring — an import cycle that happens to work because everything in it is
 * called rather than read at load. The classification a Turn does need lives in
 * ./agent.ts, which is a leaf and can import both.
 *
 * ./preview.ts is admissible under exactly that rule and for exactly that
 * reason: it imports nothing itself, reaches no Node built-in and no SDK, and is
 * a leaf below this one. It is here because a Preview's answer is a control
 * request, and the closed list of outcomes it may carry belongs beside the
 * sentences written for them.
 */

import type { NonNullableUsage, SDKMessage } from '@anthropic-ai/claude-agent-sdk'
import { isPreviewOutcome, type PreviewOutcome } from './preview.ts'

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
  | PreviewAnswerRequest
  | ReportMergeRequest

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
 * What the host did about a Preview the agent asked for.
 *
 * The one kind on this channel that is an *answer* rather than an instruction or
 * a fact — the confined process asked a question it has no way to answer itself
 * (a confined process cannot open a window) and this is the reply. The question
 * went out on stdout as a `launch-preview` line; see ./preview.ts.
 *
 * **Three fields, and one of them is a tag from a closed list.** The outcome is
 * not prose. The host is the process holding the Credential and the one that
 * performs spawns, so a sentence composed there is the string most likely to
 * carry a path, an environment or an OS error into a confined process and from
 * there into the transcript. Every sentence for these tags is authored in
 * `previewOutcomeMessage`, on this side, exactly as `turnFailureMessage` is.
 */
export interface PreviewAnswerRequest {
  readonly kind: 'preview-answer'
  /** Which `launch_preview` call this answers. */
  readonly requestId: string
  /** One of `PREVIEW_OUTCOMES` in ./preview.ts. */
  readonly outcome: PreviewOutcome
}

/**
 * One of the agent's branches landed.
 *
 * **A report, not an instruction**, and it belongs on the same footing as the
 * compaction report and `COMMANDS_REPORTED`: something the world did, which the
 * thing hearing it accepts wherever it is rather than declining. The agent wrote
 * the branch and is the only party in the conversation that does not otherwise
 * find out — so without this it goes on offering to preview a Worktree that no
 * longer exists, and reasoning about a fix it believes is running.
 *
 * ## Why the sentence is carried rather than the facts
 *
 * The obvious shape is the report itself — branch, commit, two booleans — and it
 * is rejected for the reason `preview-answer` carries a *tag* rather than prose:
 * whichever side composes the sentence is the side that decides what it says,
 * and this one has to be composed where the merge happened. Two of the things it
 * must convey are absences (the worktree is gone, the branch is gone), and an
 * absence is not something a field conveys. `mergeBriefing` in ./merge.ts writes
 * it; the Rust host relays it and writes nothing.
 *
 * ## And why it arrives on the next Turn rather than at the moment it happens
 *
 * The same route the secret names take: a `UserPromptSubmit` hook's
 * `additionalContext`, which is re-run per Turn. That is not a compromise here —
 * the fact only matters when the agent next acts on it, and delivering it as a
 * prompt would make the agent *answer* a message the developer never sent.
 */
export interface ReportMergeRequest {
  readonly kind: 'report-merge'
  /**
   * What to tell it, composed host-side and delivered unchanged.
   *
   * Non-empty, checked. An empty briefing would put a blank paragraph into the
   * agent's context for a merge it would then know nothing about — worse than
   * not being told, because the delivery is what clears it.
   */
  readonly briefing: string
  /**
   * The part that is true only while *this* process is the one that heard it.
   *
   * A Briefing outlives the process that composed it — the ordinary sequence is
   * merge, then restart, and a restart kills the agent host before the next Turn
   * drains anything — so it is kept and delivered in the session afterwards. By
   * then "varnick has not restarted" is false, which is why it arrives as its
   * own string rather than as a clause inside the one above.
   *
   * Both are composed host-side. The confined process picks which apply, from a
   * fact about *itself* — did I receive this, or find it left behind — and never
   * by editing a sentence it did not write.
   *
   * Optional, so a host that does not send one still delivers the Briefing.
   */
  readonly whileRunning?: string
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
 * Where a picture sits in the sentence about it.
 *
 * The composer writes one of these into the draft at the cursor when an image
 * is pasted, so the developer can say *"the menu in [Image #1] is what [Image
 * #2] should look like"* and mean it. Claude Code's own composer uses the same
 * shape, which is the reason for the format rather than a coincidence: the
 * developer already knows what it means.
 *
 * One-based, because it is read by a person before it is read by a parser.
 */
export const IMAGE_MARKER = /\[Image #(\d+)\]/g

/** The marker for the nth image, and the one place that shape is written. */
export function imageMarker(index: number): string {
  return `[Image #${index + 1}]`
}

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

  const { kind, turnId, prompt, model, effort, names, images, requestId, outcome, briefing, whileRunning } =
    (value ?? {}) as Record<string, unknown>

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

  /*
    The host's answer to a Preview the agent asked for. Rebuilt to three fields
    like everything else here, and the outcome is checked against the closed
    list rather than carried through as a string: an answer this build does not
    understand must not become a sentence nothing wrote.
  */
  if (kind === 'preview-answer') {
    if (typeof requestId !== 'string' || requestId.length === 0) return null
    if (!isPreviewOutcome(outcome)) return null
    return { kind, requestId, outcome }
  }

  /*
    The Briefing is required and an empty one is refused. The delivery clears it,
    so an empty string would spend the one chance to say a branch landed on a
    blank paragraph — which is worse than never having sent it.

    `whileRunning` is optional and quietly dropped when it is not a usable
    string, because it is the *lesser* half: a Briefing delivered without it is
    still true, and refusing the whole request over it would lose the part that
    matters to keep the part that expires.
  */
  if (kind === 'report-merge') {
    if (typeof briefing !== 'string' || briefing.trim().length === 0) return null
    const clause =
      typeof whileRunning === 'string' && whileRunning.trim().length > 0 ? whileRunning : undefined
    return clause === undefined ? { kind, briefing } : { kind, briefing, whileRunning: clause }
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
 * which store answered and {@link RuntimeReport.credentialSource} is the name of
 * an environment variable — both are the same class of fact as Credential
 * Source, and neither is a credential; there is no field on this type a value
 * could arrive in.
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
  /**
   * Which credential variable the agent host found in its own environment, by
   * name — `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, or the empty string
   * when neither is set.
   *
   * It exists because `apiKeySource` answers a question nobody asked. That field
   * is the SDK's word for which store an *API key* came from, and under a
   * subscription credential there is no API key — so the SDK says `none`,
   * correctly, and the one row on the panel built to prove that injection worked
   * printed `none` over an agent that was answering. Which is also exactly what
   * the genuine failure looks like, where nothing was injected at all. Every
   * subscription Session since the panel shipped read that way, and those are
   * most of them.
   *
   * Not on the init message, and it could not be: the runtime knows what it
   * authenticated with and nothing about what varnick put in front of it. So
   * this is an argument to {@link runtimeReportFrom} for the reason
   * {@link RuntimeReport.resumed} is one — varnick knows because varnick did it —
   * and a field read off `init` would be an invented answer rather than a
   * measured one.
   *
   * **A variable's name, never its contents.** The environment is read to ask
   * whether an entry is empty and for nothing else, and what comes back is one
   * of two strings this repository wrote itself; see `observedCredentialVariable`
   * in ./agent.ts, which is the only place the environment is touched.
   *
   * Deliberately not spoken of as a Credential Source, which CONTEXT.md already
   * spends on which *store* answered — `keychain` or `env`. That is a fact about
   * where the host looked; this is a fact about what the confined process at the
   * other end of the same injection ended up holding.
   */
  readonly credentialSource: string
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
 * One subagent or background task the runtime is running right now.
 *
 * ## Why this exists
 *
 * A Turn that spawns subagents looked identical to a Turn that was hung. A
 * `/code-review` ran four of them over ten minutes and the window showed one
 * `⚙ Agent(…)` line and then a spinner; answering *"is it still working?"* meant
 * reading the SDK's own transcripts off disk, from outside the app.
 *
 * **Nothing was missing from the SDK.** It sends `task_started`,
 * `task_progress`, `task_updated` and `background_tasks_changed`, and every one
 * of them fell through {@link beginTurn}'s `system` case, which answered
 * `hook_response` and returned nothing for the rest.
 *
 * ## Mirrored, not imported
 *
 * Same reason as {@link SlashCommand}: this type is bundled into the webview and
 * the SDK is a host-side module that reads a credential when it loads.
 *
 * `description` and `subagentType` are written by whoever wrote the prompt or
 * the agent definition, so they are third-party text crossing into Core, and
 * are capped like every other name here.
 */
export interface RunningTask {
  /** The runtime's own id. What a later patch is matched against. */
  readonly id: string
  /** What it was asked to do, as the runtime describes it. */
  readonly description: string
  /** `code-reviewer`, `Explore`, … Empty when the runtime did not say. */
  readonly subagentType: string
  /**
   * Tokens, tool calls and elapsed milliseconds, as last reported.
   *
   * Zero rather than absent before the first progress message: a task that has
   * just started has genuinely done nothing, and a meter rendering a dash until
   * the first report would flicker on every task that ever runs.
   */
  readonly tokens: number
  readonly toolUses: number
  readonly elapsedMs: number
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
export function runtimeReportFrom(
  message: unknown,
  resumed = false,
  credentialSource = '',
): RuntimeReport {
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
    // The second argument that is not on the message, and for a sharper version
    // of the same reason: `apiKeySource` above says which store answered for an
    // API key, which is a different question from which variable varnick's
    // credential arrived in — and it is the SDK's question to answer rather than
    // this module's to correct. Bounded like every other name here even though
    // this one was written in this repository, because a rule with one exception
    // in it is a rule somebody has to remember.
    credentialSource: name(credentialSource),
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
 * How many subagents may be listed at once.
 *
 * Far below anything a real run produces — the largest measured was four — and
 * here for the reason every other cap on this wire is: what crosses into Core
 * does not arrive at whatever size it was sent at. A panel of two hundred rows
 * would also be a panel nobody can read.
 */
const TASK_LIMIT = 32

/**
 * A live task set, read back off the wire.
 *
 * Rebuilt field by field like {@link normaliseCommands}, and an entry with no
 * id is dropped rather than defaulted: an id is what a later patch is matched
 * against, so an entry without one could never be updated or removed and would
 * sit in the panel until the Turn ended.
 */
export function normaliseTasks(list: unknown): readonly RunningTask[] {
  if (!Array.isArray(list)) return []
  return list
    .filter(
      (one): one is Record<string, unknown> =>
        one !== null && typeof one === 'object' && typeof one['id'] === 'string' && one['id'] !== '',
    )
    .slice(0, TASK_LIMIT)
    .map((one) => ({
      id: name(one['id']),
      description: name(one['description']),
      subagentType: name(one['subagentType']),
      tokens: count(one['tokens']),
      toolUses: count(one['toolUses']),
      elapsedMs: count(one['elapsedMs']),
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
    credentialSource: name(report['credentialSource']),
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

/**
 * How a tool call ended, as far as the Turn can tell.
 *
 * Structurally what Core calls a `ToolStatus`, declared here because the
 * dependency runs Core → Harness and this is where the fact is read.
 */
export type ToolStatus = 'pending' | 'success' | 'error'

/**
 * One tool the agent called.
 *
 * `id` is the runtime's own `tool_use_id` and is the only thing a result is
 * paired against — never the order the results arrive in, because a Session
 * runs tools concurrently and the n-th result is not the n-th call. The
 * containment probe in `agent.ts` pairs the same way and says so at length; this
 * is the same rule on the path that ordinary Turns take.
 *
 * `result` and `detail` are absent until the result comes back, which may be
 * minutes later and may be after the Turn has ended.
 */
export interface ToolCall {
  readonly id: string
  readonly name: string
  readonly argument?: string
  readonly result?: string
  readonly detail?: string
  readonly status: ToolStatus
}

/** Everything a Turn tells the machine, before it is stamped with its Turn. */
export type TurnUpdate =
  /** Answer text, as it arrives. Reaches the machine as `STREAM_DELTA`. */
  | { readonly kind: 'delta'; readonly text: string }
  /**
   * A tool call, the moment the runtime announces it.
   *
   * ## It ends the segment of answer before it
   *
   * A tool call used to be `text` and nothing else: the line `⚙ Read(/x)` was
   * appended to the answer, so the whole Turn — words, tools, more words —
   * arrived as one Markdown document and was stored as one message. That is why
   * `text` is still here, and it is not vestigial: it is the one-line form the
   * mirror keeps, and the unprompted-answer path still collects it as text
   * because an answer nobody asked for is assembled whole before anything sees
   * it.
   *
   * What is new is `call`, and the consequence is that this update **ends the
   * run's accumulated text**. Everything streamed before it belongs to the
   * message above the tool call; everything after belongs to the one below. So
   * the accumulation resets here, and `done` carries only the last segment
   * rather than the whole answer. A reader of this file who expects `done.text`
   * to be the entire Turn is reading the previous design.
   *
   * ## It is emitted when the call starts, not when it finishes
   *
   * Which is the whole reason the pair exists rather than one update carrying
   * both halves. A tool that runs for four minutes is four minutes in which the
   * only honest thing a window can say is *this tool is running* — and ticket 62
   * is the record of what happens when it cannot say that: a Turn doing work is
   * indistinguishable from a Turn that has hung.
   */
  | { readonly kind: 'tool'; readonly text: string; readonly call: ToolCall }
  /**
   * What a tool returned, matched to the call by {@link ToolCall.id}.
   *
   * Read off the `user` messages the runtime sends back — the half of the
   * stream this module used to discard entirely, which is why what a tool
   * *returned* existed nowhere in the product.
   *
   * Not transcript text, and deliberately not a `delta`: it does not extend the
   * answer, it completes something already in it. Core patches the entry in
   * place; see `withToolResult` in packages/core/src/domain.ts for why that one
   * rewrite is allowed in a record that is otherwise append-only.
   */
  | {
      readonly kind: 'tool-result'
      readonly id: string
      readonly result: string
      readonly detail?: string
      readonly status: Exclude<ToolStatus, 'pending'>
    }
  /**
   * A hook that did not run, said out loud. Transcript, like a tool call.
   *
   * The property that let ticket 58's bug survive was silence: a plugin
   * declared a hook, the hook could not spawn, and nothing anywhere said so —
   * not the transcript, not the runtime report, not a log. A capability was
   * missing and the only evidence was a file that never appeared.
   *
   * It is transcript rather than a Turn failure because **a hook that fails
   * must not fail the Turn**. The agent answered; something beside it did not
   * run. Those are different facts and collapsing them would turn a missing
   * `node` into a refused conversation.
   */
  | { readonly kind: 'hook'; readonly text: string }
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
   * Every subagent and background task running right now.
   *
   * **A replacement, never an addition**, like `commands` and for a related
   * reason: the SDK's `background_tasks_changed` says to swap the set, and a
   * merge would leave a finished subagent on screen forever. The progress and
   * patch messages are folded into the set here rather than in Core, so what
   * crosses is always the whole truth as of that moment.
   *
   * Ephemeral on purpose. This is the live panel and it is gone when the Turn
   * ends; what survives is {@link TurnUpdate} `task-line`, which is transcript.
   */
  | { readonly kind: 'tasks'; readonly tasks: readonly RunningTask[] }
  /**
   * A subagent started, or finished. Transcript, like a tool call.
   *
   * The durable half of the same fact the live panel shows. A developer who
   * looks away for ten minutes needs to be able to see afterwards that four
   * subagents ran and how long they took — the panel cannot tell them, because
   * by then it is empty.
   *
   * **Start and terminal status only.** A line per progress tick would be the
   * noise the `hook_response` filter exists to prevent: `task_progress` arrives
   * every few seconds per task, and a transcript is not a meter.
   */
  | { readonly kind: 'task-line'; readonly text: string }
  /**
   * Why the agent started talking without being asked.
   *
   * The first update of an unprompted Turn, and the reason the window can show
   * one at all: an answer that appears in the scrollback with no visible cause
   * reads as the agent talking to itself. Core renders it as the divider above
   * the message — *"── a subagent finished ──"* — and does not compose it, for
   * the reason it composes nothing else that arrives from outside.
   */
  | { readonly kind: 'cause'; readonly text: string }
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
 * A tool call read back off the wire, or nothing.
 *
 * Field by field for the reason {@link parseTurnEvent} gives, and it matters
 * more here than anywhere else on this boundary: this is the one value crossing
 * into Core that ends up written to the Session mirror *verbatim* rather than
 * as text somebody composed. A field nobody agreed to would be on disk.
 *
 * `id` and `name` are required and may not be empty — a call that cannot be
 * named cannot be rendered, and one with no id can never be settled.
 */
function parseToolCall(value: unknown): ToolCall | null {
  if (value === null || typeof value !== 'object') return null
  const { id, name: toolName, argument, result, detail, status } = value as Record<string, unknown>
  if (typeof id !== 'string' || id.length === 0) return null
  if (typeof toolName !== 'string' || toolName.length === 0) return null
  if (status !== 'pending' && status !== 'success' && status !== 'error') return null
  return {
    id,
    name: toolName,
    ...(typeof argument === 'string' ? { argument } : {}),
    ...(typeof result === 'string' ? { result } : {}),
    ...(typeof detail === 'string' ? { detail } : {}),
    status,
  }
}

/**
 * Read an event back, or refuse it.
 *
 * Rebuilt rather than passed through, like every other answer that crosses into
 * Core: a field nobody agreed to cannot ride into the machine's context, from
 * where it would reach the Session mirror.
 */
export function parseTurnEvent(value: unknown): TurnEvent | null {
  const { kind, turnId, text, summary, tokensUsed, failure, report, commands, tasks, call, id, result, detail, status } =
    (value ?? {}) as Record<string, unknown>
  if (typeof turnId !== 'string' || turnId.length === 0) return null

  switch (kind) {
    case 'delta':
    case 'hook':
    case 'task-line':
    // Why an unprompted Turn started. Text like any other, and rebuilt like
    // any other — Core renders it and does not compose it.
    case 'cause':
      return typeof text === 'string' ? { kind, turnId, text } : null
    case 'tool': {
      // Both halves required. The line is what the mirror keeps and what the
      // unprompted path collects; the call is what the window renders. An event
      // carrying one and not the other is malformed rather than half-usable.
      const parsed = parseToolCall(call)
      return parsed !== null && typeof text === 'string'
        ? { kind, turnId, text, call: parsed }
        : null
    }
    case 'tool-result':
      /*
        `pending` is deliberately not accepted. This event exists to *settle* a
        call, and one that settled it back into running would leave a tool that
        can never be finished by any later event — the id has already been
        answered, and nothing sends a second result for it.
      */
      return typeof id === 'string' &&
        id.length > 0 &&
        typeof result === 'string' &&
        (status === 'success' || status === 'error')
        ? {
            kind,
            turnId,
            id,
            result,
            ...(typeof detail === 'string' ? { detail } : {}),
            status,
          }
        : null
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
    case 'tasks':
      /*
        Empty is a real answer here too, and it is the most important one: it is
        what "the last subagent finished" looks like, and refusing it would
        leave the panel showing work that has stopped.
      */
      return Array.isArray(tasks) ? { kind, turnId, tasks: normaliseTasks(tasks) } : null
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

/** How much of a hook's stderr is worth a transcript line. */
const HOOK_STDERR_LIMIT = 160

/**
 * A hook that failed, as one line of transcript.
 *
 * **The one place in this module that quotes something it did not author**, and
 * the exception is deliberate rather than an oversight. Everywhere else here the
 * prose is written locally and selected by a tag, because the text being
 * described is an API response and an authentication failure is the response
 * most likely to carry a credential back.
 *
 * A hook's stderr is not that. It is the output of a local process the developer
 * put in their own clone, running inside the Sandbox — where `$HOME` is denied,
 * so the Secrets Store it might otherwise have read is unreachable. And it is
 * the whole of the value: `node: command not found` *is* the answer, and a
 * hand-written sentence saying "a hook failed" would send the reader to a log
 * that does not exist.
 *
 * Bounded rather than trusted, like every other thing that arrives from outside
 * in this file. First line only, because a stack trace is not a transcript line.
 */
export function hookFailureLine(
  name: unknown,
  event: unknown,
  exitCode: unknown,
  stderr: unknown,
): string {
  const hook = typeof name === 'string' && name.length > 0 ? name : 'a hook'
  const when = typeof event === 'string' && event.length > 0 ? ` (${event})` : ''
  const code = typeof exitCode === 'number' && Number.isFinite(exitCode) ? ` exit ${exitCode}` : ''
  const first = typeof stderr === 'string' ? (stderr.split('\n').find((line) => line.trim() !== '') ?? '') : ''
  const trimmed = first.trim()
  const detail =
    trimmed === ''
      ? ''
      : `: ${trimmed.length > HOOK_STDERR_LIMIT ? `${trimmed.slice(0, HOOK_STDERR_LIMIT)}…` : trimmed}`
  return `⚠ hook ${hook}${when} did not run${code}${detail}\n`
}

/**
 * A tool call, as one line of transcript.
 *
 * The name plus the one field that says what it was pointed at. Not the whole
 * input: a `Write` call carries the file it is writing, and a transcript that
 * inlined every one of those would be unreadable as an audit trail, which is the
 * only thing it is for.
 */
export function toolCallLine(name: string, input: unknown): string {
  const argument = toolArgument(input)
  return argument === undefined ? `⚙ ${name}\n` : `⚙ ${name}(${argument})\n`
}

/**
 * What a tool was pointed at, in one bounded string.
 *
 * Split out of {@link toolCallLine} so the line the mirror keeps and the
 * structured call the window renders name the same thing. Two lists of keys
 * would drift, and the drift is invisible: the transcript would say
 * `Bash(git status)` while the rendered call said `Bash`, and both would look
 * right on their own.
 *
 * `undefined` rather than `''` when nothing matched, because a tool called with
 * nothing worth quoting renders as its bare name — not as a name with empty
 * brackets after it.
 */
export function toolArgument(input: unknown): string | undefined {
  const fields = (input ?? {}) as Record<string, unknown>
  for (const key of ['file_path', 'path', 'command', 'pattern', 'url', 'query', 'description']) {
    const value = fields[key]
    if (typeof value !== 'string' || value.length === 0) continue
    return value.length > TOOL_ARGUMENT_LIMIT ? `${value.slice(0, TOOL_ARGUMENT_LIMIT)}…` : value
  }
  return undefined
}

/**
 * How much of a tool's answer the transcript keeps.
 *
 * A `Read` of a large file comes back as the whole file. Kept in full, one tool
 * call would be larger than every conversation varnick has ever mirrored put
 * together, and the mirror's whole virtue is that `cat` and `jq` read it — the
 * same argument that keeps pasted images out of it as a count.
 *
 * Generous rather than tight, because the truncation is what a developer sees
 * when they expand the call, and a limit that cut off the interesting part
 * would send them back to reading the SDK's own transcripts off disk.
 */
const TOOL_DETAIL_LIMIT = 4_000

/** The one-line summary shown beside a settled call, before it is expanded. */
const TOOL_RESULT_LIMIT = 120

/**
 * What a tool said back, split into the line and the rest.
 *
 * The line is the first thing in it that is not blank, which is what makes a
 * result readable at a glance for the tools whose answer is one line anyway —
 * `Bash` with no output, a `Write` confirming a path. `detail` is present only
 * when there is more than the line, so a call with a one-line answer renders as
 * a fact rather than as a disclosure with nothing behind it.
 */
export function toolResultText(raw: string): { result: string; detail?: string } {
  const text = raw.replace(/\r\n/g, '\n')
  const trimmed = text.trim()
  if (trimmed.length === 0) return { result: '(no output)' }
  const first = trimmed.split('\n').find((line) => line.trim() !== '') ?? ''
  const line = first.trim()
  const result = line.length > TOOL_RESULT_LIMIT ? `${line.slice(0, TOOL_RESULT_LIMIT)}…` : line
  // Nothing behind the disclosure when the line already is the answer.
  if (trimmed === line) return { result }
  const detail =
    trimmed.length > TOOL_DETAIL_LIMIT ? `${trimmed.slice(0, TOOL_DETAIL_LIMIT)}…` : trimmed
  return { result, detail }
}

/**
 * The text of a `tool_result` block, whatever shape the runtime sent it in.
 *
 * `content` is a string for most tools and an array of blocks for the ones that
 * answer with more than text — an image, a document. The blocks that are not
 * text contribute nothing here on purpose: the transcript records what a tool
 * returned as something a developer can read, and a base64 image in a mirror is
 * the thing `attachments` exists to avoid.
 */
export function toolResultContent(content: unknown): string {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content
    .map((block) => {
      const one = (block ?? {}) as Record<string, unknown>
      return typeof one.text === 'string' ? one.text : ''
    })
    .filter((text) => text.length > 0)
    .join('\n')
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
 * How a Turn nobody asked for is stamped.
 *
 * A prompted Turn's id comes from Core and is `t`-numbered; this is the other
 * kind, and the prefix is the whole of how they are told apart. It matters at
 * exactly one place — the window renders one under a message the developer sent
 * and the other under what caused it — so the distinction is carried on the id
 * rather than as a flag on every update.
 */
export const UNPROMPTED_TURN_PREFIX = 'u'

/** Is this a Turn the world started rather than one varnick did? */
export function isUnpromptedTurn(turnId: string): boolean {
  return turnId.startsWith(UNPROMPTED_TURN_PREFIX)
}

/** What the window says when nothing on the stream explained itself. */
export const UNPROMPTED_CAUSE_UNKNOWN = 'the agent spoke on its own'

/**
 * What caused an answer nobody asked for, in three words.
 *
 * **Read off the stream rather than guessed.** The thing that prompts an
 * unprompted answer arrives as an ordinary `user` message — a task
 * notification, a background command's output — and it is the only description
 * of the cause that exists. Core does not invent one: a marker saying
 * *"subagent finished"* over an answer that had a different cause would be a
 * transcript that lies in a new way.
 *
 * `null` when this message is not a prompt at all, which leaves whatever was
 * read last standing. Most of what crosses the stream is the agent's own
 * output and says nothing about why it started.
 *
 * The strings are deliberately short: this is a divider above a message, not a
 * report, and the message underneath is where the detail is.
 */
export function unpromptedCauseOf(message: unknown): string | null {
  const sdk = (message ?? {}) as Record<string, unknown>
  if (sdk.type !== 'user') return null
  const content = (sdk.message as { content?: unknown } | undefined)?.content
  const text =
    typeof content === 'string'
      ? content
      : Array.isArray(content)
        ? content
            .filter((b): b is Record<string, unknown> => b !== null && typeof b === 'object')
            .map((b) => (typeof b.text === 'string' ? b.text : ''))
            .join(' ')
        : ''
  if (text.length === 0) return null
  if (text.includes('<task-notification>')) return 'a subagent finished'
  if (text.includes('<system-reminder>')) return 'a reminder from the runtime'
  if (text.includes('background') && text.includes('command')) return 'a background command finished'
  return UNPROMPTED_CAUSE_UNKNOWN
}

/**
 * Is this the first message of an answer?
 *
 * The gate on opening an unprompted run at all. Most of what arrives while no
 * Turn is running is not an answer — hook responses, task progress, the
 * runtime's own bookkeeping — and a run opened for one of those would emit an
 * empty answer into the transcript.
 *
 * Streamed text or an assembled assistant message, and nothing else. A `result`
 * is deliberately not here: a result with no answer before it is the tail of
 * something already dropped, and answering it would post an empty message.
 */
export function beginsAnAnswer(message: unknown): boolean {
  const sdk = (message ?? {}) as Record<string, unknown>
  if (sdk.type === 'assistant') return true
  if (sdk.type !== 'stream_event') return false
  const event = sdk.event as Record<string, unknown> | undefined
  if (event?.type !== 'content_block_delta') return false
  const delta = event.delta as Record<string, unknown> | undefined
  return delta?.type === 'text_delta' && typeof delta.text === 'string'
}

/** The four `system` subtypes that describe a subagent rather than the Turn. */
function isTaskSubtype(subtype: unknown): boolean {
  return (
    subtype === 'task_started' ||
    subtype === 'task_progress' ||
    subtype === 'task_updated' ||
    subtype === 'background_tasks_changed'
  )
}

/** A whole number from the runtime, or zero. Never `NaN`, never negative. */
function count(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0
}

/** `code-reviewer · reviewing the diff` — how a task reads on one line. */
function taskLabel(task: RunningTask): string {
  const kind = task.subagentType.length > 0 ? task.subagentType : 'agent'
  return task.description.length > 0 ? `${kind} · ${task.description}` : kind
}

/** How long it ran, in the coarsest unit that is still true. */
function elapsedLabel(ms: number): string {
  if (ms < 1_000) return `${ms}ms`
  const seconds = Math.round(ms / 1_000)
  return seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m${seconds % 60}s`
}

export function beginTurn(turnId: string): TurnRun {
  let transcript = ''
  let finished = false
  /**
   * Whether this Turn has said anything at all yet.
   *
   * Separate from `transcript` being non-empty, and the difference is the whole
   * of why it exists. `done` falls back to the runtime's own `result` field for
   * a Turn that streamed nothing — a cached or instant answer. Now that a tool
   * call empties the accumulation, a Turn whose last act was a tool call also
   * reaches `done` with an empty `transcript`, and the fallback would post the
   * entire answer a second time underneath the pieces already shown.
   */
  let produced = false

  /*
    Every subagent this Turn has started, by the runtime's id.

    Insertion-ordered, which a Map gives for free and which matters: the panel
    lists them in the order they started, so a second subagent appearing does
    not reshuffle the first.

    A task that reaches a terminal status is removed — the set is what is
    *running*. Its last figures go out on the transcript line instead, which is
    the half that is supposed to outlive it.
  */
  const tasks = new Map<string, RunningTask>()

  /** What one task message means: the new set, and possibly one line. */
  function acceptTask(sdk: Record<string, unknown>): TurnUpdate[] {
    const updates: TurnUpdate[] = []

    if (sdk.subtype === 'background_tasks_changed') {
      /*
        Replace semantics, said in so many words by the SDK. Existing entries
        keep their measured figures — this message carries none, and dropping
        them would blank every meter each time any task started or ended.
      */
      const listed = Array.isArray(sdk.tasks) ? sdk.tasks : []
      const replacement = new Map<string, RunningTask>()
      for (const one of listed) {
        const entry = (one ?? {}) as Record<string, unknown>
        const id = name(entry.task_id)
        if (id.length === 0) continue
        const known = tasks.get(id)
        replacement.set(id, {
          id,
          description: name(entry.description) || (known?.description ?? ''),
          subagentType: name(entry.task_type) || (known?.subagentType ?? ''),
          tokens: known?.tokens ?? 0,
          toolUses: known?.toolUses ?? 0,
          elapsedMs: known?.elapsedMs ?? 0,
        })
      }
      tasks.clear()
      for (const [id, entry] of replacement) tasks.set(id, entry)
      return [{ kind: 'tasks', tasks: [...tasks.values()] }]
    }

    const id = name(sdk.task_id)
    if (id.length === 0) return []

    if (sdk.subtype === 'task_updated') {
      const patch = (sdk.patch ?? {}) as Record<string, unknown>
      const known = tasks.get(id)
      const status = patch.status
      const ended =
        status === 'completed' || status === 'failed' || status === 'killed'
      if (!ended) {
        // Still running, and possibly renamed. `paused` and `pending` stay in
        // the set: they are states of a task that has not gone away.
        if (known !== undefined && typeof patch.description === 'string') {
          tasks.set(id, { ...known, description: name(patch.description) })
        }
        return [{ kind: 'tasks', tasks: [...tasks.values()] }]
      }
      tasks.delete(id)
      if (known === undefined) return [{ kind: 'tasks', tasks: [...tasks.values()] }]
      /*
        The durable half. `failed` and `killed` say so and quote the reason the
        runtime gave, because "it finished" and "it was killed after four
        minutes" are different facts and only one of them is good news.
      */
      const reason = name(patch.error)
      const verb =
        status === 'completed' ? 'finished' : status === 'failed' ? 'failed' : 'was stopped'
      const measured =
        known.tokens > 0 || known.toolUses > 0
          ? ` · ${known.tokens} tokens · ${known.toolUses} tools`
          : ''
      const because = status !== 'completed' && reason.length > 0 ? ` — ${reason}` : ''
      updates.push({
        kind: 'task-line',
        text: `\n⚙ ${taskLabel(known)} ${verb} in ${elapsedLabel(known.elapsedMs)}${measured}${because}\n`,
      })
      updates.push({ kind: 'tasks', tasks: [...tasks.values()] })
      return updates
    }

    // `task_started` and `task_progress` carry the same descriptive fields; the
    // second adds the figures. Treated together so a progress message for a
    // task nobody announced still produces an entry rather than nothing.
    const known = tasks.get(id)
    const usage = (sdk.usage ?? {}) as Record<string, unknown>
    const entry: RunningTask = {
      id,
      description: name(sdk.description) || (known?.description ?? ''),
      subagentType: name(sdk.subagent_type) || (known?.subagentType ?? ''),
      tokens: count(usage.total_tokens) || (known?.tokens ?? 0),
      toolUses: count(usage.tool_uses) || (known?.toolUses ?? 0),
      elapsedMs: count(usage.duration_ms) || (known?.elapsedMs ?? 0),
    }
    tasks.set(id, entry)
    // The line is written once, when it first appears — not on every progress
    // message, which arrives every few seconds for the whole of a long task.
    if (known === undefined) {
      updates.push({ kind: 'task-line', text: `\n⚙ ${taskLabel(entry)} started\n` })
    }
    updates.push({ kind: 'tasks', tasks: [...tasks.values()] })
    return updates
  }

  function emit(updates: readonly TurnUpdate[]): TurnEvent[] {
    const events: TurnEvent[] = []
    for (const update of updates) {
      // A failed hook joins the transcript for the reason answer text does: it
      // has to survive into the message an interrupt keeps and into the mirror,
      // or it is a warning that exists only for whoever was watching.
      if (
        update.kind === 'delta' ||
        update.kind === 'hook' ||
        // And a subagent starting or ending, for the same reason again: the
        // live panel is empty by the time anyone reads the answer back.
        update.kind === 'task-line'
      ) {
        transcript += update.text
        produced = true
      }
      /*
        A tool call ends the segment of answer before it.

        It used to *join* the accumulation, which is what made a Turn one
        message. Now the words before the call and the words after it are
        different entries with the call between them, so the accumulation has to
        stop here — and `done` carries only what came after the last tool rather
        than the whole Turn. Core resets its own `partial` on the same event, so
        the two sides cut the answer in the same place.
      */
      if (update.kind === 'tool') {
        transcript = ''
        produced = true
      }
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
            const { type, name, input, id } = (block ?? {}) as Record<string, unknown>
            if (type !== 'tool_use' || typeof name !== 'string') continue
            /*
              A call with no id is not recorded.

              Every call in the SDK's own schema has one, so this is not a shape
              the runtime produces — but a call the transcript holds and no
              result can ever be matched to is a tool that renders as running
              for the rest of the conversation, and there is no later event that
              could fix it. Dropping it loses one line; keeping it leaves a lie
              on screen that outlives the Turn.
            */
            if (typeof id !== 'string' || id.length === 0) continue
            const argument = toolArgument(input)
            updates.push({
              kind: 'tool',
              text: toolCallLine(name, input),
              call: {
                id,
                name,
                ...(argument !== undefined ? { argument } : {}),
                status: 'pending',
              },
            })
          }
          return emit(updates)
        }

        /*
          What the tools said back.

          The half of the stream this module used to drop on the floor. It read
          `assistant` messages for the calls they announced and ignored the
          `user` messages carrying the results, so what a tool *returned* existed
          nowhere in varnick — not in the window, not in the mirror, not in a
          log. A developer who wanted to know what a `Bash` call actually
          printed had to go and read the SDK's own transcripts.

          Matched to the call by `tool_use_id` and never by arrival order: a
          Session runs tools concurrently, so the n-th result is not the n-th
          call. `agent.ts` pairs the same way in the containment probe and its
          comment records what happens when this is got wrong.

          A `user` message is also where an unprompted Turn's cause is read
          from — see `unpromptedCauseOf`. The two readings do not collide: that
          one looks at text blocks, this one at `tool_result` blocks, and a
          message carrying both is answered as both.
        */
        case 'user': {
          const content = (sdk.message as { content?: unknown } | undefined)?.content
          if (!Array.isArray(content)) return []
          const updates: TurnUpdate[] = []
          for (const block of content) {
            const one = (block ?? {}) as Record<string, unknown>
            if (one.type !== 'tool_result') continue
            const id = one.tool_use_id
            if (typeof id !== 'string' || id.length === 0) continue
            const { result, detail } = toolResultText(toolResultContent(one.content))
            updates.push({
              kind: 'tool-result',
              id,
              result,
              ...(detail !== undefined ? { detail } : {}),
              // The runtime's own verdict. A tool that failed and a tool that
              // returned an error message are the same fact to a reader, and
              // this is the only place that knows which one happened.
              status: one.is_error === true ? 'error' : 'success',
            })
          }
          return emit(updates)
        }

        /*
          A hook finished, and it is only interesting when it did not work.

          The SDK reports every hook this way — `outcome` is `success`, `error`
          or `cancelled` — so the filter is here rather than in Core: a
          transcript carrying a line per successful hook would be noise on every
          Turn, and the fact worth surfacing is the one nobody could see.

          `cancelled` is left alone. That is varnick or the developer stopping
          something on purpose, and reporting a deliberate stop as a fault is
          how a surface teaches people to ignore it.
        */
        case 'system': {
          /*
            A subagent started, reported progress, changed status, or the whole
            live set was replaced. Four subtypes, one answer: the current set,
            plus a transcript line at the two moments worth keeping.

            Folded here rather than in Core because `task_progress` *patches* an
            entry — Core would have to hold the same map to apply it, and two
            copies of a merge rule is one too many.
          */
          if (isTaskSubtype(sdk.subtype)) return emit(acceptTask(sdk as Record<string, unknown>))
          if (sdk.subtype !== 'hook_response') return []
          const hook = sdk as Record<string, unknown>
          if (hook.outcome !== 'error') return []
          return emit([
            {
              kind: 'hook',
              text: hookFailureLine(
                hook.hook_name,
                hook.hook_event,
                hook.exit_code,
                hook.stderr,
              ),
            },
          ])
        }

        case 'result': {
          // `is_error` is checked as well as the subtype: a result can be
          // flagged an error while still calling itself a success, and treating
          // that as an answer would post an error page as the agent's reply.
          if (sdk.subtype !== 'success' || sdk.is_error === true) {
            return emit([{ kind: 'failed', failure: failureOfResultSubtype(sdk.subtype) }])
          }
          /*
            The accumulated transcript, not `result`: it is what was watched.

            Since a tool call ends a segment, this is the *last* segment rather
            than the whole Turn — everything before the final tool call is
            already in the transcript as its own entries.

            `result` is still the fallback for a Turn that streamed nothing at
            all, which is what a cached or instant answer looks like. It is
            gated on `produced` and not on the accumulation being empty: a Turn
            that ended on a tool call has an empty accumulation and has said
            plenty, and falling back there would post the entire answer again
            below the pieces already on screen.
          */
          const answer = transcript.length > 0 ? transcript : produced ? '' : String(sdk.result ?? '')
          return emit([{ kind: 'done', text: answer, tokensUsed: contextTokens(sdk.usage) }])
        }

        default:
          return []
      }
    },
  }
}
