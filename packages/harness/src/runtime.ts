/**
 * The Harness runtime — the host-side half of the bridge.
 *
 * ## Where this runs, and why it is one long-lived process
 *
 * A Node process started and kept by the Rust host, talking newline-delimited
 * JSON over stdio. Long-lived rather than one per call, for three reasons that
 * are all the same reason:
 *
 *   * srt's proxies live in the process that called `SandboxManager.initialize()`.
 *     A process that established the Sandbox and then exited would leave
 *     `checkSandbox` answering `ok` about a sandbox that no longer exists, which
 *     is the one lie this product cannot tell.
 *   * the wrapping srt computes is only good while the proxies that back it are
 *     alive, and they live in this process. The agent is spawned by the Rust
 *     host, not by this one — containment travels in the argv, not through
 *     parentage.
 *   * the Session mirror serialises saves through a per-store queue. Two
 *     overlapping saves in two processes have no queue between them and would
 *     both append the same message.
 *
 * ## This process computes the wrapping; it does not spawn the agent
 *
 * Nothing here spawns a Claude Code process, and that is the decision rather
 * than an omission. Holding the Sandbox makes spawning from here look natural —
 * it is the trap ADR-0008's third rejection was written about — but the agent
 * needs the credential in its environment, and the credential lives in the Rust
 * host and may not cross the bridge. So `wrap-agent-command` answers with argv,
 * an environment overlay and a working directory, all of them free of secrets,
 * and src-tauri/src/agent.rs performs the spawn with the credential it already
 * has. The agent is inside srt either way, because the wrapping is in the argv.
 *
 * The proxies srt runs still live in *this* process, which is why it has to
 * outlive the call that established them.
 *
 * ## What this module is not
 *
 * It is not reachable from Core. `packages/core/src/actors/live.ts` imports
 * ./bridge.ts, which imports no Node; this file imports the filesystem and the
 * kernel and is only ever loaded by ./serve.ts, in the runtime process.
 *
 * ## The credential is not here
 *
 * `read-credential` is answered by the Rust host and never reaches this process.
 * A runtime that found a way to answer it would be a second process holding a
 * secret, so the request is refused below rather than left unhandled — an
 * unhandled case is a case someone can quietly implement.
 *
 * ## Secret names leave this process; secret values do not
 *
 * This is the only process that can read the Secrets Store — the keychain lives
 * under `$HOME` and the agent host is inside the Sandbox — so it is where
 * `read-secret-names` is answered, and it is the one call whose whole purpose
 * is to put something in front of the confined agent (ADR-0006's naming end).
 *
 * The values are in this process too, and they leave it in exactly one
 * direction, which is unchanged by that: into the Session mirror's redaction
 * pass, as `secretValues()`. There is no `get(name)` on a store and nothing on
 * the request path below that calls the one member which yields values.
 */

import { execFile } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { agentCommand, commandsCachePath } from './agent.ts'
import { listPendingWorktrees, type PendingWorktree } from './worktrees.ts'
import { readLines } from './framing.ts'
import { fenceHunks, UNTRACKED_PREVIEW_BYTES } from './preview.ts'
import {
  establishSandbox,
  type EstablishedSandbox,
  type WrappedCommand,
} from './sandbox.ts'
import {
  adoptLegacySessionMirror,
  appDataRoot,
  createSessionStore,
  nodeSessionFs,
  restoredTranscript,
  sessionMirrorRoot,
  type SessionStore,
  type StoredMessage,
} from './session.ts'
import { openSecretsStore, securityKeychain, type SecretsStore } from './secrets.ts'
import { normaliseCommands, type SlashCommand } from './turn.ts'

