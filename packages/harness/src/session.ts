// The host-side Session mirror.
//
// A Session is persisted twice, deliberately: the Agent SDK keeps its own copy
// for resumption, and this mirror is what survives a build the agent just broke
// and what gives the UI something queryable. The two stores answer different
// questions, and a save that fails here is a different problem from a Turn that
// fails — which is why `persistence` is its own parallel region and not a field
// on the Turn (docs/adr/0007-state-decomposition-for-the-harness.md).
//
// Nothing here imports from `packages/core`. Dependency runs Core → Harness, so
// the message shape the mirror stores is declared below rather than borrowed.
//
// This module is host-side and stays that way. Core reaches the mirror through
// the bridge (./bridge.ts) and never imports this file, which is what lets it
// import `node:fs` like any other host module.

import fsp from 'node:fs/promises'

/** A message as the mirror stores it. Structurally what Core calls a `Message`,
 *  declared here because the Harness must not import Core. */
export interface StoredMessage {
  readonly id: string
  readonly role: 'user' | 'agent'
  readonly text: string
}

/**
 * The filesystem the mirror writes through.
 *
 * A port rather than a direct `node:fs` call, for two reasons. Tests supply a
 * real one over a temporary directory, so no test can write to the developer's
 * app-data directory by forgetting an argument. And the renderer has no
 * filesystem of its own: when a host bridge exists, it plugs in here without the
 * store learning anything about it.
 */
export interface SessionFs {
  /** File contents, or `null` when the file does not exist. */
  readFile(path: string): Promise<string | null>
  /** Append and flush. Must not resolve before the bytes are on the device. */
  appendFile(path: string, data: string): Promise<void>
  /** Replace the whole file in one step that a reader never observes half of. */
  replaceFile(path: string, data: string): Promise<void>
  /** Create the directory and any missing parent. */
  makeDir(path: string): Promise<void>
  /** Names of the entries in a directory; empty when it does not exist. */
  listDir(path: string): Promise<string[]>
}

export interface SessionStoreOptions {
  /** The directory holding one file per Session. Injected so tests never touch
   *  the real app-data directory. */
  root: string
  /**
   * Values that must never reach the mirror, read fresh on every write.
   *
   * A function rather than an array because the Secrets Store changes while
   * varnick runs; a snapshot taken when the store was constructed would mirror
   * every secret added after launch.
   */
  secretValues?: () => Iterable<string>
  fs?: SessionFs
}

export interface SessionStore {
  /** The file a developer can `cat`. Throws on a Session id that would escape
   *  the root. */
  pathFor(sessionId: string): string
  /** Write the transcript. The live `persistSession` actor's contract. */
  persist(input: {
    sessionId: string
    messages: readonly StoredMessage[]
  }): Promise<{ ok: true }>
  /** The transcript as the mirror holds it. Lines that do not parse are
   *  skipped — see the durability note below. */
  read(sessionId: string): Promise<StoredMessage[]>
  /** Every Session id the root holds. */
  list(): Promise<string[]>
}

export const REDACTED = '[redacted]'

/**
 * The transcript as a relaunch gets it back.
 *
 * Two fields because a restore has to answer two questions, and the second one
 * is only interesting because of what the write path does. The mirror is
 * redacted on the way in, so a restored message can read `[redacted]` where a
 * secret value was. That is not undone here and must not be: reading a secret
 * back onto the screen after deliberately keeping it off disk would defeat the
 * redaction, and a second unredacted copy kept to make a resume prettier would
 * be a durable plaintext secret store created for cosmetic reasons. What is
 * owed instead is honesty — `redacted` is what lets the surface say the
 * developer is looking at the record rather than at what they typed.
 */
export interface RestoredTranscript {
  readonly messages: readonly StoredMessage[]
  /** Whether the mirror kept something out of this transcript. */
  readonly redacted: boolean
}

/**
 * What a relaunch continues from.
 *
 * Deliberately nothing but the messages and that one flag. There is no partial
 * to fold in and no Turn state to restore, because the mirror is written at Turn
 * *boundaries* and `persist` accepts only complete messages — a Turn that was
 * still streaming when the process was killed left nothing on disk. The
 * transcript therefore ends at the last completed boundary, which is why a
 * Session resumed from it enters `turn.idle`: nothing is in flight, and nothing
 * observed a failure either. See
 * docs/adr/0009-resume-reads-the-mirror.md.
 */
