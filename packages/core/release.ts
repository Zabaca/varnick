/**
 * What a pre-release is, decided.
 *
 * Every export here is a total, deterministic function over strings, and
 * `packages/core/scripts/drive.ts` exercises each of them with nothing built,
 * nothing serving and no git repository.
 *
 * **This module imports nothing at all, and `drive.ts` asserts that it imports
 * nothing** — the check is four lines from the one `artifacts.ts` already has,
 * and it is a check rather than this sentence for the reason that file gives
 * about its own: the alternative was a sentence in a header nothing verified,
 * and that sentence had already gone stale. It went stale inside a single ticket
 * once, which is why the assertion exists at all. Its impure twin is
 * `release-cut.ts`, which reads the files, spawns the build, writes the store and
 * moves the tag — the same split `artifacts.ts` and `artifact-store.ts` already
 * have, and for the reason
 * [ADR-0013](../../docs/adr/0013-behaviour-is-proved-headlessly.md) gives.
 *
 * **This is Core rather than Harness, and that is the whole point of the
 * ticket.** The Harness is Fence: a human merges every change to it. The release
 * machinery is the part of this system most worth iterating on overnight — the
 * bump rule will be wrong twice before it is right, and the announcement will
 * read badly before it reads well — so putting it behind a merge would put the
 * fastest-moving decisions behind the slowest gate. Nothing here decides what
 * the agent may do, so nothing here belongs to the Fence.
 *
 * ## Diffs decide the number, tickets decide the words
 *
 * That division is the design, and it is what
 * {@link levelOfRun} and {@link announcement} are respectively for.
 *
 * A diff is structured and a commit message is not, so the *number* — the thing
 * that has to be right without anyone reading it — is inferred from what the run
 * added and removed. Prose is written by people who knew what they meant, so the
 * *words* come from the tickets: each one opens with a `**What to build:**`
 * paragraph saying what changes for the developer, which is exactly the sentence
 * an announcement wants and exactly the sentence a commit message is not.
 *
 * ## The changelog is the accumulator
 *
 * There is no separate ledger of "what has piled up since the last promotion".
 * The changelog's **pending** entry is that ledger: {@link pendingEntry} reads it
 * back, {@link accumulate} adds this run to it, and {@link changelogWith} writes
 * the sum in place of what was there. Three nights nobody promoted therefore
 * produce three nights of notes in one entry, because the second night read the
 * first night's entry before replacing it.
 *
 * That is also what makes the version recompute rather than compound. The base
 * is the last **promoted** version, never the manifest — so two patch nights in
 * a row both land on the same number, the same artifact id, and the same tag,
 * and the store does not grow one directory per night nobody looked. A version
 * only moves when the accumulated level rises, which is the honest reading of
 * "this is what would be released if you took it".
 *
 * ## The format, written down because three tickets read it
 *
 * ```markdown
 * # Changelog                      <- anything before the first `## ` is header
 *
 * ## v0.0.2 — pending              <- at most one, always first
 *
 * - **06 — Cut a pre-release from the command line** — one command turns a
 *   finished queue of tickets into something to accept in the morning.
 *
 * ## v0.0.1 — 2026-08-04           <- promoted; a date rather than `pending`
 * ```
 *
 * Promotion (ticket 08) is a one-line edit to this file: the pending heading's
 * `pending` becomes the date it was accepted. Nothing else about the entry
 * changes, because nothing else about it was ever provisional.
 */

// ---------------------------------------------------------------------------
// The shape of a run
// ---------------------------------------------------------------------------

/**
 * How much a change moves the number.
 *
 * Three levels and only two outcomes pre-1.0 — see {@link nextVersion}, where
 * `feature` and `fix` are deliberately the same bump. The distinction is kept
 * anyway because it is real in the prose and because it starts mattering the
 * moment the major reaches 1, and a level that only existed after 1.0 would be
 * one nothing had ever exercised.
 */
export type ReleaseLevel = 'fix' | 'feature' | 'breaking'

const LEVEL_ORDER: readonly ReleaseLevel[] = ['fix', 'feature', 'breaking']

/** The coarser of two levels — a run is as breaking as its most breaking part. */
export function coarserLevel(a: ReleaseLevel, b: ReleaseLevel): ReleaseLevel {
  return LEVEL_ORDER.indexOf(a) >= LEVEL_ORDER.indexOf(b) ? a : b
}

/**
 * One path the run touched, and what happened to it.
 *
 * The status is the half `git diff --name-only` throws away and the half that
 * carries the signal: a file appearing and a file disappearing mean opposite
 * things about the developer's tree, and only one of them is a promise being
 * broken. `release-cut.ts` asks git for `--name-status` for exactly this.
 */
export interface ChangedPath {
  readonly status: 'added' | 'modified' | 'removed'
  readonly path: string
}