/** What the runtime can actually do. Injected so tests supply their own. */
export interface HarnessCapabilities {
  /** Establish the Sandbox, or throw with the reason. */
  establishSandbox(): Promise<unknown>
  /**
   * Compute how to start the agent under the Sandbox, or throw with the reason.
   *
   * Computes; never spawns. The spawn belongs to the Rust host, because that is
   * the process holding the credential and the credential may not cross the
   * bridge — ADR-0008's third rejection.
   */
  wrapAgentCommand(): Promise<WrappedCommand>
  /** Write a transcript to the Session mirror, or throw with the reason. */
  persist(input: {
    sessionId: string
    messages: readonly StoredMessage[]
  }): Promise<{ ok: true }>
  /**
   * Read a transcript back out of the Session mirror, or throw with the reason.
   *
   * A Session that has never been written is an empty transcript, not a
   * failure — that is a first run. A read that could not be *done* must throw,
   * because an empty answer would be indistinguishable from a first run and the
   * next save would replace a transcript nobody managed to read.
   */
  readSession(sessionId: string): Promise<readonly StoredMessage[]>
  /**
   * The commands the agent last reported, from the cache the agent host wrote.
   *
   * Answered here because this is the process with a filesystem, and asked at
   * all because the live list can only reach Core stamped with a Turn id — so a
   * window that has not run a Turn has never been told what the agent accepts,
   * which is exactly when someone types `/`. Empty when there is no cache,
   * which is a first run rather than a failure.
   */
  readCommands(): Promise<readonly SlashCommand[]>
  /**
   * The names of the stored secrets, for telling the agent which exist.
   *
   * ADR-0006's naming end, and the reason it is answered *here*: the keychain
   * lives under `$HOME`, which the Sandbox denies read on, so the confined agent
   * host cannot look for itself. This process can, and this is the only member
   * of the Harness's whole host-side surface that answers a question about the
   * Secrets Store.
   *
   * **Names, and there is no shape here a value could come back in.** It
   * answers with `store.names()`, which the store guarantees never yields one —
   * `secretValues()` is the single member that does, it is named for it, and
   * nothing on this path calls it.
   *
   * Re-read rather than answered from the snapshot taken at open, for the same
   * reason {@link persist} re-reads: `bun run secret add` is a different
   * process, and a list answered out of the launch-time snapshot would leave a
   * developer relaunching varnick to make a new key nameable.
   */
  readSecretNames(): Promise<readonly string[]>
  /**
   * Which Worktrees hold commits the live tree does not, and what changed.
   *
   * Answered here because it needs a filesystem and a subprocess, and because
   * it must not be answered by the agent: this is the list that shows what the
   * agent changed, and a list the agent composed is a list the agent can shade.
   * See ./worktrees.ts, which runs three read-only commands and parses them.
   *
   * A listing that could not be made **throws**. An empty list means nothing is
   * waiting to be merged, which is a different fact with different copy —
   * `review.empty` against `review.listFailed` in the Harness machine.
   */
  listWorktrees(): Promise<readonly PendingWorktree[]>
  /**
   * The **Fence** part of what a Worktree changes, as hunks.
   *
   * What the native dialog in front of a Preview shows, and the whole of what
   * decides whether one is raised: empty means the worktree's Fence is the Fence
   * already running, and that launches without asking.
   *
   * **Here rather than in the Rust host**, though the host is what draws the
   * dialog. Two reasons, and the second is the load-bearing one. This is the
   * process with a filesystem and with git already in reach, so running two
   * commands and reading a diff costs nothing new. And `isFencePath` — which
   * decides what Fence *is* — is one list that three separate mechanisms key off
   * (the dialog, the diff view's highlighting, and `denyWrite` itself), so it
   * belongs where the other two can read it rather than written a second time in
   * another language.
   *
   * The path is absolute and comes from the host, which resolved it out of what
   * `git worktree list` reported. Nothing the agent typed reaches this.
   */
  readFenceDiff(worktree: string): Promise<string>
}

export interface HostCapabilitiesInput {
  /**
   * The clone the agent works in — everything this runtime does is about this
   * one directory, and it arrives as an argument.
   *
   * Required, and it is the whole of ticket 28. It was not here at all: the
   * Tauri host set a working directory computed from `env!("CARGO_MANIFEST_DIR")`
   * and `establishSandbox()` picked it back up out of `process.cwd()` four hops
   * later. The runtime does not read `VARNICK_CLONE_ROOT` itself — the host
   * resolves it once and passes the answer, because two readers of one variable
   * are two answers waiting to disagree, and the Sandbox must be established for
   * the same root the mirror is keyed by. See ./clone-root.ts and
   * docs/adr/0012-the-clone-root-is-an-input.md.
   */
  readonly cloneRoot: string
}

