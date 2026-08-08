#!/usr/bin/env bun
/**
 * The agent, and the two halves of starting one.
 *
 * ## Who spawns what
 *
 * Three processes, and the split between them is the whole of ADR-0008:
 *
 *   * the **Harness runtime** holds the Sandbox. It computes the wrapping —
 *     `EstablishedSandbox.wrap()` gives argv, an environment overlay, and the
 *     directory to spawn in — and that answer contains no secret.
 *   * the **Rust host** performs the spawn, because that is where the credential
 *     already is. `credential_env()` in src-tauri/src/credential.rs is the one
 *     way the value leaves that module, and it goes into this process's
 *     environment: never into a string the host keeps, never across the bridge,
 *     never into a log.
 *   * the **agent host** — this file, run as a script — is what that spawn
 *     starts, inside `srt`. It opens the Claude Agent SDK session, which starts
 *     a Claude Code process as its child, inside `srt` too because containment
 *     wraps the whole tree (ADR-0003).
 *
 * The tempting shortcut is to let the runtime spawn the agent, since the runtime
 * is the half holding the Sandbox. That would mean sending the credential across
 * the bridge, which is the one thing that may never happen — see ADR-0008's
 * third rejection, which exists for exactly this ticket.
 *
 * ## The SDK's own sandbox stays off
 *
 * The kernel refuses `sandbox_apply` inside an existing sandbox, so leaving the
 * SDK's `sandbox` option on kills every Bash command with exit 71 (ADR-0003).
 * It is set to `enabled: false` below rather than merely left unset, because
 * "off" should be visible in the code that would be blamed for exit 71.
 */

import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { credentialRejection } from './credentials.ts'
import {
  beginTurn,
  encodeTurnEvent,
  parseTurnControl,
  type TurnEvent,
  type TurnFailure,
  type TurnRun,
} from './turn.ts'

/**
 * Classify something the Session *threw* rather than reported.
 *
 * The SDK names most failures itself, in an enum ./turn.ts maps. An exception
 * out of the stream carries only prose, and prose is where a 401 body would be —
 * so it is handed to {@link credentialRejection}, the shared classifier, and
 * nothing but its verdict is kept. This is the caller that classifier was
 * written for, and it lives here rather than in ./turn.ts because ./turn.ts has
 * to stay importable from the webview bundle without reaching back through the
 * bridge — see the note at the top of that file.
 */
export function failureOfThrown(error: unknown): TurnFailure {
  return credentialRejection(error) === null ? 'execution' : 'authentication'
}

/** Where the agent host lives inside a clone. */
export const AGENT_ENTRY_RELATIVE_PATH = 'packages/harness/src/agent.ts'

/**
 * The variable the credential arrives in.
 *
 * Mirrored as `ENV_VAR` in src-tauri/src/credential.rs and as
 * `CREDENTIAL_ENV_VAR` in ./credentials.ts. Named here so
 * {@link sandboxEnvOverlay} can refuse to carry it.
 */
export const CREDENTIAL_ENV_VAR_NAME = 'ANTHROPIC_API_KEY'

/** The agent host's path in a given clone. */
export function agentEntryPath(cloneRoot: string): string {
  return join(cloneRoot, AGENT_ENTRY_RELATIVE_PATH)
}

/**
 * Where the Agent SDK actually is, as an absolute path.
 *
 * Resolved *here*, in the unsandboxed runtime, and handed to the confined
 * process as an argument. That is not indirection for its own sake — it is a
 * measured requirement.
 *
 * `packages/harness/node_modules/@anthropic-ai/claude-agent-sdk` is a symlink
 * into the workspace store, and a bare-specifier import of it from inside the
 * Sandbox fails: bun reports `Cannot find module` while every read the resolver
 * needs — the directory listing, the symlink, the target's files — succeeds when
 * done directly, and srt's violation monitor records nothing. The same import
 * from an absolute path works, and so does the same bare specifier from a file
 * at the clone root. So the resolver's package walk is what the kernel refuses,
 * silently, and the fix is to not make the confined process walk it.
 *
 * Worth keeping: the failure looked exactly like a missing dependency.
 */
