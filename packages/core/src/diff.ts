import { isFencePath } from '@varnick/harness/fence'

/**
 * What git printed, read as what changed.
 *
 * The parser between `git diff` and the one view in this product whose job is to
 * be read carefully. It is here rather than in the component for the reason
 * ADR-0001 gives for everything else on this surface: a rule inside a `.tsx` is
 * a rule `drive.ts` cannot reach, and this rule decides whether a Fence hunk is
 * drawn as one. Same arrangement as ./markdown.ts beside it.
 *
 * ## Fence is asked, never restated
 *
 * `isFencePath` comes from the Harness. Three mechanisms key off that one list —
 * the pending-worktree list's flag, the Preview dialog, and this — and a fourth
 * glob written here would drift from the other three invisibly: every caller
 * goes on working, and the one that fell behind stops marking a file the others
 * still mark. See packages/harness/src/fence.ts.
 *
 * ## Nothing is dropped
 *
 * A file git described without hunks — a binary blob, a rename, a mode change —
 * is still a file, and it is exactly the change a hunk-only renderer would leave
 * off the screen. An icon added under `src-tauri/` is a Fence change with no
 * hunk in it.
 *
 * ## Elements, not markup
 *
 * Like ./markdown.ts: this hands the view tagged data and the view builds a
 * tree. Nothing here produces a string the DOM will interpret, so there is
 * nothing for a sanitiser to get wrong, and the text of a diff is the least
 * trustworthy text in the product — it is written by the agent.
 */

/** What one line of a hunk is. The view draws the marker from this. */
export type DiffLineKind =
  /** A line the branch adds. */
  | 'add'
  /** A line the branch removes. */
  | 'remove'
  /** A line that is in both, printed so a change can be read in place. */
  | 'context'
  /**
   * git talking about the file rather than a line of it — `\ No newline at end
   * of file`. Rendering it as context would put a line in the diff that is not
   * in the file.
   */
  | 'meta'

export interface DiffLine {
  readonly kind: DiffLineKind
  /**
   * The line without git's leading marker.
   *
   * The marker is `kind`, and the view draws it back. Keeping it out of the text
   * is what lets a line be styled by what it is rather than by what it starts
   * with — and it is the difference between a removed `--foo` and a header.
   */
  readonly text: string
}

export interface DiffHunk {
  /** The `@@ … @@` line, exactly as git wrote it, section heading and all. */
  readonly header: string
  readonly lines: readonly DiffLine[]
}

export interface DiffFile {
  /** Repository-relative, as git names it. Where it landed, for a rename. */
  readonly path: string
  /**
   * Whether this file decides what the agent may do.
   *
   * The Harness's answer, for the path it is at *and* the path it came from: a
   * move out of `packages/harness/` is an edit to the Fence that arrives at a
   * path which is not one, and classifying only the destination would render it
   * as an ordinary Core change.
   */
  readonly fence: boolean
  readonly hunks: readonly DiffHunk[]
  /**
   * What git said instead of hunks, when it said something.
   *
   * `null` for the ordinary case. Short and authored here — `binary`,
   * `deleted`, `renamed from <path>` — because git's own phrasing for these is
   * a sentence about two blobs, and this sits in a header beside a filename.
   */
  readonly note: string | null
}

interface Building {
  path: string
  from: string | null
  hunks: DiffHunk[]
  note: string | null
}

/**
 * Every file in a unified diff, with its hunks.
 *
 * An empty diff is no files, and that is a real answer rather than an absence: a
 * branch can be ahead by a commit that changed nothing tracked. The view says so
 * in words; nothing here invents a file to fill the space.
 */
