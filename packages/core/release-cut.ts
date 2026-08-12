/**
 * Cutting a pre-release: the part that touches the disk.
 *
 * One exported function, and everything it decides was decided in `release.ts`
 * before it wrote anything. That is the split `artifacts.ts` and
 * `artifact-store.ts` already have and what
 * [ADR-0013](../../docs/adr/0013-behaviour-is-proved-headlessly.md) argues for:
 * the pure module is where the release is *improved*, and it is improvable
 * without a human merge precisely because it is Core and not Fence.
 *
 * What is irreducibly impure, and therefore what is in here:
 *
 *   * reading the tickets, the changelog, the manifest and the diff;
 *   * writing the manifest, *before* the build, because the version is baked
 *     into the artifact at build time and a build carrying the previous number
 *     is a display bug with an ordering cause;
 *   * spawning the build — **injected**, not called, so `drive.ts` can drive
 *     both the successful and the failing case without compiling a frontend;
 *   * installing the artifact, through {@link installArtifact} rather than a
 *     second copy of that sequence, which is where `dereference` lives;
 *   * writing the changelog, the pending record and the tag.
 *
 * ## What it never does
 *
 * **It does not touch `served`.** Writing an artifact and choosing to serve it
 * are two acts and a cut performs only the first — the developer's window goes
 * on running whatever it was running until somebody promotes this. That is
 * ticket 08's, and `installArtifact` already refuses to do it by default so this
 * file does not have to remember.
 *
 * **It does not push.** The network allowlist reaches the API and the npm
 * registry and no git remote; the tag is local, which is also what makes moving
 * a superseded one safe.
 */

import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { installArtifact } from './artifact-store.ts'
import {
  CHANGELOG_RELATIVE_PATH,
  PENDING_RECORD_RELATIVE_PATH,
  type ChangedPath,
  type PendingPreRelease,
  type TicketSummary,
  changedPathsFromNameStatus,
  lastPromotedVersion,
  parsePendingRecord,
  parseTicket,
  pendingRecordText,
  releasePlan,
  tagDisposition,
  tagForVersion,
} from './release.ts'

/** The changelog, for a clone. */
export function changelogPath(cloneRoot: string): string {
  return resolve(cloneRoot, CHANGELOG_RELATIVE_PATH)
}

/** The one pending pre-release's record, for a clone. */
export function pendingRecordPath(cloneRoot: string): string {
  return resolve(cloneRoot, PENDING_RECORD_RELATIVE_PATH)
}

/**
 * The empty tree, which is what "everything, from the beginning" is spelled as.
 *
 * A repository with nothing promoted has no tag to diff from, and `git diff`
 * against the root commit would leave the root commit's own files out. This
 * hash is git's and is the same in every repository.
 */
const EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

/**
 * How the build is run.
 *
 * Injected rather than called, and this is the seam the whole file is testable
 * through. `drive.ts` passes one that writes two files, and one that fails, and
 * gets to assert the thing that is otherwise only observable by cutting a real
 * release: that a failed build leaves **nothing** pending — not a bumped
 * manifest, not a changelog entry, not a tag, not a record.
 *
 * It answers where it wrote, rather than being told, because the real one is
 * Vite and Vite's output directory is Vite's business.
 */
export type BuildFrontend = (
  cloneRoot: string,
) => Promise<{ readonly ok: boolean; readonly distDirectory: string; readonly reason?: string }>

export interface CutInput {
  readonly cloneRoot: string
  /** `.scratch/<feature-slug>/issues`, whose landed tickets become the notes. */
  readonly issuesDirectory: string
  readonly build: BuildFrontend
  /** When this is happening. Injected so a cut is reproducible in a driver. */
  readonly now: () => Date
}

/**
 * Why a cut did not happen, in the one distinction a caller can act on.
 *
 * `decided` is this refusing: nothing landed, or a tag that is not ours to move.
 * A night where every ticket was parked is a real night and retrying it changes
 * nothing. `environment` is the world failing underneath it — a build that will
 * not compile, a commit that will not be made — which is worth a person looking.
 *
 * Two values rather than one code per refusal, because the caller is a shell
 * exit status and `landing-cli.ts` already spends the codes this way: `1` for an
 * answer of no, `2` for could not answer.
 */
export type RefusalKind = 'decided' | 'environment'

export type CutOutcome =
  | { readonly cut: false; readonly kind: RefusalKind; readonly reason: string }
  | { readonly cut: true; readonly record: PendingPreRelease; readonly artifact: string }

/**
 * A `git` that answers rather than throws.
 *
 * Every call here is one whose failure is a real answer — a tag that is not
 * there, a diff in a repository with no commits — so the exit code is data. The
 * one place a failure must stop the release is the commit and the tag, and that
 * is checked at the call site where the consequence is.
 */
function git(cloneRoot: string, args: readonly string[]): { ok: boolean; stdout: string; stderr: string } {
  const run = Bun.spawnSync(['git', ...args], { cwd: cloneRoot })
  return {
    ok: run.exitCode === 0,
    stdout: new TextDecoder().decode(run.stdout),
    stderr: new TextDecoder().decode(run.stderr),
  }
}

