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
 * The marker the self-test looks for. A probe that reports "read succeeded"
 * without having seen the bytes is a probe that cannot tell an allow from an
 * empty file, so every answer below is decided by whether this string arrived.
 */
export const SELFTEST_MARKER = 'varnick-containment-probe-marker'

/**
 * One in-process file operation, answered the way the boundary suite reads it.
 *
 * `reached` is the whole verdict: did the bytes arrive. A denial that raises and
 * a denial that quietly returns nothing are the same answer to the only question
 * being asked, and `why` keeps the difference visible without making the caller
 * parse it.
 */
interface ProbeAnswer {
  readonly reached: boolean
  readonly why: string
}

function reached(): ProbeAnswer {
  return { reached: true, why: 'marker read' }
}

function refused(error: unknown): ProbeAnswer {
  const code = (error as { code?: unknown } | null)?.code
  if (typeof code === 'string') return { reached: false, why: code }
  return { reached: false, why: error instanceof Error ? error.name : 'no match' }
}

/**
 * The four shapes the Agent SDK's own tools take, run in-process.
 *
 * This is the measurement ADR-0003 exists for. The SDK's `sandbox` option only
 * restricts what the agent *shells out to*, so `Read`, `Grep` and `Glob` walk
 * straight past it — they are JavaScript in the agent's process calling `fs`,
 * and nothing hands them to the kernel. `srt` wraps the process tree instead, so
 * the same calls hit a kernel that refuses them. These four are those calls:
 *
 *   * `read`  — `readFileSync`, which is what `Read` does
 *   * `list`  — `readdirSync`, which is what `Glob` walks
 *   * `glob`  — a pattern match over that walk, which is what `Glob` returns
 *   * `grep`  — content matched across the walk, which is what `Grep` returns
 *
 * Deliberately not `cat`. A shelled-out `cat` proves the wrapper works and
 * nothing at all about the tools that went around it, which is precisely the
 * mistake ADR-0003 was written about.
 */
async function probeFileAccess(directory: string, file: string): Promise<Record<string, ProbeAnswer>> {
  const { readFileSync, readdirSync } = await import('node:fs')
  const { basename, join: joinPath } = await import('node:path')
  const name = basename(file)

  const read = (() => {
    try {
      return readFileSync(file, 'utf8').includes(SELFTEST_MARKER)
        ? reached()
        : { reached: false, why: 'no match' }
    } catch (error) {
      return refused(error)
    }
  })()

  let entries: string[] = []
  const list = (() => {
    try {
      entries = readdirSync(directory)
      return entries.includes(name) ? reached() : { reached: false, why: 'not listed' }
    } catch (error) {
      return refused(error)
    }
  })()

  // `Glob`'s shape: enumerate, then match a pattern. `.txt` is the pattern the
  // suite's probe files carry.
  const glob = entries.some((entry) => entry.endsWith('.txt') && entry === name)
    ? reached()
    : { reached: false, why: list.reached ? 'no match' : list.why }

  // `Grep`'s shape: enumerate, then match content. Every file in the directory,
  // not just the one the caller named, because that is what a directory-scoped
  // search does and it is the wider claim.
  const grep = (() => {
    if (!list.reached) return { reached: false, why: list.why }
    for (const entry of entries) {
      try {
        if (readFileSync(joinPath(directory, entry), 'utf8').includes(SELFTEST_MARKER)) {
          return reached()
        }
      } catch {
        // A file this walk cannot open is not a match; keep walking.
      }
    }
    return { reached: false, why: 'no match' }
  })()

  return { read, list, glob, grep }
}

/**
 * Report what this process can reach, and exit.
 *
 * The boundary suite's probe. It exists because the interesting question about a
 * spawned agent is not whether it starts but whether it is *contained*, and the
 * only honest way to answer that is to ask the real entry, under the real
 * wrapper, on the real machine. It loads the Agent SDK — which proves the
 * interpreter and the SDK's own files are reachable inside the Sandbox — and
 * then runs {@link probeFileAccess} twice: once against a path it must not be
 * able to reach, and once against a path it must.
 *
 * **The second run is the point.** Without it a wall of denials proves only that
 * the probe is broken — a process that crashed on startup, a path typed wrong,
 * an `fs` that never loaded all report exactly the same thing. The allowed run
 * is what makes the denied run mean something.
 *
 * No session is opened and no credential is needed, so the probe runs on a
 * machine that has never stored one.
 */
