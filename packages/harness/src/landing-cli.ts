// `bun run landable <branch> [base]` — may this branch be merged with nobody
// watching?
//
// The orchestrator asks twice: before it starts a ticket, so a night is not
// spent authoring work that cannot be delivered, and again before it merges,
// because what the branch touches is not known until it is written.
//
// Everything that decides anything is in ./fence.ts and is pure, and everything
// that asks git about it is in ./landing-verdict.ts. What is left here is a
// command: resolve two revisions, print the sentence the predicate wrote, and
// set an exit code.
//
// **This asks the same question the same way as `land_worktree`, because it asks
// the same function.** The two used to be written twice, and an orchestrator asks
// this one before a night starts and that one at the merge — two different
// answers about one branch is worse than either answer alone. The verdict module
// is shared for that reason; see its header for what the flags cost when they
// drift.
//
// The one thing not shared is how git is run: this is a command, so it runs git
// synchronously, and the shared half takes an async port. That is the adapter
// below and it is the whole of the difference.
//
// The exit code is the answer, so this is usable from a skill:
//
//   0  may land unattended
//   1  refused, with the rule and the reason on stdout
//   2  could not be answered — a bad revision, or no git
//
// Two rather than one for the middle case, because "refused" and "not asked
// properly" want opposite handling: the first parks a ticket for the developer
// and the second is a bug in the caller.
//
// **A manifest that cannot be read is now `1` rather than `2`**, and that is a
// deliberate change from ticket 02. It used to die here with a parse error; it is
// a `manifest-not-read` refusal now, because the predicate has that refusal and
// because the tool that merges must treat it as one — a command that exits `2`
// where the tool refuses is the two callers disagreeing again, one layer down.

import { resolve } from 'node:path'
import type { UnattendedLanding } from './fence.ts'
import { landingVerdict } from './landing-verdict.ts'
import type { GitRunner } from './worktrees.ts'

const USAGE = 'usage: bun run landable <branch> [base]   (base defaults to main)'

/** Resolved from this file, so the command means the same run from anywhere. */
const CLONE_ROOT = resolve(import.meta.dir, '../../..')

/**
 * The async git the shared verdict takes, backed by the synchronous one above.
 *
 * The adapter that made sharing possible, and it is four lines. A rejection
 * where `git` answers `null`, because the shared half distinguishes "git would
 * not answer" from "the answer was empty" and a port that collapsed the two
 * would report a branch that changed nothing — the answer that lands everything.
 */
const asyncGit: GitRunner = async (args) => {
  const out = git(args)
  if (out === null) throw new Error(`git ${args.join(' ')} failed in ${CLONE_ROOT}.`)
  return out
}

function die(message: string): never {
  process.stderr.write(`\nbun run landable — not answered.\n\n${message}\n\n`)
  process.exit(2)
}

/** One git invocation, or null if git refused it. */
function git(args: readonly string[]): string | null {
  const run = Bun.spawnSync({
    cmd: ['git', ...args],
    cwd: CLONE_ROOT,
    stdout: 'pipe',
    stderr: 'pipe',
  })
  return run.exitCode === 0 ? run.stdout.toString() : null
}

function requireGit(args: readonly string[], what: string): string {
  const out = git(args)
  if (out === null) die(`${what}\n\n  git ${args.join(' ')}\n\nfailed in ${CLONE_ROOT}.`)
  return out
}

function report(branch: string, base: string, verdict: UnattendedLanding): string {
  if (verdict.mayLand) {
    return [
      '',
      `${branch} may land unattended.`,
      '',
      `  base:    ${base}`,
      '  nothing on it is protected, and the root manifest runs what it ran before.',
      '',
    ].join('\n')
  }
  return [
    '',
    `${branch} may not land unattended.`,
    '',
    `  base:    ${base}`,
    `  rule:    ${verdict.refusal}`,
    `  subject: ${verdict.subject}`,
    '',
    `  ${verdict.reason}`,
    '',
    '  Author it, check it, and hand the branch over. A human merges this one.',
    '',
  ].join('\n')
}

async function main(): Promise<void> {
  const [branch, base = 'main'] = process.argv.slice(2)
  if (branch === undefined || branch === '') die(USAGE)

  /*
    Resolved before anything is diffed, so a typo in a branch name is a usage
    error rather than an empty diff that reads as "nothing protected here".

    The **branch's** resolution is kept, and it is what the verdict is about: a
    ref name is a moving answer, and the tool that merges pins the same way for
    a sharper reason — see `landingVerdict`. Here it also means the sentence
    printed is about a tree that existed when it was printed.
  */
  const commit = requireGit(
    ['rev-parse', '--verify', `${branch}^{commit}`],
    `No such revision: ${branch}.`,
  ).trim()
  requireGit(['rev-parse', '--verify', `${base}^{commit}`], `No such revision: ${base}.`)

  let verdict: UnattendedLanding
  try {
    verdict = await landingVerdict({ git: asyncGit, base, commit })
  } catch (error) {
    // Only git rejects out of there. Everything else is a verdict.
    die(error instanceof Error ? error.message : String(error))
  }

  process.stdout.write(report(branch, base, verdict))
  process.exit(verdict.mayLand ? 0 : 1)
}

await main()