export function restoredTranscript(
  messages: readonly StoredMessage[],
): RestoredTranscript {
  return {
    messages,
    redacted: messages.some((message) => message.text.includes(REDACTED)),
  }
}

/** The Tauri bundle identifier, from src-tauri/tauri.conf.json. */
const APP_IDENTIFIER = 'com.zabaca.varnick'

const FILE_SUFFIX = '.jsonl'

/**
 * Credential shapes redacted whether or not the host has ever seen the value.
 *
 * This is defence in depth, not the mechanism. The mechanism is `secretValues`:
 * an exact-value match cannot miss a secret the host holds. These patterns
 * catch the other case — a key the developer pasted into the chat, or one the
 * agent read out of a file and quoted back — which no exact-value list can
 * know about. They will not catch a credential with no recognisable shape, and
 * that limit is the reason the exact-value path exists.
 *
 * Every pattern is idempotent over its own output: `[redacted]` matches none of
 * them, so re-saving an already-written transcript produces identical bytes and
 * the mirror does not churn.
 */
const CREDENTIAL_PATTERNS: readonly RegExp[] = [
  // Private key blocks, whole.
  /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g,
  /\bsk-ant-[A-Za-z0-9_-]{16,}/g,
  /\bsk-[A-Za-z0-9]{20,}\b/g,
  /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}\b/g,
  /\bgithub_pat_[A-Za-z0-9_]{20,}\b/g,
  /\b(?:A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}\b/g,
  /\bAIza[0-9A-Za-z_-]{35}\b/g,
  /\bxox[abprs]-[A-Za-z0-9-]{10,}/g,
]

/** `Authorization: Bearer <token>` — the value only, so the shape stays legible. */
const BEARER_PATTERN = /\b([Bb]earer\s+)[A-Za-z0-9._~+/=-]{20,}/g

/**
 * An assignment to a name that announces itself as a secret.
 *
 * Deliberately narrow on the value — eight characters and no whitespace — so
 * that prose like "set ANTHROPIC_API_KEY to the one you stored" survives while
 * `ANTHROPIC_API_KEY=sk-...` does not.
 */
