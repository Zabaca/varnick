/**
 * A Preview, and the one line that decides whether one is asked about.
 *
 * A **Preview** is a second varnick launched from a **Worktree** so a Core
 * change can be run before it is merged. The agent asks for one through the
 * `launch_preview` **Custom Tool**; the host spawns it. This module is the
 * Harness's half of that: the tool's shape, the sentences the agent reads back,
 * and — the part with teeth — which changed paths are **Fence**.
 *
 * ## Fence is smaller than Core, and the difference is the whole design
 *
 * A Preview runs unconfined, and it has to: it reads the Keychain to resolve a
 * Credential. So there is a three-step path from confined to unconfined — the
 * agent edits `sandbox.ts` in a worktree, calls the tool, and the host spawns a
 * varnick whose fence the agent wrote, whose own agent then runs under it. A
 * native dialog stands in that path and in nothing else.
 *
 * {@link isFencePath} is the condition on that dialog. It names three things —
 * `packages/harness/**`, which generates the Sandbox policy; `src-tauri/**`,
 * which holds the Credential; and `sandbox-policy.baseline.json`, which is how a
 * widening is told from varnick's own work. `packages/core/**`, `vite.config.*`
 * and `package.json` are Core and are *not* Fence: they are denied so a broken
 * edit cannot take the conversation down, not because they decide the boundary.
 * A dialog that appeared on every Core preview is a dialog nobody reads by the
 * second week, which is worse than no dialog. See CONTEXT.md and
 * docs/adr/0014-core-is-authored-in-a-worktree.md.
 *
 * ## Nothing here spawns anything
 *
 * The spawn and the dialog are `src-tauri/src/preview.rs`, because a confined
 * process cannot open a window and because a dialog Userspace could draw is a
 * dialog Userspace can forge. What is here is what can be decided from text: a
 * diff in, a smaller diff out.
 */

/**
 * The three paths that decide what the agent may do.
 *
 * Prefixes, matched against a repository-relative path with forward slashes —
 * which is the form git writes in a `diff --git` header and in `ls-files`.
 *
 * Deliberately not read out of the Sandbox policy's `denyWrite`. That list is
 * larger and is a different question: it is "what would break or widen varnick
 * if the agent wrote it in the live tree", and this is "what would let the agent
 * write its own fence and then run under it". Core is on the first list and not
 * on this one, and the two must be able to move independently — see the
 * `Fence` entry in CONTEXT.md, which says the same thing in the other order.
 */
export const FENCE_DIRECTORIES = ['packages/harness', 'src-tauri'] as const

/**
 * The one Fence entry that is a file rather than a tree.
 *
 * The recorded baseline: what the generator produced, beside what is in force.
 * An agent that can write this can make its own widening look like something
 * varnick generated, and be believed — which is a subtler version of writing the
 * policy itself and is why it is Fence rather than Core.
 *
 * Mirrored from `SANDBOX_BASELINE_FILENAME` in ./sandbox.ts rather than imported
 * from it, because this module is imported by the agent host *inside* the
 * Sandbox and ./sandbox.ts pulls in `@anthropic-ai/sandbox-runtime`. A constant
 * shared by an import that drags a runtime dependency across a boundary is a
 * worse dependency than a duplicated string, and ./sandbox.test.ts is where the
 * two are held to each other.
 */
export const FENCE_BASELINE_FILE = 'sandbox-policy.baseline.json'

/**
 * Does a change to this path change what the agent may do?
 *
 * The path is repository-relative and uses forward slashes. Anything else — an
 * absolute path, a `./` prefix, a Windows separator — answers `false`, because
 * this is asked about strings git wrote and a shape git does not write is a
 * shape this cannot vouch for. Refusing to classify is the safe direction only
 * for the *caller* that treats unknown as Fence; nothing does, so the rule is
 * instead that the caller feeds this git's own output and nothing else.
 */