export function parseDiff(text: string): DiffFile[] {
  const files: DiffFile[] = []
  let file: Building | null = null
  let hunk: { header: string; lines: DiffLine[] } | null = null

  const closeHunk = () => {
    if (file !== null && hunk !== null) file.hunks.push({ header: hunk.header, lines: hunk.lines })
    hunk = null
  }
  const closeFile = () => {
    closeHunk()
    if (file !== null) files.push(finish(file))
    file = null
  }

  /*
    The final newline is a terminator, not a line.

    git ends its output with one, so a plain split leaves an empty string on the
    end — and inside a hunk an empty string is a genuine empty context line, so
    it would be rendered as one. Every diff would finish with a blank line that
    is not in the file, under the hunk a reviewer is reading most closely.

    Only the last one, and only when it is empty: a blank line anywhere else is
    the file's own.
  */
  const lines = text.split('\n')
  if (lines.at(-1) === '') lines.pop()

  for (const line of lines) {
    if (line.startsWith('diff --git ')) {
      closeFile()
      file = { path: pathFromHeader(line), from: null, hunks: [], note: null }
      continue
    }

    // Anything before the first `diff --git` is not part of a file. git does not
    // print such a line; a caller pasting one is not a reason to invent a file.
    if (file === null) continue

    if (line.startsWith('@@')) {
      closeHunk()
      hunk = { header: line, lines: [] }
      continue
    }

    /*
      Inside a hunk, every line is a line of the file.

      The check is the position rather than the characters, and that is the whole
      of why `--- a/x` and `--foo` cannot be confused: the first can only appear
      before a hunk begins and the second only inside one. A parser testing the
      prefix alone eats a removed line that starts with `--`, which in this
      repository's own diffs is a removed flag disappearing from the review.
    */
    if (hunk !== null) {
      hunk.lines.push(lineOf(line))
      continue
    }

    if (line.startsWith('+++ ') || line.startsWith('--- ')) {
      const named = pathFromMarker(line)
      // `/dev/null` names no file. A deletion has only the `---` side and an
      // addition only the `+++` side, so each fills in what the other cannot.
      if (named !== null) file.path = named
      continue
    }

    if (line.startsWith('rename from ')) {
      file.from = line.slice('rename from '.length)
      file.note = `renamed from ${file.from}`
      continue
    }
    if (line.startsWith('rename to ')) {
      file.path = line.slice('rename to '.length)
      continue
    }
    if (line.startsWith('Binary files ')) {
      file.note = 'binary'
      continue
    }
    if (line.startsWith('deleted file mode')) {
      file.note = 'deleted'
      continue
    }
    if (line.startsWith('new file mode')) {
      // Only when nothing better has been said. A new binary file is binary
      // first: that is the fact explaining why there are no hunks under it.
      file.note ??= 'new file'
      continue
    }
  }

  closeFile()
  return files
}

function finish(file: Building): DiffFile {
  return {
    path: file.path,
    fence: isFencePath(file.path) || (file.from !== null && isFencePath(file.from)),
    hunks: file.hunks,
    note: file.note,
  }
}

function lineOf(line: string): DiffLine {
  const marker = line.charAt(0)
  if (marker === '+') return { kind: 'add', text: line.slice(1) }
  if (marker === '-') return { kind: 'remove', text: line.slice(1) }
  if (marker === '\\') return { kind: 'meta', text: line.slice(2) }
  // A space is context, and so is an empty line: anything that trimmed trailing
  // whitespace on the way here turned an empty context line into one, and it is
  // still a line of the file.
  return { kind: 'context', text: line.slice(1) }
}

/**
 * The path out of `+++ b/x` or `--- a/x`, or `null` for `/dev/null`.
 *
 * git appends a tab and a timestamp in some configurations, so the name ends at
 * the first tab. Everything before that is the path, spaces and all.
 */
function pathFromMarker(line: string): string | null {
  const rest = line.slice(4).split('\t')[0] ?? ''
  if (rest === '/dev/null') return null
  return rest.startsWith('a/') || rest.startsWith('b/') ? rest.slice(2) : rest
}

/**
 * The path out of `diff --git a/x b/x`, which is the last resort.
 *
 * Ambiguous by construction for a path containing a space — `a/one two b/one
 * two` has several readings — so it is only ever the starting guess, and the
 * `+++`, `---` and `rename to` lines below overwrite it whenever git printed
 * one. What it is for is the file git described with none of those: a mode
 * change, which has no hunk and no marker pair and would otherwise be a file
 * with no name.
 */
function pathFromHeader(line: string): string {
  const rest = line.slice('diff --git '.length)
  const half = Math.floor(rest.length / 2)
  // `a/x b/x` is symmetric, so the second half begins one space past the middle
  // when both names are the same — which is every case except a rename, and a
  // rename says so on its own line.
  const second = rest.slice(half + 1)
  const candidate = second.startsWith('b/') ? second.slice(2) : null
  if (candidate !== null) return candidate
  const marked = rest.indexOf(' b/')
  return marked === -1 ? rest : rest.slice(marked + 3)
}
