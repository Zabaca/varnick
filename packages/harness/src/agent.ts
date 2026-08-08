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
 *
 * ## The session is isolated from the developer's own Claude Code
 *
 * A Claude Code process reads settings, `CLAUDE.md`, MCP servers, plugins and
 * hooks off the filesystem, and reads a good deal more out of its environment.
 * Left alone it would pick up whichever of those the person launching varnick
 * happens to have — including things they set months ago and have forgotten.
 * That is unreproducible for everyone else, so varnick isolates by default and
 * takes a flag to inherit. See ADR-0010, and `agentEnvironment` below.
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
// Configuration isolation
// ---------------------------------------------------------------------------

/**
 * The flag that turns isolation off.
 *
 * An environment variable rather than a UI control or a config file, for the
 * same reason `VARNICK_HOST` and `VARNICK_HARNESS_ENTRY` are: it is a property
 * of one launch, it has to be readable before anything is rendered, and a
 * setting stored in the clone would be a setting the agent can write.
 *
 *     VARNICK_INHERIT_CLAUDE_CONFIG=1 bun tauri dev
 */
export const INHERIT_CLAUDE_CONFIG_ENV_VAR = 'VARNICK_INHERIT_CLAUDE_CONFIG'

/** Where Claude Code keeps its own state. */
export const CLAUDE_CONFIG_DIR_ENV_VAR = 'CLAUDE_CONFIG_DIR'

/**
 * varnick's Claude Code configuration directory, relative to the clone.
 *
 * Inside the clone because the Sandbox leaves nowhere else durable: measured
 * under the generated policy, `mkdir` anywhere below `$HOME` is "Operation not
 * permitted", and `allowWrite` is the clone and the temp directory. A Claude
 * Code process left pointing at `~/.claude` cannot write its session store, so
 * redirecting this is a condition of the agent running at all — not only of it
 * running isolated.
 *
 * Gitignored, per clone, and never committed: it is one machine's state.
 */
export const CLAUDE_CONFIG_RELATIVE_PATH = '.varnick/claude'

/** varnick's Claude Code configuration directory in a given clone. */
export function claudeConfigDir(cloneRoot: string): string {
  return join(cloneRoot, CLAUDE_CONFIG_RELATIVE_PATH)
}

/**
 * Variables that belong to Claude Code or to the Anthropic client, and are
 * therefore the developer's rather than varnick's.
 *
 * A prefix rule rather than a list. The list would be right today and stale on
 * the next release, and the failure mode of a stale list is silent: a variable
 * nobody added to it changes the agent's behaviour and nothing says so.
 *
 * The credential is the one exception, and it is named rather than pattern
 * matched — see {@link agentEnvironment}.
 */
const INHERITED_CONFIG_PREFIXES = ['CLAUDE', 'ANTHROPIC_'] as const

/** Whether this launch was told to inherit the developer's configuration. */
export function inheritsClaudeConfig(env: Record<string, string | undefined>): boolean {
  const value = env[INHERIT_CLAUDE_CONFIG_ENV_VAR]
  if (value === undefined) return false
  const normalised = value.trim().toLowerCase()
  // An empty, `0` or `false` value is not a flag anyone meant to set. A
  // variable left behind in a shell profile must not quietly un-isolate a run.
  return normalised !== '' && normalised !== '0' && normalised !== 'false'
}

export interface AgentEnvironmentInput {
  /** The clone the agent works inside. */
  readonly cloneRoot: string
  /** True when {@link INHERIT_CLAUDE_CONFIG_ENV_VAR} was set. */
  readonly inherit: boolean
}

/**
 * The environment the Claude Code process runs with.
 *
 * Pure, and computed rather than inherited, because the SDK's `env` option
 * *replaces* the subprocess environment — so what this returns is the whole of
 * what Claude Code sees.
 *
 * Isolated (the default): every `CLAUDE*` and `ANTHROPIC_*` variable is
 * dropped, except the credential the host injected. This is not hypothetical
 * tidying. Probed under the real policy, the sandboxed process was handed nine
 * inherited `CLAUDE*` variables — `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`,
 * `CLAUDE_EFFORT` and the rest — none of them chosen by varnick, all of them
 * an accident of which terminal the app was launched from.
 *
 * Inherited (under the flag): everything is left as the developer had it.
 *
 * `CLAUDE_CONFIG_DIR` is set to the clone's own directory in both cases, for
 * the containment reason recorded on {@link CLAUDE_CONFIG_RELATIVE_PATH}: the
 * default is unwritable inside the Sandbox.
 *
 * The flag itself never reaches the agent. It is varnick's switch, and an agent
 * that can read it is an agent whose behaviour depends on it.
 */
export function agentEnvironment(
  base: Record<string, string | undefined>,
  input: AgentEnvironmentInput,
): Record<string, string | undefined> {
  const environment: Record<string, string | undefined> = {}

  for (const [key, value] of Object.entries(base)) {
    if (key === INHERIT_CLAUDE_CONFIG_ENV_VAR) continue
    if (key === CREDENTIAL_ENV_VAR_NAME) {
      environment[key] = value
      continue
    }
    if (!input.inherit && INHERITED_CONFIG_PREFIXES.some((prefix) => key.startsWith(prefix))) {
      continue
    }
    environment[key] = value
  }

  environment[CLAUDE_CONFIG_DIR_ENV_VAR] = claudeConfigDir(input.cloneRoot)
  return environment
}