/**
 * The real capabilities, built once for the life of the process, for one root.
 *
 * The Session mirror is made on first use rather than at module load: it needs
 * an app-data directory, and constructing it eagerly would make a runtime that
 * only ever checks the Sandbox fail on start.
 *
 * The Secrets Store is opened alongside it and handed over as `secretValues`,
 * which is what turns "no secret reaches the transcript" from a pattern match
 * into an exact-value match. Both halves belong here for the same reason: the
 * mirror needs a filesystem and the store needs the keychain, and this is the
 * process that has both.
 *
 * `secretValues` is a function rather than a snapshot, and the store is
 * re-read before each save. That is what makes "without a restart" true from
 * the mirror's side as well: `bun run secret add` runs in a different process,
 * so a running varnick would otherwise redact against the secrets it knew at
 * launch and write the new one into the transcript verbatim. A refresh that
 * fails keeps the previous snapshot — every secret the last good read knew
 * about — because redacting against that beats refusing to save.
 *
 * A store that will not open at all is the other way round: the save rejects,
 * so `persistence.saveFailed` says so rather than a transcript being written
 * that nothing can promise is clean.
 */
export function hostCapabilities(input: HostCapabilitiesInput): HarnessCapabilities {
  const cloneRoot = input.cloneRoot
  let opened: Promise<{ store: SessionStore; secrets: SecretsStore }> | null = null

  function open() {
    opened ??= (async () => {
      const secrets = await openSecretsStore({ keychain: securityKeychain() })
      // Keyed by the clone root, so two roots on one machine are two
      // Workspaces with two transcripts rather than one file both append to —
      // see sessionMirrorRoot. The adoption that follows runs once per machine
      // and is what stops the change resuming an existing developer into an
      // empty conversation over a mirror that is not empty.
      const fs = nodeSessionFs()
      const root = sessionMirrorRoot(cloneRoot)
      await adoptLegacySessionMirror({ appDataRoot: appDataRoot(), mirrorRoot: root, fs })
      const store = createSessionStore({
        root,
        fs,
        secretValues: () => secrets.secretValues(),
      })
      return { store, secrets }
    })().catch((error: unknown) => {
      // Dropped rather than cached, so a RETRY_SAVE genuinely retries instead
      // of replaying the failure that happened once at open.
      opened = null
      throw error
    })
    return opened
  }

  /**
   * The Sandbox this process is holding, once it holds one.
   *
   * The gate for starting an agent, and the reason it is a variable rather than
   * a call: `establishSandbox()` is what makes the kernel restrictions real, and
   * an agent may only be started under restrictions that already exist. Null
   * here means no agent starts. There is no other branch.
   */
  let sandbox: EstablishedSandbox | null = null

  return {
    establishSandbox: async () => {
      // The root this runtime was launched for, passed rather than inherited.
      // It used to be no argument at all, which meant `process.cwd()` inside
      // sandbox.ts, which meant the directory the Tauri host had set from a
      // path compiled into the binary. Nothing in that chain was a decision.
      sandbox = await establishSandbox({ cloneRoot })
    },

    wrapAgentCommand: async () => {
      if (sandbox === null) {
        throw new Error(
          'The Sandbox is not established, so there is nothing to start an agent inside. varnick has no unconfined mode: check the sandbox first, and if that failed, the reason it gave is the thing to fix.',
        )
      }
      // The clone the Sandbox was established for, not one chosen here. A
      // command wrapped for one policy and run against another is the failure
      // this cannot be allowed to have.
      return sandbox.wrap(agentCommand({ cloneRoot: sandbox.cloneRoot }))
    },

    persist: async (input) => {
      const { store, secrets } = await open()
      await secrets.reload().catch(() => undefined)
      return store.persist(input)
    },

    // Reads do not reload the Secrets Store: redaction happens on the way in,
    // so what is on disk is already clean and nothing here can unredact it.
    readSession: async (sessionId) => (await open()).store.read(sessionId),

    readCommands: async () => {
      try {
        const raw = await readFile(commandsCachePath(input.cloneRoot), 'utf8')
        return normaliseCommands((JSON.parse(raw) as { commands?: unknown }).commands)
      } catch {
        // No cache, or one this build does not understand. Either way the menu
        // falls back to varnick's own commands until the first Turn.
        return []
      }
    },

    readSecretNames: async () => {
      const { secrets } = await open()
      // The same swallowed refresh `persist` does, for the same reason: a
      // keychain that would not answer this time leaves the previous snapshot
      // in place, and naming the secrets the last good read knew about beats
      // telling the agent there are none. A store that will not open *at all*
      // still throws, because that is a refusal the caller can distinguish
      // from an empty store — and an empty store is what "no secrets are
      // stored" means, which is a sentence this must not put in front of the
      // agent by accident.
      await secrets.reload().catch(() => undefined)
      return secrets.names()
    },

    listWorktrees: async () => listPendingWorktrees({ git: gitIn(cloneRoot), cloneRoot }),
    readFenceDiff: async (worktree) => fenceDiffOf(worktree, cloneRoot),
  }
}

