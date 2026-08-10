// Domain types and pure helpers. No framework, no XState, no React.

/** Where the agent's credential came from. */
export type CredentialSource = 'keychain' | 'env'

/**
 * What the agent's credential is: an Anthropic API key, or a Claude
 * subscription token minted by `claude setup-token`.
 *
 * Decided by the host from what it resolved, never configured — ADR-0011. It
 * decides which variable the agent is spawned with, and that is the whole of
 * what it decides. Orthogonal to the source: either kind can come from either
 * store.
 */
export type CredentialKind = 'api-key' | 'subscription'

/**
 * Everything Core learns from a successful read.
 *
 * Two facts, and neither is the value. This is the whole of what crosses the
 * bridge — see packages/harness/src/credentials.ts, where the same shape is
 * narrowed out of whatever the host answered.
 */
export interface CredentialReading {
  readonly source: CredentialSource
  readonly kind: CredentialKind
}

export interface Credential extends CredentialReading {
  /** Never the value itself — Core only ever needs to know one exists. */
  readonly present: true
}

/** Why the Harness refused to start the agent. Shown, not swallowed. */
export type StartRefusal =
  | { kind: 'no-credential' }
  | { kind: 'credential-rejected'; detail: string }
  | { kind: 'sandbox-unavailable'; detail: string }

export interface SandboxPolicy {
  /** Paths the agent may not write. Core, build config, package scripts. */
  readonly denyWrite: readonly string[]
  /** Hosts the agent may reach. Every entry is an exfiltration path. */
  readonly allowedHosts: readonly string[]
  /**
   * Paths the agent may not read: the home directory, the machine-wide
   * keychains, and four binaries. Read only — three of the four binaries still
   * execute. See UNREADABLE_BINARIES in the Harness.
   */

  readonly denyRead: readonly string[]
}

/**
 * One Worktree holding Core changes nobody has merged.
 *
 * **Produced by running git, host-side.** Not by the agent, and the distinction
 * is the whole point of the surface this feeds: it is the mechanism that shows
 * what the agent changed, and a report the agent composes is a report the agent
 * can shade. See packages/harness/src/worktrees.ts, which runs the three
 * read-only commands, and ADR-0014.
 *
 * A summary rather than a diff. `changed` is path names and nothing else, and
 * there is deliberately no field for a hunk: a list that read every diff of
 * every branch would spend the whole of a large branch before drawing a row,
 * and the list is what a developer reads to decide which branch to open. The
 * contents are fetched for the one they opened.
 *
 * Spelled out here rather than imported from the Harness, like
 * {@link CredentialReading} and {@link SandboxPolicy} above: Core owns the shape
 * it renders, the bridge rebuilds what the host answered into it, and the
 * dependency runs Core -> Harness rather than both ways.
 */
export interface PendingWorktree {
  /** Where it is on disk, absolute, as git reports it. */
  readonly path: string
  /** Short branch name, or `null` for a detached HEAD. */
  readonly branch: string | null
  /**
   * Commits this worktree has that the live tree does not.
   *
   * Always at least one, because a worktree at zero is not pending — it is an
   * agent that has started rather than one that has finished, and it is left
   * out of the list rather than shown with a zero on it.
   */
  readonly commits: number
  /** Repository-relative paths changed since the branch diverged. Names only. */
  readonly changed: readonly string[]
  /**
   * Whether any changed path is Fence.
   *
   * The field the next ticket turns into colour. Decided by one pure function
   * in the Harness — `isFencePath` — because three separate things key off the
   * same list: this row, the Preview dialog, and the diff view's highlighting.
   * Three glob lists would drift, and the drift is invisible until the one that
   * fell behind stops raising a dialog for a file the others still colour.
   */
  readonly touchesFence: boolean
  /**
   * Whether it will land, and what stands in the way when it will not.
   *
   * A **fact carried on the entry**, the way `touchesFence` is, and for the same
   * reason: it is git's answer at the moment the listing was made, not something
   * with a lifetime of its own. It goes stale as soon as either side moves,
   * which is what the end-of-Turn refresh is for.
   *
   * The surface reads it to decide what to offer. A `fast-forward` or a `clean`
   * entry can be merged from the window; a `conflicts` entry names its files and
   * offers nothing, because resolving somebody else's branch is not this
   * application's job — the agent merges `main` down into the worktree, where it
   * may write and where it has the context.
   */
  readonly merge: Mergeability
}