export function isFencePath(path: string): boolean {
  if (path === FENCE_BASELINE_FILE) return true
  // `packages/harnessed/x` is not `packages/harness/x`, and a prefix test
  // without the separator would say it was.
  return FENCE_DIRECTORIES.some(
    (directory) => path === directory || path.startsWith(`${directory}/`),
  )
}

// ---------------------------------------------------------------------------
// The diff
// ---------------------------------------------------------------------------

/** How much of an untracked file is worth showing before it stops being a hunk. */
export const UNTRACKED_PREVIEW_BYTES = 4_000

/**
 * The paths a `diff --git` header names, or null when it names none this
 * understands.
 *
 * git writes `diff --git a/<old> b/<new>`, and quotes a path with anything
 * unusual in it — `diff --git "a/odd name" "b/odd name"`. A quoted header is
 * deliberately *not* unquoted here: a Fence path is `packages/harness/…`,
 * `src-tauri/…` or one exact filename, none of which git ever quotes, so a
 * quoted header cannot be a Fence path and reading it would only be a second
 * parser to get wrong.
 */
function headerPaths(header: string): readonly string[] | null {
  const match = /^diff --git a\/(\S+) b\/(\S+)$/.exec(header.trim())
  if (match === null) return null
  return [match[1] as string, match[2] as string]
}

export interface FenceHunksInput {
  /** A unified diff, as `git diff` wrote it. */
  readonly patch: string
  /** Repository-relative paths git does not track yet. */
  readonly untracked?: readonly string[]
  /** The first bytes of an untracked file, or null if it could not be read. */
  readonly readUntracked?: (path: string) => string | null
}

/**
 * The Fence part of a diff, and nothing else.
 *
 * **A filter rather than a summary.** The bytes that come out are bytes git
 * wrote; nothing here rewrites a hunk, counts one, or says what a change does.
 * ADR-0005 found the reason and it survives its own supersession: approving a
 * request means approving a sentence the agent wrote, and that sentence is
 * exactly what prompt injection produces. Approving hunks means reading bytes.
 *
 * **Untracked files are included, and that is not tidiness.** `git diff` shows
 * nothing for a file that has never been added, so a new
 * `packages/harness/src/widen.ts` sitting in a worktree would produce an empty
 * diff and launch with no dialog — a hole exactly the shape of the thing the
 * dialog exists to catch. They are rendered as an added file, capped, and a file
 * that could not be read is still named.
 */
export function fenceHunks(input: FenceHunksInput): string {
  const sections: string[] = []

  // Split on the header rather than scanning line by line: a diff's body can
  // contain any line at all, including one that looks like a header, and only a
  // line at the start of a section is one.
  const parts = input.patch.split(/(?=^diff --git )/m)
  for (const part of parts) {
    if (!part.startsWith('diff --git ')) continue
    const paths = headerPaths(part.split('\n', 1)[0] ?? '')
    if (paths === null) continue
    // Either side, so a rename *into* the Fence and a rename *out of* it are
    // both shown. A file moved out of `src-tauri` is a change to the host.
    if (!paths.some(isFencePath)) continue
    sections.push(part.replace(/\n+$/, '\n'))
  }

  for (const path of input.untracked ?? []) {
    if (!isFencePath(path)) continue
    const contents = input.readUntracked?.(path) ?? null
    if (contents === null) {
      sections.push(
        `diff --git a/${path} b/${path}\nnew file, untracked, and this host could not read it\n`,
      )
      continue
    }
    const shown = contents.slice(0, UNTRACKED_PREVIEW_BYTES)
    const body = shown
      .split('\n')
      .map((line) => `+${line}`)
      .join('\n')
    sections.push(
      [
        `diff --git a/${path} b/${path}`,
        'new file, untracked',
        `--- /dev/null`,
        `+++ b/${path}`,
        body,
        shown.length < contents.length ? `+… truncated at ${UNTRACKED_PREVIEW_BYTES} characters` : '',
      ]
        .filter((line) => line !== '')
        .join('\n') + '\n',
    )
  }

  return sections.join('')
}

// ---------------------------------------------------------------------------
// What the agent asked for, and what it is told
// ---------------------------------------------------------------------------

