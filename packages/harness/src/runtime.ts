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
 */

import { agentCommand } from './agent.ts'
import { readLines } from './framing.ts'
import {
  establishSandbox,
  type EstablishedSandbox,
  type WrappedCommand,
} from './sandbox.ts'
import {
  createSessionStore,
  defaultSessionRoot,
  restoredTranscript,
  type SessionStore,
  type StoredMessage,
} from './session.ts'
import { openSecretsStore, securityKeychain, type SecretsStore } from './secrets.ts'

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
}

/**
 * The real capabilities, built once for the life of the process.
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
export function hostCapabilities(): HarnessCapabilities {
  let opened: Promise<{ store: SessionStore; secrets: SecretsStore }> | null = null

  function open() {
    opened ??= (async () => {
      const secrets = await openSecretsStore({ keychain: securityKeychain() })
      const store = createSessionStore({
        root: defaultSessionRoot(),
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
      sandbox = await establishSandbox()
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
  }
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
 * forwarded anyway. A restore is the one call here with a payload.
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
    // exceptions are a restore, whose transcript *is* the answer, and
    // `wrap-agent-command` — deliberately the one thing this process computes
    // for a spawn it does not perform. A credential read never comes here.
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
 */
export async function serveHarness(
  input: AsyncIterable<Uint8Array | string>,
  write: (reply: string) => void,
  capabilities: HarnessCapabilities = hostCapabilities(),
): Promise<void> {
  await readLines(input, async (line) => {
    write(await answerHarnessLine(line, capabilities))
  })
}