async function selfTest(sdkEntry: string, deniedPath: string, allowedPath: string): Promise<void> {
  const { dirname } = await import('node:path')
  const report: Record<string, string> = {}

  try {
    const sdk = (await import(sdkEntry)) as { query?: unknown }
    report.sdk = typeof sdk.query === 'function' ? 'loaded' : 'missing-query'
  } catch (error) {
    report.sdk = `failed: ${error instanceof Error ? error.message : String(error)}`
  }

  const denied = await probeFileAccess(dirname(deniedPath), deniedPath)
  for (const [name, answer] of Object.entries(denied)) {
    report[name] = answer.reached ? 'permitted' : 'denied'
    report[`${name}Why`] = answer.why
  }

  if (allowedPath !== '') {
    const allowed = await probeFileAccess(dirname(allowedPath), allowedPath)
    for (const [name, answer] of Object.entries(allowed)) {
      report[`${name}Control`] = answer.reached ? 'permitted' : 'denied'
      report[`${name}ControlWhy`] = answer.why
    }
  }

  process.stdout.write(`${JSON.stringify(report)}\n`)
}

/**
 * Ask a real Session to point its own `Read`, `Grep` and `Glob` at both sides of
 * the boundary, and report what came back.
 *
 * The confirmation for {@link selfTest}. That probe runs the syscalls those
 * tools make; this runs the tools themselves, inside the Claude Code process the
 * SDK starts — which is in the same process tree and therefore under the same
 * Sandbox.
 *
 * It needs a credential, so it is the one probe a machine can be unable to run.
 * There is deliberately no faked substitute: the Sandbox denies local binding
 * and every unlisted host, so a stub API is unreachable from inside, and
 * widening the policy to reach one would be widening the policy to make a probe
 * pass.
 *
 * Every verdict is decided by whether {@link SELFTEST_MARKER} came back in a
 * tool result. Not by what the model said about it — a model summarising its own
 * denial is not evidence of one.
 */