/** The Custom Tool's name, as the agent sees it. */
export const LAUNCH_PREVIEW_TOOL = 'launch_preview'

/**
 * What the tool says it does — including the two things it will not do.
 *
 * The refusals are described rather than left to be discovered, because an agent
 * that knows the tool takes a name does not try a path, and a tool call that was
 * never made is the cheapest refusal there is.
 */
export const LAUNCH_PREVIEW_DESCRIPTION = [
  'Launch a preview of a git worktree: a second varnick running from it, in its own window,',
  'so a Core change can be run before it is merged.',
  '',
  'Takes the name of a worktree under .claude/worktrees/ — one path component, nothing else.',
  'It is not a path and not a command: an absolute path, anything with a slash in it, and any',
  'name git does not report are all refused. The window is opened by the host, because a',
  'confined process cannot open one.',
  '',
  'A worktree that changes packages/harness/**, src-tauri/** or sandbox-policy.baseline.json',
  'raises a dialog showing those hunks to the developer first, and launches only if they say so.',
].join('\n')

/**
 * What happened to a request for a Preview.
 *
 * The tags `src-tauri/src/preview.rs` writes. Every sentence for them is
 * authored below and selected by the tag, which is the same rule
 * `turnFailureMessage` follows and it is load-bearing for the same reason: the
 * host holds the Credential, and nothing it observed — a path, an OS error, an
 * environment — may become a string the confined agent reads.
 */
export const PREVIEW_OUTCOMES = [
  'launched',
  'declined',
  'unknown-worktree',
  'no-worktrees',
  'no-launch',
] as const

export type PreviewOutcome = (typeof PREVIEW_OUTCOMES)[number]

export function isPreviewOutcome(value: unknown): value is PreviewOutcome {
  return typeof value === 'string' && (PREVIEW_OUTCOMES as readonly string[]).includes(value)
}

/** What to tell the agent, in one sentence, selected by the tag. */
export function previewOutcomeMessage(outcome: PreviewOutcome): string {
  switch (outcome) {
    case 'launched':
      return 'A preview of that worktree is starting in its own window, on its own port, with its own session.'
    case 'declined':
      return 'That worktree changes the code that decides what an agent may do, and the developer declined the preview after reading the diff. Nothing was launched. Do not ask again for the same change; explain what the change does instead.'
    case 'unknown-worktree':
      return 'That is not the name of a worktree under .claude/worktrees/. The name is one path component — not a path, not an absolute path, and not the live clone. Create the worktree first, or name one that exists.'
    case 'no-worktrees':
      return 'The host could not ask git what worktrees exist, so nothing could be checked and nothing was launched.'
    case 'no-launch':
      return 'The worktree was found and the preview did not start. Nothing is running from it.'
  }
}

/**
 * The tool's answer, as the agent reads it.
 *
 * A sentence and a flag. The flag is what makes "it was declined" a fact the
 * agent can act on rather than prose it has to interpret — the one outcome the
 * ticket names in its own right.
 */
export function previewToolResult(outcome: PreviewOutcome): {
  readonly launched: boolean
  readonly text: string
} {
  return { launched: outcome === 'launched', text: previewOutcomeMessage(outcome) }
}

/**
 * One request for a Preview, as one line on the agent host's stdout.
 *
 * The second shape on a pipe that carries Turn events, told apart by which id it
 * names: a Turn event names a `turnId` and this names a `requestId`. `preview_request_of`
 * in src-tauri/src/preview.rs is the reader, and `agent_event_of` beside it
 * drops this line rather than delivering it to a Turn.
 *
 * Two fields, because there is nothing else a Preview needs. There is
 * deliberately no field for a command, a path, a port or an environment: the
 * host decides all four, and a field the agent could fill would be the shell out
 * of the Sandbox this whole tool is shaped to avoid.
 */
export function encodePreviewRequest(requestId: string, worktree: string): string {
  return `${JSON.stringify({ kind: 'launch-preview', requestId, worktree })}\n`
}