/**
 * Whether a branch will land, and what stands in the way when it will not.
 *
 * Spelled out here rather than imported from the Harness, like
 * {@link PendingWorktree} that carries it: Core owns the shape it renders.
 * `packages/harness/src/worktrees.ts` has the same union and the argument for
 * each of its four members; the short version is that `unknown` exists because
 * `merge-tree` distinguishes *conflicted* from *broken* by exit code, and
 * collapsing the second into either of the first two would put a merge control
 * over an answer nobody gave.
 */
export type Mergeability =
  | { readonly kind: 'fast-forward' }
  | { readonly kind: 'clean' }
  | { readonly kind: 'conflicts'; readonly files: readonly string[] }
  | { readonly kind: 'unknown'; readonly reason: string }

/** One process standing in a Worktree that was about to be removed. */
export interface CwdHolder {
  readonly pid: number
  readonly command: string
}

/**
 * What a merge did, once it has been done.
 *
 * Spelled out here rather than imported from the Harness, like everything else
 * Core renders. `packages/harness/src/merge.ts` has the same shape and the
 * argument for each field; the one worth repeating is `leftOver`, because it is
 * the reason this is a report rather than a boolean.
 *
 * **A merge that landed and a cleanup that could not finish is a success**, not
 * a failure. The commit is on the live branch either way, so reporting it as a
 * failure would invite a second merge of a branch that has already gone in. What
 * is owed instead is a sentence about the directory still on disk, which is what
 * `leftOver` is.
 */
export interface MergeReport {
  /** The branch that landed, or the commit it was on when it had no branch. */
  readonly branch: string
  /** The squash commit on the live branch, abbreviated as git abbreviates it. */
  readonly commit: string
  /** How many of the branch's commits went into that one. */
  readonly squashed: number
  readonly worktreeRemoved: boolean
  readonly branchDeleted: boolean
  /** Who is standing in the Worktree, when that is why it is still there. */
  readonly heldBy: readonly CwdHolder[]
  /** What is left to do by hand, printed verbatim, or `null` when nothing is. */
  readonly leftOver: string | null
}

/** A Surface as discovered on disk, before anything tries to load it. */
export interface SurfaceDescriptor {
  readonly id: string
  readonly name: string
  readonly modulePath: string
}

export type MessageRole = 'user' | 'agent'

export interface Message {
  readonly id: string
  readonly role: MessageRole
  readonly text: string
  /**
   * How many pictures went with this message.
   *
   * A count, not the bytes. The transcript has to record that a screenshot was
   * sent — a message reading "what is wrong here?" with nothing beside it is a
   * transcript that lies about the conversation — but the mirror's whole virtue
   * is that `cat` and `jq` read it, and megabytes of base64 per message ends
   * that. Absent rather than `0` for the overwhelming majority that carry none.
   */
  readonly attachments?: number
  /**
   * Why the agent said this, when nobody asked it to.
   *
   * Present only on an answer the developer did not prompt — a subagent
   * finishing, a background command's output. It renders as the divider above
   * the message, because **an answer with no visible cause reads as the agent
   * talking to itself**, and a developer who cannot tell why it started
   * talking cannot tell whether to trust it.
   *
   * Read off the message stream host-side and carried through unchanged.
   * Absent for every prompted message, which is almost all of them: the prompt
   * above it is its cause.
   */
  readonly cause?: string
}