export function agentSdkEntry(): string {
  return fileURLToPath(import.meta.resolve('@anthropic-ai/claude-agent-sdk'))
}

export interface AgentCommandInput {
  /** The clone the agent works inside — the one tree the policy reads back. */
  readonly cloneRoot: string
  /**
   * The interpreter to run the agent host with.
   *
   * Defaults to the runtime's own, which is the point: the runtime is already
   * running under this interpreter, so an agent started with it cannot be
   * started with one that is not installed. It must be absolute — a PATH search
   * inside the Sandbox has to read the directory holding the interpreter, and
   * the policy denies the home directory that usually is.
   */
  readonly execPath?: string
  /** Defaults to {@link agentSdkEntry}. */
  readonly sdkEntry?: string
}

/**
 * The command the Sandbox wraps.
 *
 * A string, because that is what `wrap()` takes; every path in it is quoted
 * through `JSON.stringify`, because the wrapper hands this to `bash -c` and an
 * unquoted path is an injection point rather than a cosmetic problem.
 */
export function agentCommand(input: AgentCommandInput): string {
  const exec = input.execPath ?? process.execPath
  const parts = [exec, agentEntryPath(input.cloneRoot), input.sdkEntry ?? agentSdkEntry()]
  return parts.map((part) => JSON.stringify(part)).join(' ')
}

/**
 * What the wrapper *added*, rather than the whole environment it was computed
 * against.
 *
 * `SandboxManager.wrapWithSandboxArgv` answers with the calling process's own
 * `process.env` plus whatever the platform needs (on macOS it adds nothing — the
 * proxy variables are baked into the wrapped command instead). Forwarding that
 * whole environment would put every variable the runtime was started with onto
 * the wire, and the runtime inherits the host's environment — which on a
 * developer's machine may hold an exported `ANTHROPIC_API_KEY`.
 *
 * So only the difference crosses, and the credential variable is dropped
 * outright even if it somehow became one. Structural, not remembered: there is
 * no code path that puts it in.
 */
export function sandboxEnvOverlay(
  wrapped: Record<string, string | undefined>,
  base: Record<string, string | undefined>,
): Record<string, string> {
  const overlay: Record<string, string> = {}
  for (const [key, value] of Object.entries(wrapped)) {
    if (value === undefined) continue
    if (key === CREDENTIAL_ENV_VAR_NAME) continue
    if (base[key] === value) continue
    overlay[key] = value
  }
  return overlay
}

// ---------------------------------------------------------------------------
// The agent host, as a process
// ---------------------------------------------------------------------------

/**
 * Report what this process can reach, and exit.
 *
 * The boundary suite's probe. It exists because the interesting question about a
 * spawned agent is not whether it starts but whether it is *contained*, and the
 * only honest way to answer that is to ask the real entry, under the real
 * wrapper, on the real machine. It loads the Agent SDK — which proves the
 * interpreter and the SDK's own files are reachable inside the Sandbox — and
 * then tries to read a path it should not be able to.
 *
 * No session is opened and no credential is needed, so the probe runs on a
 * machine that has never stored one.
 */
async function selfTest(sdkEntry: string, deniedPath: string): Promise<void> {
  const report: Record<string, string> = {}

  try {
    const sdk = (await import(sdkEntry)) as { query?: unknown }
    report.sdk = typeof sdk.query === 'function' ? 'loaded' : 'missing-query'
  } catch (error) {
    report.sdk = `failed: ${error instanceof Error ? error.message : String(error)}`
  }

  try {
    const { readFileSync } = await import('node:fs')
    readFileSync(deniedPath, 'utf8')
    report.read = 'permitted'
  } catch {
    report.read = 'denied'
  }

  process.stdout.write(`${JSON.stringify(report)}\n`)
}

// ---------------------------------------------------------------------------
// Turns, on the Session that is already open
// ---------------------------------------------------------------------------