/**
 * Every ticket in the run that has landed, in file order.
 *
 * File order is ticket order — `01-`, `02-` — which is the order the developer
 * wrote them in and a reasonable order to read a night's work in. `parseTicket`
 * is what decides "landed": every acceptance box ticked. A directory that is not
 * there is an empty run rather than an error, because a release pointed at the
 * wrong slug should say "there is nothing to cut" and not stack-trace.
 */
export function landedTickets(issuesDirectory: string): readonly TicketSummary[] {
  if (!existsSync(issuesDirectory)) return []

  return readdirSync(issuesDirectory)
    .filter((name) => name.endsWith('.md'))
    .sort()
    .map((name) => {
      try {
        return parseTicket(readFileSync(join(issuesDirectory, name), 'utf-8'))
      } catch {
        return null
      }
    })
    .filter((ticket): ticket is TicketSummary => ticket !== null)
}

/**
 * What the run changed, since the last thing anybody promoted.
 *
 * The spawn, and nothing else: what the output *means* is
 * {@link changedPathsFromNameStatus} in `release.ts`, where it can be asserted
 * against real git output without a repository. The flags are argued there,
 * beside the parse that depends on them.
 *
 * A diff that fails answers no paths, which reads as "nothing changed" and
 * therefore as the smallest bump. That is why {@link lastPromotedTag} verifies
 * the tag resolves before this is ever asked to diff from it.
 */
export function changedPathsSince(cloneRoot: string, base: string): readonly ChangedPath[] {
  const diff = git(cloneRoot, ['diff', '--name-status', '-z', '--no-renames', base, 'HEAD'])
  if (!diff.ok) return []
  return changedPathsFromNameStatus(diff.stdout)
}

/**
 * Cut one pre-release, or say why not.
 *
 * The order below is the whole of what this function is, and every step of it
 * is a criterion:
 *
 * 1. **decide everything first.** Nothing is written until the plan is complete,
 *    so a run with nothing to release writes nothing at all.
 * 2. **refuse a tag that is not ours to move.** Before the manifest, so a refusal
 *    costs nothing.
 * 3. **write the manifest, then build.** This order is forced: the version is
 *    substituted into the renderer when the renderer is built, so a build that
 *    ran first would ship an artifact carrying the previous number under a tag
 *    carrying the new one.
 * 4. **on a failed build, put the manifest back and stop.** Nothing pending, no
 *    version bump with no artifact behind it. This is the one step that exists
 *    entirely to undo step 3, and it is why step 3 is the only pre-build write.
 * 5. **install the artifact and write the changelog, then commit and tag.** Any
 *    failure here puts the two committed files back.
 * 6. **write the pending record last.** Nothing on disk offers a pre-release
 *    until every part of it exists — see the comment at that line, which is
 *    where the two-sided version of criterion 8 actually lives.
 *
 * Criterion 8 reads "a version bump with no artifact behind it", and the
 * symmetric failure is the one that costs more: an artifact, a changelog and a
 * record with no tag behind them, reported as "nothing was cut" while ticket
 * 08's band offers it to the developer anyway. Steps 4 and 6 are the two
 * directions of the same rule.
 */