/**
 * The conversation after a Compaction, built from the one before it.
 *
 * A pure function returning a new transcript, and that shape is the point
 * rather than a style preference. `CONTEXT.md` defines **Compaction** as
 * replacing earlier messages with a summary, and names what it must not be
 * confused with — *truncate, prune (both lose the fact that nothing is
 * discarded blindly)*. A rewrite performed step by step over the live
 * transcript can fail halfway and leave exactly that: a conversation partly
 * discarded, behind a `turn.idle` that says nothing happened. Built as a value,
 * the replacement either exists whole or does not exist, and the only way it
 * reaches the Session is as the actor's result.
 *
 * The summary is the Session's own — the text its compaction produced, not
 * anything composed here. What is composed here is the one line above it,
 * because a summary rendered as an ordinary agent message is indistinguishable
 * from an answer: a developer scrolling back would read varnick's account of
 * their conversation as something the agent said in it. The line names the
 * count, which is the fact the transcript can no longer show for itself.
 */
export function compactedTranscript(previous: readonly Message[], summary: string): Message[] {
  const replaced = previous.length === 1 ? '1 earlier message' : `${previous.length} earlier messages`
  return [
    {
      // `m1`, so the ids the Session hands out next — `m${length + 1}` — carry
      // on from the summary rather than colliding with it.
      id: 'm1',
      role: 'agent',
      text: `⟲ Compacted — ${replaced}, summarised.\n\n${summary}`,
    },
  ]
}

/**
 * The conversation varnick continues when it launches.
 *
 * One name, fixed, because varnick runs one Session. The mirror can hold
 * several files — the `#/states` cards write under their own ids, and an id
 * that has since changed leaves its transcript behind — but none of them is a
 * candidate: resume asks the store for the Session it is about to run and never
 * searches. Picking "the most recently written" would be inventing a way to
 * choose between conversations, and there is no term for a set of Sessions in
 * CONTEXT.md because the product has no such thing. When it grows one, the
 * selection is that feature's decision to make, not a rule left behind by this
 * one.
 *
 * The literal lives here rather than in the machine's default so that the id
 * the app resumes and the id the app runs cannot drift into two strings.
 */
export const LIVE_SESSION_ID = 'session-1'

/**
 * Read one region out of a parallel machine's state value.
 *
 * A parallel state value is a record of region name to value, and the value may
 * itself be a nested record. Returns a dotted path either way.
 */
export function regionOf(value: unknown, region: string): string {
  const raw = (value as Record<string, unknown> | undefined)?.[region]
  if (typeof raw === 'string') return raw
  if (raw && typeof raw === 'object') {
    const key = Object.keys(raw)[0]
    if (key === undefined) return ''
    const tail = (raw as Record<string, unknown>)[key]
    return typeof tail === 'string' ? `${key}.${tail}` : key
  }
  return ''
}

/** The predicate the START guard uses. Exported so the UI can read the same
 *  rule rather than binding to `can()`, which a fallback transition makes
 *  permanently true. */
export function canStartAgent(input: {
  credential: string
  sandbox: string
}): boolean {
  return input.credential === 'present' && input.sandbox === 'available'
}

/*
  `hasPlanUsage` was here, gating a plan-usage strip and the `subscription`
  region that fed it. Both are gone, and the predicate went with them rather
  than being kept for a caller that might return.

  It answered "is this credential a subscription", which was never the question
  the strip needed. The question was "does this credential report rolling
  windows", and the answer measured under a `claude setup-token` credential —
  the only subscription varnick can hold — is no: `subscription_type: null`,
  `rate_limits_available: false`, `rate_limits: null`. Claude Code treats such a
  session as API authentication, not as a plan. So the predicate said yes in a
  configuration where no figure existed, and the region it gated could only ever
  sit in `unread`. See ADR-0011 and ticket 31.
*/

/**
 * Whether there is an agent to answer a message.
 *
 * **The rule that stops a message being recorded with nothing alive to answer
 * it.** Measured: an agent host exited on a terminal error while the Tauri host
 * and the Harness runtime stayed up, so the runtime went on writing the Session
 * mirror — and a message typed afterwards was appended to the transcript, saved,
 * and answered by nobody. The transcript is the thing a developer trusts most on
 * this screen, and a message in it that no process ever received is the one
 * entry it must not contain.
 *
 * A predicate here rather than a guard on the Session, because the two facts
 * belong to two machines and neither may learn the other's internals: whether
 * there is an agent process is the Harness's, and the draft is the Session's.
 * The surface holds both snapshots and is the only place they meet — which is
 * the same arrangement `canStartAgent` has, and the reason both live here where
 * `drive.ts` can reach them (ADR-0001, ADR-0013).
 *
 * **Only `running`.** `starting` is a process that is being spawned and cannot
 * be written to yet, and the honest thing to do with a message typed into that
 * second is to keep the draft and let the developer press send again — not to
 * record it against a process that does not exist. Nothing is lost either way:
 * refusing leaves the text in the composer.
 */