/**
 * What a Turn needs from the Session, and nothing else.
 *
 * A port rather than the SDK's `Query`, so the loop below can be driven by a
 * test with no Claude Code process anywhere. That is not a testing convenience:
 * a test that opened a session to exercise a Turn would be a session outside
 * `srt` on a developer's machine, which is exactly what ADR-0003's last
 * consequence forbids.
 *
 * Four methods, and deliberately no fifth. This is the surface something outside
 * the Sandbox can reach into the Sandbox with.
 */
export interface TurnSessionPort {
  /** Put a prompt on the Session's streaming input. */
  prompt(text: string): void
  /** What the *next* answer runs on. Applied before the prompt goes out. */
  setModel(model: string): Promise<void>
  setEffort(effort: string): Promise<void>
  /** Stop the answer in flight. What has arrived stays arrived. */
  interrupt(): Promise<void>
}

export interface ServeTurnsInput {
  /** Control requests, as newline-delimited JSON. The process's stdin. */
  readonly control: AsyncIterable<Uint8Array | string>
  /** The Session's messages. One stream for the life of the process. */
  readonly messages: AsyncIterable<unknown>
  readonly session: TurnSessionPort
  /** One event, already newline-terminated. The process's stdout. */
  readonly write: (line: string) => void
}

/**
 * Run Turns on one Session until both streams end.
 *
 * Two loops over one piece of state — the Turn currently running. The control
 * loop starts and interrupts Turns; the message loop reads the Session and turns
 * what it says into events. They are separate because they are separate facts: a
 * control request must be answerable while an answer is streaming, which is what
 * makes interrupting cost seconds rather than the rest of the Turn.
 *
 * A message arriving with no Turn running is dropped. The Session emits its own
 * init and status messages, and a stray delta attributed to the next Turn would
 * become that Turn's first word.
 */
export async function serveTurns(input: ServeTurnsInput): Promise<void> {
  const { control, messages, session, write } = input

  /** The Turn currently running, and the only state these two loops share. */
  let running: TurnRun | null = null

  const emit = (events: readonly TurnEvent[]) => {
    for (const event of events) write(encodeTurnEvent(event))
  }

  async function start(request: {
    turnId: string
    prompt: string
    model: string
    effort: string
  }): Promise<void> {
    const run = beginTurn(request.turnId)
    running = run
    try {
      // Before the prompt, so the Turn runs on what it was started with. A
      // SET_MODEL that arrives mid-Turn belongs to the next one, and applying
      // it here rather than reconfiguring a Turn in flight is what makes that
      // true rather than likely.
      await session.setModel(request.model)
      await session.setEffort(request.effort)
      session.prompt(request.prompt)
    } catch (error) {
      // A Turn that was sent and never answered is the worst available state:
      // `sending` for ever, with nothing to retry and nothing to dismiss.
      emit([{ kind: 'failed', turnId: request.turnId, failure: failureOfThrown(error) }])
      if (running === run) running = null
    }
  }

  async function handle(line: string): Promise<void> {
    const request = parseTurnControl(line)
    // A line this host does not understand is dropped rather than guessed at.
    // It runs inside the Sandbox holding a live agent, so a loosely-read control
    // channel is a way in rather than a robustness feature.
    if (request === null) return
    if (request.kind === 'run-turn') return start(request)
    // A stale interrupt from an abandoned Turn must not stop the one that
    // replaced it, so it has to name the Turn it means.
    if (running !== null && !running.finished && running.turnId === request.turnId) {
      await session.interrupt()
    }
  }

  async function readControl(): Promise<void> {
    const decoder = new TextDecoder()
    let pending = ''

    for await (const chunk of control) {
      pending += typeof chunk === 'string' ? chunk : decoder.decode(chunk, { stream: true })
      let newline = pending.indexOf('\n')
      while (newline !== -1) {
        const line = pending.slice(0, newline)
        pending = pending.slice(newline + 1)
        if (line.trim().length > 0) await handle(line)
        newline = pending.indexOf('\n')
      }
    }
    if (pending.trim().length > 0) await handle(pending)
  }

  async function readMessages(): Promise<void> {
    for await (const message of messages) {
      const run = running
      if (run === null || run.finished) continue
      emit(run.accept(message))
      if (run.finished && running === run) running = null
    }
  }

  await Promise.all([readControl(), readMessages()])
}

