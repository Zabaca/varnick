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
import {
  liveTreeIsDirty,
  mergeBriefing,
  RESTART_STILL_OWED,
  mergeWorktree,
  type CwdHolder,
  type MergeReport,
} from './merge.ts'
import {
  listPendingWorktrees,
  readPendingWorktreeDiff,
  type GitAttemptResult,
  type PendingWorktree,
} from './worktrees.ts'
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
   * Whether the tree those Worktrees would be merged *into* has uncommitted
   * work in it.
   *
   * Answered beside the listing rather than inside it, because it is a fact
   * about a different tree — the live one — and folding it into an entry would
   * put the same boolean on every row. It rides on the same call because it is
   * a fact about the same moment and git is already being run.
   *
   * It decides whether a merge control appears. The merge itself asks again, on
   * facts that are current; see `liveTreeIsDirty` in ./merge.ts, which is the
   * one definition both use.
   */
  liveTreeDirty(): Promise<boolean>
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
  /**
   * Everything one pending Worktree changed, as git printed it.
   *
   * The contents behind one row of the listing, read when a developer opens it,
   * and here for the same two reasons: it needs a subprocess, and it must not be
   * the agent's account of its own work. The list is what makes a branch
   * visible; this is what makes a widening inside one visible, so of the two
   * this is the one that must not be composed.
   *
   * `path` is a **selector against git's own listing**, not an argument git is
   * handed — the whole of that rule is in ./worktrees.ts, and a path matching no
   * pending worktree **throws** rather than reading something else.
   */
  readWorktreeDiff(path: string): Promise<string>
  /**
   * Land one pending Worktree on the live tree, and clear up after it.
   *
   * **The only capability on this whole surface that writes the developer's
   * clone**, and it is here rather than in the Rust host for the reason the
   * listing is: this is the process with git in reach. It is not a widening of
   * what the agent may do — the agent cannot reach this module, and the call
   * arrives from the renderer because a human clicked a control in a surface
   * `denyWrite` refuses the agent (ADR-0002, ADR-0014). The merge is still the
   * gate; what has gone is the context switch, not the decision.
   *
   * `path` is a selector against git's own listing, like the diff's. It refuses
   * a dirty live tree, a branch that will not go in, and a directory somebody is
   * standing in. See ./merge.ts, which sequences all of it.
   */
  mergeWorktree(path: string): Promise<MergeReport>
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

    listWorktrees: async () =>
      listPendingWorktrees({
        git: gitIn(cloneRoot),
        attempt: gitAttemptIn(cloneRoot),
        cloneRoot,
      }),

    liveTreeDirty: async () => liveTreeIsDirty(gitIn(cloneRoot)),
    readFenceDiff: async (worktree) => fenceDiffOf(worktree, cloneRoot),

    // The clone is this process's, as it is for the listing; the path names
    // which of the worktrees git reported in it. Nothing chooses the tree.
    readWorktreeDiff: async (path) =>
      readPendingWorktreeDiff({ git: gitIn(cloneRoot), cloneRoot, path }),

    mergeWorktree: async (path) =>
      mergeWorktree({
        git: gitIn(cloneRoot),
        attempt: gitAttemptIn(cloneRoot),
        holders: cwdHoldersOf,
        cloneRoot,
        path,
      }),
  }
}

/**
 * Which processes have a directory, or anything under it, as their cwd.
 *
 * `lsof -a -d cwd +D <path>`: `-d cwd` restricts the answer to working
 * directories rather than every open file, `+D` walks the tree so an agent
 * standing in a subdirectory is found, and `-F pcn` asks for the field-per-line
 * form so nothing has to be recovered from a column layout.
 *
 * **`lsof` exits non-zero routinely** — one unreadable path anywhere under the
 * directory is enough — so the exit code is not consulted at all. What matters
 * is whether it printed processes. A run that could not happen *does* throw,
 * and {@link mergeWorktree} treats that as "leave the directory alone": the
 * sentence this function's empty answer authorises is the deletion of a
 * directory, and a probe that did not run must never produce it.
 *
 * **This probe's own `lsof` is filtered out, by pid rather than by name.**
 *
 * It should never need to be. `execFile` inherits *this* process's working
 * directory — the clone root — and a Worktree is below that, not above it, so
 * `+D <worktree>` does not reach the probe itself. The filter is there for the
 * arrangement where that stops being true, which is one refactor away: a runtime
 * started in a Worktree, or a probe spawned with `cwd` set.
 *
 * It is a pid rather than a name because of what the wrong answer costs. Dropping
 * every process called `lsof` would also drop a developer's own — run in that
 * directory to find out what is holding it — and "nobody is in there" is the
 * sentence that authorises deleting a directory. There is exactly one process
 * this may ignore, so it is identified rather than described.
 */