export function agentCanAnswer(agentState: string): boolean {
  return agentState === 'running'
}

/**
 * What a pending row says about merging, and whether it offers to.
 *
 * One function, three readers: the guard that decides whether the machine will
 * accept `MERGE_WORKTREE`, the badge on the row, and the note under the list
 * that tells a developer what to do about a branch that will not go in. The
 * same arrangement as {@link canStartAgent} and for the same reason — the
 * affordance and the rule must not be two pieces of code that agree today.
 *
 * It is here rather than in components/worktree-review.tsx because that file
 * cannot be imported outside Vite, so a branch written inside it is a branch
 * `drive.ts` cannot reach (ADR-0001, ADR-0013). The words are part of the
 * decision and not a decoration on it: "conflicts" without the files is not
 * actionable, and the sentence naming whose job the fix is *is* the product
 * requirement — see `.claude/skills/change-core/SKILL.md`.
 */
export interface MergeSummary {
  /** What the row says, in three or four words. */
  readonly says: string
  /**
   * Whether the window will merge it.
   *
   * `fast-forward` and `clean` do. `conflicts` deliberately does not, and
   * neither does `unknown`: a control over an answer nobody gave is worse than
   * no control, because it reads as varnick having checked.
   */
  readonly offered: boolean
  /**
   * Whether this is the ordinary case or the build admitting something.
   *
   * `warn` on the two that are not ordinary, `quiet` on the two that are —
   * most branches merge, and a colour spent on the normal case stops meaning
   * anything on the screen where colour means Fence.
   */
  readonly tone: 'quiet' | 'warn'
  /** The conflicted paths, empty for every other answer. */
  readonly files: readonly string[]
  /** What to do about it, or `null` when there is nothing to do. */
  readonly advice: string | null
}

export function mergeSummary(merge: Mergeability): MergeSummary {
  switch (merge.kind) {
    case 'fast-forward':
      return { says: 'fast-forward', offered: true, tone: 'quiet', files: [], advice: null }
    case 'clean':
      return { says: 'merges cleanly', offered: true, tone: 'quiet', files: [], advice: null }
    case 'conflicts':
      return {
        says: `conflicts in ${merge.files.length} file${merge.files.length === 1 ? '' : 's'}`,
        offered: false,
        tone: 'warn',
        files: merge.files,
        /*
          The instruction, not an apology. varnick builds no conflict resolver
          and this sentence is why: the agent may write inside the worktree, it
          wrote the branch, and it is the only party that knows what it meant.
          A developer hand-resolving somebody else's branch inside a review tool
          is guessing at reasoning they do not have.
        */
        advice: `Ask the agent to merge main down into that worktree and hand back a fast-forward — it can write there, and it knows what it meant. Conflicts in ${merge.files.join(', ')}.`,
      }
    case 'unknown':
      return {
        says: 'mergeability unknown',
        offered: false,
        tone: 'warn',
        files: [],
        advice: `git could not say whether this merges: ${merge.reason}`,
      }
  }
}

export function refusalFor(input: {
  credential: string
  sandbox: string
}): StartRefusal {
  if (input.credential === 'rejected')
    return { kind: 'credential-rejected', detail: 'The stored credential was rejected.' }
  if (input.credential !== 'present') return { kind: 'no-credential' }
  return { kind: 'sandbox-unavailable', detail: 'sandbox-runtime could not be established.' }
}