/**
 * What `git diff --name-status -z` said, as changed paths.
 *
 * A decision rather than plumbing, which is why it is here and not beside the
 * spawn that produces the text. `artifacts.ts` kept *every* decision and left
 * `artifact-store.ts` a single sequence; the same line runs here, and this was
 * on the wrong side of it — a total function over a string, reachable only
 * through a real git repository, which is the definition of a thing that should
 * have been pure and was not.
 *
 * `-z` means NUL-separated fields in `status\0path\0` pairs, and it is what the
 * caller passes for the reason `landing-cli.ts` gives: git quotes non-ASCII
 * paths under the default `core.quotePath`, and a quoted path matches nothing
 * downstream. `--no-renames` keeps every entry to one path, so a rename arrives
 * as the delete and the add it is — which is the honest reading for a version
 * bump anyway, since a moved file is a file that is gone from where it was.
 *
 * A status letter this does not know answers `modified`, which is the
 * conservative direction here and the opposite of the one `isProtectedPath`
 * takes. That is deliberate: an unknown letter that read as `removed` would call
 * a copy or a type change breaking, and the level only ever rises, so one
 * misread letter would pin every future night to the wrong minor.
 */
export function changedPathsFromNameStatus(text: string): readonly ChangedPath[] {
  const fields = text.split('\0').filter((field) => field !== '')
  const paths: ChangedPath[] = []

  for (let index = 0; index + 1 < fields.length; index += 2) {
    const code = (fields[index] ?? '').trim().charAt(0)
    const path = fields[index + 1] ?? ''
    if (path === '') continue
    paths.push({
      status: code === 'A' ? 'added' : code === 'D' ? 'removed' : 'modified',
      path,
    })
  }

  return paths
}

/**
 * One ticket, read as what it says rather than as what it committed.
 *
 * `summary` is the ticket's `**What to build:**` paragraph with the marker
 * taken off — one paragraph of prose, in the present tense, about what the
 * developer can do that they could not before.
 *
 * `acceptedConsequence` is the ticket's `**Accepted consequence:**` line if it
 * carries one, and it is the only thing a ticket says that moves the number.
 * That is not the per-ticket bump declaration this design turned down: nobody
 * writes `breaking` on a ticket to choose a version. It is a sentence a ticket
 * writes anyway, because something the developer relied on stops working and the
 * ticket has to say so — and a release that read the tickets and then failed to
 * notice the one sentence saying "this takes something away" would be reading
 * them for decoration.
 */
export interface TicketSummary {
  readonly id: string
  readonly title: string
  readonly summary: string
  readonly acceptedConsequence: string | null
}

/**
 * One line of a changelog entry: a ticket, once it has landed.
 *
 * **There is no commit in here, and that is load-bearing.** "The announcement
 * never reads as a list of commits" is a property of this type rather than a
 * rule {@link announcement} has to keep — there is no sha, no author and no
 * subject line for it to reach for, because a note is made from a ticket and a
 * ticket is the thing that says what changed for the developer.
 */
export interface ReleaseNote {
  readonly id: string
  readonly title: string
  /** One sentence. The changelog prints it; {@link announcement} prints `detail`. */
  readonly line: string
  /** The whole `What to build` paragraph, which is what the announcement reads. */
  readonly detail: string
}

/** A note, from the ticket it came from. */
export function noteOf(ticket: TicketSummary): ReleaseNote {
  return {
    id: ticket.id,
    title: ticket.title,
    line: firstSentence(ticket.summary),
    detail: ticket.summary,
  }
}

/**
 * The first sentence of a paragraph, for the one-line form.
 *
 * A full stop followed by a space or the end of the text. Not a general
 * sentence splitter — `e.g.` and `0.0.1` would both defeat one — and it does not
 * need to be: what it is protecting against is a changelog bullet that runs to
 * six lines, and a bullet that occasionally carries one sentence too many is a
 * cosmetic miss where a wrong version number is not.
 */
export function firstSentence(text: string): string {
  const collapsed = text.replace(/\s+/g, ' ').trim()
  const end = /\.(\s|$)/.exec(collapsed)
  if (end === null) return collapsed
  return collapsed.slice(0, end.index + 1)
}

// ---------------------------------------------------------------------------
// The number
// ---------------------------------------------------------------------------

/** Where the sequence starts, when nothing has ever been promoted. */
export const INITIAL_VERSION = '0.0.0'

export interface SemanticVersion {
  readonly major: number
  readonly minor: number
  readonly patch: number
}

/**
 * A three-number version, or `null` for anything else.
 *
 * Deliberately strict: no leading `v`, no pre-release suffix, no build metadata.
 * A version this cannot parse is one {@link nextVersion} must not guess at, and
 * the caller turns `null` into a stopped release rather than into a default —
 * the same reason `versionFromManifest` throws rather than falling back.
 */
export function parseVersion(version: string): SemanticVersion | null {
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(version.trim())
  if (match === null) return null
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
  }
}

/** A version, back as the manifest spells it. */
export function formatVersion(version: SemanticVersion): string {
  return `${version.major}.${version.minor}.${version.patch}`
}

