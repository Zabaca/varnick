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
// Type only, and deliberately: `bun:ffi` is imported for real inside nestProbe
// and nowhere else, so the agent host does not link libsandbox to run an agent.
import type { Pointer } from 'bun:ffi'
import { CREDENTIAL_ENV_VARS, credentialRejection } from './credentials.ts'
import { readLines } from './framing.ts'
import { watchForOrphaning } from './orphan.ts'
import {
  BUN_CACHE_ENV_VAR,
  bunCacheDir,
  provisionCommandFor,
  provisionFailureMessage,
} from './provision.ts'
import {
  encodePreviewRequest,
  previewToolResult,
  LAUNCH_PREVIEW_DESCRIPTION,
  LAUNCH_PREVIEW_TOOL,
  type PreviewOutcome,
} from './preview.ts'
import { describeSecretsForAgent } from './secrets.ts'
import {
  beginTurn,
  beginsAnAnswer,
  encodeTurnEvent,
  unpromptedCauseOf,
  UNPROMPTED_TURN_PREFIX,
  UNPROMPTED_CAUSE_UNKNOWN,
  normaliseCommands,
  parseControlRequest,
  runtimeReportFrom,
  type TurnEvent,
  type RuntimeReport,
  IMAGE_MARKER,
  type PastedImage,
  type SlashCommand,
  type TurnFailure,
  type TurnRun,
} from './turn.ts'
import { agentSystemPrompt } from './voice.ts'

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
 * Where zod is, as an absolute path, for exactly the reason above.
 *
 * The second entry the confined process is handed rather than left to find, and
 * it is here because a **Custom Tool** needs one: `createSdkMcpServer` refuses
 * an input schema that is not a zod raw shape — *"inputSchema must be a Zod
 * schema or raw shape, received an unrecognized object"*, measured — and zod is
 * a peer dependency of the Agent SDK rather than something it re-exports. A bare
 * `import 'zod'` inside the Sandbox would fail the same silent way the SDK's own
 * bare specifier does, so it is resolved out here and imported by path in there.
 *
 * Empty when this installation has none. That is not an error and must not be
 * one: an agent with no `launch_preview` tool is an agent that cannot ask for a
 * Preview, which is where varnick was before this existed. An agent that will
 * not start is a different and much worse thing — the same rule ADR-0004 applies
 * to a Surface.
 */
export function zodEntry(): string {
  try {
    return fileURLToPath(import.meta.resolve('zod'))
  } catch {
    return ''
  }
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
  /** Defaults to {@link zodEntry}. Empty means this installation has none. */
  readonly zodEntry?: string
}

/**
 * The command the Sandbox wraps.
 *
 * A string, because that is what `wrap()` takes; every path in it is quoted
 * through `JSON.stringify`, because the wrapper hands this to `bash -c` and an
 * unquoted path is an injection point rather than a cosmetic problem.
 *
 * Two library paths, both resolved out here and never looked for in there — see
 * {@link agentSdkEntry} for the measurement that forced the first and
 * {@link zodEntry} for why the second follows it. They are positional and always
 * present, empty string included, so the probe flags after them keep their
 * places.
 */
