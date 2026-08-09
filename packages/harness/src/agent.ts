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
 *
 * ## What this process is told, as opposed to asked
 *
 * Every control request but one asks the confined process to do something. The
 * exception is `describe-secrets`, which tells it which secrets exist — a fact
 * it cannot look up, because the Secrets Store is a keychain under `$HOME` and
 * this process is on the wrong side of `denyRead`. It arrives as names, is held
 * in {@link runAgentHost}, and becomes a `UserPromptSubmit` hook's
 * `additionalContext` once per Turn. Nothing in this file reads a secret value
 * and there is no member on the store it could read one from; ADR-0006 and
 * `DescribeSecretsRequest` in ./turn.ts have the rest.
 */

import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { CREDENTIAL_ENV_VARS, credentialRejection } from './credentials.ts'
import { readLines } from './framing.ts'
import { describeSecretsForAgent } from './secrets.ts'
import {
  beginCompaction,
  beginTurn,
  COMPACT_COMMAND,
  encodeTurnEvent,
  parseControlRequest,
  runtimeReportFrom,
  type CompactionRun,
  type CompactionSettlement,
  type TurnEvent,
  type RuntimeReport,
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
 * The two variables a credential can arrive in — an API key, then a
 * subscription token.
 *
 * Two rather than one because a Credential has a Kind (ADR-0011), and the kind
 * decides which of these the host injects. Exactly one of them is ever set on a
 * spawned agent: the host injects the one that matches what it resolved and
 * removes the other, so an `ANTHROPIC_API_KEY` the developer happened to export
 * cannot sit beside an injected subscription token.
 *
 * The same two names as `CREDENTIAL_ENV_VARS` in ./credentials.ts, taken from it
 * rather than written out again: the pair by Kind is what a store and a spawn
 * need, and this is that pair with the Kinds dropped. Everything here asks "is
 * this one of the credential variables" and has no Kind to ask it about —
 * {@link sandboxEnvOverlay} refuses to carry either of them, and
 * {@link agentEnvironment} holds either of them back from the scrub. Mirrored a
 * third time, in another language, as
 * `API_KEY_ENV_VAR` and `SUBSCRIPTION_ENV_VAR` in src-tauri/src/credential.rs,
 * where it is a literal because Rust cannot read this one.
 */
export const CREDENTIAL_ENV_VAR_NAMES = [
  CREDENTIAL_ENV_VARS['api-key'],
  CREDENTIAL_ENV_VARS.subscription,
] as const

/** Is this variable one varnick injects a credential into? */
function isCredentialVariable(key: string): boolean {
  return (CREDENTIAL_ENV_VAR_NAMES as readonly string[]).includes(key)
}

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

/**
 * Where the developer toolchain's own binaries live, newest choice first.
 *
 * `/usr/bin/git` on macOS is a shim: it hands over to whichever developer
 * directory `xcode-select` has active, and the real `git` — along with `clang`,
 * `make` and the rest — lives under one of these two. Which one depends on
 * whether Xcode is installed, and they are not in the same tree, so a policy
 * that named a path here would be right on one machine and wrong on the next.
 *
 * The Command Line Tools directory is first because that is what a plain
 * `xcode-select --install` selects, and because it is the narrower of the two.
 *
 * Measured under a policy that denies reads by default, which is what this is
 * for. The shim reads the symlink `/var/select/developer_dir` to find the real
 * binary, and that link is in the denied root:
 *
 * ```
 * /usr/bin/git --version              exit 1  xcode-select: unable to read data link
 * <toolchain>/usr/bin/git --version   exit 0  git version 2.50.1 (Apple Git-155)
 * git --version, toolchain on PATH    exit 0  git version 2.50.1 (Apple Git-155)
 * ```
 *
 * The denial is of *traversing* the link, so allowing its target does not fix
 * it — `/private/var`, `/private/var/select` and the toolchain directory were
 * each tried and each failed identically.
 */
export const DEVELOPER_TOOLS_CANDIDATES = [
  '/Library/Developer/CommandLineTools/usr/bin',
  '/Applications/Xcode.app/Contents/Developer/usr/bin',
] as const

/**
 * The active developer toolchain's `bin`, or null when this machine has none.
 *
 * Probed rather than resolved by running `xcode-select -p`. This is called from
 * the Sandbox policy generator, and a generator that spawns a process to decide
 * what a policy says is a generator that cannot be run twice cheaply, cannot be
 * tested without the toolchain installed, and fails in a new way when the spawn
 * does. The answer is a directory either way.
 *
 * Null is not an error. It is a machine where the agent cannot run `git`, which
 * is a problem the agent reports the first time it tries — unlike a policy that
 * silently omits the path, which is `exit 133`.
 *
 * `exists` is injected so the tests can ask about a machine that is not this
 * one; nothing else passes it.
 */
export function developerToolsBin(exists: (path: string) => boolean = existsSync): string | null {
  // For `git` inside the candidate, not for the candidate. A toolchain
  // directory that exists without git in it shadows nothing while claiming to
  // fix this, and the whole point of putting it on PATH is to get past
  // /usr/bin/git.
  return DEVELOPER_TOOLS_CANDIDATES.find((bin) => exists(join(bin, 'git'))) ?? null
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
    if (isCredentialVariable(key)) continue
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
 * Which conversation the agent was in last, so the next one can continue it.
 *
 * **The gap this closes.** A Session is persisted twice, and until now only one
 * of the two was ever read back. The mirror gives varnick the transcript to
 * *display* ([ADR-0009](../../../docs/adr/0009-resume-reads-the-mirror.md)); the
 * Agent SDK's own store is what the agent *remembers* — and nothing passed
 * `resume`, so every launch opened a new conversation. The window showed the
 * whole history and the agent behind it had never seen a word of it. That ADR
 * says "the SDK's copy is what the agent resumes from" as though it were true;
 * it was the intention, and this is the code.
 *
 * A file beside the SDK's own store rather than a field on the mirror, and the
 * reason is which process can reach what: the id arrives inside the Sandbox, on
 * the message stream, and the agent host is the only process that sees it. The
 * mirror belongs to the runtime, three processes away. Routing a pointer out
 * through the bridge and back down again would be four hops to write a UUID
 * next to the store it already points into.
 *
 * Sitting in the clone makes it agent-writable, which is worth stating rather
 * than discovering. It changes nothing: `CLAUDE_CONFIG_DIR` is *already* in the
 * clone, so the agent can already rewrite the transcript this points at. A
 * pointer beside a store you can edit is not a new capability.
 */
export function lastSessionPath(cloneRoot: string): string {
  return join(claudeConfigDir(cloneRoot), 'last-session.json')
}

/** Where the CLI keeps conversations, whatever it calls this clone's folder. */
function sdkProjectsDir(cloneRoot: string): string {
  return join(claudeConfigDir(cloneRoot), 'projects')
}

/**
 * Remember the conversation the agent is in.
 *
 * Written on every `init`, which is once per Session, and written whole rather
 * than appended so there is only ever one answer in the file. A failure is
 * swallowed: not being able to record the pointer costs the *next* launch its
 * memory, and failing the launch that is working to protect the one that is not
 * would be the worse trade.
 */
export function rememberSession(
  cloneRoot: string,
  sessionId: string,
  write: (path: string, contents: string) => void = (path, contents) =>
    writeFileSync(path, contents),
): void {
  if (sessionId.length === 0) return
  try {
    write(lastSessionPath(cloneRoot), `${JSON.stringify({ sessionId })}\n`)
  } catch {
    // Nothing to do and nowhere to say it. See above.
  }
}

/**
 * The conversation to resume, if there is one that still exists.
 *
 * Two conditions, and the second is what keeps a bad launch off the table.
 * `resume` against an id the CLI has never heard of fails the *whole session* —
 * so a pointer left behind by a clone whose store was cleared would turn "the
 * agent forgets" into "the agent will not start", which is a worse product than
 * the one being fixed.
 *
 * The transcript is looked for as `projects/<any>/<id>.jsonl` rather than at a
 * computed path. The CLI derives that folder name from the working directory by
 * a rule it owns and does not document, and a mangling this file guessed at
 * would silently stop matching the day the rule changed — reporting "nothing to
 * resume" for a store that is right there. Scanning one shallow directory is
 * cheap and depends only on the id.
 */
export function resumableSession(
  cloneRoot: string,
  fs: {
    readFile: (path: string) => string
    readDir: (path: string) => readonly string[]
    exists: (path: string) => boolean
  } = {
    readFile: (path) => readFileSync(path, 'utf8'),
    readDir: (path) => readdirSync(path),
    exists: (path) => existsSync(path),
  },
): string | null {
  let sessionId: unknown
  try {
    sessionId = (JSON.parse(fs.readFile(lastSessionPath(cloneRoot))) as { sessionId?: unknown })
      .sessionId
  } catch {
    // No file, or a file this build does not understand. Either way there is
    // nothing to resume, which is a first run rather than a failure.
    return null
  }
  if (typeof sessionId !== 'string' || sessionId.length === 0) return null

  const projects = sdkProjectsDir(cloneRoot)
  let folders: readonly string[]
  try {
    folders = fs.readDir(projects)
  } catch {
    return null
  }
  const found = folders.some((folder) => fs.exists(join(projects, folder, `${sessionId}.jsonl`)))
  return found ? sessionId : null
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
  /**
   * The real developer toolchain's `bin`, prepended to `PATH`. Null when there
   * is none — see {@link developerToolsBin}.
   */
  readonly toolsBin?: string | null
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
    if (isCredentialVariable(key)) {
      environment[key] = value
      continue
    }
    if (!input.inherit && INHERITED_CONFIG_PREFIXES.some((prefix) => key.startsWith(prefix))) {
      continue
    }
    environment[key] = value
  }

  environment[CLAUDE_CONFIG_DIR_ENV_VAR] = claudeConfigDir(input.cloneRoot)

  // The real toolchain ahead of the shim, so `git` is git. See
  // {@link developerToolsBin} for what the shim does and why allowing its
  // target is not the fix. Prepended rather than appended: /usr/bin is already
  // on PATH and would otherwise win.
  if (input.toolsBin) {
    const path = environment.PATH
    environment.PATH = path ? `${input.toolsBin}:${path}` : input.toolsBin
  }

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
 * The variables in those namespaces that are varnick's own.
 *
 * Three of them, and they are therefore not "inherited" whatever their names
 * look like: either variable a credential can arrive in — the host read one and
 * injected it, and isolation must never take it away — and the config
 * directory, which varnick sets because the Sandbox leaves nowhere else
 * writable. All three match {@link INHERITED_CONFIG_PREFIXES} and none of them
 * came from whoever launched the app, so the count below takes them off the
 * list.
 *
 * `CLAUDE_CODE_OAUTH_TOKEN` is the one that has to be *named*: it matches the
 * `CLAUDE` prefix the scrub drops by, so a subscription credential left to the
 * rule would be removed from the environment of the very process it
 * authenticates. There is no error on that path — the agent starts, and every
 * Turn fails as though the token were wrong. {@link agentEnvironment} makes the
 * same exception by a different route, keeping the credential variable by name
 * and rewriting the config directory outright.
 */
const VARNICK_OWNED_VARIABLES = [
  ...CREDENTIAL_ENV_VAR_NAMES,
  CLAUDE_CONFIG_DIR_ENV_VAR,
] as const

/**
 * Variables in Claude Code's namespace that varnick did not put there.
 *
 * Counts by {@link INHERITED_CONFIG_PREFIXES}, the same list the scrub in
 * {@link agentEnvironment} drops by, so what is counted here and what is
 * dropped there cannot drift into two different answers.
 *
 * Called twice by {@link selfTest}, over the environment as it arrived and over
 * the environment the scrub produced. That is what makes sandbox.boundary.test's
 * `isolated` figure a measurement taken inside the confined process rather than
 * a claim made outside it. Exported so agent.test.ts can pin it directly.
 */
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

  const isolated = agentEnvironment(process.env, {
    cloneRoot: process.cwd(),
    inherit: false,
  })
  report.inherited = String(inheritedConfigVariables(process.env).length)
  report.isolated = String(inheritedConfigVariables(isolated).length)
  report.configDir = isolated[CLAUDE_CONFIG_DIR_ENV_VAR] ?? ''

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
        /*
          "It reached the file" means the result carried the marker — what Read
          and a content-matching Grep return — or the probe file's own path,
          which is what Glob and a files-with-matches Grep return instead. An
          errored result is never a reach, which also keeps a failure message
          that happens to quote the path from being read as success.

          **The path is matched in both forms, and that is not defensive
          coding.** Comparing only the absolute path made this probe report
          `Grep` and `Glob` as denied inside the clone, where they work: those
          two answer with paths *relative to the working directory*, so the
          result read `.varnick-probe-inside-1234/probe.txt` while the probe
          looked for `/Users/…/varnick/.varnick-probe-inside-1234/probe.txt`.
          Read was unaffected because it answers with contents, and the marker
          matched.

          That cost a day. It was read as the tools being broken, diagnosed as
          `rg` being unreachable under the policy, and written up as a defect
          against the product — when the product was right and the assertion was
          wrong. A control that fails for the wrong reason is worse than no
          control, which this suite's own header says, and this is the second
          instance of it in this file.
        */
        const wanted = target.side === 'denied' ? deniedPath : allowedPath
        const wantedRelative = relative(process.cwd(), wanted)
        const reached =
          block.is_error !== true &&
          (text.includes(SELFTEST_MARKER) ||
            text.includes(wanted) ||
            (wantedRelative !== '' && !wantedRelative.startsWith('..') && text.includes(wantedRelative)))
        record(target.tool, target.side, reached)
        // Why it did not, when it did not. Without this the probe can say a tool
        // failed and never say what it answered, which is exactly how a working
        // tool was mistaken for a broken one.
        if (!reached) {
          const key = `${target.tool.toLowerCase()}${target.side === 'denied' ? '' : 'Control'}Answered`
          if (report[key] === undefined) report[key] = text.slice(0, 200)
        }
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

// ---------------------------------------------------------------------------
// Turns, on the Session that is already open
// ---------------------------------------------------------------------------

/**
 * What the control channel needs from the Session, and nothing else.
 *
 * A port rather than the SDK's `Query`, so the loop below can be driven by a
 * test with no Claude Code process anywhere. That is not a testing convenience:
 * a test that opened a session to exercise a Turn would be a session outside
 * `srt` on a developer's machine, which is exactly what ADR-0003's last
 * consequence forbids.
 *
 * Five members, and each one was a decision. Four are what a Turn cannot be run
 * without, and {@link contextTokens} is what a Compaction needs. This is the
 * surface something outside the Sandbox can reach into the Sandbox with, so it
 * grows one member at a time and each one has to be argued for — and, read the
 * other way, it is the whole list of questions that do not need a second
 * session to answer. Nothing here can create one: there is no `query` in this
 * interface and no way to get at the one `runAgentHost` holds.
 *
 * It was six. A `usage` member handed over the SDK's `get_usage` reader for the
 * plan-usage read, and went with it in ticket 31 — the read had no figure to
 * return under any credential varnick can hold. Shrinking this interface is the
 * one direction it is always safe to move in.
 *
 * {@link contextTokens} is the one added for Compaction. It reads and cannot
 * write, takes no argument, and answers with a number — and the alternative to
 * having it is a context meter showing a figure nobody measured, which is the
 * thing story 69 exists to prevent.
 */
export interface AgentSessionPort {
  /** Put a prompt on the Session's streaming input. */
  prompt(text: string): void
  /** What the *next* answer runs on. Applied before the prompt goes out. */
  setModel(model: string): Promise<void>
  setEffort(effort: string): Promise<void>
  /** Stop the answer in flight. What has arrived stays arrived. */
  interrupt(): Promise<void>
  /**
   * How much context the Session now holds, or `null` if it would not say.
   *
   * The same measurement `/context` shows, asked of the Session rather than
   * derived from a message — which is what makes the meter after a Compaction a
   * reading rather than an estimate.
   */
  contextTokens(): Promise<number | null>
}

export interface ServeTurnsInput {
  /** Control requests, as newline-delimited JSON. The process's stdin. */
  readonly control: AsyncIterable<Uint8Array | string>
  /** The Session's messages. One stream for the life of the process. */
  readonly messages: AsyncIterable<unknown>
  readonly session: AgentSessionPort
  /** One event, already newline-terminated. The process's stdout. */
  readonly write: (line: string) => void
  /**
   * Where a compaction summary comes in, for whoever has one to give.
   *
   * The Agent SDK reports the summary through its `PostCompact` hook rather
   * than on the message stream, so it cannot ride `messages` and this loop
   * cannot go and fetch it. The caller is handed a reporter to call — see
   * `runAgentHost`, which registers an in-process hook callback and forwards it.
   *
   * Optional because the loop is complete without it: a Compaction with no
   * summary fails, which is the outcome that costs a context window rather than
   * a conversation.
   */
  readonly compactionSummaries?: (report: (summary: string) => void) => void
  /**
   * Where the names of the stored secrets come in.
   *
   * Called once per `describe-secrets` request with the whole list, replacing
   * whatever was known before rather than adding to it — a removed secret has
   * to stop being named, or the agent writes code against a key the host can no
   * longer resolve.
   *
   * Optional because the loop is complete without it: an agent that is never
   * told anything is told nothing, which is where varnick was before this
   * existed. What it must never be is told a value — see
   * {@link DescribeSecretsRequest}, whose parse is what makes that structural.
   */
  readonly secretsDescribed?: (names: readonly string[]) => void
  /**
   * Whether this Session was opened by resuming the last one.
   *
   * Reported rather than inferred: the init message describes the session the
   * CLI ended up in and says nothing about how it got there, so this is the
   * only place the answer exists. It rides the runtime report to the window,
   * where a restored transcript over a fresh agent has to be able to say so.
   */
  readonly resumed?: boolean
  /**
   * The Session the runtime says it is in, as soon as it says it.
   *
   * Handed over so the host can write it down for the next launch. Called on
   * every `init` — once per Session — and before the first Turn is answered,
   * which is what makes the pointer survive a crash mid-answer.
   */
  readonly sessionStarted?: (sessionId: string) => void
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
  /** The Compaction currently running. Never both at once — see `start`. */
  let compacting: CompactionRun | null = null

  /**
   * What the runtime said it was, the last time it said anything.
   *
   * **Kept rather than forwarded, because the timing is against us.** The
   * Session's `init` message is emitted when the Claude Code process starts,
   * which is when the agent is *spawned* — before any Turn exists to stamp it
   * with, and once per Session rather than once per Turn. Forwarded straight
   * through it would be dropped by the rule two paragraphs of this function's
   * own doc comment describe, and the panel would stay empty for ever.
   *
   * So it is held here and replayed at the start of each Turn. Replay is not a
   * cache of a stale fact: nothing about the runtime changes between Turns
   * without a new `init`, and if one arrives it overwrites this.
   */
  let runtime: RuntimeReport | null = null

  const emit = (events: readonly TurnEvent[]) => {
    for (const event of events) write(encodeTurnEvent(event))
  }

  /**
   * Turn a settled Compaction into the one event it is worth.
   *
   * The only asynchronous step in either loop, and it is here rather than
   * inside {@link beginCompaction} because it is a *question for the Session*:
   * a boundary that did not report its size is measured by asking, and a
   * measurement nobody could take fails the Compaction rather than reporting a
   * figure that was assumed. `turn.compacting` returns to `idle` either way, so
   * the cost of failing is a full context window; the cost of guessing is a
   * meter that disagrees with the screen.
   */
  async function concluded(
    turnId: string,
    settlement: CompactionSettlement,
  ): Promise<readonly TurnEvent[]> {
    if (settlement.kind === 'failed') {
      return [{ kind: 'failed', turnId, failure: settlement.failure }]
    }
    const measured =
      settlement.postTokens ?? (await session.contextTokens().catch(() => null))
    if (measured === null || !Number.isFinite(measured)) {
      return [{ kind: 'failed', turnId, failure: 'compaction-unmeasured' }]
    }
    return [{ kind: 'compacted', turnId, summary: settlement.summary, tokensUsed: measured }]
  }

  /**
   * Report a Compaction once, whichever half completed it.
   *
   * `compacting` is cleared before the await rather than after, so a summary
   * arriving while the size is being measured cannot settle the same Compaction
   * a second time.
   */
  async function settle(run: CompactionRun): Promise<void> {
    const settlement = run.settled
    if (settlement === null || compacting !== run) return
    compacting = null
    emit(await concluded(run.turnId, settlement))
  }

  // The summary arrives out of band, from the SDK's `PostCompact` hook. A
  // report with no Compaction running is dropped: the same hook fires for an
  // auto-compaction, and a conversation nobody asked to compact must not be
  // rewritten because the window filled up.
  input.compactionSummaries?.((summary) => {
    const run = compacting
    if (run === null) return
    run.summarised(summary)
    void settle(run)
  })

  /**
   * Ask the Session to summarise itself.
   *
   * One prompt, onto the streaming input that is already open — the same pipe a
   * Turn uses, which is the whole of why this is a control request rather than
   * a `query()` on the host (ADR-0003's last consequence). The command is a
   * constant this module owns; nothing the caller sent becomes part of it.
   */
  async function compact(request: { turnId: string }): Promise<void> {
    const run = beginCompaction(request.turnId)
    compacting = run
    // A Turn cannot be running — the machine only sends COMPACT from a settled
    // turn — but if one somehow were, its messages belong to it and not here.
    running = null
    try {
      session.prompt(COMPACT_COMMAND)
    } catch (error) {
      // Same reason as a Turn: a compaction that was asked for and never
      // answered leaves `turn.compacting` for ever, with nothing to dismiss.
      if (compacting === run) compacting = null
      emit([{ kind: 'failed', turnId: request.turnId, failure: failureOfThrown(error) }])
    }
  }

  async function start(request: {
    turnId: string
    prompt: string
    model: string
    effort: string
  }): Promise<void> {
    const run = beginTurn(request.turnId)
    running = run
    // Symmetric with `compact`: one thing at a time on one Session, so a Turn
    // that somehow arrived during a Compaction takes the stream rather than
    // leaving both waiting on messages the other is reading.
    compacting = null
    // Before the prompt rather than after the answer: what the runtime is
    // is worth knowing while the Turn runs, and a report that waited for the
    // answer would arrive at the moment it stopped being interesting.
    if (runtime !== null) emit([{ kind: 'runtime', turnId: request.turnId, report: runtime }])
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
    const request = parseControlRequest(line)
    // A line this host does not understand is dropped rather than guessed at.
    // It runs inside the Sandbox holding a live agent, so a loosely-read control
    // channel is a way in rather than a robustness feature.
    if (request === null) return
    if (request.kind === 'run-turn') return start(request)
    if (request.kind === 'compact') return compact(request)
    if (request.kind === 'describe-secrets') {
      // Handed straight over and never kept here. This loop has no use for the
      // names: it does not compose the brief, does not put one on the Session,
      // and answers nothing — the request is the host telling the confined
      // process a fact, not asking it for one, and it is the only kind on this
      // channel that is.
      input.secretsDescribed?.(request.names)
      return
    }
    /*
      A stale interrupt from an abandoned Turn must not stop the one that
      replaced it, so it has to name the Turn it means.

      A Compaction is answerable on the same terms. Nothing sends one today —
      `turn.compacting` has no INTERRUPT, because half a summary is worth
      nothing and there would be no partial to keep — but a channel where every
      request names a Turn and one kind of Turn silently ignores it is an
      asymmetry the next person has to discover.
    */
    const named =
      (running !== null && !running.finished && running.turnId === request.turnId) ||
      (compacting !== null && compacting.turnId === request.turnId)
    if (named) await session.interrupt()
  }

  // The same framing the runtime's pipe uses, and the same reader — see
  // ./framing.ts for why it is one function rather than two identical ones.
  function readControl(): Promise<void> {
    return readLines(control, handle)
  }

  async function readMessages(): Promise<void> {
    for await (const message of messages) {
      // Read before anything is dropped, and outside both runs, because this is
      // the one message on the stream that belongs to the Session rather than to
      // whatever is running on it.
      const sdk = message as { type?: string; subtype?: string }
      if (sdk?.type === 'system' && sdk.subtype === 'init') {
        runtime = runtimeReportFrom(message, input.resumed === true)
        // Written down before anything is answered. A conversation whose
        // pointer was recorded only at the end would lose its continuity to
        // exactly the crash the mirror already survives.
        if (runtime.sessionId.length > 0) input.sessionStarted?.(runtime.sessionId)
        // A Turn already in flight gets it now; anything else waits for `start`.
        // Both paths run through the same replay, so there is one description of
        // when a report reaches Core rather than two that can disagree.
        if (running !== null && !running.finished) {
          emit([{ kind: 'runtime', turnId: running.turnId, report: runtime }])
        }
        continue
      }

      // A Compaction takes the stream while it runs. Its messages are the
      // Session talking about its own context, not an answer to anything, and
      // attributing them to a Turn would put the summarisation's chatter into
      // the transcript.
      const compaction = compacting
      if (compaction !== null) {
        compaction.accept(message)
        await settle(compaction)
        continue
      }

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

  const cloneRoot = process.cwd()
  const inherit = inheritsClaudeConfig(process.env)

  /*
    Where a compaction summary comes from.

    The SDK reports it through `PostCompact` and nowhere else — it is not on the
    message stream, which carries only the `compact_boundary` that says a
    compaction happened. This callback is registered *here*, in process, as an
    option on the query: it is varnick's own code, not a hook out of
    `.claude/settings.json`, so `settingSources: []` neither removes it nor is
    weakened by it and no agent-authored code runs because of it.

    Only a manual compaction is reported. `PostCompact` fires for auto-compaction
    too, and rewriting varnick's transcript because the window filled up would be
    a rewrite nobody asked for.
  */
  let reportSummary: ((summary: string) => void) | null = null

  /*
    Which secrets exist, as the host last said.

    `null` until the host says anything, and that is a different thing from the
    empty list. An empty list means the Secrets Store was read and holds
    nothing, which is worth telling the agent — it is the difference between
    "there are no keys" and "go and look for one". `null` means nobody has said,
    and the honest thing to do with that is say nothing at all rather than
    announce an emptiness this process has no evidence for.
  */
  let secretNames: readonly string[] | null = null

  // Created rather than assumed. Claude Code writes its own state here, and a
  // directory it cannot create is a start that fails with an error about
  // something else. Inside the clone, which is writable — see
  // CLAUDE_CONFIG_RELATIVE_PATH for why nowhere under $HOME is.
  const { mkdirSync } = await import('node:fs')
  mkdirSync(claudeConfigDir(cloneRoot), { recursive: true })

  // Streaming input, held open. Prompts are pushed onto it as Turns arrive and
  // it never returns, which is what keeps the Claude Code process up. A
  // `prompt` string instead would run one turn and exit, and `agent.running`
  // would come to mean "a process was there once".
  const prompt = (async function* () {
    for (;;) {
      while (queued.length > 0) yield queued.shift() as UserMessage
      await new Promise<void>((resolve) => {
        wake = resolve
      })
    }
  })() as Prompt

  /*
    The conversation this process is continuing, or nothing.

    Resolved before the query rather than after, because `resume` is a question
    asked at the start of a session and cannot be asked later: a Claude Code
    process that opened a new conversation has already opened it. `null` on a
    first run, on a cleared store, and on a pointer whose transcript is gone —
    all three are a fresh conversation rather than a failure, which is what
    keeps a stale pointer from turning "the agent forgets" into "the agent will
    not start".
  */
  const resuming = resumableSession(cloneRoot)

  const session = query({
    prompt,
    options: {
      cwd: cloneRoot,
      // Spread rather than `resume: resuming ?? undefined`: the option is
      // documented as mutually exclusive with `continue`, and an explicit
      // `undefined` on a key the CLI checks for presence is the kind of thing
      // that works until it does not.
      ...(resuming === null ? {} : { resume: resuming }),
      // What makes an answer arrive in pieces. Without it the SDK reports one
      // assembled message when the Turn is over, and "working" would be
      // indistinguishable from "hung" for the whole of it.
      includePartialMessages: true,
      // ADR-0003: the kernel refuses sandbox_apply inside an existing sandbox,
      // so the SDK's own sandbox must stay off. srt is already around this
      // whole process tree. Set rather than omitted, because "off" belongs in
      // the code that would be blamed for exit 71.
      sandbox: { enabled: false },
      // ADR-0010. Isolated by default; `VARNICK_INHERIT_CLAUDE_CONFIG=1` is the
      // flag out. `env` replaces the subprocess environment outright, which is
      // why agentEnvironment returns the whole of it rather than an overlay.
      env: agentEnvironment(process.env, {
        cloneRoot,
        inherit,
        toolsBin: developerToolsBin(existsSync),
      }),
      hooks: {
        PostCompact: [
          {
            hooks: [
              async (hook) => {
                if (hook.hook_event_name !== 'PostCompact') return {}
                if (hook.trigger === 'manual') reportSummary?.(hook.compact_summary)
                return {}
              },
            ],
          },
        ],
        /*
          ADR-0006's naming end: the agent is told which secrets exist, by name,
          so it can write `process.env.STRIPE_KEY` in the Userspace it builds.

          **Here rather than in the system prompt, because the list changes.**
          `appendSystemPrompt` belongs to the SDK's `initialize` request and is
          fixed for the life of the session, so anything carried there would be
          the list as it stood when varnick launched — and `bun run secret add`
          runs in another process, minutes later. A `UserPromptSubmit` hook is
          re-run per Turn, so the brief is composed from whatever the host last
          said and a key added mid-session is nameable on the very next Turn.
          See DescribeSecretsRequest in ./turn.ts for the route in.

          Registered in process, exactly like the PostCompact hook above and for
          the same reason: it is varnick's own code rather than a hook out of
          `.claude/settings.json`, so `settingSources: []` neither removes it nor
          is weakened by it, and no agent-authored code runs because of it.

          `describeSecretsForAgent` composes the text and this does not reword
          it. That matters more than it looks: the sentence it writes is the one
          saying a value cannot be read and that resolution happens host-side,
          and an agent told the second half differently writes the renderer
          version of an integration and reads `undefined` with nothing to
          explain why.
        */
        UserPromptSubmit: [
          {
            hooks: [
              async (hook) => {
                if (hook.hook_event_name !== 'UserPromptSubmit') return {}
                const names = secretNames
                if (names === null) return {}
                return {
                  hookSpecificOutput: {
                    hookEventName: 'UserPromptSubmit',
                    additionalContext: describeSecretsForAgent(names),
                  },
                }
              },
            ],
          },
        ],
      },
      ...agentConfigurationOptions(inherit),
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
    compactionSummaries: (report) => {
      reportSummary = report
    },
    // Replaced wholesale, so a secret the developer removed stops being named
    // on the next Turn rather than lingering as a name nothing can resolve.
    secretsDescribed: (names) => {
      secretNames = names
    },
    resumed: resuming !== null,
    sessionStarted: (sessionId) => rememberSession(cloneRoot, sessionId),
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
      // What `/context` shows, asked of the Session itself. A control request
      // on the session already open — the same rule the whole channel exists
      // for — and the reason the meter after a Compaction is a reading rather
      // than a subtraction someone worked out.
      contextTokens: async () => {
        const usage = await session.getContextUsage()
        const total = usage?.totalTokens
        return typeof total === 'number' && Number.isFinite(total) ? total : null
      },
    },
  })
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