/**
 * How long git gets before it counts as not answering.
 *
 * A bound rather than a policy on latency: `git` on a large repository is
 * quick, and a `git` that is waiting on a credential prompt or a lock is not
 * going to finish. The Rust host bounds the whole call at ninety seconds and
 * drops the runtime when it overruns, which would take the Sandbox with it — so
 * this fails first, and fails as a listing rather than as a dead process.
 */
const GIT_WAIT_MS = 20_000

/**
 * git, in one clone, reading only.
 *
 * The one impure half of the review list, kept here because this is the module
 * that is allowed to reach a process at all. Three properties are deliberate:
 *
 *   * **argv, never a shell.** `execFile` takes an array, so nothing in a branch
 *     name can become a command. Every argument is git's own output anyway (see
 *     ./worktrees.ts), and that is the second lock rather than the first.
 *   * **`-C <clone>` and not a working directory.** The runtime's cwd is set by
 *     the Rust host and is not the thing this is about; the clone is an input,
 *     the same way it is for the Sandbox and the mirror (ADR-0012).
 *   * **`GIT_OPTIONAL_LOCKS=0`.** A read must not take the index lock and must
 *     not refresh it: the agent may be running git in that clone at the same
 *     moment, and a review that blocked its subject would be a review nobody
 *     could run twice.
 *
 * Rejects with git's own stderr, which reaches `review.listFailed` as the
 * reason. Nothing secret can be in it — this process holds no credential, and
 * the commands read a repository.
 */
function gitIn(cloneRoot: string) {
  return (args: readonly string[]): Promise<string> =>
    new Promise((resolve, reject) => {
      execFile(
        'git',
        ['-C', cloneRoot, ...args],
        {
          timeout: GIT_WAIT_MS,
          // A branch that changed a thousand files is a long line of names and
          // nothing more; the default 1MB truncates it into a listing that
          // silently forgets what a worktree touched.
          maxBuffer: 32 * 1024 * 1024,
          env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' },
        },
        (error, stdout, stderr) => {
          if (error) {
            const said = stderr.trim()
            reject(new Error(said.length > 0 ? said : error.message))
            return
          }
          resolve(stdout)
        },
      )
    })
}

/**
 * What git says a Worktree has that the running varnick does not, filtered to
 * the Fence.
 *
 * Two commands, and the second one is not belt-and-braces. `git diff <live
 * HEAD>` shows tracked changes — committed and uncommitted — but says nothing
 * about a file that has never been added, so a fresh
 * `packages/harness/src/widen.ts` sitting in a worktree would produce an empty
 * diff and launch with no dialog at all. That hole is exactly the shape of the
 * thing the dialog exists to catch, which is why untracked files are
 * enumerated separately and rendered as added files.
 *
 * **The base is the live clone's `HEAD`, not the worktree's merge base.** The
 * question the developer is being asked is "what is different about the fence
 * between the varnick you are running and the one about to start", and that is a
 * comparison against what is checked out here — not against a fork point, which
 * would also show changes the live tree already has.
 *
 * A failure anywhere is an empty answer, and that is deliberate in the *unsafe*
 * direction, which is worth stating rather than hiding: a worktree whose diff
 * could not be taken launches without a dialog. The alternative is a dialog with
 * nothing in it, which asks the developer to approve bytes it cannot show them —
 * and approving bytes is the whole mechanism. A git that will not answer is a
 * broken machine rather than an attack, and the host still refuses every name
 * git did not report.
 */
async function fenceDiffOf(worktree: string, cloneRoot: string): Promise<string> {
  const git = async (cwd: string, args: readonly string[]): Promise<string | null> => {
    try {
      const run = Bun.spawn(['git', ...args], {
        cwd,
        stdout: 'pipe',
        stderr: 'ignore',
        stdin: 'ignore',
      })
      const text = await new Response(run.stdout).text()
      return (await run.exited) === 0 ? text : null
    } catch {
      return null
    }
  }

  const head = (await git(cloneRoot, ['rev-parse', 'HEAD']))?.trim()
  if (head === undefined || head === '') return ''

  const patch = await git(worktree, ['diff', head, '--'])
  const untracked = await git(worktree, ['ls-files', '--others', '--exclude-standard'])
  if (patch === null && untracked === null) return ''

  return fenceHunks({
    patch: patch ?? '',
    untracked: (untracked ?? '').split('\n').filter((path) => path.length > 0),
    readUntracked: (path) => {
      try {
        // Bounded on the way in as well as on the way out: an untracked file is
        // whatever size the agent made it, and this process reads it whole.
        return readFileSync(join(worktree, path), 'utf8').slice(0, UNTRACKED_PREVIEW_BYTES)
      } catch {
        return null
      }
    },
  })
}