/**
 * The version a run produces, from the last promoted one and how much it moved.
 *
 * **Pre-1.0, `feature` and `fix` are the same bump, and that is the convention
 * rather than a shortcut.** While the major is `0` the minor is where a break
 * goes — `^0.1.0` refuses to cross it and the major is reserved — so `0.y.z`
 * reads as `y` for "something you relied on changed" and `z` for everything
 * else. The number therefore answers exactly one question, which is the only
 * question it can answer honestly at this stage: *did anything break?* What
 * arrived and what was fixed is what the changelog is for, and a changelog is
 * better at it than a digit.
 *
 * The alternative — features to the minor — was turned down because it leaves a
 * break nowhere to go pre-1.0 except the same digit a feature just took, so the
 * one thing the number is for stops being legible. It also puts the first cut of
 * this repository at `0.1.0`, where the ticket asks for `0.0.1`.
 *
 * **Past 1.0 the ordinary rule applies**, unchanged and written here rather than
 * discovered later: a break takes the major, a feature the minor, a fix the
 * patch. It is exercised now so that crossing 1.0 is not the first time this
 * branch runs.
 */
export function nextVersion(promoted: string, level: ReleaseLevel): string | null {
  const base = parseVersion(promoted)
  if (base === null) return null

  if (base.major === 0) {
    return level === 'breaking'
      ? formatVersion({ major: 0, minor: base.minor + 1, patch: 0 })
      : formatVersion({ ...base, patch: base.patch + 1 })
  }

  if (level === 'breaking') return formatVersion({ major: base.major + 1, minor: 0, patch: 0 })
  if (level === 'feature') return formatVersion({ ...base, minor: base.minor + 1, patch: 0 })
  return formatVersion({ ...base, patch: base.patch + 1 })
}

/**
 * The coarsest level that would produce `version` from `promoted`, or `null`.
 *
 * This is how the accumulated level survives a night without being stored: the
 * pending version *is* the record of how far the run has moved so far, so a
 * second night reads it back rather than carrying a field that could disagree
 * with the heading above it.
 *
 * **`feature` is unreachable pre-1.0 and that is not a bug.** A patch bump could
 * have come from either a feature or a fix, and answering `fix` is right,
 * because both produce the same next version — the value is only ever fed back
 * into {@link nextVersion}, and there it makes no difference. Answering
 * `feature` would be claiming to know something the number does not record.
 */
export function levelBetween(promoted: string, version: string): ReleaseLevel | null {
  for (const level of LEVEL_ORDER) {
    if (nextVersion(promoted, level) === version) return level
  }
  return null
}

/**
 * What a run's diff says about how much it moved.
 *
 * **A source file that is gone is the signal.** Everything else about a diff is
 * ambiguous — a modified file may be a rewrite or a typo, an added one may be a
 * feature or a test — but a file that used to be there and is not is the one
 * shape that reliably means something stopped existing. That is what `breaking`
 * is for, and ticket 03 is the case: it deleted the Preview approval dialog.
 *
 * **It errs toward breaking**, deliberately and in the cheap direction. A wrong
 * `breaking` costs a minor bump on a version nobody has promoted; a wrong `fix`
 * ships a number that promises stability the build does not have, to a developer
 * who was asleep and is now deciding from it.
 *
 * Documents, tickets and the changelog itself are excluded because they are how
 * the run describes itself: a run that retires an ADR and deletes a ticket file
 * has removed nothing anybody was running. Tests are excluded for the same
 * reason from the other end — a deleted assertion is a change to how the tree is
 * proved, not to what it does.
 */
export function levelOfPaths(paths: readonly ChangedPath[]): ReleaseLevel {
  let level: ReleaseLevel = 'fix'
  for (const changed of paths) {
    if (!isSourcePath(changed.path)) continue
    if (changed.status === 'removed') return 'breaking'
    if (changed.status === 'added') level = coarserLevel(level, 'feature')
  }
  return level
}

/**
 * Whether a path is code the product is made of, rather than something written
 * about it.
 *
 * The exclusions are the ones {@link levelOfPaths} argues for. Written as a
 * closed list of prefixes and suffixes rather than as a matcher, because it is
 * read by exactly one function and a glob engine here would be a second reading
 * of a syntax `fence.ts` already owns for a stricter purpose.
 */
export function isSourcePath(path: string): boolean {
  const subject = path.startsWith('./') ? path.slice(2) : path
  if (subject === '') return false
  if (subject.startsWith('.scratch/') || subject.startsWith('docs/')) return false
  if (subject.endsWith('.md')) return false
  if (/\.(test|probe|boundary)\.[cm]?[jt]sx?$/.test(subject)) return false
  if (subject.endsWith('/drive.ts')) return false
  return true
}

/**
 * How much this run moved, from its tickets and its diff together.
 *
 * The diff is the floor and a ticket can only raise it. A ticket that records an
 * **accepted consequence** has said in prose that something the developer relied
 * on stops working, which is the definition of the top level and is a thing no
 * diff can show: ticket 05 took live Surface hot-reloading away from the main
 * window by *adding* a script, and every path in its diff reads as a feature.
 */