export async function cutPreRelease(input: CutInput): Promise<CutOutcome> {
  const { cloneRoot } = input
  const manifestPath = resolve(cloneRoot, 'package.json')
  const manifestBefore = readFileSync(manifestPath, 'utf-8')
  const changelogBefore = existsSync(changelogPath(cloneRoot))
    ? readFileSync(changelogPath(cloneRoot), 'utf-8')
    : undefined

  const pending = parsePendingRecord(
    existsSync(pendingRecordPath(cloneRoot))
      ? readFileSync(pendingRecordPath(cloneRoot), 'utf-8')
      : undefined,
  )

  const plan = releasePlan({
    changelog: changelogBefore,
    tickets: landedTickets(input.issuesDirectory),
    changedPaths: changedPathsSince(
      cloneRoot,
      lastPromotedTag(cloneRoot, changelogBefore) ?? EMPTY_TREE,
    ),
    manifest: manifestBefore,
    cutAt: input.now().toISOString(),
  })

  // A plan that will not cut is always a decision — nothing landed, or a
  // changelog this cannot count from. Nothing in `releasePlan` touches the world.
  if (!plan.cut) return { cut: false, kind: 'decided', reason: plan.reason }

  const tag = plan.record.tag
  const disposition = tagDisposition(tag, {
    exists: git(cloneRoot, ['rev-parse', '-q', '--verify', `refs/tags/${tag}`]).ok,
    pendingTag: pending?.tag ?? null,
  })
  if (disposition === 'refuse') {
    return {
      cut: false,
      kind: 'decided',
      reason: `${tag} already exists and nothing pending claims it, so this would move a tag somebody else wrote`,
    }
  }

  writeFileSync(manifestPath, plan.manifest)

  const built = await input.build(cloneRoot)
  if (!built.ok) {
    /*
      The manifest goes back exactly as it was, and it is the only thing that
      needs to: it is the only write that happened before this point. What the
      developer wakes up to is the tree they went to bed with, rather than a
      version nobody can run — "a version bump with no artifact behind it" is the
      failure this line is the whole of.
    */
    writeFileSync(manifestPath, manifestBefore)
    return {
      cut: false,
      kind: 'environment',
      reason: `the build failed, so nothing was cut and the manifest is back at its previous version${built.reason === undefined ? '' : ` — ${built.reason}`}`,
    }
  }

  const artifact = installArtifact(cloneRoot, plan.record.artifact, built.distDirectory)

  writeFileSync(changelogPath(cloneRoot), plan.changelog)

  /**
   * Put the two committed files back, for a failure after the build.
   *
   * Not the artifact: it is installed under an id nothing points at yet, so an
   * orphan there is a directory taking up space, which ticket 07's pruner
   * bounds. Undoing a `renameSync` is not worth inventing for that.
   */
  const restoreTree = () => {
    writeFileSync(manifestPath, manifestBefore)
    if (changelogBefore === undefined) rmSync(changelogPath(cloneRoot), { force: true })
    else writeFileSync(changelogPath(cloneRoot), changelogBefore)
  }

  /*
    The commit is what the tag names, so the two are one step. `git add` is given
    the two files this wrote and nothing else — a release running over a dirty
    tree must commit the release and not whatever else was lying around.

    A repository with nothing to commit is not a failure: two cuts at the same
    level produce the same manifest, and the second one has only the changelog to
    write. `--allow-empty` would rather make a commit than leave the tag on
    something older than the release it names.
  */
  git(cloneRoot, ['add', '--', 'package.json', CHANGELOG_RELATIVE_PATH])
  const committed = git(cloneRoot, [
    'commit',
    '--allow-empty',
    '-m',
    `varnick v${plan.record.version} — a pre-release nobody has promoted yet`,
  ])
  if (!committed.ok) {
    restoreTree()
    return {
      cut: false,
      kind: 'environment',
      reason: `the release could not be committed, so nothing is pending — ${committed.stderr.trim()}`,
    }
  }

  const tagged = git(cloneRoot, disposition === 'move' ? ['tag', '-f', tag] : ['tag', tag])
  if (!tagged.ok) {
    restoreTree()
    return {
      cut: false,
      kind: 'environment',
      reason: `${tag} could not be written, so nothing is pending — ${tagged.stderr.trim()}`,
    }
  }

  /*
    A pre-release the developer is offered stops being one, because the version
    that supersedes it has a different name. Removing it here rather than leaving
    it is the difference between "the newer supersedes the older" and "the newer
    exists too": nothing else prunes tags — ticket 07's retention bounds
    artifacts and does not look at refs — so a tag left here is left for ever.

    Guarded exactly as the move is, and by the same reading: only a tag the
    pending record claims. A tag anybody else wrote is never touched, which is
    why this is safe to do with nobody watching.
  */
  if (pending !== null && pending.tag !== tag) {
    git(cloneRoot, ['tag', '-d', pending.tag])
  }

  /*
    **The record is the last write, and that ordering is the whole guarantee.**

    Everything above can fail, and until this line lands there is nothing on disk
    claiming a pre-release is on offer. That matters because the thing that
    *reports* a failure and the thing that *acts* on it are different: this
    function returns a sentence to a terminal nobody is reading at 3am, while
    ticket 08's band reads this file and offers the developer a build. A record
    written before the tag meant the CLI could say "not cut" while the window
    said "promote this", pointing at a tag that does not exist — the two
    disagreeing about whether a release happened, which is the worst available
    version of this failure and the opposite of story 13's "a single thing to
    accept or reject".

    It is the same property `installArtifact` holds one level down: assemble
    everything, and make the thing that points at it the final, single act.
  */
  mkdirSync(dirname(pendingRecordPath(cloneRoot)), { recursive: true })
  writeFileSync(pendingRecordPath(cloneRoot), pendingRecordText(plan.record))

  return { cut: true, record: plan.record, artifact }
}

/**
 * The tag the last promoted release is under, if that tag is really there.
 *
 * The changelog says which version was promoted and git says whether it was
 * tagged; both have to agree before a diff is taken from it, because a base that
 * does not resolve makes `git diff` fail and an empty diff reads as "nothing
 * changed" — which would quietly turn every night into a patch.
 */
function lastPromotedTag(cloneRoot: string, changelog: string | undefined): string | null {
  const promoted = lastPromotedVersion(changelog)
  if (promoted === null) return null
  const tag = tagForVersion(promoted)
  return git(cloneRoot, ['rev-parse', '-q', '--verify', `refs/tags/${tag}`]).ok ? tag : null
}

/**
 * Remove a pending record. Exported for the promotion in ticket 08, which is the
 * only other thing that may touch this file.
 */
export function clearPendingRecord(cloneRoot: string): void {
  rmSync(pendingRecordPath(cloneRoot), { force: true })
}