/** A message, as much of one as the mirror stores. Nothing else crosses. */
function storedMessage(value: unknown): StoredMessage | null {
  const { id, role, text } = (value ?? {}) as Record<string, unknown>
  if (typeof id !== 'string' || typeof text !== 'string') return null
  if (role !== 'user' && role !== 'agent') return null
  // Rebuilt, not passed through: a sender that volunteered extra fields cannot
  // have them written into the transcript a developer later reads.
  return { id, role, text }
}

function storedMessages(value: unknown): readonly StoredMessage[] | null {
  if (!Array.isArray(value)) return null
  const messages: StoredMessage[] = []
  for (const entry of value) {
    const message = storedMessage(entry)
    if (message === null) return null
    messages.push(message)
  }
  return messages
}

/**
 * Answer one request.
 *
 * Returns what the caller gets as `ok`. Most calls have nothing to say beyond
 * having been done, and answer with an empty object — the bridge rebuilds every
 * answer, so a runtime that volunteered extra fields could not have them
 * forwarded anyway. A restore and a read of the secret names are the two calls
 * here with a payload, and neither payload can hold a secret value: a
 * transcript is redacted on the way in, and the names are the store's `names()`.
 *
 * Throws with the reason. Every throw here becomes a `refused` on the bridge,
 * carrying this message — which is the string `sandbox.unavailable` and
 * `persistence.saveFailed` have always rendered.
 */
async function answer(
  request: unknown,
  capabilities: HarnessCapabilities,
): Promise<Record<string, unknown>> {
  const kind = (request as { kind?: unknown } | null | undefined)?.kind

  switch (kind) {
    case 'check-sandbox':
      await capabilities.establishSandbox()
      // `{ ok: true }`, not `{}`. The bridge's okAnswer rejects anything else as
      // malformed, and an empty object here made every launch report the Sandbox
      // unavailable with a message blaming a version mismatch. Both sides' tests
      // agreed with themselves and disagreed with each other; nothing drove the
      // join until it was driven by hand.
      return { ok: true }

    case 'wrap-agent-command': {
      const { argv, env, cwd } = await capabilities.wrapAgentCommand()
      // Rebuilt rather than forwarded, like every other answer here: the host
      // gets argv, an overlay and a directory, and nothing a capability
      // volunteered alongside them.
      return { argv, env, cwd }
    }

    case 'persist-session': {
      const { sessionId, messages } = request as Record<string, unknown>
      if (typeof sessionId !== 'string') {
        throw new Error('A save needs a Session id, and this request carried none.')
      }
      const stored = storedMessages(messages)
      if (stored === null) {
        throw new Error(
          `The transcript for Session ${JSON.stringify(sessionId)} was not a list of messages the mirror can store.`,
        )
      }
      await capabilities.persist({ sessionId, messages: stored })
      return { ok: true }
    }

    case 'read-commands':
      return { commands: await capabilities.readCommands() }

    case 'read-session': {
      const { sessionId } = request as Record<string, unknown>
      if (typeof sessionId !== 'string') {
        throw new Error('A restore needs a Session id, and this request carried none.')
      }
      // The mirror, not the Agent SDK's own store: this is the copy that
      // survives a build the agent just broke, which is the case resume exists
      // for. See docs/adr/0009-resume-reads-the-mirror.md.
      return { ...restoredTranscript(await capabilities.readSession(sessionId)) }
    }

    case 'list-worktrees': {
      /*
        Rebuilt entry by entry like every other answer here, and this one has a
        reason of its own: the list carries names and counts, and the hunks are
        fetched for the one worktree a developer opens. A capability that
        volunteered a diff alongside a summary would put every branch's contents
        on this wire, which is the cost the summary exists to avoid.
      */
      const worktrees = await capabilities.listWorktrees()
      return {
        worktrees: worktrees.map((entry) => ({
          path: entry.path,
          branch: entry.branch,
          commits: entry.commits,
          changed: [...entry.changed],
          touchesFence: entry.touchesFence,
        })),
      }
    }

    case 'read-fence-diff': {
      const { worktree } = request as Record<string, unknown>
      if (typeof worktree !== 'string' || worktree.length === 0) {
        throw new Error('A fence diff needs the worktree to take it in, and this request named none.')
      }
      /*
        Asked by the host and by nothing else — it is absent from `route_of`,
        like `wrap-agent-command` and `read-secret-names`, because it is a step
        inside answering a Preview rather than a capability the renderer has.

        The answer is hunks git wrote and never a summary of them. ADR-0005
        found the reason and it survives its own supersession: approving a
        request means approving a sentence the agent wrote, and that sentence is
        exactly what prompt injection produces.
      */
      return { hunks: await capabilities.readFenceDiff(worktree) }
    }

    case 'read-secret-names': {
      // Rebuilt into a fresh array like every other answer here, so a
      // capability that volunteered something alongside the names could not
      // have it forwarded to the confined process.
      const names = await capabilities.readSecretNames()
      return { names: [...names] }
    }

    case 'read-credential':
      // Structural, not an oversight. The credential is read by the Tauri host,
      // which is the process that injects it into the agent subprocess; a
      // runtime that answered this would be a second process holding a secret.
      throw new Error(
        'The Harness runtime does not read the credential. The host reads it, and injects it into the agent subprocess — see src-tauri/src/credential.rs.',
      )

    default:
      throw new Error(
        `The Harness runtime was asked for ${JSON.stringify(String(kind))}, which it does not answer.`,
      )
  }
}