export function levelOfRun(
  tickets: readonly TicketSummary[],
  paths: readonly ChangedPath[],
): ReleaseLevel {
  let level = levelOfPaths(paths)
  for (const ticket of tickets) {
    if (ticket.acceptedConsequence !== null) level = coarserLevel(level, 'breaking')
  }
  return level
}

// ---------------------------------------------------------------------------
// The changelog
// ---------------------------------------------------------------------------

/** The changelog, relative to the clone that owns it. */
export const CHANGELOG_RELATIVE_PATH = 'CHANGELOG.md'

/** What a heading says instead of a date while nobody has promoted it. */
export const PENDING_MARKER = 'pending'

/**
 * A release entry's heading: `## v0.0.1 — pending`, or the same with a date.
 *
 * One expression, used by both the reader and the writer, because two readings
 * of this line is a writer that produces headings the reader cannot find — and
 * the failure would be silent in the worst direction: an unreadable pending
 * heading means a second night sees nothing pending and starts the accumulation
 * over.
 *
 * An em dash or a hyphen, because the file is prose that people edit.
 */
const ENTRY_HEADING = /^##\s+v(\d+\.\d+\.\d+)\s+[—-]\s+(.+?)\s*$/

/** The heading of a changelog entry, parsed. */
export interface ChangelogEntry {
  readonly version: string
  /** `null` while it is pending; the date it was promoted otherwise. */
  readonly promotedOn: string | null
  readonly notes: readonly ReleaseNote[]
}

/**
 * One bullet, once its continuation lines have been folded back into it.
 *
 * `- **06 — Title** — a sentence.` on one line, or the same sentence wrapped
 * across three with the rest indented under it. Markdown reads those as one
 * bullet and so does this.
 */
const NOTE_BULLET = /^-\s+\*\*(\S+)\s+[—-]\s+(.+?)\*\*\s+[—-]\s+(.+?)\s*$/

/**
 * The whole changelog, as entries.
 *
 * A heading this cannot read ends the entry above it and starts nothing, so a
 * hand-written section is carried through {@link changelogWith} untouched rather
 * than being absorbed into a release's notes. The one thing that must never
 * happen here is a parse that quietly swallows an entry: everything downstream
 * treats "not in the changelog" as "not yet released".
 *
 * **A wrapped bullet is one bullet**, which is the whole reason this reads lines
 * into a buffer instead of matching each one. The first version of this was
 * line-anchored, and it truncated a note at its first newline: `- **06 — Cut a
 * pre-release** — one command turns a` and the rest of the sentence silently
 * gone. That is worse than it looks, because {@link accumulate} makes the
 * *carried* note win a collision — so a truncation is not a bad night, it is the
 * text every night after that inherits. This file is prose that people edit, it
 * is written wrapped to the width the repository wraps everything else to, and a
 * reader that could not survive its own output was a reader that broke on the
 * first hand edit in the house style.
 */
export function changelogEntries(changelog: string | undefined | null): readonly ChangelogEntry[] {
  if (changelog === undefined || changelog === null) return []

  interface Building {
    version: string
    promotedOn: string | null
    notes: ReleaseNote[]
  }

  const entries: Building[] = []
  let current: Building | null = null
  /** The bullet being read, with any continuation lines already joined onto it. */
  let bullet: string | null = null

  const finishBullet = () => {
    if (bullet === null) return
    const note = NOTE_BULLET.exec(bullet)
    bullet = null
    if (note === null || current === null) return
    current.notes.push({
      id: note[1] ?? '',
      title: note[2] ?? '',
      line: note[3] ?? '',
      detail: note[3] ?? '',
    })
  }

  for (const line of changelog.split('\n')) {
    const heading = ENTRY_HEADING.exec(line)
    if (heading !== null) {
      finishBullet()
      const version = heading[1] ?? ''
      const rest = heading[2] ?? ''
      current = { version, promotedOn: rest === PENDING_MARKER ? null : rest, notes: [] }
      entries.push(current)
      continue
    }
    if (line.startsWith('## ')) {
      finishBullet()
      current = null
      continue
    }
    if (current === null) continue

    if (line.startsWith('- ')) {
      finishBullet()
      bullet = line
      continue
    }

    /*
      A continuation is an indented, non-empty line under a bullet — the shape a
      wrapped markdown list item has. A blank line ends the bullet, and so does
      anything starting at column zero: both of those end the list item for a
      markdown renderer too, so this agrees with what the file looks like.
    */
    if (bullet !== null && line.trim() !== '' && /^\s/.test(line)) {
      bullet = `${bullet} ${line.trim()}`
      continue
    }
    finishBullet()
  }
  finishBullet()

  return entries
}

/**
 * The entry nobody has promoted, if there is one.
 *
 * At most one exists — {@link changelogWith} replaces it rather than adding
 * beside it, which is where "exactly one pre-release is ever pending" is held.
 * If a hand edit ever leaves two, the first wins, because the file is written
 * newest-first and the newest is the one that supersedes.
 */