/**
 * Open the confined Session and hold it.
 *
 * Streaming input that never closes on its own, so the Claude Code process
 * starts and stays up: `agent.running` has to mean a process is actually there,
 * and a query that ended after one turn would make it mean "a process was there
 * once". Turns ride this session rather than opening their own — ADR-0003's last
 * consequence, which is the rule most likely to be broken by accident.
 *
 * Exiting is how the agent stops. Whatever ends this function ends the process,
 * and the Rust host reports the exit as `AGENT_EXIT` carrying the real reason.
 */
async function runAgentHost(sdkEntry: string): Promise<void> {
  const { query } = (await import(sdkEntry)) as typeof import('@anthropic-ai/claude-agent-sdk')
  type Prompt = Parameters<typeof query>[0]['prompt']
  type UserMessage = { type: 'user'; message: { role: 'user'; content: string }; parent_tool_use_id: null; session_id: string }

  /*
    Streaming input, held open, fed by the control channel.

    The queue is what makes a Turn a Turn: the generator never returns, so the
    Claude Code process stays up between Turns and `agent.running` keeps meaning
    "a process is there" rather than "a process was there once". A `prompt`
    string instead would run one Turn and exit.
  */
  const queued: UserMessage[] = []
  let wake: (() => void) | null = null

  const prompt = (async function* () {
    for (;;) {
      while (queued.length > 0) yield queued.shift() as UserMessage
      await new Promise<void>((resolve) => {
        wake = resolve
      })
    }
  })() as Prompt

  const session = query({
    prompt,
    options: {
      cwd: process.cwd(),
      // What makes an answer arrive in pieces. Without it the SDK reports one
      // assembled message when the Turn is over, and "working" would be
      // indistinguishable from "hung" for the whole of it.
      includePartialMessages: true,
      // ADR-0003: the kernel refuses sandbox_apply inside an existing sandbox,
      // so the SDK's own sandbox must stay off. srt is already around this
      // whole process tree. Set rather than omitted, because "off" belongs in
      // the code that would be blamed for exit 71.
      sandbox: { enabled: false },
    },
  })

  // Announced rather than awaited. `agent.running` is decided by the spawn
  // succeeding, not by this line: measured against a session held open with no
  // message sent, the SDK's init does not necessarily arrive, and a start that
  // waited for it would hang on a working agent.
  process.stdout.write(`${JSON.stringify({ ready: true })}\n`)

  await serveTurns({
    control: process.stdin,
    messages: session,
    write: (line) => process.stdout.write(line),
    session: {
      prompt: (text) => {
        queued.push({
          type: 'user',
          message: { role: 'user', content: text },
          parent_tool_use_id: null,
          session_id: '',
        })
        wake?.()
      },
      setModel: (model) => session.setModel(model),
      // `effortLevel` through the flag settings layer, which is the only way to
      // change effort on a session that is already running. `max` is
      // session-scoped and never persisted, which is what we want: the Session
      // is varnick's, and writing to the developer's settings files would be a
      // side effect nobody asked for.
      setEffort: (effort) =>
        session.applyFlagSettings({ effortLevel: effort as 'low' | 'medium' | 'high' | 'xhigh' | 'max' }),
      interrupt: async () => {
        await session.interrupt()
      },
    },
  })
}

// `agent.ts <sdkEntry> [--selftest <path>]`, spawned by src-tauri/src/agent.rs
// through the wrapping the runtime computed. The SDK's location is an argument
// rather than a bare import — see agentSdkEntry above for the measurement that
// forced that.
if (import.meta.main) {
  const [sdkEntry, flag, deniedPath] = process.argv.slice(2)
  if (sdkEntry === undefined) {
    process.stderr.write('The agent host was started without the Agent SDK path it needs.\n')
    process.exit(2)
  }
  if (flag === '--selftest') {
    await selfTest(sdkEntry, deniedPath ?? '')
  } else {
    await runAgentHost(sdkEntry)
  }
}