/**
 * One line in, one line out.
 *
 * The reply always carries the id it was called with, so the host can tell an
 * answer to its own call from a pipe that has lost its place — and a runtime
 * that could not read the call at all replies with `id: null` rather than
 * staying silent, which would hang the caller.
 *
 * `JSON.stringify` escapes newlines, so a reason with one in it cannot split a
 * reply across two lines and desynchronise the pipe. That is load-bearing: the
 * framing is "one reply per line" and nothing else enforces it. The other half
 * of that framing — reading calls back out of a stream of chunks — is
 * {@link readLines}, shared with the agent host's control channel.
 */
export async function answerHarnessLine(
  line: string,
  capabilities: HarnessCapabilities,
): Promise<string> {
  let id: number | null = null
  let request: unknown

  try {
    const call = JSON.parse(line) as { id?: unknown; request?: unknown }
    if (typeof call?.id !== 'number') {
      return `${JSON.stringify({ id: null, error: 'A call to the Harness runtime carried no id, so its answer could not be addressed.' })}\n`
    }
    id = call.id
    request = call.request
  } catch {
    return `${JSON.stringify({ id: null, error: 'A line reached the Harness runtime that was not a JSON call.' })}\n`
  }

  try {
    // Most answers are an empty object: the bridge rebuilds every answer, so
    // there is nothing for the runtime to say beyond having done it. The
    // exceptions are a restore, whose transcript *is* the answer;
    // `wrap-agent-command` — deliberately the one thing this process computes
    // for a spawn it does not perform; and `read-secret-names`, which is the
    // one question about the Secrets Store this process answers and answers
    // with names. A credential read never comes here.
    return `${JSON.stringify({ id, ok: await answer(request, capabilities) })}\n`
  } catch (error) {
    return `${JSON.stringify({ id, error: error instanceof Error ? error.message : String(error) })}\n`
  }
}

/**
 * Read calls from a stream of bytes and write replies.
 *
 * Calls are answered one at a time. The Sandbox is established once and the
 * mirror serialises its own saves, so concurrency here would buy latency in
 * exchange for two callers racing to establish the same sandbox.
 *
 * `capabilities` has no default any more. It used to fall back to
 * `hostCapabilities()`, and that default was one of the four hops that let the
 * clone root arrive without anybody choosing it — a caller who supplied nothing
 * got a runtime bound to whatever directory the process happened to be in. The
 * root is now an argument all the way down, so the capabilities are too, and
 * ./serve.ts is where it is resolved.
 */
export async function serveHarness(
  input: AsyncIterable<Uint8Array | string>,
  write: (reply: string) => void,
  capabilities: HarnessCapabilities,
): Promise<void> {
  await readLines(input, async (line) => {
    write(await answerHarnessLine(line, capabilities))
  })
}