/**
 * A draft is addressing the command menu while some command name still starts
 * with what has been typed.
 *
 * The first version closed the menu at the first space, which was right when
 * every command was one word and wrong the moment `/model sonnet-5` existed —
 * you could never filter past `/model `. Asking whether anything still matches
 * handles both: `/model son` keeps the menu, `/model sonnet-5 ` closes it
 * because the trailing space matches no name, and `/clear everything` closes it
 * for the same reason.
 */
export function isCommandDraft(draft: string, names: readonly string[]): boolean {
  if (!draft.startsWith('/')) return false
  const typed = draft.slice(1).toLowerCase()
  return typed === '' || names.some((name) => nameAnswers(name, typed))
}

/**
 * Whether a name answers what has been typed, by the menu's own rule.
 *
 * **Shared with the matcher on purpose.** The machine decides whether the menu
 * is open and {@link matchCommands} decides what is in it, and they used two
 * different rules: the machine asked whether a name *starts with* the draft
 * while the matcher would also match inside one. Every plugin-qualified command
 * fell through the gap — `mattpocock-skills:grill-with-docs` is not found by
 * `/grill`, so the menu closed on the keystroke that should have found it, and
 * the list the matcher would have returned was never rendered.
 *
 * The two-character floor is the matcher's, for the matcher's reason: one
 * character is inside half the names, so a single letter matching everything
 * makes the first keystroke of a hunt widen the list.
 */
function nameAnswers(name: string, typed: string): boolean {
  const bare = name.startsWith('/') ? name.slice(1).toLowerCase() : name.toLowerCase()
  return bare.startsWith(typed) || (typed.length >= 2 && bare.includes(typed))
}

/*
  ---------------------------------------------------------------------------
  The command menu

  Ported from the sibling `forge` service, whose rules were each learned from a
  live runtime rather than reasoned out. varnick's menu was thirteen commands it
  wrote itself, filtered by one `startsWith`; the runtime it talks to has
  skills, plugins and the CLI's own commands, and none of them had ever appeared
  in it.
  ---------------------------------------------------------------------------
*/

/**
 * One row in the menu, whoever it belongs to.
 *
 * Names are bare — `compact`, not `/compact` — because that is how the runtime
 * reports them and the slash is presentation. {@link commandLabel} puts it back.
 *
 * `source` is not decoration. A varnick command is an event this window sends
 * and a guard decides whether it is offered; an agent command is text the
 * Session runs. They are two different mechanisms sharing one list, and the
 * distinction has to survive to the point where one is picked.
 */
export interface MenuCommand {
  readonly name: string
  readonly description: string
  readonly argumentHint: string
  readonly aliases?: readonly string[]
  readonly source: 'varnick' | 'agent'
  /**
   * Only varnick's rows have one; an agent command is sent, not run.
   *
   * Takes whatever was typed after the name, which is empty for most of them.
   * `/effort` and `/model` are the two that read it — they were one row per
   * value until the list grew, and eight rows for two settings is a menu
   * describing its own implementation rather than the thing you wanted.
   */
  readonly run?: (argument: string) => void
}

/** What a command is called on screen. */
export function commandLabel(command: MenuCommand): string {
  return `/${command.name}`
}

/**
 * One row per name, with varnick's own winning.
 *
 * Two things this settles, and the second is the reason it is a function rather
 * than a spread.
 *
 * **A name can arrive twice from the runtime alone.** forge observed
 * `caveman:caveman` coming back both as a command, carrying its argument hint,
 * and as the skill of the same name, carrying a paragraph and no hint. Two rows
 * under one name asks you to choose between two things that are the same thing.
 * Merged rather than dropped, because each copy knows something the other does
 * not: the hint from whichever has one, the longest description, aliases unioned.
 *
 * **And a name can collide across the two sources.** `/compact` is varnick's
 * Compaction — a machine state that can fail and says so — and it is also a CLI
 * command that would be sent as text. varnick's wins, because a developer
 * typing `/compact` in this window means the one this window implements.
 */