export function pendingEntry(changelog: string | undefined | null): ChangelogEntry | null {
  return changelogEntries(changelog).find((entry) => entry.promotedOn === null) ?? null
}

/** The most recent version anybody actually accepted, or `null`. */
export function lastPromotedVersion(changelog: string | undefined | null): string | null {
  return changelogEntries(changelog).find((entry) => entry.promotedOn !== null)?.version ?? null
}

/** Every ticket id that has already gone out in a promoted release. */
export function promotedNoteIds(changelog: string | undefined | null): readonly string[] {
  return changelogEntries(changelog)
    .filter((entry) => entry.promotedOn !== null)
    .flatMap((entry) => entry.notes.map((note) => note.id))
}

/**
 * This run's notes, added to what was already pending, minus what has shipped.
 *
 * Three rules and each one is a night this has to survive:
 *
 *   * **carried first, in the order they were written.** A developer reading a
 *     three-night entry reads it in the order the work happened.
 *   * **deduplicated by ticket id**, because the tickets a run reads are every
 *     landed ticket in the directory, and last night's are still landed. Without
 *     this, an entry would gain a copy of every note every night.
 *   * **nothing already promoted.** The same tickets stay ticked for ever, so
 *     the only thing that can say "this one has gone out" is a promoted entry
 *     naming it. This is the whole of what makes the accumulation start at the
 *     last promotion rather than at the first commit.
 *
 * The carried note wins a collision rather than the incoming one. They are the
 * same ticket; the carried text is the one the developer may already have read
 * in a superseded announcement, and a note that silently rewords itself between
 * nights is a diff nobody asked for.
 */
export function accumulate(
  carried: readonly ReleaseNote[],
  incoming: readonly ReleaseNote[],
  alreadyPromoted: readonly string[] = [],
): readonly ReleaseNote[] {
  const shipped = new Set(alreadyPromoted)
  const seen = new Set<string>()
  const notes: ReleaseNote[] = []

  for (const note of [...carried, ...incoming]) {
    if (shipped.has(note.id) || seen.has(note.id)) continue
    seen.add(note.id)
    notes.push(note)
  }

  return notes
}

/**
 * The width the changelog wraps to — what the rest of the repository's prose
 * uses, so a release's own entry and a hand-written one look the same.
 */
export const CHANGELOG_WRAP = 80

/**
 * One entry, as it appears in the file.
 *
 * **Wrapped, and {@link changelogEntries} folds it back.** The two have to agree
 * and they are asserted round-trip rather than by inspection: a writer that
 * emitted a shape its own reader truncated is exactly the defect this pair had,
 * and the reason it was invisible is that both halves looked right on their own.
 */
export function changelogEntryText(
  version: string,
  notes: readonly ReleaseNote[],
  promotedOn: string | null = null,
): string {
  const heading = `## v${version} — ${promotedOn ?? PENDING_MARKER}`
  const lines = notes.map((note) => wrapBullet(`- **${note.id} — ${note.title}** — ${note.line}`))
  return `${heading}\n\n${lines.join('\n')}\n`
}

/**
 * One bullet, wrapped to {@link CHANGELOG_WRAP} with its continuations indented.
 *
 * Greedy and word-based, and it never breaks inside a word: an over-long token —
 * a URL, a path — takes its line and overflows rather than being cut in half,
 * because a broken path in a changelog is worse than a long line. Two spaces of
 * indent, which is what puts a continuation under the bullet's text rather than
 * under its dash.
 */
function wrapBullet(bullet: string): string {
  const words = bullet.split(' ')
  const lines: string[] = []
  let line = ''

  for (const word of words) {
    const candidate = line === '' ? word : `${line} ${word}`
    if (line !== '' && candidate.length > CHANGELOG_WRAP) {
      lines.push(line)
      line = `  ${word}`
      continue
    }
    line = candidate
  }
  if (line !== '') lines.push(line)

  return lines.join('\n')
}

/** What a changelog that does not exist yet starts with. */
export const CHANGELOG_HEADER = `# Changelog

Every entry is one pre-release. \`pending\` means it has been cut and nobody has
promoted it yet; a date means somebody did. Written by
\`bun run release\` — see \`packages/core/release.ts\`.
`

/**
 * The changelog with this pre-release's entry in it, replacing any pending one.
 *
 * **Replacing rather than prepending is where supersession lives.** The
 * superseded entry's notes have already been read back into `notes` by the
 * caller, so nothing is lost by dropping the block — and leaving it would give
 * the developer two pre-releases to choose between, which is the exact thing the
 * ticket says must never happen.
 *
 * Everything before the first `## ` is kept as the file's header, and every
 * promoted entry is kept verbatim, including anything hand-written inside it.
 * This function only ever removes the one block it also writes.
 */