export function agentCommand(input: AgentCommandInput): string {
  const exec = input.execPath ?? process.execPath
  const parts = [
    exec,
    agentEntryPath(input.cloneRoot),
    input.sdkEntry ?? agentSdkEntry(),
    input.zodEntry ?? zodEntry(),
  ]
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
 * Where varnick puts executables the agent's environment needs and the machine
 * does not have.
 *
 * Beside the configuration directory and gitignored for the same reason: it is
 * one machine's state, written at launch and never committed.
 */
export const AGENT_BIN_RELATIVE_PATH = '.varnick/bin'

/** varnick's own `bin` in a given clone. */
export function agentBinDir(cloneRoot: string): string {
  return join(cloneRoot, AGENT_BIN_RELATIVE_PATH)
}

/** Where a temporary file written inside the Sandbox goes. */
export const TEMP_DIR_ENV_VAR = 'TMPDIR'

/**
 * Where zsh writes the temporary file a heredoc needs.
 *
 * A second variable rather than a consequence of the first, because zsh does not
 * derive it: `TMPPREFIX` defaults to the literal `/tmp/zsh` and is consulted
 * before `TMPDIR` for here-documents. Setting only `TMPDIR` leaves the heredoc
 * exactly as broken as it was.
 */
export const TEMP_PREFIX_ENV_VAR = 'TMPPREFIX'

/**
 * The agent's temporary directory, relative to the clone.
 *
 * ## The finding this exists for
 *
 * **`srt` sets `TMPDIR=/tmp/claude`, and that path is in neither list.** It is
 * baked into the wrapped command — `env TMPDIR=/tmp/claude … sandbox-exec …` —
 * so every process inside the Sandbox inherits a temporary directory it is not
 * allowed to write. Measured by asking a wrapped shell what it had:
 *
 *     echo $TMPDIR       /tmp/claude          (denied)
 *     echo $TMPPREFIX    /tmp/zsh             (denied, zsh's default)
 *
 * That is ticket 53. The symptom a developer sees is a heredoc, because a
 * heredoc is the first thing that needs a temporary file:
 *
 *     zsh:1: can't create temp file for here document: operation not permitted
 *
 * and it is shell-specific, which is why it reads as random. `bash` and `sh`
 * write their here-documents to a pipe and never touch the filesystem — both
 * measured passing under the same policy, at the same moment zsh failed. Claude
 * Code's Bash tool runs the developer's login shell, which on macOS is zsh.
 *
 * **It is set here rather than granted in the policy.** `/tmp/claude` is a fixed
 * name directly under a world-writable directory and shared with every user on
 * the machine; granting it would be a wider boundary bought to fix a variable.
 * The clone is already writable, so pointing the variable at the clone costs
 * nothing and moves nothing. This is what ticket 53 asked for first and what its
 * third criterion holds to: `allowWrite` is unchanged.
 *
 * **Not the same path as Claude Code's own scratch, which is separately
 * granted.** `/tmp/claude-<uid>` is where Claude Code puts the directory every
 * Bash command needs, it does not honour `TMPDIR` for that, and it is in
 * `allowWrite` for the reason ticket 27 recorded. Two temporary directories,
 * two reasons, and neither replaces the other.
 *
 * Gitignored, per clone, and never committed, like everything else in
 * `.varnick`: it is one machine's scratch.
 */
export const AGENT_TEMP_RELATIVE_PATH = '.varnick/tmp'

/** The agent's temporary directory in a given clone. */
export function agentTempDir(cloneRoot: string): string {
  return join(cloneRoot, AGENT_TEMP_RELATIVE_PATH)
}

/**
 * zsh's here-document prefix in a given clone.
 *
 * A *file* prefix, not a directory: zsh appends its own suffix, so this names
 * `…/tmp/zsh` and the files beside it are `zsh<pid>`. It sits inside
 * {@link agentTempDir} so one `mkdir` covers both.
 */
export function agentTempPrefix(cloneRoot: string): string {
  return join(agentTempDir(cloneRoot), 'zsh')
}

/**
 * A `node` that is bun, so that a plugin's hooks can run.
 *
 * ## The finding this exists for
 *
 * Plugin hooks had never run. ADR-0010's amendment made the clone's own
 * configuration the agent's — *"its hooks, its skills, its MCP servers"* — and
 * priced the decision on hooks at length, but the hooks half was never
 * happening: a plugin declares its hook as a command, that command is
 * conventionally `node <script>`, and `node` is not on the agent's `PATH`.
 * `agentEnvironment` builds the environment outright rather than inheriting it,
 * and varnick runs on bun. A hook that cannot spawn fails silently, so a
 * developer got a plugin's skills and MCP servers and silently did not get its
 * hooks.
 *
 * ## Why a shim rather than Node
 *
 * Measured rather than assumed: bun runs a real plugin hook correctly. The
 * `caveman` plugin's `SessionStart` hook is CommonJS over `fs`, `path`, `os`
 * and a synchronous stdin read; under bun it produced its full output and wrote
 * every file it claims to. Installing a second runtime to run scripts the one
 * we already have can run would be a dependency bought for a naming
 * convention.
 *
 * The command string belongs to the plugin and is third-party, so it cannot be
 * rewritten. What can be arranged is that the name it uses resolves.
 *
 * **The honest limit.** Bun's Node compatibility is high and not total, so a
 * hook reaching an API bun does not implement will fail — and that is an
 * argument for reporting hook failures rather than against the shim, because
 * today such a hook fails silently either way.
 *
 * ## Why the interpreter is baked in rather than looked up
 *
 * `exec bun` would make the hook depend on a `PATH` search inside the Sandbox,
 * which is the same class of failure {@link agentSdkEntry} records for a bare
 * module specifier. The absolute path is known — it is the interpreter this
 * process is already running under — so it is written into the file.
 *
 * ## What this does not grant
 *
 * The shim is inside the clone and the clone is agent-writable, so the agent
 * can replace it. That grants nothing: the agent can already run bun directly,
 * and everything a hook does happens inside the Sandbox. It is written on every
 * launch rather than created once, so a broken one repairs itself.
 */
export function writeNodeShim(
  cloneRoot: string,
  interpreter: string,
  fs: {
    mkdir: (path: string) => void
    write: (path: string, contents: string) => void
    chmod: (path: string, mode: number) => void
  },
): string {
  const bin = agentBinDir(cloneRoot)
  fs.mkdir(bin)
  const shim = join(bin, 'node')
  /*
    `exec` rather than a call, so the hook's process *is* bun: a wrapper left in
    the middle would take the signals and report the exit status secondhand.
    The interpreter is quoted because a clone path may contain a space, and this
    file is handed to a shell.
  */
  fs.write(shim, `#!/bin/sh\nexec ${JSON.stringify(interpreter)} "$@"\n`)
  fs.chmod(shim, 0o755)
  return bin
}

/**
 * Give a Worktree its dependencies, if it is one and it has none.
 *
 * Returns the sentence to put in front of the agent when it could not, and
 * `null` when there was nothing to do or it worked. Reported, never thrown —
 * see {@link provisionFailureMessage} for why a Worktree without dependencies
 * must not be a Worktree the agent refuses to enter.
 *
 * **Two callers, because there are two ways to end up in one**, and the second
 * was missed on the first pass: `CwdChanged` covers a session that *walks* into
 * a Worktree, and the `init` report covers one that **resumes already inside**
 * it. A resumed session never changes directory — `EnterWorktree` is session
 * state and survives a restart — so the hook alone left exactly the case that
 * happens after every crash, and the agent went back to linking `node_modules`
 * by hand.
 */
async function provisionWorktreeAt(cloneRoot: string, path: string): Promise<string | null> {
  const plan = provisionCommandFor(cloneRoot, path, existsSync)
  if (plan === null) return null
  /*
    Awaited rather than left running. The next thing the agent does in a fresh
    Worktree is read or test something, and an install racing that would fail in
    a way that looks like a broken change rather than a directory that was not
    ready yet.
  */
  const install = Bun.spawn([plan.command, ...plan.args], {
    cwd: plan.cwd,
    env: process.env,
    stdout: 'pipe',
    stderr: 'pipe',
  })
  const status = await install.exited
  if (status === 0) return null
  return provisionFailureMessage(plan.cwd, await new Response(install.stderr).text())
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

/**
 * The commands this runtime last reported, kept for the next window.
 *
 * **Because the answer arrives too late to be useful the first time.** The list
 * can only reach Core stamped with a Turn id — that is what the event channel
 * carries — so a freshly launched window has an empty menu until someone sends
 * a message. Typing `/` before saying anything is exactly when a person is
 * looking for a command, and it was the one moment the menu had nothing.
 *
 * Written beside the session pointer, in the clone, for the same reasons: the
 * agent host is the only process that sees this, and the runtime — three
 * processes away but the one with a filesystem — is what reads it back for a
 * window that has not run a Turn yet.
 *
 * A cache of a fact that changes rarely, and wrong in only one direction: it
 * can be a launch out of date, which shows a command that has since gone. The
 * live list replaces it on the first Turn.
 */
export function commandsCachePath(cloneRoot: string): string {
  return join(claudeConfigDir(cloneRoot), 'last-commands.json')
}

/**
 * Briefings that have not reached the agent yet.
 *
 * ## Why a Briefing has to be on disk
 *
 * A Briefing is delivered by a `UserPromptSubmit` hook, which runs when the
 * developer next speaks — and **the thing varnick tells them to do next is
 * restart**. The band that appears after a merge says a restart is owed and
 * offers the button, so the ordinary sequence is merge, then restart, with no
 * Turn in between. A restart kills the agent host, and an in-process queue goes
 * with it: the agent is never told, in exactly the flow the product recommends.
 *
 * The same hole swallows it when the agent host dies on its own, which it does.
 *
 * So it is written where {@link claudeConfigDir} already keeps the session
 * pointer and the command cache: inside the clone, writable within the Sandbox,
 * gitignored, one machine's state.
 *
 * **Kept until delivered, not until the process ends.** The file is cleared by
 * the hook that hands the text over, so a Briefing survives any number of
 * restarts and crashes and is still said once.
 */
export function pendingBriefingsPath(cloneRoot: string): string {
  return join(claudeConfigDir(cloneRoot), 'pending-briefings.json')
}

/**
 * A Briefing, as it is kept.
 *
 * Two strings, because one of them expires. `whileRunning` says a restart is
 * still owed, which stops being true the moment one happens — and this file
 * exists precisely to carry a Briefing across that. It is delivered only by the
 * process that received it, and dropped by any process that finds it left
 * behind. See `RESTART_STILL_OWED` in ./merge.ts for why the split is here
 * rather than a sentence edited on the way out.
 */
export interface PendingBriefing {
  readonly briefing: string
  readonly whileRunning?: string
}

/** Read the briefings a previous process did not manage to deliver. */
export function readPendingBriefings(
  cloneRoot: string,
  read: (path: string) => string = (path) => readFileSync(path, 'utf8'),
): readonly PendingBriefing[] {
  try {
    const parsed = JSON.parse(read(pendingBriefingsPath(cloneRoot))) as unknown
    if (!Array.isArray(parsed)) return []
    return parsed.flatMap((entry) => {
      const briefing = (entry as { briefing?: unknown } | null)?.briefing
      // Nothing is reconstructed from a partial record. A Briefing is a sentence
      // or it is not there — half of one, delivered, spends the one chance to
      // say a branch landed.
      return typeof briefing === 'string' && briefing.trim().length > 0 ? [{ briefing }] : []
    })
  } catch {
    // No file, or one this build does not understand. Either way there is
    // nothing owed, which is what a first run looks like too.
    return []
  }
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
  /**
   * varnick's own `bin`, prepended to `PATH` behind {@link toolsBin}. Null when
   * it was not written — see {@link writeNodeShim} for what is in it.
   */
  readonly agentBin?: string | null
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

  /*
    And bun's cache, for the same reason and with the same answer: the default
    is `~/.bun/install/cache` and the Sandbox denies `$HOME`, so an install run
    by the agent — the one that gives a new Worktree its dependencies — would
    fail on a path rather than on anything about the install. See
    {@link BUN_CACHE_RELATIVE_PATH}.

    Set in both modes, like the config directory above. Under `inherit` the
    developer's own cache is still unreachable, so honouring their value would
    hand the agent a path it cannot read and call that inheritance.
  */
  environment[BUN_CACHE_ENV_VAR] = bunCacheDir(input.cloneRoot)

  /*
    And the temporary directory, which arrives wrong rather than missing.

    `srt` bakes `TMPDIR=/tmp/claude` into the wrapped command, and that path is
    in neither `allowRead` nor `allowWrite` — so the agent inherits a temporary
    directory the kernel refuses. Overwritten here for the same reason the two
    above are: the value that reaches the agent is varnick's, not whatever the
    layer below happened to leave.

    Both variables, because zsh consults `TMPPREFIX` for a here-document and
    defaults it to `/tmp/zsh` rather than deriving it. See
    {@link AGENT_TEMP_RELATIVE_PATH} for the measurement, and for why this is an
    environment fix rather than a wider `allowWrite`.
  */
  environment[TEMP_DIR_ENV_VAR] = agentTempDir(input.cloneRoot)
  environment[TEMP_PREFIX_ENV_VAR] = agentTempPrefix(input.cloneRoot)

  // The real toolchain ahead of the shim, so `git` is git. See
  // {@link developerToolsBin} for what the shim does and why allowing its
  // target is not the fix. Prepended rather than appended: /usr/bin is already
  // on PATH and would otherwise win.
  /*
    varnick's own bin next, so the shim is reachable — and behind the real
    toolchain, which must keep winning for every name it supplies. The only
    thing in here is a name nothing else on PATH answers to, so the order is
    about the rule rather than about a collision that exists today.
  */
  if (input.agentBin) {
    const path = environment.PATH
    environment.PATH = path ? `${input.agentBin}:${path}` : input.agentBin
  }

  if (input.toolsBin) {
    const path = environment.PATH
    environment.PATH = path ? `${input.toolsBin}:${path}` : input.toolsBin
  }

  return environment
}

/**
 * Where the agent's environment comes from.
 *
 * **The agent owns its environment, inside the fence.** It reads the clone's
 * `.claude/settings.json`, its hooks, its skills, its MCP servers and — the one
 * that was costing the most — its `CLAUDE.md`, which the SDK loads only when
 * `project` is among the sources.
 *
 * This reverses the isolation this function used to apply, and the argument it
 * reversed is worth keeping because it was half right. `settingSources: []`
 * was defending against agent-authored code running out of the clone. But a
 * hook loaded here runs *inside the Sandbox*, in the same confined process the
 * agent already runs `Bash` in — it grants no capability the agent does not
 * have. What it grants is **reach through time**: a hook fires in future
 * sessions, before anyone reads anything, and never appears in the transcript.
 * So an injection that lands once can make itself permanent and invisible.
 *
 * That is a real cost and it is not the one isolation was priced for. The line
 * that actually matters is narrower, and it now stands on its own:
 *
 * > Nothing derived from the clone is ever executed outside the Sandbox.
 *
 * varnick runs exactly one Claude Code process outside it — the `setup-token`
 * mint, ADR-0003's bounded exception — and that one already sets a
 * `CLAUDE_CONFIG_DIR` and a working directory outside the clone, for precisely
 * this reason. `the_mint_cannot_read_the_clone` in src-tauri/src/mint.rs is
 * what keeps it true.
 *
 * The mitigation for the reach problem is the one this codebase reaches for
 * everywhere else: make it visible rather than forbidden. The runtime panel
 * already reports what the agent actually loaded — skills, plugins, MCP
 * servers — because configured is not the same as loaded. An agent-written hook
 * is a thing to be able to see.
 *
 * `user` is deliberately absent. It is `~/.claude`, and the Sandbox denies
 * reads on `$HOME`, so naming it would be a claim this cannot honour — the flag
 * below adds it anyway for a run that has widened the policy by hand.
 */
export const AGENT_SETTING_SOURCES = ['project', 'local'] as const

export function agentConfigurationOptions(inherit: boolean): {
  settingSources: ('user' | 'project' | 'local')[]
  skills: 'all'
} {
  return {
    settingSources: inherit
      ? ['user', ...AGENT_SETTING_SOURCES]
      : [...AGENT_SETTING_SOURCES],
    /*
      Skills need turning on explicitly — the SDK calls this "the single place
      to turn skills on", and omitting it is not "skills off" but "no SDK
      opinion". Stated rather than left to a default, because the runtime panel
      reports the list and an empty one should mean the agent found none, not
      that varnick never asked.
    */
    skills: 'all',
  }
}

/**
 * The SDK's permission layer, turned off — because the kernel is the boundary.
 *
 * `CONTEXT.md` has said so since the Sandbox was defined: *"**Avoid**:
 * permissions (the SDK's prompt layer, which this replaces)"*. **It was never
 * actually turned off.** `permissionMode` appeared exactly once in this
 * repository, in the containment probe below, and the chat agent's `query()`
 * set neither it nor `canUseTool` — so the SDK applied its documented default,
 * `'default'`, which *"prompts for dangerous operations"*.
 *
 * There is no prompt surface in varnick and no callback was registered, so
 * every prompted tool use was refused. Read, Grep and a read-only Bash pass
 * that check, which is why it looked like a working agent for months: it could
 * investigate anything and write nothing.
 *
 * Found by an agent trying to write into a Worktree — a path `denyWrite` does
 * not name — being refused anyway, and correctly reporting that the Worktree
 * was not the reason. Two walls stood where the design describes one, and the
 * kernel one had been getting the credit.
 *
 * ## Why bypass rather than a narrower mode
 *
 * `'dontAsk'` denies anything not pre-approved, which needs an allowlist of
 * tools and paths — a second boundary, in a second language, maintained beside
 * `sandbox-policy.json` and free to disagree with it. Two boundaries that can
 * disagree is how the *first* one stopped being believed.
 *
 * `'acceptEdits'` covers Edit and not Bash, which is a strange half-fence: an
 * agent that may not run `Write` but may run `bash -c 'cat > file'` is confined
 * by nothing except its own choice of tool.
 *
 * So: one boundary, kernel-enforced, measured by eleven containment probes,
 * with nothing above it pretending to hold. That is ADR-0003's whole argument
 * and this is the line that finally honours it.
 *
 * ## What this genuinely costs
 *
 * Everything the agent may do is now decided by `sandbox-policy.json` and
 * nothing else. A mistake in that file is no longer caught by a second layer,
 * because there is no second layer — which is exactly why the policy is denied
 * to the agent, why the baseline records what varnick generated, and why the
 * probes run the real operations rather than reading the file back.
 *
 * `allowDangerouslySkipPermissions` is the SDK's own name and it is not
 * softened here. A reader should feel what this line does.
 */
export function agentPermissionOptions(): {
  permissionMode: 'bypassPermissions'
  allowDangerouslySkipPermissions: true
} {
  return { permissionMode: 'bypassPermissions', allowDangerouslySkipPermissions: true }
}

/**
 * Plugins the clone carries, as the SDK's own local-plugin config.
 *
 * Discovered from the filesystem rather than registered, the same rule Surfaces
 * follow: adding one must never require editing Core. A directory under
 * `.claude/plugins/` holding a `.claude-plugin/plugin.json` is a plugin.
 *
 * Passed as a query option rather than left to a settings file, which is what
 * makes this work at all: the plugins a developer has *installed* live under
 * `~/.claude`, which the Sandbox denies, so a plugin only exists for this agent
 * if it is inside the clone where the agent can read it. Copying one in is the
 * price of a fence that holds.
 *
 * A malformed plugin is skipped rather than fatal — the same rule ADR-0004
 * applies to a Surface. An agent left with no plugins is workable; an agent
 * that will not start is not.
 */
export const AGENT_PLUGINS_RELATIVE_PATH = '.claude/plugins'

/**
 * varnick's own fixture plugin, and the file its hook writes.
 *
 * Ticket 58's evidence, made permanent. The finding — that no plugin hook had
 * ever run — was visible only because the `caveman` plugin wrote a flag file
 * that had never appeared, and deleting that plugin took the evidence with it.
 * A fixture varnick owns cannot be removed by a decision about somebody else's
 * plugin.
 *
 * The file lands under {@link claudeConfigDir}, which is writable inside the
 * Sandbox and gitignored, so its presence is a fact about *this launch* rather
 * than something a commit could fake.
 *
 * Read {@link hookProbeRecord} for what it holds and why each field is there.
 */
export const HOOK_PROBE_PLUGIN = 'varnick-hook-probe'

/** The fixture plugin's directory in a given clone. */
export function hookProbePluginDir(cloneRoot: string): string {
  return join(cloneRoot, AGENT_PLUGINS_RELATIVE_PATH, HOOK_PROBE_PLUGIN)
}

/**
 * What the fixture plugin's `SessionStart` hook wrote, if it ran.
 *
 * Null when the file is absent or unreadable, which is the negative result and
 * the state varnick was in for months: **absence is the finding**, so this must
 * never invent a record to stand in for one.
 */
export function hookProbeRecord(
  cloneRoot: string,
  read: (path: string) => string = (path) => readFileSync(path, 'utf8'),
): { ran: string; pluginRoot: string | null; argv0: string | null } | null {
  try {
    const parsed = JSON.parse(read(join(claudeConfigDir(cloneRoot), 'hook-probe.json'))) as Record<
      string,
      unknown
    >
    if (typeof parsed.ran !== 'string') return null
    return {
      ran: parsed.ran,
      // The two candidates ticket 58 named. Recorded from the run rather than
      // reasoned about: varnick supplies `node` on PATH, Claude Code supplies
      // CLAUDE_PLUGIN_ROOT, and only a run says whether both arrived.
      pluginRoot: typeof parsed.pluginRoot === 'string' ? parsed.pluginRoot : null,
      argv0: typeof parsed.argv0 === 'string' ? parsed.argv0 : null,
    }
  } catch {
    return null
  }
}

export function agentPlugins(
  cloneRoot: string,
  fs: { readDir: (path: string) => readonly string[]; exists: (path: string) => boolean } = {
    readDir: (path) => readdirSync(path),
    exists: (path) => existsSync(path),
  },
): { type: 'local'; path: string }[] {
  const root = join(cloneRoot, AGENT_PLUGINS_RELATIVE_PATH)
  let entries: readonly string[]
  try {
    entries = fs.readDir(root)
  } catch {
    return []
  }
  return entries
    .map((entry) => join(root, entry))
    .filter((path) => fs.exists(join(path, '.claude-plugin', 'plugin.json')))
    .map((path) => ({ type: 'local' as const, path }))
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
async function selfTest(
  sdkEntry: string,
  zodPath: string,
  deniedPath: string,
  allowedPath: string,
): Promise<void> {
  const { dirname } = await import('node:path')
  const report: Record<string, string> = {}

  try {
    const sdk = (await import(sdkEntry)) as { query?: unknown }
    report.sdk = typeof sdk.query === 'function' ? 'loaded' : 'missing-query'
  } catch (error) {
    report.sdk = `failed: ${error instanceof Error ? error.message : String(error)}`
  }

  /*
    The second library the confined process is handed by path rather than left to
    find, and the one thing about the Custom Tool that could not be checked
    anywhere else.

    `runAgentHost` needs zod to build `launch_preview`'s input schema, and the
    reason it is an argument at all is a measured failure: a *bare* specifier
    resolved from inside the Sandbox fails silently, with `Cannot find module`
    and nothing in srt's violation log — see `agentSdkEntry`. That measurement
    was taken against the SDK. This is the same claim about zod, taken the same
    way, in the same process, under the same policy — because "the fix works for
    the other module too" is exactly the kind of sentence that turns out to be
    prose.

    A build with no zod reports `absent`, which is a real answer: it is an agent
    that cannot ask for a Preview rather than an agent that will not start.
  */
  if (zodPath === '') {
    report.zod = 'absent'
  } else {
    try {
      const zod = (await import(zodPath)) as { z?: { string?: unknown } }
      report.zod = typeof zod.z?.string === 'function' ? 'loaded' : 'missing-string'
    } catch (error) {
      report.zod = `failed: ${error instanceof Error ? error.message : String(error)}`
    }
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
 * The second profile the nested-Sandbox probe tries to put itself under.
 *
 * Two things at once, and both are load-bearing.
 *
 * `(allow default)` is the **widening**: it grants a read under `$HOME`, which
 * the outer policy denies and which is where the Keychain sits. That is the
 * operation the probe is about.
 *
 * The `deny` is the **witness**: `allowedDir` is inside the clone, which the
 * outer policy reads back out, so it is permitted before this profile and
 * refused after it — but only if this profile is actually in force. Without it,
 * "the nested policy was established and the read was still denied" and "nothing
 * was established" are the same output, and a probe that cannot tell them apart
 * has measured nothing. See ADR-0014.
 */
export function nestedProbeProfile(allowedDir: string): string {
  return ['(version 1)', '(allow default)', `(deny file-read* (subpath ${JSON.stringify(allowedDir)}))`].join(
    '\n',
  )
}

/**
 * Try to put this process under a second, wider Seatbelt profile, and report
 * what the kernel said and what changed.
 *
 * ADR-0014 asserted in prose that a nested sandbox cannot widen the outer one,
 * and marked the sentence as reasoning about Seatbelt semantics rather than a
 * result. This is the result — ticket 47.
 *
 * **In-process, and not by shelling out to `sandbox-exec`.** That is the same
 * distinction ADR-0003 was written about: `Read`, `Grep` and `Glob` walked past
 * the Agent SDK's `sandbox` option because they never handed anything to a
 * shell. A widening attempt that only ever ran `sandbox-exec` would measure the
 * shell path and leave the interesting one — `libsandbox` linked into the
 * agent's own process, forty lines of code away from any binary — unmeasured.
 * `sandbox_compile_string` and `sandbox_apply` are exactly that path.
 *
 * Every step is reported rather than collapsed into a verdict, because the
 * failure mode that matters is a nested sandbox that never started: the read
 * would be refused, the probe would go green, and nothing would have been
 * measured.
 */
async function nestProbe(deniedPath: string, allowedPath: string): Promise<void> {
  const { readFileSync } = await import('node:fs')
  const { dirname } = await import('node:path')
  const report: Record<string, string> = {}

  const read = (path: string): string => {
    try {
      return readFileSync(path, 'utf8').includes(SELFTEST_MARKER) ? 'permitted' : 'no match'
    } catch (error) {
      const code = (error as { code?: unknown } | null)?.code
      return `denied:${typeof code === 'string' ? code : 'unknown'}`
    }
  }

  const allowedDir = dirname(allowedPath)
  const profile = nestedProbeProfile(allowedDir)
  report.profile = profile.replaceAll('\n', ' ')

  // Before. The widening's target is refused and the witness's target is not —
  // which is what makes the two lines after the attempt mean anything.
  report.deniedBefore = read(deniedPath)
  report.allowedBefore = read(allowedPath)

  try {
    const { dlopen, FFIType, ptr, read: readMemory, CString } = await import('bun:ffi')
    const sandbox = dlopen('/usr/lib/libsandbox.1.dylib', {
      sandbox_compile_string: {
        args: [FFIType.ptr, FFIType.ptr, FFIType.ptr],
        returns: FFIType.ptr,
      },
      sandbox_apply: { args: [FFIType.ptr], returns: FFIType.i32 },
    })
    const libc = dlopen('/usr/lib/libSystem.B.dylib', {
      __error: { args: [], returns: FFIType.ptr },
      strerror: { args: [FFIType.i32], returns: FFIType.ptr },
    })
    report.dlopen = 'opened'

    // `sandbox_compile_string(profile, params, &error)`. Compiled separately from
    // applied so that a refusal cannot be mistaken for a profile this probe wrote
    // wrong — a syntax error and a kernel denial are different answers.
    const error = new BigUint64Array(1)
    // The out-parameter is an address the callee writes, so it comes back as a
    // number and has to be handed to `CString` as a pointer.
    const at = (address: bigint): Pointer => Number(address) as unknown as Pointer
    const compiled = sandbox.symbols.sandbox_compile_string(
      ptr(Buffer.from(`${profile}\0`, 'utf8')),
      null,
      ptr(error),
    )
    report.compiled = compiled ? 'compiled' : 'failed'
    if (error[0]) {
      report.compileError = new CString(at(error[0])).toString()
    }

    if (compiled) {
      const rc = sandbox.symbols.sandbox_apply(compiled)
      report.applyRc = String(rc)
      if (rc !== 0) {
        const errnoPtr = libc.symbols.__error()
        const errno = errnoPtr === null ? 0 : readMemory.i32(errnoPtr)
        const message = libc.symbols.strerror(errno)
        report.applyErrno = String(errno)
        report.applyError = message === null ? '' : new CString(message).toString()
      }
    }
  } catch (thrown) {
    report.dlopen = `failed: ${thrown instanceof Error ? thrown.message : String(thrown)}`
  }

  // After. `deniedAfter` is the boundary; `allowedAfter` is the witness, and it
  // is the line that says whether a second profile ever took effect.
  report.deniedAfter = read(deniedPath)
  report.allowedAfter = read(allowedPath)

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
  /**
   * Put a prompt on the Session's streaming input.
   *
   * `images` is what the developer pasted, and it is almost always empty. A
   * message carrying one becomes SDK content blocks rather than a string —
   * there is no text form of a picture, and inventing one (a path, a caption)
   * would be varnick describing an image to the model instead of showing it.
   */
  prompt(text: string, images?: readonly PastedImage[]): void
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
  /**
   * Every slash command this runtime will accept, with what each one does.
   *
   * The sixth member, and the argument for it is the one this interface's own
   * doc asks for: **nothing else can see this list.** It is assembled inside the
   * Claude Code process from the CLI's own commands, the skills it discovered
   * and the plugins it loaded, and it changes while the agent works — a skill
   * found in a subdirectory appears mid-session. The init message carries names
   * only; the descriptions and argument hints, which come from each command's
   * own frontmatter, are here or nowhere.
   *
   * Reading it is not running one. Executing a command already worked — a
   * message whose text is `/compact` is handed to the SDK like any other and the
   * CLI runs it — and this is about *discovery*: until now the window listed
   * thirteen commands varnick wrote itself and nothing the agent actually had.
   */
  supportedCommands(): Promise<readonly SlashCommand[]>
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
   * Optional because the loop is complete without it. A run with no reporter
   * simply never says a compaction happened, which is what this loop did for
   * every compaction varnick did not ask for, back when it could ask.
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
   * Where the news that one of the agent's branches landed comes in.
   *
   * Accumulating rather than replacing, which is the opposite of
   * {@link secretsDescribed} beside it and for a reason: a secret list is a
   * *state* and only the latest is true, while each of these is an **event**
   * that happened once. Two branches merged between two Turns are two things
   * the agent has to be told, and the second replacing the first would lose a
   * merge silently.
   *
   * Optional like the rest. A run with no reporter simply never tells the
   * agent, which is where varnick was before this existed: the agent went on
   * offering to preview a Worktree that had been deleted.
   */
  readonly mergesReported?: (briefing: string, whileRunning?: string) => void
  /**
   * Where a request for a Preview goes out, and how its answer comes back.
   *
   * Handed a function rather than being one, the same shape
   * {@link ServeTurnsInput.compactionSummaries} uses: the loop owns the request
   * ids and the pending answers, and the caller — `runAgentHost` — owns the
   * Custom Tool that calls it. Optional because the loop is complete without it,
   * which is what lets every existing test drive Turns with no Preview anywhere.
   *
   * **The confined process cannot do this itself, which is why it is a
   * question.** srt gates mach lookups by service name and varnick's policy
   * names none, so `com.apple.windowserver.active` is unreachable and no window
   * can be opened from in here. The host is asked; the host decides; the host
   * may put a native dialog in front of the decision. All this loop does is
   * carry the name out and the tag back.
   */
  readonly previewLaunches?: (ask: (worktree: string) => Promise<PreviewOutcome>) => void
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
  /**
   * Where the Session is standing, as its own `init` message reports it.
   *
   * Separate from {@link sessionStarted} because it answers a different
   * question and has a different consumer: the pointer is about continuity,
   * this is about whether the directory the agent resumed into is ready to be
   * worked in. See `provisionWorktreeAt`.
   */
  readonly sessionCwd?: (cwd: string) => void
  /**
   * The commands the runtime reported, as soon as it reports them.
   *
   * Handed over so the host can keep them for the next launch. The list can
   * only reach Core stamped with a Turn id, so a window that has not run a Turn
   * has an empty menu — which is exactly when someone types `/`.
   */
  readonly commandsListed?: (commands: readonly SlashCommand[]) => void
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
/**
 * Content is a string or a list of blocks.
 *
 * A plain prompt stays a string, which is what every Turn before images was and
 * what the SDK is happiest with. A prompt carrying pictures becomes blocks,
 * because that is the only shape an image has on the API: base64 and a media
 * type, beside the text rather than described by it.
 */
export type ContentBlock =
  | { type: 'text'; text: string }
  | { type: 'image'; source: { type: 'base64'; media_type: string; data: string } }

/**
 * A prompt and its pictures, in the order the developer wrote them.
 *
 * The composer puts `[Image #1]` where the paste happened, so the text already
 * says where each picture belongs. Splitting on those markers puts every image
 * next to the words about it, which is the difference between *"here are three
 * screenshots, now some questions"* and a question with its screenshot beside
 * it.
 *
 * Three rules, and two of them are about not losing a picture:
 *
 *   * a marker naming an image that is not there stays as text, because it is
 *     what the developer typed and hiding it would silently change the question
 *     they asked;
 *   * an image no marker names goes on the end, because the alternative is
 *     dropping it — a screenshot that was attached and never sent is the one
 *     failure this whole path exists to prevent;
 *   * the same marker twice is one picture, because a duplicated marker is
 *     somebody editing a sentence rather than asking to pay for the image
 *     again.
 */
export function interleave(text: string, images: readonly PastedImage[]): ContentBlock[] {
  const asBlock = (image: PastedImage): ContentBlock => ({
    type: 'image',
    source: { type: 'base64', media_type: image.mediaType, data: image.data },
  })

  const blocks: ContentBlock[] = []
  const used = new Set<number>()
  let at = 0

  for (const match of text.matchAll(IMAGE_MARKER)) {
    const index = Number(match[1]) - 1
    const image = images[index]
    if (image === undefined || used.has(index)) continue
    const before = text.slice(at, match.index)
    // Trimmed before it is judged: "[Image #1] " would otherwise send a block
    // containing one space, which is a block the model has to account for and
    // nobody wrote.
    if (before.trim().length > 0) blocks.push({ type: 'text', text: before })
    blocks.push(asBlock(image))
    used.add(index)
    at = match.index + match[0].length
  }

  const rest = text.slice(at)
  if (rest.trim().length > 0) blocks.push({ type: 'text', text: rest })
  for (const [index, image] of images.entries()) {
    if (!used.has(index)) blocks.push(asBlock(image))
  }
  return blocks
}

export async function serveTurns(input: ServeTurnsInput): Promise<void> {
  const { control, messages, session, write } = input

  /** The Turn currently running, and the only state these two loops share. */
  let running: TurnRun | null = null

  /*
    An answer the developer did not ask for, and how many there have been.

    Separate from `running` rather than a special value of it, because the two
    can be told apart from outside: a `u`-stamped Turn is one the world started,
    and Core renders it under what caused it rather than under a prompt nobody
    typed. See {@link UNPROMPTED_TURN_PREFIX}.
  */
  let unprompted: TurnRun | null = null
  let unpromptedTurns = 0
  /*
    What most recently arrived that the agent might be answering.

    Held rather than derived at the moment an answer starts, because by then the
    thing that caused it is several messages back on the stream — the
    notification lands, the agent thinks, and only then does the first token
    appear.
  */
  let lastCause = UNPROMPTED_CAUSE_UNKNOWN

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

  /**
   * Every command the runtime will accept, as it last said.
   *
   * Held and replayed for the same reason the report above is: the answer
   * arrives outside any Turn — once when the Session opens, and again whenever
   * the CLI discovers a skill mid-session — and an update with no Turn to stamp
   * it with is dropped by the rule this loop's own doc describes.
   *
   * `null` until the runtime has said anything, which is a different fact from
   * the empty list. Empty means it was asked and has none; `null` means nobody
   * has asked yet, and the window keeps showing varnick's own commands rather
   * than announcing an emptiness nothing has evidence for.
   */
  let commands: readonly SlashCommand[] | null = null

  /**
   * Ask the runtime what it will accept, and say so.
   *
   * Best-effort on purpose. This is a description of the agent, not a step in
   * answering anything, and a Session that will not answer the question is a
   * Session that still runs Turns — with a menu one refresh out of date, which
   * is a far better failure than a Turn that did not happen.
   */
  const askForCommands = async (turnId: string | null) => {
    let answer: readonly SlashCommand[]
    try {
      answer = await session.supportedCommands()
    } catch (error) {
      // stderr, which the host inherits and a developer can see. Not the wire:
      // this is a description of the agent failing to describe itself, and it
      // must not become an event a Turn has to reason about.
      process.stderr.write(
        `varnick: the runtime would not list its commands — ${error instanceof Error ? error.message : String(error)}\n`,
      )
      return
    }
    commands = answer
    // Handed over rather than written here: this loop has no filesystem in it
    // and no clone root, which is what keeps it testable without one.
    input.commandsListed?.(answer)
    if (turnId !== null) emit([{ kind: 'commands', turnId, commands: answer }])
  }

  const emit = (events: readonly TurnEvent[]) => {
    for (const event of events) write(encodeTurnEvent(event))
  }

  /*
    Previews the host has been asked for and has not answered yet.

    Keyed by a request id this loop mints, because a Preview is the one thing on
    this channel with no Turn to name it by — the agent may ask for one in the
    middle of any Turn, or in the middle of two.

    A pending request is resolved exactly once: by the answer, or by the control
    stream ending. The second is not tidiness. The host is what writes these
    answers, so a host that has gone is an answer that is never coming, and a
    tool call awaiting one would hold the Turn open for the life of a process
    that has stopped listening.
  */
  const awaitingPreview = new Map<string, (outcome: PreviewOutcome) => void>()
  let previewsAsked = 0

  input.previewLaunches?.((worktree: string) => {
    previewsAsked += 1
    const requestId = `preview-${previewsAsked}`
    return new Promise<PreviewOutcome>((resolve) => {
      awaitingPreview.set(requestId, resolve)
      // The name, unexamined. Deciding here whether it is a real worktree would
      // be this process vouching for a directory it is on the wrong side of the
      // Sandbox from; the host validates it against what git reports, which is
      // the only list that means anything. See src-tauri/src/preview.rs.
      write(encodePreviewRequest(requestId, worktree))
    })
  })

  /*
    A compaction, which arrives out of band through the SDK's `PostCompact`
    hook rather than on the message stream.

    **varnick asks for none of these and hears about all of them.** It used to
    own a `/compact` with a control request behind it, and that covered the
    compactions varnick was asked for and no others — the CLI has its own
    command, and an auto-compaction has no command at all. Every one of those
    rewrote the agent's context while the window kept the conversation it had
    already replaced. Nobody asked, and nobody could tell.

    So it is a report now, stamped with whatever Turn is running, the way every
    other agent-level fact on this channel is. Which kind it was does not
    travel: a compaction the developer asked for and one the window forced
    change the same thing in the same way, and a field nothing reads is a field
    that goes stale unnoticed.

    A compaction with no Turn to stamp is dropped, like every other message
    with no Turn. That is the one case listening does not reach — an
    auto-compaction cannot happen outside a Turn, because nothing is filling
    the context when nothing is running, and the CLI's `/compact` is itself a
    Turn.
  */
  input.compactionSummaries?.((summary) => {
    // Whitespace is not a summary. A transcript replaced by one would be a
    // transcript discarded, reported as a success.
    if (summary.trim().length === 0) return
    const carrying = running
    if (carrying === null || carrying.finished) return
    void (async () => {
      // Read, never assumed. A Session that will not say what it now holds
      // sends `null`, and the meter is left alone — a figure nobody took is a
      // meter that disagrees with the screen, which is the disagreement this
      // whole change is about.
      const measured = await session.contextTokens().catch(() => null)
      emit([
        {
          kind: 'compacted',
          turnId: carrying.turnId,
          summary,
          tokensUsed: measured !== null && Number.isFinite(measured) ? measured : null,
        },
      ])
    })()
  })

  async function start(request: {
    turnId: string
    prompt: string
    model: string
    effort: string
    images: readonly PastedImage[]
  }): Promise<void> {
    const run = beginTurn(request.turnId)
    running = run
    // Before the prompt rather than after the answer: what the runtime is
    // is worth knowing while the Turn runs, and a report that waited for the
    // answer would arrive at the moment it stopped being interesting.
    if (runtime !== null) emit([{ kind: 'runtime', turnId: request.turnId, report: runtime }])
    if (commands !== null) emit([{ kind: 'commands', turnId: request.turnId, commands }])
    try {
      // Before the prompt, so the Turn runs on what it was started with. A
      // SET_MODEL that arrives mid-Turn belongs to the next one, and applying
      // it here rather than reconfiguring a Turn in flight is what makes that
      // true rather than likely.
      await session.setModel(request.model)
      await session.setEffort(request.effort)
      session.prompt(request.prompt, request.images)
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
    if (request.kind === 'describe-secrets') {
      // Handed straight over and never kept here. This loop has no use for the
      // names: it does not compose the brief, does not put one on the Session,
      // and answers nothing — the request is the host telling the confined
      // process a fact, not asking it for one, and it is the only kind on this
      // channel that is.
      input.secretsDescribed?.(request.names)
      return
    }
    if (request.kind === 'report-merge') {
      // Handed over unchanged, like the names above and for the sharper version
      // of the same reason: the sentence was composed where the merge happened,
      // and this loop rewording it would be a confined process editing a report
      // about the tree it is not allowed to write.
      input.mergesReported?.(request.briefing, request.whileRunning)
      return
    }
    if (request.kind === 'preview-answer') {
      // Answered once and forgotten. A second answer to the same request — a
      // host that wrote twice, or a line replayed — has nothing to resolve, and
      // resolving a promise twice would be a tool call answered by whichever
      // arrived last rather than by the developer's decision.
      const waiting = awaitingPreview.get(request.requestId)
      if (waiting === undefined) return
      awaitingPreview.delete(request.requestId)
      waiting(request.outcome)
      return
    }
    // A stale interrupt from an abandoned Turn must not stop the one that
    // replaced it, so it has to name the Turn it means.
    const named = running !== null && !running.finished && running.turnId === request.turnId
    if (named) await session.interrupt()
  }

  // The same framing the runtime's pipe uses, and the same reader — see
  // ./framing.ts for why it is one function rather than two identical ones.
  async function readControl(): Promise<void> {
    try {
      await readLines(control, handle)
    } finally {
      // The channel is closed, so no answer can arrive on it. Everything still
      // waiting is told the launch did not happen, which is true and is the one
      // thing a caller can act on — see `awaitingPreview`.
      for (const [requestId, waiting] of awaitingPreview) {
        awaitingPreview.delete(requestId)
        waiting('no-launch')
      }
    }
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
        /*
          And where it resumed to, which is the only announcement a session
          already standing in a Worktree ever makes. `EnterWorktree` is session
          state and survives a restart, so the cwd is right without anything
          having *changed* it — and the hook that watches for a change never
          fires. Reported here rather than acted on: this loop knows nothing
          about clone roots, and `runAgentHost` does.
        */
        if (runtime.cwd.length > 0) input.sessionCwd?.(runtime.cwd)
        // A Turn already in flight gets it now; anything else waits for `start`.
        // Both paths run through the same replay, so there is one description of
        // when a report reaches Core rather than two that can disagree.
        if (running !== null && !running.finished) {
          emit([{ kind: 'runtime', turnId: running.turnId, report: runtime }])
        }
        // The described list, which the init message does not carry: it has
        // `slash_commands` as bare names, and what makes a menu usable — the
        // description and the argument hint, both out of each command's own
        // frontmatter — has to be asked for. Not awaited, because this loop is
        // reading a live message stream and a Turn must not wait behind a
        // description of one.
        void askForCommands(running !== null && !running.finished ? running.turnId : null)
        continue
      }

      /*
        The runtime discovered something while it was working.

        A skill found in a subdirectory, a plugin loaded mid-session. The SDK
        pushes the whole list and says to replace the cached one, which is what
        this does — a merge would go on offering a skill that has gone.
      */
      /*
        The conversation was reset — by `/clear`, or by anything else the CLI
        does it for. The pointer has to follow, or the next launch resumes the
        conversation this one was told to forget.
      */
      if (sdk?.type === 'conversation_reset') {
        const fresh = (message as { new_conversation_id?: unknown }).new_conversation_id
        if (typeof fresh === 'string' && fresh.length > 0) {
          input.sessionStarted?.(fresh)
          if (runtime !== null) runtime = { ...runtime, sessionId: fresh }
        }
        /*
          And tell the window, so the transcript goes when the memory does.

          Stamped with the Turn that was running, because that is how this
          channel carries anything — a reset arrives *during* the turn whose
          prompt was `/clear`. With no turn running there is nobody to tell and
          nothing on screen to correct.
        */
        if (running !== null && !running.finished) {
          emit([{ kind: 'reset', turnId: running.turnId }])
        }
        continue
      }

      if (sdk?.type === 'system' && sdk.subtype === 'commands_changed') {
        const pushed = normaliseCommands((message as { commands?: unknown }).commands)
        commands = pushed
        if (running !== null && !running.finished) {
          emit([{ kind: 'commands', turnId: running.turnId, commands: pushed }])
        }
        continue
      }

      const run = running
      if (run === null || run.finished) {
        /*
          No Turn of varnick's — and the agent may still be answering.

          This `continue` used to be unconditional, and it is where two complete
          answers were thrown away: a subagent finished, the notification
          reached the Session as a prompt varnick never sent, the agent answered
          it twice, and every message of both was dropped here. The developer
          then asked why it had not reported, and it correctly said it had.

          So an answer nobody asked for gets a run of its own, stamped `u1`,
          `u2`, … so Core can tell it from a Turn it started. Begun lazily,
          because most of what arrives while idle is not an answer and a run
          opened for every stray message would emit an empty one.
        */
        if (unprompted === null) {
          const cause = unpromptedCauseOf(message)
          if (cause !== null) lastCause = cause
          if (!beginsAnAnswer(message)) continue
          unpromptedTurns += 1
          unprompted = beginTurn(`${UNPROMPTED_TURN_PREFIX}${unpromptedTurns}`)
          // Said first, so Core knows what it is looking at before any of it
          // arrives. The window must never show an answer with no visible
          // cause — that reads as the agent talking to itself.
          emit([{ kind: 'cause', turnId: unprompted.turnId, text: lastCause }])
        }
        emit(unprompted.accept(message))
        if (unprompted.finished) unprompted = null
        continue
      }
      // A Turn of varnick's takes over: anything still open belongs to a
      // conversation this prompt is now part of, and two runs accumulating the
      // same stream would post the answer twice.
      unprompted = null
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
async function runAgentHost(sdkEntry: string, zodPath: string): Promise<void> {
  const sdk = (await import(sdkEntry)) as typeof import('@anthropic-ai/claude-agent-sdk')
  const { query } = sdk
  type Prompt = Parameters<typeof query>[0]['prompt']
  type UserMessage = {
    type: 'user'
    message: { role: 'user'; content: string | ContentBlock[] }
    parent_tool_use_id: null
    session_id: string
  }

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
    `.claude/settings.json`, so the clone's own settings neither remove it nor
    weaken it, and no agent-authored code runs because of it.

    Every compaction is reported, whatever triggered it.
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

  /*
    Branches of the agent's that landed and which it has not been told about.

    A queue rather than a value, and it is **drained** on delivery rather than
    kept. Each entry is an event that happened once, so re-announcing it every
    Turn would have the agent reading that its branch merged for the rest of the
    session — and the last thing that briefing says is that a restart is still
    owed, which stops being true the moment one happens. A stale copy of that
    sentence is a worse lie than silence.

    Nothing here composes one. The text arrives whole from the host, which got
    it from the process that performed the merge; see `mergeBriefing`.
  */
  /*
    Loaded first, so a Briefing a previous process could not deliver is said in
    this one. What is loaded carries no `whileRunning`: a restart has plainly
    happened, so the clause saying one is still owed is no longer true — see
    {@link readPendingBriefings}.
  */
  const mergeBriefings: PendingBriefing[] = [...readPendingBriefings(cloneRoot)]

  /** Write what is still owed, so a restart or a crash does not swallow it. */
  const rememberBriefings = () => {
    try {
      writeFileSync(pendingBriefingsPath(cloneRoot), `${JSON.stringify(mergeBriefings)}\n`)
    } catch {
      // Best effort, like the session pointer beside it. A Briefing that could
      // not be written is one this process still holds and will still deliver
      // if it lives long enough; refusing to merge over it would be worse.
    }
  }

  /*
    Where a request for a Preview goes once the loop below is running.

    Assigned by `serveTurns` through `previewLaunches`, exactly as
    `reportSummary` above is assigned through `compactionSummaries`, and for the
    same reason: the query has to be built before the loop that drives it, and
    the tool the query carries needs something the loop owns.

    Null is unreachable in practice — a tool call happens inside a Turn and a
    Turn only exists once the loop is serving — and it answers `no-launch`
    rather than throwing, because a tool that raises is a failed Turn and this
    one is never worth failing a Turn over.
  */
  let askForPreview: ((worktree: string) => Promise<PreviewOutcome>) | null = null

  /*
    The `launch_preview` **Custom Tool**.

    ADR-0014's one addition to what the agent can do, and it is a Custom Tool
    rather than a widening for the reason CONTEXT.md gives the term: one narrow
    capability granted in process, instead of a policy loosened for everything
    else. The work it asks for happens outside the Sandbox, so the tool's own
    surface *is* the security boundary — which is why the whole of what crosses
    is one string, and why what that string may be is decided by the host
    against `git worktree list` rather than here.

    **Built inside a try, and a failure costs the tool rather than the agent.**
    zod is resolved by the runtime and handed in as a path (see `zodEntry`);
    an installation without it, or an SDK that has moved on, leaves an agent
    that cannot ask for a Preview. That is where varnick was before this
    existed. The alternative — an agent that will not start because a tool would
    not build — is the failure ADR-0004 refuses for a Surface, and there is no
    reason to accept it here.
  */
  type McpServers = NonNullable<NonNullable<Parameters<typeof query>[0]['options']>['mcpServers']>

  const previewServers: McpServers = await (async (): Promise<McpServers> => {
    if (zodPath === '') return {}
    try {
      const { z } = (await import(zodPath)) as typeof import('zod')
      const previewTool = sdk.tool(
        LAUNCH_PREVIEW_TOOL,
        LAUNCH_PREVIEW_DESCRIPTION,
        {
          // One field, and it is a name. There is deliberately no `path`, no
          // `command`, no `port` and no `env`: this is a host-side process spawn
          // driven by agent input, and every field that is not here is a field
          // that cannot be filled in.
          worktree: z
            .string()
            .describe(
              'The name of a worktree under .claude/worktrees/ — one path component, not a path.',
            ),
        },
        async (args) => {
          const ask = askForPreview
          const outcome = ask === null ? 'no-launch' : await ask(args.worktree)
          const { launched, text } = previewToolResult(outcome)
          return {
            content: [{ type: 'text' as const, text }],
            // A refusal is a refusal, not a broken tool: `isError` is what stops
            // the model reading "the developer declined" as "try again".
            isError: !launched,
          }
        },
      )
      return {
        varnick: sdk.createSdkMcpServer({ name: 'varnick', tools: [previewTool] }),
      }
    } catch (error) {
      process.stderr.write(
        `varnick: the launch_preview tool could not be built, so this agent cannot ask for a preview — ${error instanceof Error ? error.message : String(error)}\n`,
      )
      return {}
    }
  })()

  // Created rather than assumed. Claude Code writes its own state here, and a
  // directory it cannot create is a start that fails with an error about
  // something else. Inside the clone, which is writable — see
  // CLAUDE_CONFIG_RELATIVE_PATH for why nowhere under $HOME is.
  const { mkdirSync, chmodSync } = await import('node:fs')
  mkdirSync(claudeConfigDir(cloneRoot), { recursive: true })

  // And the temporary directory the environment points at, for the same reason
  // in a sharper form: a `TMPDIR` naming a directory that does not exist is not
  // an improvement on one naming a directory the kernel refuses. See
  // AGENT_TEMP_RELATIVE_PATH.
  mkdirSync(agentTempDir(cloneRoot), { recursive: true })

  /*
    Written every launch, for the reason {@link writeNodeShim} gives: a plugin
    hook's command names `node`, and without this nothing answers to it.

    Failure here must not be fatal. A clone whose `.varnick` cannot be written
    is a clone whose hooks will not run, which is the state varnick has been in
    all along — it is not a reason to refuse to start, and a start that fails
    over a shim would be a worse bug than the one this fixes.
  */
  let agentBin: string | null = null
  try {
    agentBin = writeNodeShim(cloneRoot, process.execPath, {
      mkdir: (path) => mkdirSync(path, { recursive: true }),
      write: (path, contents) => writeFileSync(path, contents),
      chmod: (path, mode) => chmodSync(path, mode),
    })
  } catch {
    agentBin = null
  }

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
      /*
        Claude Code's own system prompt, asked for rather than assumed.

        **The agent did not know what directory it was in.** Not confused —
        uninformed: it ran `pwd` because that was genuinely the only way to find
        out. The SDK does not give you Claude Code's prompt by default; it is a
        preset you opt into, and it is the only thing that carries the working
        directory, the memory path and git status ("per-user dynamic sections",
        in the SDK's own words). Omitting it left an agent with no idea where it
        was standing, in a product whose whole subject is a clone.

        Not the same question as `settingSources`. That one was `[]` when this
        was written and is `['project', 'local']` now — ticket 38 reversed it,
        so `CLAUDE.md` *is* loaded as a memory file and the clone's own hooks
        and skills are the agent's. What has not changed is why the two are
        separate questions: this is a prompt varnick asks the CLI for, nothing
        agent-authored runs because of it, and the boundary does not move.

        `excludeDynamicSections` is deliberately left off: stripping the working
        directory back out is the whole of what this fixes.
      */
      systemPrompt: agentSystemPrompt(),
      // What makes an answer arrive in pieces. Without it the SDK reports one
      // assembled message when the Turn is over, and "working" would be
      // indistinguishable from "hung" for the whole of it.
      includePartialMessages: true,
      // ADR-0003: the kernel refuses sandbox_apply inside an existing sandbox,
      // so the SDK's own sandbox must stay off. srt is already around this
      // whole process tree. Set rather than omitted, because "off" belongs in
      // the code that would be blamed for exit 71.
      sandbox: { enabled: false },
      /*
        And the SDK's *permission* layer off with it, for the same reason and
        with a much larger consequence — see {@link agentPermissionOptions},
        which is where the argument lives. Beside `sandbox` on purpose: they are
        two halves of one sentence, "the kernel is the boundary and nothing
        above it pretends to hold", and separating them is how one of them came
        to be missing for months without anybody noticing.
      */
      ...agentPermissionOptions(),
      // ADR-0010. Isolated by default; `VARNICK_INHERIT_CLAUDE_CONFIG=1` is the
      // flag out. `env` replaces the subprocess environment outright, which is
      // why agentEnvironment returns the whole of it rather than an overlay.
      env: agentEnvironment(process.env, {
        cloneRoot,
        inherit,
        toolsBin: developerToolsBin(existsSync),
        agentBin,
      }),
      hooks: {
        PostCompact: [
          {
            hooks: [
              async (hook) => {
                if (hook.hook_event_name !== 'PostCompact') return {}
                /*
                  Every compaction, whatever triggered it.

                  This was `trigger === 'manual'` on the reasoning that
                  rewriting the transcript because the window filled up would be
                  a rewrite nobody asked for. The opposite turned out to be
                  true: an auto-compaction rewrites the *agent's* context
                  whether or not varnick joins in, so dropping it left the
                  window showing a conversation the agent no longer held — the
                  same disagreement `/clear` had, with no command involved at
                  all and nobody able to notice.

                  `hook.trigger` is deliberately not read. It is the difference
                  between a compaction asked for and one the window forced, and
                  varnick does the same thing with both.
                */
                reportSummary?.(hook.compact_summary)
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
                /*
                  Two kinds of thing ride this hook now, and they are combined
                  here rather than given a hook each: the SDK re-runs
                  `UserPromptSubmit` once per Turn, so a second registration
                  would be a second pass over the same moment for no gain.

                  They behave oppositely and the difference is deliberate. The
                  secret names are **state** — the whole list, every Turn,
                  because it changes and only the latest is true. A merge
                  briefing is an **event**: said once and drained, because
                  repeating it would have the agent reading that its branch just
                  landed for the rest of the session, and the sentence ends with
                  a restart being owed — which stops being true as soon as one
                  happens.
                */
                const parts: string[] = []
                if (secretNames !== null) parts.push(describeSecretsForAgent(secretNames))
                if (mergeBriefings.length > 0) {
                  /*
                    Both halves for a Briefing this process received; the
                    durable half alone for one it found left behind, because
                    "varnick has not restarted" is false in a process that
                    started after the restart.
                  */
                  for (const held of mergeBriefings.splice(0)) {
                    parts.push(
                      held.whileRunning === undefined
                        ? held.briefing
                        : `${held.briefing} ${held.whileRunning}`,
                    )
                  }
                  // Delivered, so no longer owed. Cleared here rather than on
                  // exit: this is the moment it stopped being true.
                  rememberBriefings()
                }
                if (parts.length === 0) return {}
                return {
                  hookSpecificOutput: {
                    hookEventName: 'UserPromptSubmit',
                    additionalContext: parts.join('\n\n'),
                  },
                }
              },
            ],
          },
        ],
        /*
          Entering a Worktree gives it its dependencies.

          `EnterWorktree` is Claude Code's own and ADR-0014 keeps it that way,
          so varnick does not create the directory and cannot provision it at
          creation. This is the next honest moment: the session has just moved
          into it and has not yet run anything that would need `node_modules`.

          `WorktreeCreate` is the more precise seam and was rejected — its
          output *is* the worktree path, so a hook there replaces creation
          rather than following it, and varnick would have to reimplement branch
          naming, base-ref resolution and locking to keep behaviour identical.
          Getting any of that subtly wrong breaks `EnterWorktree` outright,
          which is a poor trade for a step that is idempotent anyway.

          Idempotent, and it must be: re-entering a Worktree is ordinary, and
          {@link provisionCommandFor} answers `null` for one already provisioned
          and for anywhere that is not a Worktree at all — including the live
          tree, where an install nobody asked for would run over the developer's
          own `node_modules`.
        */
        CwdChanged: [
          {
            hooks: [
              async (hook) => {
                if (hook.hook_event_name !== 'CwdChanged') return {}
                const failure = await provisionWorktreeAt(cloneRoot, hook.new_cwd)
                // Reported, never fatal: see {@link provisionFailureMessage}.
                return failure === null ? {} : { systemMessage: failure }
              },
            ],
          },
        ],
      },
      ...agentConfigurationOptions(inherit),
      /*
        The Custom Tools. One, and it is `launch_preview` — an in-process SDK
        MCP server, which is what CONTEXT.md means by the term: code running in
        this process rather than a capability the Sandbox policy had to grant.

        Empty when the tool could not be built, which is an agent without it
        rather than no agent at all.
      */
      mcpServers: previewServers,
      /*
        Plugins the clone carries. Empty on a fresh checkout, which is the
        honest default — a plugin only exists for this agent if it is somewhere
        the agent can read, and `~/.claude/plugins` is not.
      */
      plugins: agentPlugins(cloneRoot),
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
    // The other half of the Custom Tool above: the loop hands over the way to
    // ask, and the tool's handler is what calls it.
    previewLaunches: (ask) => {
      askForPreview = ask
    },
    // Replaced wholesale, so a secret the developer removed stops being named
    // on the next Turn rather than lingering as a name nothing can resolve.
    secretsDescribed: (names) => {
      secretNames = names
    },
    // Appended, never replaced: each is a thing that happened once, and two
    // merges between two Turns are two things the agent has to be told.
    mergesReported: (briefing, whileRunning) => {
      mergeBriefings.push(whileRunning === undefined ? { briefing } : { briefing, whileRunning })
      // On disk before the next thing happens, because the next thing varnick
      // recommends is a restart.
      rememberBriefings()
    },
    resumed: resuming !== null,
    sessionStarted: (sessionId) => rememberSession(cloneRoot, sessionId),
    /*
      A session that resumed into a Worktree gets its dependencies here, because
      it never announced a change of directory to get them any other way.

      Not awaited: the first Turn cannot start before the developer sends one,
      and blocking the message loop on an install would stall every other thing
      `init` carries — the runtime report and the command list among them.
    */
    sessionCwd: (cwd) => {
      void provisionWorktreeAt(cloneRoot, cwd)
    },
    commandsListed: (listed) => {
      // Best-effort, like the session pointer: a cache that could not be
      // written costs the next launch a menu, and failing this launch to say so
      // would be the worse trade.
      try {
        writeFileSync(commandsCachePath(cloneRoot), `${JSON.stringify({ commands: listed })}\n`)
      } catch {
        // Nothing to do about it, and nowhere useful to say it.
      }
    },
    session: {
      prompt: (text, images) => {
        const content: string | ContentBlock[] =
          images === undefined || images.length === 0 ? text : interleave(text, images)
        queued.push({
          type: 'user',
          message: { role: 'user', content },
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
      // The runtime's own list, asked of the Session that is already open —
      // the same rule the whole port follows. `supportedCommands` tracks the
      // latest `commands_changed` push, so re-asking after one is redundant
      // rather than wrong; this is asked once, when the Session opens.
      supportedCommands: async () => normaliseCommands(await session.supportedCommands()),
      contextTokens: async () => {
        const usage = await session.getContextUsage()
        const total = usage?.totalTokens
        return typeof total === 'number' && Number.isFinite(total) ? total : null
      },
    },
  })
}

// `agent.ts <sdkEntry> <zodEntry> [--selftest|--toolprobe|--nestprobe <deniedPath> <allowedPath>]`,
// spawned by src-tauri/src/agent.rs through the wrapping the runtime computed.
// Both library locations are arguments rather than bare imports — see
// agentSdkEntry above for the measurement that forced the first and zodEntry for
// why the second follows it. Both are always present and the second may be the
// empty string, so the flags after them keep their places. All three flags
// belong to the containment probes in containment.probe.test.ts; none is
// reachable from the host, which passes the two paths and nothing else.
if (import.meta.main) {
  const [sdkEntry, zodPath, flag, deniedPath, allowedPath] = process.argv.slice(2)
  if (sdkEntry === undefined) {
    process.stderr.write('The agent host was started without the Agent SDK path it needs.\n')
    process.exit(2)
  }
  if (flag === '--selftest') {
    await selfTest(sdkEntry, zodPath ?? '', deniedPath ?? '', allowedPath ?? '')
  } else if (flag === '--toolprobe') {
    await toolProbe(sdkEntry, deniedPath ?? '', allowedPath ?? '')
    process.exit(0)
  } else if (flag === '--nestprobe') {
    // The one probe that changes this process irreversibly if it succeeds: a
    // second profile cannot be lifted once applied. So it is the last thing this
    // process does, and the process is the probe's own.
    await nestProbe(deniedPath ?? '', allowedPath ?? '')
    process.exit(0)
  } else {
    /*
      Take the sandboxed tree down if the host that started it dies.

      The last line of the shutdown story, and the only one that survives a
      `kill -9`. varnick kills this group on ⌘Q and on SIGTERM; neither runs
      when the host is killed outright or crashes, and what was left behind was
      a confined Claude Code process with a credential in its environment,
      running with nothing attached to it. Several were measured at five hours
      old.

      `process.kill(0, …)` signals this process's own **group**, which is
      exactly this tree and nothing else: the host spawns the wrapper with
      `process_group(0)` (src-tauri/src/agent.rs), so the group is the bash
      wrapper, `sandbox-exec`, this host, and the Claude Code process under it.
      Killing the group rather than this process alone is what keeps the agent
      from outliving its own host — and it is the same signal, to the same
      group, that varnick's own teardown sends.
    */
    watchForOrphaning({
      parentPid: () => process.ppid,
      teardown: () => {
        process.kill(0, 'SIGKILL')
      },
      // Not reached in practice — the group signal above includes this process
      // — and here because a teardown that somehow returns must still end it.
      exit: () => process.exit(0),
    })
    await runAgentHost(sdkEntry, zodPath ?? '')
  }
}