export function mergeCommands(commands: readonly MenuCommand[]): readonly MenuCommand[] {
  const byName = new Map<string, MenuCommand>()
  for (const command of commands) {
    const seen = byName.get(command.name)
    if (seen === undefined) {
      byName.set(command.name, command)
      continue
    }
    // The first varnick entry for a name is final. Nothing an agent reports can
    // replace a control this window owns, or take its `run` away.
    if (seen.source === 'varnick') continue
    if (command.source === 'varnick') {
      byName.set(command.name, command)
      continue
    }
    const aliases = [...new Set([...(seen.aliases ?? []), ...(command.aliases ?? [])])]
    byName.set(command.name, {
      ...seen,
      description:
        command.description.length > seen.description.length ? command.description : seen.description,
      argumentHint: seen.argumentHint || command.argumentHint,
      ...(aliases.length > 0 ? { aliases } : {}),
    })
  }
  return [...byName.values()]
}

/**
 * How well a command answers a query, lowest first. `null` when it does not.
 *
 * Two rules here are the difference between a filter that narrows and one that
 * widens, and both were found by using forge's rather than by thinking about it:
 *
 * **Aliases match exactly and never by prefix.** `/usage` carries the alias
 * `cost`, so a prefix rule makes a lone `c` drag it in beside `compact` and
 * `clear` — the first keystroke of a hunt returning *more* than the last.
 *
 * **Substrings count only from two characters.** A single letter is inside half
 * the names and all of the descriptions; `c` found `mem-search`.
 */
function rankOf(command: MenuCommand, query: string): number | null {
  const name = command.name.toLowerCase()
  if (name === query) return 0
  if (command.aliases?.some((alias) => alias.toLowerCase() === query)) return 1
  if (name.startsWith(query)) return 2
  if (query.length < 2) return null
  if (name.includes(query)) return 3
  if (command.description.toLowerCase().includes(query)) return 4
  return null
}

/**
 * The commands a query means, best first.
 *
 * An empty query is everything, in the order it was given. **A query nothing
 * answers is nothing** — not the full list. A filter that falls back to
 * everything on no match tells you a command exists when it does not, which is
 * the one lie a discovery surface must not tell.
 */
export function matchCommands(
  commands: readonly MenuCommand[],
  query: string,
): readonly MenuCommand[] {
  const wanted = query.toLowerCase()
  if (wanted === '') return commands

  return commands
    .map((command, index) => ({ command, index, rank: rankOf(command, wanted) }))
    .filter((scored): scored is { command: MenuCommand; index: number; rank: number } => scored.rank !== null)
    .sort((a, b) => a.rank - b.rank || a.index - b.index)
    .map((scored) => scored.command)
}

/**
 * The command a draft has already chosen, while its arguments are still blank.
 *
 * **The gap the menu leaves behind.** Accepting `/agents` closes the menu —
 * correctly, the command is settled — and closes the argument list with it. So
 * the single moment you need to know it takes `[name]` is the moment nothing on
 * screen says so.
 *
 * `null` once an argument has been typed: by then you are answering the
 * question rather than asking it. `null` too for a command that takes nothing,
 * because a signature bar with no signature in it is a row that says nothing.
 */
export function signatureFor(
  commands: readonly MenuCommand[],
  draft: string,
): MenuCommand | null {
  const named = /^\/(\S+)\s?$/.exec(draft)?.[1]?.toLowerCase()
  if (named === undefined) return null

  const found = commands.find(
    (command) =>
      command.name.toLowerCase() === named ||
      command.aliases?.some((alias) => alias.toLowerCase() === named),
  )
  return found?.argumentHint ? found : null
}

/**
 * What accepting a command puts in the composer.
 *
 * The trailing space is the whole decision: a command that takes an argument
 * leaves you mid-sentence, and one that does not is finished — so the next
 * Enter sends it rather than adding a space nobody wanted.
 */
export function completionFor(command: MenuCommand): string {
  return `${commandLabel(command)}${command.argumentHint ? ' ' : ''}`
}

/**
 * The command a draft invokes, if any.
 *
 * Sending is how a command runs: `/clear` typed and sent runs the command
 * rather than posting the word. Anything that does not name a known command is
 * an ordinary message, including a half-typed `/cl`.
 *
 * Names may contain spaces — `/effort xhigh` is one command, not a command and
 * an argument — so the longest matching name wins. Matching the first word
 * would resolve `/effort xhigh` to a bare `/effort` that means something else.
 */