const ASSIGNMENT_PATTERN =
  /\b([A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[A-Za-z0-9_]*)(\s*[:=]\s*)(["']?)([^\s"']{8,})\3/gi

/**
 * Remove secret values from one piece of text.
 *
 * Exported because it is the mechanism the "no secret reaches the mirror" claim
 * rests on, and a claim that cannot be tested directly is a claim taken on
 * faith. Pure: same input, same output, no filesystem.
 */
export function redactSecrets(text: string, secrets: Iterable<string>): string {
  let out = text

  // Exact values first. This is the authoritative pass: a value the host holds
  // cannot be missed, whatever shape it has.
  for (const secret of secrets) {
    // An empty or whitespace-only entry would otherwise redact every character
    // boundary in the transcript.
    if (typeof secret !== 'string' || secret.trim().length === 0) continue
    out = out.split(secret).join(REDACTED)
  }

  for (const pattern of CREDENTIAL_PATTERNS) out = out.replace(pattern, REDACTED)
  out = out.replace(BEARER_PATTERN, (_m, prefix: string) => `${prefix}${REDACTED}`)
  out = out.replace(
    ASSIGNMENT_PATTERN,
    (_m, name: string, sep: string, quote: string) => `${name}${sep}${quote}${REDACTED}${quote}`,
  )

  return out
}

/**
 * A Session id has to be safe as a filename.
 *
 * Rejecting rather than sanitising: two ids that sanitise to the same name
 * would silently share a transcript, which is worse than a loud refusal.
 */
const SAFE_SESSION_ID = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

function assertSafeSessionId(sessionId: string): void {
  if (
    typeof sessionId !== 'string' ||
    !SAFE_SESSION_ID.test(sessionId) ||
    sessionId === '.' ||
    sessionId === '..' ||
    sessionId.includes('..')
  ) {
    throw new Error(
      `Refusing to mirror a Session under the id ${JSON.stringify(sessionId)} — a Session id must be letters, digits, dot, dash or underscore, so it cannot address a path outside the store.`,
    )
  }
}

function sameMessage(a: StoredMessage, b: StoredMessage): boolean {
  return a.id === b.id && a.role === b.role && a.text === b.text
}

function serialise(message: StoredMessage): string {
  // Field order fixed so two saves of the same message produce the same bytes.
  return JSON.stringify({ id: message.id, role: message.role, text: message.text })
}

function parseLine(line: string): StoredMessage | null {
  try {
    const value: unknown = JSON.parse(line)
    if (typeof value !== 'object' || value === null) return null
    const { id, role, text } = value as Record<string, unknown>
    if (typeof id !== 'string' || typeof text !== 'string') return null
    if (role !== 'user' && role !== 'agent') return null
    return { id, role, text }
  } catch {
    return null
  }
}

interface OnDisk {
  messages: StoredMessage[]
  /**
   * Whether the file is in a state an append can safely extend: every line
   * parsed, and the file ends on a line boundary. A half-written final line
   * makes this false, and the next save rewrites rather than appending after
   * the wreckage.
   */
  appendable: boolean
}

function decode(raw: string | null): OnDisk {
  if (raw === null || raw.length === 0) return { messages: [], appendable: true }

  const endsCleanly = raw.endsWith('\n')
  const lines = raw.split('\n').filter((line) => line.length > 0)
  const messages: StoredMessage[] = []
  let allParsed = true

  for (const line of lines) {
    const message = parseLine(line)
    if (message === null) allParsed = false
    else messages.push(message)
  }

  return { messages, appendable: endsCleanly && allParsed }
}

/**
 * The Session mirror over one directory.
 *
 * ## What a crash costs
 *
 * Two write paths, because the transcript is usually extended and occasionally
 * rewritten. Compaction replaces earlier messages with a summary and `/clear`
 * empties the transcript, and an append-only file would keep both versions.
 *
 * **Append**, when what is on disk is a prefix of what is being saved. New
 * messages are written in one `write` to a handle opened `O_APPEND` and flushed
 * with `fsync` before `persist` resolves.
 *
 * - *Survives:* the process being killed at any moment. Everything a resolved
 *   `persist` reported is on the device, and bytes already on disk are never
 *   rewritten, so an earlier Turn cannot be damaged by a later save.
 * - *Survives:* a crash partway through the write itself. The tail of that one
 *   write is lost and the reader skips the unparseable final line, so the cost
 *   is the messages in that save, never the transcript.
 * - *Does not survive:* power loss or a kernel panic, on hardware whose disk
 *   cache reports a flush it has not performed. `fsync` is the strongest thing
 *   this layer can ask for and it is not a guarantee about the device.
 * - *Does not survive:* losing the directory entry of a Session file created
 *   moments before a power cut — the directory itself is not flushed, so a
 *   brand-new file can vanish whole even though its contents were flushed.
 * - *Does not survive:* a second process writing the same Session. Saves are
 *   serialised within this store, not across processes. `O_APPEND` keeps two
 *   writers from overwriting each other's bytes, but nothing keeps them from
 *   interleaving two different transcripts.
 *
 * **Replace**, when history was rewritten. The new transcript is written whole
 * to a temporary file in the same directory, flushed, and `rename`d over the
 * old one.
 *
 * - *Survives:* a crash at any point. `rename` within a directory is atomic, so
 *   a reader sees either the complete old transcript or the complete new one and
 *   never a mixture. A crash before the rename leaves a stray temporary file and
 *   the previous transcript intact.
 * - *Does not survive:* the same power-loss and cross-process cases as above.
 *   Atomicity is not durability.
 */
export function createSessionStore(options: SessionStoreOptions): SessionStore {
  const fs = options.fs ?? nodeSessionFs()
  const root = options.root
  const secretValues = options.secretValues ?? (() => [])

  // Saves are serialised per store. Two overlapping saves both reading the file
  // before either wrote would each append the same message.
  let queue: Promise<unknown> = Promise.resolve()
  const serialised = <T>(work: () => Promise<T>): Promise<T> => {
    const run = queue.then(work, work)
    queue = run.then(
      () => undefined,
      () => undefined,
    )
    return run
  }

  const pathFor = (sessionId: string): string => {
    assertSafeSessionId(sessionId)
    return `${root}/${sessionId}${FILE_SUFFIX}`
  }

  const read = async (sessionId: string): Promise<StoredMessage[]> => {
    const raw = await fs.readFile(pathFor(sessionId))
    return decode(raw).messages
  }

  const persist: SessionStore['persist'] = (input) =>
    serialised(async () => {
      const path = pathFor(input.sessionId)
      const secrets = [...secretValues()]
      const wanted = input.messages.map((m) => ({
        id: m.id,
        role: m.role,
        text: redactSecrets(m.text, secrets),
      }))

      await fs.makeDir(root)
      const disk = decode(await fs.readFile(path))

      const extends_ =
        disk.appendable &&
        disk.messages.length <= wanted.length &&
        disk.messages.every((m, i) => {
          const candidate = wanted[i]
          return candidate !== undefined && sameMessage(m, candidate)
        })

      if (extends_) {
        const tail = wanted.slice(disk.messages.length)
        if (tail.length > 0) {
          await fs.appendFile(path, `${tail.map(serialise).join('\n')}\n`)
        } else if (disk.messages.length === 0) {
          // An empty Session still gets a file, so a developer looking for the
          // transcript finds an empty one rather than nothing at all.
          await fs.appendFile(path, '')
        }
        return { ok: true }
      }

      // History was rewritten — Compaction, or `/clear`. Replace, do not append.
      await fs.replaceFile(path, wanted.map((m) => `${serialise(m)}\n`).join(''))
      return { ok: true }
    })

  const list = async (): Promise<string[]> => {
    const entries = await fs.listDir(root)
    return entries
      .filter((name) => name.endsWith(FILE_SUFFIX))
      .map((name) => name.slice(0, -FILE_SUFFIX.length))
  }

  return { pathFor, persist, read, list }
}

/**
 * Where the mirror lives when varnick is running for real.
 *
 * The Tauri app-data directory, per platform, under the bundle identifier. Kept
 * out of `createSessionStore` on purpose: a store that defaulted to this would
 * let a test write to the developer's real transcripts by leaving an argument
 * out.
 */
export function defaultSessionRoot(): string {
  const env = globalThis.process?.env
  const platform = globalThis.process?.platform
  if (env === undefined || platform === undefined) {
    throw new Error(
      'The Session mirror has no app-data directory here — defaultSessionRoot() needs a host process, and the renderer has none. Pass an explicit root, or reach the store through the host.',
    )
  }

  const home = env.HOME ?? env.USERPROFILE ?? '.'
  const base =
    platform === 'darwin'
      ? `${home}/Library/Application Support`
      : platform === 'win32'
        ? (env.APPDATA ?? `${home}/AppData/Roaming`)
        : (env.XDG_DATA_HOME ?? `${home}/.local/share`)

  return `${base}/${APP_IDENTIFIER}/sessions`
}

/**
 * The filesystem as the host has it.
 *
 * `node:fs/promises` is imported statically. It used to be reached through a
 * dynamic import with a non-literal specifier, to hide it from the bundler:
 * Core's live actors imported this module directly, and a static Node built-in
 * would have been dragged into the renderer bundle. They do not any more — the
 * mirror is reached through the bridge, and this module is only ever loaded in
 * the Harness runtime, which is a host process by definition.
 */
export function nodeSessionFs(): SessionFs {
  return {
    async readFile(path) {
      try {
        return await fsp.readFile(path, 'utf8')
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null
        throw error
      }
    },

    async appendFile(path, data) {
      // O_APPEND, one write, then flush. The flush is what makes a resolved
      // save a claim about the device rather than about the page cache.
      const handle = await fsp.open(path, 'a')
      try {
        if (data.length > 0) await handle.write(data)
        await handle.sync()
      } finally {
        await handle.close()
      }
    },

    async replaceFile(path, data) {
      // Same directory, so the rename is a rename and not a copy across
      // filesystems — which would not be atomic.
      const temp = `${path}.${Date.now().toString(36)}${Math.trunc(Math.random() * 1e6).toString(36)}.tmp`
      const handle = await fsp.open(temp, 'w')
      try {
        if (data.length > 0) await handle.write(data)
        await handle.sync()
      } finally {
        await handle.close()
      }
      await fsp.rename(temp, path)
    },

    async makeDir(path) {
      await fsp.mkdir(path, { recursive: true })
    },

    async listDir(path) {
      try {
        return await fsp.readdir(path)
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') return []
        throw error
      }
    },
  }
}