export function changelogWith(
  changelog: string | undefined | null,
  version: string,
  notes: readonly ReleaseNote[],
): string {
  const entry = changelogEntryText(version, notes)
  if (changelog === undefined || changelog === null || changelog.trim() === '') {
    return `${CHANGELOG_HEADER}\n${entry}`
  }

  const lines = changelog.split('\n')
  const kept: string[] = []
  const header: string[] = []
  let seenHeading = false
  let droppingPending = false

  for (const line of lines) {
    const isHeading = line.startsWith('## ')
    if (isHeading) {
      const parsed = ENTRY_HEADING.exec(line)
      droppingPending = parsed !== null && (parsed[2] ?? '') === PENDING_MARKER
      seenHeading = true
    }
    if (!seenHeading) {
      header.push(line)
      continue
    }
    if (droppingPending) continue
    kept.push(line)
  }

  /*
    The header's own trailing blank lines go, so the entry is separated from it
    by exactly one however the file was left. A changelog with no entries yet is
    all header — the loop above put every line there — so this is also the path a
    first cut takes, and it is the one that made the rule necessary: a file
    ending in a newline contributes a final empty line, which read as a blank the
    entry then added a second to.
  */
  while (header.length > 0 && (header[header.length - 1] ?? '').trim() === '') header.pop()
  while (kept.length > 0 && (kept[0] ?? '').trim() === '') kept.shift()

  const tail = kept.length === 0 ? '' : `\n${kept.join('\n').replace(/\n+$/, '')}\n`
  return `${header.join('\n')}\n\n${entry}${tail}`
}

// ---------------------------------------------------------------------------
// The announcement
// ---------------------------------------------------------------------------

/**
 * What gets said about the release, in prose.
 *
 * Paragraphs, not bullets, and each paragraph is one ticket's own account of
 * what the developer can now do — the `**What to build:**` opening that every
 * ticket in this repository carries. Nothing here reads a commit, because
 * {@link ReleaseNote} has no commit in it to read: the guarantee is in the type
 * rather than in a rule this function keeps.
 *
 * It closes by saying that nothing is serving the build yet, because the whole
 * shape of a pre-release is that it was cut while nobody was watching and the
 * decision is still the developer's. Ticket 08 posts this into the transcript.
 */
export function announcement(
  version: string,
  notes: readonly ReleaseNote[],
  promoted: string | null,
): string {
  const since = promoted === null ? 'since the first commit' : `since v${promoted}`
  const count = notes.length === 1 ? 'One ticket' : `${countWord(notes.length)} tickets`

  const paragraphs = [
    `varnick v${version} is cut and waiting. ${count} landed ${since}.`,
    ...notes.map((note) => note.detail.replace(/\s+/g, ' ').trim()),
    'Nothing is served from it yet. The window is still running what it was running, and promoting this build is still yours to do.',
  ]

  return `${paragraphs.join('\n\n')}\n`
}

/**
 * A small count as a word, because the first line of an announcement is prose.
 *
 * Falls back to digits past twelve rather than growing a number-speller — a
 * night that lands thirteen tickets has earned a numeral.
 */
function countWord(count: number): string {
  const words = [
    'Zero',
    'One',
    'Two',
    'Three',
    'Four',
    'Five',
    'Six',
    'Seven',
    'Eight',
    'Nine',
    'Ten',
    'Eleven',
    'Twelve',
  ]
  return words[count] ?? String(count)
}

// ---------------------------------------------------------------------------
// The pending record, and the tag
// ---------------------------------------------------------------------------

/**
 * Where the one pending pre-release is recorded, relative to the clone.
 *
 * Under `.varnick/` beside the artifact store, for the same reason: it is a fact
 * about this clone on this machine, it is already gitignored, and it must never
 * be committed. One file, overwritten, which is how "exactly one is pending" is
 * held on disk rather than by a rule somebody has to keep.
 *
 * A file rather than a line in `served`, because the two answer different
 * questions and one of them is the developer's window. `served` says what is
 * running; this says what is on offer. A pre-release that wrote into `served`
 * would be a promotion nobody made.
 */
export const PENDING_RECORD_RELATIVE_PATH = '.varnick/pending-release.json'

/**
 * The pre-release on offer.
 *
 * Read by ticket 08's band, which needs the version to show, the announcement to
 * post into the transcript, and the artifact id to switch `served` to. Written
 * only by a cut, and deleted by a promotion.
 */
export interface PendingPreRelease {
  readonly version: string
  /** The artifact in the store this names — {@link artifactIdForVersion}. */
  readonly artifact: string
  readonly tag: string
  /** ISO 8601, so an older record can be told from a newer one by reading it. */
  readonly cutAt: string
  readonly announcement: string
  readonly notes: readonly ReleaseNote[]
}

/**
 * The artifact id a version is stored under.
 *
 * The version, exactly. It is a function rather than a use site so that the one
 * property that matters can be asserted about all of it: every version
 * {@link nextVersion} can produce has to be a name `isArtifactId` accepts, or a
 * release writes a directory the server will refuse to resolve. `drive.ts`
 * asserts that relationship across the two modules rather than either one
 * asserting it about itself — the arrangement `fence.test.ts` uses for its three
 * lists.
 */
export function artifactIdForVersion(version: string): string {
  return version
}