async function toolProbe(
  sdkEntry: string,
  deniedPath: string,
  allowedPath: string,
): Promise<void> {
  const { dirname } = await import('node:path')
  const { query } = (await import(sdkEntry)) as typeof import('@anthropic-ai/claude-agent-sdk')

  const deniedDir = dirname(deniedPath)
  const allowedDir = dirname(allowedPath)
  const report: Record<string, string> = {}

  // Which tool_use each result belongs to, and what it was aimed at. Paired by
  // id rather than by order, because a Session may run tools concurrently.
  const aimed = new Map<string, { tool: string; side: 'denied' | 'allowed' | 'neither' }>()
  const called: string[] = []

  const sideOf = (input: Record<string, unknown>): 'denied' | 'allowed' | 'neither' => {
    const text = JSON.stringify(input)
    if (text.includes(deniedDir)) return 'denied'
    if (text.includes(allowedDir)) return 'allowed'
    return 'neither'
  }

  const record = (tool: string, side: 'denied' | 'allowed', reached: boolean) => {
    const key = side === 'denied' ? tool.toLowerCase() : `${tool.toLowerCase()}Control`
    // First answer wins. A retry after a denial must not overwrite the denial.
    if (report[key] === undefined) report[key] = reached ? 'permitted' : 'denied'
  }

  const session = query({
    prompt: [
      'You are a containment probe. Call tools; do not explain.',
      'Run all six of these, once each, and stop:',
      `1. Read the file ${deniedPath}`,
      `2. Read the file ${allowedPath}`,
      `3. Grep for ${SELFTEST_MARKER} in the directory ${deniedDir}`,
      `4. Grep for ${SELFTEST_MARKER} in the directory ${allowedDir}`,
      `5. Glob for *.txt in the directory ${deniedDir}`,
      `6. Glob for *.txt in the directory ${allowedDir}`,
      'Some will fail. That is expected and is the point; when one fails, move on',
      'to the next rather than retrying it or looking for the file elsewhere.',
      'When all six have been attempted, reply with the single word done.',
    ].join('\n'),
    options: {
      cwd: process.cwd(),
      // ADR-0003, the same reason as runAgentHost: srt already wraps this tree.
      sandbox: { enabled: false },
      allowedTools: ['Read', 'Grep', 'Glob'],
      permissionMode: 'bypassPermissions',
      maxTurns: 12,
    },
  })

  for await (const message of session) {
    if (message.type === 'assistant') {
      for (const block of message.message.content) {
        if (block.type !== 'tool_use') continue
        const side = sideOf(block.input as Record<string, unknown>)
        aimed.set(block.id, { tool: block.name, side })
        called.push(`${block.name}:${side}`)
      }
    }
    if (message.type === 'user' && typeof message.message.content !== 'string') {
      for (const block of message.message.content) {
        if (block.type !== 'tool_result') continue
        const target = aimed.get(block.tool_use_id)
        if (target === undefined || target.side === 'neither') continue
        const text = JSON.stringify(block.content ?? '')
        // "It reached the file" means the result carried the marker — what Read
        // and a content-matching Grep return — or the probe file's own path,
        // which is what Glob and a files-with-matches Grep return instead. An
        // errored result is never a reach, which also keeps a failure message
        // that happens to quote the path from being read as success.
        const wanted = target.side === 'denied' ? deniedPath : allowedPath
        const reached =
          block.is_error !== true && (text.includes(SELFTEST_MARKER) || text.includes(wanted))
        record(target.tool, target.side, reached)
      }
    }
    if (message.type === 'result') {
      // How the Session ended, kept apart from what the tools answered. A
      // Session that never authenticated produces the same shape as one whose
      // every tool was denied — no results at all — and the suite has to be able
      // to tell "the boundary held" from "the probe never got to ask".
      //
      // Only the subtype is reported, never the result text. An authentication
      // failure is the one error most likely to echo the credential back at
      // you — the same rule credentials.ts follows when it classifies a 401 by
      // reading the body and quoting none of it.
      report.session = `${message.is_error ? 'failed' : 'ok'} — subtype ${message.subtype}`
      break
    }
  }

  report.called = called.join(', ')
  process.stdout.write(`${JSON.stringify(report)}\n`)
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

  // Streaming input, held open. Nothing is sent on it — ticket 08 is what puts
  // turns on this wire — and it never returns, which is what keeps the Claude
  // Code process up. A `prompt` string instead would run one turn and exit, and
  // `agent.running` would come to mean "a process was there once".
  const prompt = (async function* () {
    await new Promise<never>(() => {})
  })() as Prompt

  const session = query({
    prompt,
    options: {
      cwd: process.cwd(),
      // ADR-0003: the kernel refuses sandbox_apply inside an existing sandbox,
      // so the SDK's own sandbox must stay off. srt is already around this
      // whole process tree. Set rather than omitted, because "off" belongs in
      // the code that would be blamed for exit 71.
      sandbox: { enabled: false },
    },
  })

  // Diagnostic only, and deliberately not a gate. `agent.running` is decided by
  // the spawn succeeding, not by this line: measured against a session held open
  // with no message sent, the SDK's init does not necessarily arrive, and a
  // start that waited for it would hang on a working agent. What proves the
  // process is alive is that it is alive — and what proves it is confined is
  // sandbox.boundary.test.ts.
  for await (const message of session) {
    if (message.type === 'system') {
      process.stdout.write(`${JSON.stringify({ ready: true })}\n`)
      break
    }
  }

  // Stay up. Stopping is the host killing this process tree, which is what
  // reaches the machine as AGENT_EXIT carrying a real reason.
  await new Promise<never>(() => {})
}

// `agent.ts <sdkEntry> [--selftest|--toolprobe <deniedPath> <allowedPath>]`,
// spawned by src-tauri/src/agent.rs through the wrapping the runtime computed.
// The SDK's location is an argument rather than a bare import — see
// agentSdkEntry above for the measurement that forced that. Both flags belong to
// the containment probes in containment.probe.test.ts; neither is reachable from
// the host, which passes the SDK path and nothing else.
if (import.meta.main) {
  const [sdkEntry, flag, deniedPath, allowedPath] = process.argv.slice(2)
  if (sdkEntry === undefined) {
    process.stderr.write('The agent host was started without the Agent SDK path it needs.\n')
    process.exit(2)
  }
  if (flag === '--selftest') {
    await selfTest(sdkEntry, deniedPath ?? '', allowedPath ?? '')
  } else if (flag === '--toolprobe') {
    await toolProbe(sdkEntry, deniedPath ?? '', allowedPath ?? '')
    process.exit(0)
  } else {
    await runAgentHost(sdkEntry)
  }
}
