// `bun run landable <branch> [base]` — may this branch be merged with nobody
// watching?
//
// The orchestrator asks twice: before it starts a ticket, so a night is not
// spent authoring work that cannot be delivered, and again before it merges,
// because what the branch touches is not known until it is written.
//
// Everything that decides anything is in ./fence.ts and is pure. This file is
// the thin impure half — it runs git, parses two manifests, prints the sentence
// the pure function wrote, and sets an exit code. That division is deliberate:
// `unattendedLanding` is asserted headlessly in fence.test.ts with no repository
// at all, and nothing below it can be wrong in a way a test would not catch.
//
// The exit code is the answer, so this is usable from a skill:
//
//   0  may land unattended
//   1  refused, with the rule and the reason on stdout
//   2  could not be answered — bad revision, unparseable manifest, no git
//
// Two rather than one for the third case, because "refused" and "not asked
// properly" want opposite handling: the first parks a ticket for the developer
// and the second is a bug in the caller.

import { resolve } from 'node:path'
import {
  INSTALL_LIFECYCLE_FIELDS,
  ROOT_MANIFEST,
  unattendedLanding,
  type InstallLifecycle,
  type UnattendedLanding,
} from './fence.ts'

const USAGE = 'usage: bun run landable <branch> [base]   (base defaults to main)'

/** Resolved from this file, so the command means the same run from anywhere. */
const CLONE_ROOT = resolve(import.meta.dir, '../../..')

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

/**
 * The root manifest's lifecycle fields at one revision.
 *
 * A manifest that is not there at that revision is `{}` and not `undefined`:
 * the branch that adds one has no fields before it, which is a real answer.
 * `undefined` is reserved for "not read", which {@link unattendedLanding}
 * refuses — so a parse failure here dies rather than returning it.
 */
function lifecycleAt(revision: string): InstallLifecycle {
  const source = git(['show', `${revision}:${ROOT_MANIFEST}`])
  if (source === null) return {}

  let manifest: unknown
  try {
    manifest = JSON.parse(source)
  } catch (error) {
    die(
      `${ROOT_MANIFEST} at ${revision} is not JSON, so its install lifecycle fields cannot be read: ${String(error)}`,
    )
  }
  if (typeof manifest !== 'object' || manifest === null) {
    die(`${ROOT_MANIFEST} at ${revision} is not an object.`)
  }

  const scripts = (manifest as { scripts?: unknown }).scripts
  if (scripts === undefined) return {}
  if (typeof scripts !== 'object' || scripts === null) {
    die(`${ROOT_MANIFEST} at ${revision} has a "scripts" field that is not an object.`)
  }

  const fields: Record<string, string> = {}
  for (const field of INSTALL_LIFECYCLE_FIELDS) {
    const value = (scripts as Record<string, unknown>)[field]
    // A non-string here is not "absent" — it is a manifest shape nothing should
    // guess at, and guessing is how a lifecycle script lands unnoticed.
    if (value === undefined) continue
    if (typeof value !== 'string') {
      die(`${ROOT_MANIFEST} at ${revision} has a "${field}" that is not a string.`)
    }
    fields[field] = value
  }
  return fields
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

function main(): void {
  const [branch, base = 'main'] = process.argv.slice(2)
  if (branch === undefined || branch === '') die(USAGE)

  // Resolved before anything is diffed, so a typo in a branch name is a usage
  // error rather than an empty diff that reads as "nothing protected here".
  for (const revision of [branch, base]) {
    requireGit(['rev-parse', '--verify', `${revision}^{commit}`], `No such revision: ${revision}.`)
  }

  // `base...branch` is the diff against the merge base rather than against the
  // tip of `base`, so work that landed on `base` since this branch forked is not
  // reported as something this branch changed.
  const changedPaths = requireGit(['diff', '--name-only', `${base}...${branch}`], 'The diff')
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line !== '')

  // Read only when the answer can turn on it. `git show` on a revision with no
  // manifest is indistinguishable from a revision that does not exist, and the
  // rev-parse above is what already ruled the second one out.
  const touchesManifest = changedPaths.includes(ROOT_MANIFEST)
  const mergeBase = touchesManifest
    ? requireGit(['merge-base', base, branch], 'The merge base').trim()
    : ''

  const verdict = unattendedLanding({
    changedPaths,
    rootManifestBefore: touchesManifest ? lifecycleAt(mergeBase) : undefined,
    rootManifestAfter: touchesManifest ? lifecycleAt(branch) : undefined,
  })

  process.stdout.write(report(branch, base, verdict))
  process.exit(verdict.mayLand ? 0 : 1)
}

main()