/** The tag a version is written under. */
export function tagForVersion(version: string): string {
  return `v${version}`
}

/** What to write into {@link PENDING_RECORD_RELATIVE_PATH}. */
export function pendingRecordText(record: PendingPreRelease): string {
  return `${JSON.stringify(record, null, 2)}\n`
}

/**
 * The record a file holds, or `null` for nothing usable.
 *
 * Absent, unparseable and shaped wrong all answer the same way, for the reason
 * `markedArtifactId` gives about the store's own markers: the honest reading of
 * a record nobody can parse is that nothing is pending, and there is no partial
 * pre-release to offer. It throws for nothing, because its callers are a band in
 * a window and a release that is about to overwrite it.
 */
export function parsePendingRecord(text: string | undefined | null): PendingPreRelease | null {
  if (text === undefined || text === null) return null

  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    return null
  }

  const record = parsed as Partial<PendingPreRelease> | null
  if (record === null || typeof record !== 'object') return null
  if (typeof record.version !== 'string' || parseVersion(record.version) === null) return null
  if (typeof record.artifact !== 'string' || record.artifact === '') return null
  if (typeof record.tag !== 'string' || record.tag === '') return null
  if (typeof record.cutAt !== 'string' || record.cutAt === '') return null
  if (typeof record.announcement !== 'string') return null

  return {
    version: record.version,
    artifact: record.artifact,
    tag: record.tag,
    cutAt: record.cutAt,
    announcement: record.announcement,
    notes: Array.isArray(record.notes) ? record.notes : [],
  }
}

/** What a cut may do with the tag it wants to write. */
export type TagDisposition = 'write' | 'move' | 'refuse'

/**
 * Whether a tag may be written, moved, or neither.
 *
 * A pre-release cut twice at the same level lands on the same version, so the
 * second cut has to move a tag the first one wrote. That is right — the tag
 * names a pre-release nobody has promoted, it was never pushed, and moving it is
 * exactly what "the newer supersedes the older" means.
 *
 * **It may only move a tag the pending record names**, which is the guard rather
 * than the convenience. A tag that exists with nothing pending behind it is a
 * release somebody accepted, or a tag a person wrote by hand; either way a run
 * with nobody watching must not move it. The version arithmetic should never
 * produce that case — the base is the last promoted version, so the next one is
 * always higher — and this is what happens when it does anyway, because a
 * hand-edited changelog is a thing that happens.
 */
export function tagDisposition(
  tag: string,
  state: { readonly exists: boolean; readonly pendingTag: string | null },
): TagDisposition {
  if (!state.exists) return 'write'
  if (state.pendingTag === tag) return 'move'
  return 'refuse'
}

// ---------------------------------------------------------------------------
// The manifest
// ---------------------------------------------------------------------------

/**
 * The root manifest with a new version in it, or a refusal.
 *
 * A targeted replacement rather than `JSON.parse` and `JSON.stringify`, because
 * the second reformats the whole file: a release would arrive as a manifest-wide
 * diff with the version somewhere in it, which is unreadable in exactly the
 * review a developer does at breakfast. Only the top-level field is matched —
 * two-space indent, which is how this manifest is written and how `bun` writes
 * it — so a `version` inside a nested object is left alone.
 *
 * The result is parsed back and checked before it is returned. A regex that
 * matched the wrong thing would otherwise ship a manifest that no longer parses,
 * and the next thing to read it is a build.
 */
export function manifestWithVersion(manifest: string, version: string): string | null {
  if (parseVersion(version) === null) return null

  let replaced = false
  const next = manifest.replace(/^(\s{2}"version":\s*)"[^"]*"/m, (_match, prefix: string) => {
    replaced = true
    return `${prefix}${JSON.stringify(version)}`
  })
  if (!replaced) return null

  try {
    if ((JSON.parse(next) as { version?: unknown }).version !== version) return null
  } catch {
    return null
  }

  return next
}

// ---------------------------------------------------------------------------
// The whole decision
// ---------------------------------------------------------------------------

export interface ReleasePlanInput {
  /** The changelog as it is on disk, or `undefined` for a repository with none. */
  readonly changelog: string | undefined
  /** Every ticket in the run that has landed — see `release-cut.ts`. */
  readonly tickets: readonly TicketSummary[]
  /** What the run changed, since the last promoted tag. */
  readonly changedPaths: readonly ChangedPath[]
  /** The root manifest as it is on disk. */
  readonly manifest: string
  /** When this cut is happening, ISO 8601. */
  readonly cutAt: string
}

export type ReleasePlan =
  | { readonly cut: false; readonly reason: string }
  | {
      readonly cut: true
      readonly level: ReleaseLevel
      readonly promoted: string | null
      readonly record: PendingPreRelease
      /** The manifest to write **before** the build, because the build bakes it in. */
      readonly manifest: string
      readonly changelog: string
    }