async function cwdHoldersOf(path: string): Promise<readonly CwdHolder[]> {
  // Captured, not guessed. `-1` is no pid at all, so a spawn that never got one
  // filters nothing — and a probe that could not spawn rejects below anyway.
  let probe = -1
  const printed = await new Promise<string>((resolve, reject) => {
    const child = execFile(
      'lsof',
      ['-a', '-d', 'cwd', '-F', 'pcn', '+D', path],
      { timeout: GIT_WAIT_MS, maxBuffer: 8 * 1024 * 1024 },
      (error, stdout) => {
        const code = (error as NodeJS.ErrnoException & { code?: unknown } | null)?.code
        // A number is an exit status, which `lsof` uses to mean "something under
        // there could not be read" as often as it means anything. Anything else
        // — no binary, a timeout, a signal — is the probe not having run.
        if (error === null || typeof code === 'number') resolve(stdout)
        else reject(new Error(error.message))
      },
    )
    probe = child.pid ?? -1
  })

  const holders: CwdHolder[] = []
  let pid: number | null = null
  for (const line of printed.split('\n')) {
    if (line.startsWith('p')) {
      const parsed = Number.parseInt(line.slice(1), 10)
      pid = Number.isFinite(parsed) ? parsed : null
    } else if (line.startsWith('c') && pid !== null) {
      const command = line.slice(1)
      if (pid !== probe) holders.push({ pid, command })
      pid = null
    }
  }
  return holders
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
    gitAttemptIn(cloneRoot)(args).then((result) => {
      if (result.code === 0) return result.stdout
      const said = result.stderr.trim()
      throw new Error(said.length > 0 ? said : `git ${args[0]} exited ${result.code}.`)
    })
}

/**
 * The same git, answering with its exit code instead of rejecting on it.
 *
 * One command needs this and it is `merge-tree`, whose exit status is the fact
 * being asked for rather than a report about whether it ran — see `GitAttempt`
 * in ./worktrees.ts. {@link gitIn} is now written in terms of this rather than
 * beside it, so there is one place that decides how git is invoked in this
 * process and the two cannot drift on a timeout, a buffer size or a lock.
 *
 * **A process that could not be started at all still rejects.** `execFile`
 * reports a missing binary and a timeout through the same `error` argument as a
 * non-zero exit, and collapsing those into `{ code: 1 }` would make a git that
 * never ran indistinguishable from a merge that conflicts. So the exit code is
 * taken only when there is one, and everything else throws with what it said.
 */