/**
 * What was typed after the command's name.
 *
 * The whole of the argument parsing, and it is one line because the menu does
 * the rest: {@link signatureFor} shows the values a command takes for exactly
 * as long as the argument is blank, so nothing here has to explain itself when
 * it does not recognise one.
 */
export function commandArgument(draft: string, name: string): string {
  return draft.trim().slice(name.length).trim()
}

export function invokedCommand(draft: string, names: readonly string[]): string | null {
  const text = draft.trim()
  let best: string | null = null
  for (const name of names) {
    if (text !== name && !text.startsWith(`${name} `)) continue
    if (best === null || name.length > best.length) best = name
  }
  return best
}

/** Effort levels the Agent SDK accepts, cheapest first. */
export const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max'] as const
export type Effort = (typeof EFFORTS)[number]

/**
 * Models this session can run on.
 *
 * Real ids, because a picker offering something the API would reject is the
 * same class of lie as a status line reporting on a timer.
 */
export const MODELS = [
  { id: 'claude-opus-5', label: 'opus-5' },
  { id: 'claude-sonnet-5', label: 'sonnet-5' },
  { id: 'claude-haiku-4-5', label: 'haiku-4.5' },
] as const
export type ModelId = (typeof MODELS)[number]['id']

/** Context window per model, in tokens. */
export const CONTEXT_WINDOW: Record<ModelId, number> = {
  'claude-opus-5': 1_000_000,
  'claude-sonnet-5': 1_000_000,
  'claude-haiku-4-5': 200_000,
}

/** `12.4k/1M (1%)` — the shape Claude Code uses. */
export function formatContext(used: number, total: number): string {
  const short = (n: number) =>
    n >= 1_000_000
      ? `${+(n / 1_000_000).toFixed(n % 1_000_000 === 0 ? 0 : 1)}M`
      : n >= 1_000
        ? `${+(n / 1_000).toFixed(n % 1_000 === 0 ? 0 : 1)}k`
        : String(n)
  const pct = total > 0 ? Math.round((used / total) * 100) : 0
  return `${short(used)}/${short(total)} (${pct}%)`
}

/**
 * `1m12s · 34k · 9 tools` — how far along one subagent is.
 *
 * Pure and here rather than in the component, so the states page and `drive.ts`
 * can assert the shape without rendering anything.
 *
 * **A field that has not been reported is left out rather than shown as zero.**
 * A subagent that has just started has genuinely used no tools, and `0 tools`
 * beside a spinner reads as a task that is stuck; an absent field reads as one
 * that has not said yet, which is the truth. Elapsed is always shown, because a
 * task that started has been running for some length of time even if nobody has
 * measured it — that one is honestly zero.
 */
export function taskMeter(task: {
  readonly tokens: number
  readonly toolUses: number
  readonly elapsedMs: number
}): string {
  const seconds = Math.round(task.elapsedMs / 1_000)
  const elapsed =
    seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m${String(seconds % 60).padStart(2, '0')}s`
  const tokens =
    task.tokens >= 1_000
      ? `${+(task.tokens / 1_000).toFixed(task.tokens % 1_000 === 0 ? 0 : 1)}k`
      : String(task.tokens)
  return [
    elapsed,
    ...(task.tokens > 0 ? [tokens] : []),
    ...(task.toolUses > 0 ? [`${task.toolUses} ${task.toolUses === 1 ? 'tool' : 'tools'}`] : []),
  ].join(' · ')
}

/** The query a command draft is filtering by — everything typed so far. */
export function commandQuery(draft: string): string {
  return draft.startsWith('/') ? draft : ''
}

/*
  `makeIdFactory` was here, unused. It existed for a real constraint — Core must
  not reach for `Math.random()` or a live clock, or the states page cannot be
  compared between runs — and nothing in Core does either, so the factory was
  guarding a rule that already held by construction. Removed rather than kept as
  a comment with an implementation attached: the ids that exist are literals in
  seed data and scenario definitions, which is as deterministic as it gets.
*/