/**
 * Everything a cut decides, decided at once and before anything is written.
 *
 * One function rather than five called in order, because the order is the part
 * that is easy to get wrong and impossible to see: the version depends on the
 * accumulated notes, the notes depend on what was already pending, the artifact
 * id and the tag depend on the version, and the announcement depends on all of
 * it. A caller composing those by hand would work, and would work differently
 * the second time somebody wrote one.
 *
 * It answers `cut: false` for a run with nothing in it. That is not an error —
 * a queue where every ticket was parked is a real night — and a release that
 * bumped a version for it would put a number and a tag on an empty changelog
 * entry.
 */
export function releasePlan(input: ReleasePlanInput): ReleasePlan {
  const promoted = lastPromotedVersion(input.changelog)
  const base = promoted ?? INITIAL_VERSION
  if (parseVersion(base) === null) {
    return { cut: false, reason: `the changelog's most recent promoted version ${JSON.stringify(base)} is not a version this can count from` }
  }

  const pending = pendingEntry(input.changelog)
  const notes = accumulate(
    pending?.notes ?? [],
    input.tickets.map(noteOf),
    promotedNoteIds(input.changelog),
  )
  if (notes.length === 0) {
    return { cut: false, reason: 'no landed ticket is unreleased, so there is nothing to cut' }
  }

  /*
    The level accumulates the same way the notes do, and for the same reason: a
    breaking night followed by a quiet one is still a breaking pre-release. It is
    read back out of the pending version rather than stored beside it, so the
    heading in the changelog cannot disagree with a field nobody looks at.
  */
  const carried = pending === null ? null : levelBetween(base, pending.version)
  const level = carried === null
    ? levelOfRun(input.tickets, input.changedPaths)
    : coarserLevel(carried, levelOfRun(input.tickets, input.changedPaths))

  const version = nextVersion(base, level)
  if (version === null) {
    return { cut: false, reason: `${base} is not a version this can count from` }
  }

  const manifest = manifestWithVersion(input.manifest, version)
  if (manifest === null) {
    return {
      cut: false,
      reason: `the root manifest has no top-level "version" to bump to ${version}, so the build would carry the previous number`,
    }
  }

  return {
    cut: true,
    level,
    promoted,
    manifest,
    changelog: changelogWith(input.changelog, version, notes),
    record: {
      version,
      artifact: artifactIdForVersion(version),
      tag: tagForVersion(version),
      cutAt: input.cutAt,
      announcement: announcement(version, notes, promoted),
      notes,
    },
  }
}

// ---------------------------------------------------------------------------
// Reading a ticket
// ---------------------------------------------------------------------------

/**
 * One ticket file, read as a {@link TicketSummary}, or `null` for a file that is
 * not one.
 *
 * Three things are taken and nothing else: the heading, the `**What to build:**`
 * paragraph, and an `**Accepted consequence:**` line if there is one.
 *
 * **A ticket with an unticked acceptance criterion answers `null`.** That is how
 * a run knows which tickets landed, and it is read from the box rather than from
 * git because the box is what the run itself ticks as it goes — a parked ticket
 * keeps its branch and its worktree and never gets its boxes ticked, so it stays
 * out of the changelog without anybody having to remember to leave it out. A
 * ticket with no criteria at all is also `null`: a file with nothing to satisfy
 * has not been satisfied.
 */
export function parseTicket(text: string): TicketSummary | null {
  const body = ticketBody(text)

  const heading = /^#\s+(\S+)\s+[—-]\s+(.+?)\s*$/m.exec(body)
  if (heading === null) return null

  const boxes = [...body.matchAll(/^-\s+\[( |x|X)\]/gm)]
  if (boxes.length === 0) return null
  if (boxes.some((box) => (box[1] ?? '') === ' ')) return null

  const build = /\*\*What to build:\*\*\s*([\s\S]*?)(?:\n\s*\n|$)/.exec(body)
  if (build === null) return null
  const summary = (build[1] ?? '').replace(/\s+/g, ' ').trim()
  if (summary === '') return null

  const consequence = /\*\*Accepted consequence:\*\*\s*([\s\S]*?)(?:\n\s*\n|$)/.exec(body)

  return {
    id: heading[1] ?? '',
    title: heading[2] ?? '',
    summary,
    acceptedConsequence:
      consequence === null ? null : (consequence[1] ?? '').replace(/\s+/g, ' ').trim() || null,
  }
}

/**
 * A ticket without its conversation — everything above `## Comments`.
 *
 * `docs/agents/issue-tracker.md` puts comments at the bottom under that heading,
 * and a release must read only the half above it. This is not tidiness: the
 * comments are where the ticket is *discussed*, and a ticket whose comments
 * explain what an `**Accepted consequence:**` line is for would otherwise be
 * read as having one. That happened to this very ticket, which is why the rule
 * is here rather than in a note asking people to phrase comments carefully.
 *
 * The acceptance boxes are cut off with it, and that is the same rule rather
 * than a second one: a criterion is something the ticket asks for, and a box
 * drawn inside a comment is somebody quoting one.
 */
export function ticketBody(text: string): string {
  const comments = /^##\s+Comments\s*$/m.exec(text)
  return comments === null ? text : text.slice(0, comments.index)
}