/**
 * The Agent SDK options that decide where configuration comes from.
 *
 * `settingSources: []` is the SDK's own isolation mode: no
 * `~/.claude/settings.json`, no `.claude/settings.json`, no
 * `.claude/settings.local.json`, and — because `CLAUDE.md` loads with the
 * project source — no memory files either. Hooks live in those settings, so
 * they go with them. `strictMcpConfig` drops `.mcp.json`, MCP servers declared
 * in user settings, and MCP servers contributed by plugins.
 *
 * Inheriting is the *absence* of both, rather than an option asking for the
 * opposite: what the flag restores is the CLI's own default, and stating it any
 * other way would be varnick deciding what "inherit" means on Claude Code's
 * behalf.
 *
 * Worth being plain about what the flag cannot restore. The Sandbox denies read
 * on `$HOME`, so `~/.claude` — user settings, user `CLAUDE.md`, skills,
 * plugins, and any stdio MCP server installed under the home directory — is
 * unreachable with or without it. The flag restores the clone's own
 * configuration and the developer's environment, and nothing under `$HOME`.
 * Widening the policy to reach it is not on the table: `~/.claude.json` holds
 * MCP server credentials, and a read-allow over the home directory is the exact
 * mistake ADR-0003 records twice.
 */
export function agentConfigurationOptions(inherit: boolean): {
  settingSources?: never[]
  strictMcpConfig?: true
} {
  return inherit ? {} : { settingSources: [], strictMcpConfig: true }
}

/**
 * Variables in Claude Code's namespace that varnick did not put there.
 *
 * Two are varnick's own and are therefore not "inherited" whatever their names
 * look like: the credential, which the host read and injected and which
 * isolation must never take away, and the config directory, which varnick sets
 * because the Sandbox leaves nowhere else writable. Everything else matching
 * the prefixes came from whoever launched the app.
 *
 * Exported so the boundary probe counts the same set the scrub uses, rather
 * than a second definition that could drift from it.
 */
const VARNICK_OWNED_VARIABLES = [CREDENTIAL_ENV_VAR_NAME, CLAUDE_CONFIG_DIR_ENV_VAR] as const

export function inheritedConfigVariables(
  env: Record<string, string | undefined>,
): readonly string[] {
  return Object.keys(env).filter(
    (key) =>
      !(VARNICK_OWNED_VARIABLES as readonly string[]).includes(key) &&
      INHERITED_CONFIG_PREFIXES.some((prefix) => key.startsWith(prefix)),
  )
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
 * It also reports what isolation does to this process's own environment. That
 * is here rather than only in a unit test because the number that started this
 * work was measured, not imagined: nine `CLAUDE*` variables reached the
 * confined process from whichever terminal launched varnick. `inherited` is
 * whatever this run happened to be handed — it varies with how varnick was
 * started, so nothing asserts a figure — and `isolated` is what survives the
 * scrub, which must be none.
 *
 * No session is opened and no credential is needed, so the probe runs on a
 * machine that has never stored one. Nothing here reads a settings file: the
 * environment is computed, and no Claude Code process is started.
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

  const isolated = agentEnvironment(process.env, {
    cloneRoot: process.cwd(),
    inherit: false,
  })
  report.inherited = String(inheritedConfigVariables(process.env).length)
  report.isolated = String(inheritedConfigVariables(isolated).length)
  report.configDir = isolated[CLAUDE_CONFIG_DIR_ENV_VAR] ?? ''

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
 *
 * This is the one place a Claude Code process is started, and it is inside the
 * Sandbox. The configuration this hands it is computed here, from strings —
 * nothing in the Harness opens a settings file, so a `SessionStart` hook the
 * agent wrote runs in the confined process or not at all. ADR-0003's last
 * consequence is the rule that makes that matter.
 */
async function runAgentHost(sdkEntry: string): Promise<void> {
  const { query } = (await import(sdkEntry)) as typeof import('@anthropic-ai/claude-agent-sdk')
  type Prompt = Parameters<typeof query>[0]['prompt']

  const cloneRoot = process.cwd()
  const inherit = inheritsClaudeConfig(process.env)

  // Created rather than assumed. Claude Code writes its own state here, and a
  // directory it cannot create is a start that fails with an error about
  // something else. Inside the clone, which is writable — see
  // CLAUDE_CONFIG_RELATIVE_PATH for why nowhere under $HOME is.
  const { mkdirSync } = await import('node:fs')
  mkdirSync(claudeConfigDir(cloneRoot), { recursive: true })

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
      cwd: cloneRoot,
      // ADR-0003: the kernel refuses sandbox_apply inside an existing sandbox,
      // so the SDK's own sandbox must stay off. srt is already around this
      // whole process tree. Set rather than omitted, because "off" belongs in
      // the code that would be blamed for exit 71.
      sandbox: { enabled: false },
      // ADR-0010. Isolated by default; `VARNICK_INHERIT_CLAUDE_CONFIG=1` is the
      // flag out. `env` replaces the subprocess environment outright, which is
      // why agentEnvironment returns the whole of it rather than an overlay.
      env: agentEnvironment(process.env, { cloneRoot, inherit }),
      ...agentConfigurationOptions(inherit),
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