function gitAttemptIn(cloneRoot: string) {
  return (args: readonly string[]): Promise<GitAttemptResult> =>
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
          if (error === null) {
            resolve({ code: 0, stdout, stderr })
            return
          }
          const code = (error as NodeJS.ErrnoException & { code?: unknown }).code
          if (typeof code === 'number') {
            resolve({ code, stdout, stderr })
            return
          }
          // No exit code: the binary is missing, the wait ran out, the process
          // was signalled. None of those is git's answer to anything.
          const said = stderr.trim()
          reject(new Error(said.length > 0 ? said : error.message))
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
 * **A failure anywhere throws, and the host then refuses the launch.** This was
 * written the other way first, returning `''` so that a diff which could not be
 * taken launched with no dialog, on the argument that the alternative is a
 * dialog with nothing in it — asking the developer to approve bytes it cannot
 * show them, when approving bytes is the whole mechanism.
 *
 * The premise is right and the conclusion does not follow: the alternative is
 * not an empty dialog, it is **refusing**. Empty and unknown are two facts and
 * only one of them is safe to render as "nothing to show". A git that will not
 * answer is indeed a broken machine rather than an attack — but this is the
 * single step between a confined agent and an unconfined one, a broken machine
 * is a rare, visible, fixable state, and the developer can still start the
 * Preview by hand. A gate that disappears when git is unwell is not a gate.
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

  /*
    A git that will not answer **throws**, and the host refuses the launch.

    Empty and unknown are two different facts and only one of them is safe to
    treat as "nothing to show": empty means this worktree's Fence is the Fence
    already running, and unknown means nobody can say. Returning `''` for both
    would make the dialog disappear exactly when the machine is in a state
    nobody understands, and this is the single step between a confined agent
    and an unconfined one.
  */
  const head = (await git(cloneRoot, ['rev-parse', 'HEAD']))?.trim()
  if (head === undefined || head === '') {
    throw new Error('git would not say what the live tree has checked out, so the Fence cannot be compared against it.')
  }

  const patch = await git(worktree, ['diff', head, '--'])
  const untracked = await git(worktree, ['ls-files', '--others', '--exclude-standard'])
  if (patch === null || untracked === null) {
    throw new Error('git would not say what this worktree changes, so whether it touches the Fence is unknown.')
  }

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

    case 'read-worktree-diff': {
      const { path } = request as Record<string, unknown>
      /*
        Refused rather than defaulted. There is no worktree this could sensibly
        be about when none was named, and picking one — the first pending, the
        most recent — would be the host deciding what a developer is reviewing.
      */
      if (typeof path !== 'string' || path.length === 0) {
        throw new Error('A diff is of one worktree, and this request named none.')
      }
      // Whether that path is one anybody may open is decided by ./worktrees.ts
      // against git's own listing, and a path that is not throws from there.
      return { diff: await capabilities.readWorktreeDiff(path) }
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
        // Asked in the same answer as the rows, because it is a fact about the
        // same moment: it decides whether any of them can be offered a merge.
        liveTreeDirty: await capabilities.liveTreeDirty(),
        worktrees: worktrees.map((entry) => ({
          path: entry.path,
          branch: entry.branch,
          commits: entry.commits,
          changed: [...entry.changed],
          touchesFence: entry.touchesFence,
          // Rebuilt a level down as well, for the reason the entry is: the
          // conflicted case carries a list, and a list forwarded by reference
          // is a list something else can still be holding.
          merge:
            entry.merge.kind === 'conflicts'
              ? { kind: entry.merge.kind, files: [...entry.merge.files] }
              : entry.merge.kind === 'unknown'
                ? { kind: entry.merge.kind, reason: entry.merge.reason }
                : { kind: entry.merge.kind },
        })),
      }
    }

    case 'merge-worktree': {
      const { path } = request as Record<string, unknown>
      /*
        Refused rather than defaulted, and harder than the diff's version of the
        same refusal. Picking a worktree when none was named would be the host
        choosing which branch to write into the developer's tree.
      */
      if (typeof path !== 'string' || path.length === 0) {
        throw new Error('A merge is of one Worktree, and this request named none.')
      }
      // Rebuilt field by field like every other answer here. `heldBy` is a list
      // and is copied for the reason the changed paths are: a list forwarded by
      // reference is a list something else can still be holding.
      const report = await capabilities.mergeWorktree(path)
      return {
        branch: report.branch,
        commit: report.commit,
        squashed: report.squashed,
        worktreeRemoved: report.worktreeRemoved,
        branchDeleted: report.branchDeleted,
        heldBy: report.heldBy.map((holder) => ({ pid: holder.pid, command: holder.command })),
        leftOver: report.leftOver,
        /*
          What to tell the agent, composed here and read by nobody on the way
          past.

          It rides the answer rather than being pushed from here because this
          process cannot reach the agent: the control channel belongs to the
          Rust host, which is the process that spawned it. So the host takes
          this string off the reply and writes it onto that pipe, composing
          nothing — the same division `describe-secrets` has, where the sentence
          is written in TypeScript and Rust only carries it.

          Core drops it. `mergeAnswer` in ./bridge.ts rebuilds the report field
          by field and this is not one of them, which is the ordinary rule here
          working in varnick's favour: the window has no use for a brief
          addressed to the agent.
        */
        briefing: mergeBriefing(report),
        /*
          And the half that stops being true. See {@link RESTART_STILL_OWED}: a
          Briefing has to survive the restart the band is about to recommend,
          and this sentence must not.
        */
        whileRunning: RESTART_STILL_OWED,
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
/**
 * The kinds that are a *wait* rather than an act.
 *
 * Each of these is re-asked for the life of the process — the host bounds every
 * one and answers "still nothing" when it expires — so tracing their successes
 * would write a line every fifteen seconds for ever and bury the calls somebody
 * is actually looking for.
 *
 * Their *failures* are still traced. A poll that fails is not noise; it is the
 * thing nobody would otherwise see.
 */
export const UNTRACED_KINDS = [
  'next-turn-event',
  'next-unprompted-event',
  'next-mint-event',
  'await-agent-exit',
] as const

/** Whether a successful call of this kind is worth a line. */
export function worthTracing(kind: string): boolean {
  return !(UNTRACED_KINDS as readonly string[]).includes(kind)
}

/**
 * The kind a call names, as a string safe to print.
 *
 * Read defensively and bounded, because this is untrusted input by the time it
 * reaches here — a line that is not a request at all still produces a trace, and
 * a trace is the one thing that must not fail.
 */
function kindOf(request: unknown): string {
  const kind = (request as { kind?: unknown } | null | undefined)?.kind
  return typeof kind === 'string' && kind.length > 0 ? kind.slice(0, 40) : '<no kind>'
}

/**
 * One line of trace for one call.
 *
 * ## The rule this exists under
 *
 * **The kind, never the payload.** These calls carry a pasted credential
 * (`store-credential`), a minted token, a developer's prompt and their pasted
 * images. A trace that logged requests would put every one of those in a file
 * the developer's terminal is writing, which is precisely what the whole product
 * is arranged to prevent — the credential never enters a transcript, a log line,
 * an error message or the Session mirror.
 *
 * So the only thing taken from the request is `kind`, which is a closed
 * vocabulary this codebase writes. The failure detail is a message this codebase
 * also composed, and the one place that could echo something foreign — git's own
 * stderr — is already quoted into those messages deliberately.
 *
 * ## Why it is always on
 *
 * The merge writes the developer's repository, and it did so with **no
 * observable trace anywhere**: no line in the runtime, none in the host, none in
 * git's reflog until a commit succeeds. When it did not happen, there was
 * nothing to read and nothing to distinguish "Core never sent it" from "the
 * runtime refused it" — which is a debugging session that has to guess.
 *
 * One line per act is cheap. The waits are filtered out above, so an idle
 * varnick writes nothing at all.
 */
export function traceLine(
  kind: string,
  outcome: 'ok' | 'failed' | 'refused',
  ms: number,
  detail?: string,
): string {
  // Bounded here as well as in `kindOf`, because this is the function that
  // formats and a caller is not a reason to trust an argument. A kind is a
  // closed vocabulary in every path that exists today; the cap is what keeps
  // that from being a thing to remember.
  const named = kind.slice(0, 40)
  const took = Number.isFinite(ms) && ms >= 0 ? `${Math.round(ms)}ms` : '?'
  const said = detail === undefined ? '' : ` — ${detail.split('\n')[0]?.slice(0, 200) ?? ''}`
  return `varnick runtime: ${named} ${outcome} in ${took}${said}\n`
}

export async function answerHarnessLine(
  line: string,
  capabilities: HarnessCapabilities,
  trace: (line: string) => void = () => {},
  now: () => number = () => Date.now(),
): Promise<string> {
  let id: number | null = null
  let request: unknown

  try {
    const call = JSON.parse(line) as { id?: unknown; request?: unknown }
    if (typeof call?.id !== 'number') {
      trace(traceLine('<no id>', 'refused', 0, 'the call carried no id'))
      return `${JSON.stringify({ id: null, error: 'A call to the Harness runtime carried no id, so its answer could not be addressed.' })}\n`
    }
    id = call.id
    request = call.request
  } catch {
    trace(traceLine('<not json>', 'refused', 0, 'the line was not a JSON call'))
    return `${JSON.stringify({ id: null, error: 'A line reached the Harness runtime that was not a JSON call.' })}\n`
  }

  const kind = kindOf(request)
  const started = now()

  try {
    // Most answers are an empty object: the bridge rebuilds every answer, so
    // there is nothing for the runtime to say beyond having done it. The
    // exceptions are a restore, whose transcript *is* the answer;
    // `wrap-agent-command` — deliberately the one thing this process computes
    // for a spawn it does not perform; and `read-secret-names`, which is the
    // one question about the Secrets Store this process answers and answers
    // with names. A credential read never comes here.
    const reply = `${JSON.stringify({ id, ok: await answer(request, capabilities) })}\n`
    if (worthTracing(kind)) trace(traceLine(kind, 'ok', now() - started))
    return reply
  } catch (error) {
    const said = error instanceof Error ? error.message : String(error)
    // Failures are always traced, including the long waits: a poll that *fails*
    // is not the noise the filter exists to suppress, it is the thing nobody
    // would otherwise see.
    trace(traceLine(kind, 'failed', now() - started, said))
    return `${JSON.stringify({ id, error: said })}\n`
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
  /*
    Where a trace goes. Injected rather than reached for, because stdout is the
    wire — anything written there that is not a reply desynchronises the pipe —
    and because a test that traced to the real stderr would print through the
    suite. ./serve.ts is the one caller that passes stderr.
  */
  trace: (line: string) => void = () => {},
): Promise<void> {
  await readLines(input, async (line) => {
    write(await answerHarnessLine(line, capabilities, trace))
  })
}
