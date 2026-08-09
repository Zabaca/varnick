// The record of which containment probes have actually run.
//
// Ticket 26. Probe 6 — the only probe that opens a real Session, and so the only
// one that measures the Agent SDK's *own* Read, Grep and Glob rather than the
// syscalls underneath them — needs a credential, and skipped from the day it was
// written to the day the ticket was filed. It printed its reason every single
// time. Behind that skip sat one real defect (ticket 27: every Bash command
// failed at `mkdir`) and one fictional one that cost most of a day.
//
// The suite's header is right that a red suite everyone learns to ignore is
// worse than a skipped one, and it is right that a machine with no credential
// must not be told it has failed. Both of those are about *this machine, today*.
// The thing that was never visible is a different fact entirely: **nobody, on
// any machine, has ever run this probe**. That is a property of the repository,
// and a repository can hold it.
//
// So it is a committed file. It survives the terminal scrolling, it appears in
// review as `"lastCompleted": null`, and the only thing that changes it is a run
// that got all the way to the last assertion. There is no prose to tick.
//
// Two properties worth stating because they are the reason this is not just a
// comment somewhere:
//
//   - The file lives under `packages/harness/**`, which `sandbox-policy.json`
//     denies the agent write access to (ADR-0002). The agent cannot forge an
//     attestation about a probe that measures the agent.
//   - Nothing here weakens a probe. Recording that a measurement did not happen
//     is the opposite of arranging for it to happen without a credential, which
//     would produce a probe that measures nothing — the exact failure ticket 26
//     is about.

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

export const PROBE_ATTESTATION_FILENAME = 'probe-attestation.json'

/**
 * How old a completion may be before the standing says so.
 *
 * Not a failure and deliberately not one: an old measurement is still a
 * measurement, and the boundary it measured does not decay on a calendar. What
 * an old record means is that the policy, `agent.ts` and the SDK have all had
 * time to move underneath it, so anyone about to quote the README's boundary
 * claims should re-run rather than cite.
 */
export const STALE_AFTER_DAYS = 60

/** The verdicts probe 6 records — the six tool results, as it reported them. */
export type ProbeVerdicts = Readonly<Record<string, string>>

/** One probe's standing, as the committed file holds it. */
export interface ProbeCompletion {
  /** Which probe, in the words the suite prints. */
  readonly probe: string
  /** What a completed run establishes. */
  readonly measures: string
  /** What a machine must have for it to run at all. */
  readonly needs: string
  /** The date of the last end-to-end completion, or null for never. */
  readonly lastCompleted: string | null
  /** The commit it was measured at, so a reader can diff forward from it. */
  readonly commit: string | null
  /** `${platform}-${arch}`. Only macOS is claimed; see the README. */
  readonly platform: string | null
  /** What the six tools answered, kept so the record is evidence and not a tick. */
  readonly verdicts: ProbeVerdicts | null
}

export interface ProbeAttestation {
  readonly note: readonly string[]
  readonly sdkTools: ProbeCompletion
}

/** A malformed or missing record, which is itself a result worth failing on. */
export class ProbeAttestationError extends Error {
  override readonly name = 'ProbeAttestationError'
}

/** The Harness package root, which is where the record lives. */
function harnessRoot(): string {
  return resolve(import.meta.dir, '..')
}

export function probeAttestationPath(): string {
  return join(harnessRoot(), PROBE_ATTESTATION_FILENAME)
}

/**
 * Read the record, or explain precisely what is wrong with it.
 *
 * This throws where most readers would return a default, and the difference
 * matters: a default would turn a deleted record into "never completed", which
 * is a much quieter thing than "the record is gone". The record is the artefact
 * ticket 26 exists to produce, so losing it is a red, not a shrug.
 */
export function readProbeAttestation(): ProbeAttestation {
  const path = probeAttestationPath()
  if (!existsSync(path)) {
    throw new ProbeAttestationError(
      `${PROBE_ATTESTATION_FILENAME} is missing. It is a committed file and the only record of whether the credential-gated containment probes have ever run; restore it with "git checkout ${path}".`,
    )
  }

  let parsed: unknown
  try {
    parsed = JSON.parse(readFileSync(path, 'utf8'))
  } catch (cause) {
    throw new ProbeAttestationError(
      `${PROBE_ATTESTATION_FILENAME} is not valid JSON: ${cause instanceof Error ? cause.message : String(cause)}`,
    )
  }

  const record = parsed as Partial<ProbeAttestation>
  const entry = record.sdkTools as Partial<ProbeCompletion> | undefined
  if (entry === undefined || typeof entry.probe !== 'string') {
    throw new ProbeAttestationError(
      `${PROBE_ATTESTATION_FILENAME} has no "sdkTools" entry naming a probe, so nothing in it records whether probe 6 has run.`,
    )
  }
  if (entry.lastCompleted !== null && typeof entry.lastCompleted !== 'string') {
    throw new ProbeAttestationError(
      `${PROBE_ATTESTATION_FILENAME}'s "sdkTools.lastCompleted" must be a date string or null, and is ${JSON.stringify(entry.lastCompleted)}.`,
    )
  }

  return parsed as ProbeAttestation
}

/** Today, to the day. Coarser than a timestamp so a re-run is not a diff. */
function today(): string {
  return new Date().toISOString().slice(0, 10)
}

function daysBetween(from: string, to: string): number | null {
  const start = Date.parse(from)
  const end = Date.parse(to)
  if (Number.isNaN(start) || Number.isNaN(end)) return null
  return Math.max(0, Math.round((end - start) / 86_400_000))
}

/**
 * The commit the measurement was taken at.
 *
 * Recorded rather than asserted against. A record from six commits ago is still
 * a measurement; what the commit buys is that a reader can run `git log` from it
 * and see whether `sandbox.ts` or `agent.ts` moved since. Turning that into a
 * pass/fail rule was considered and rejected — it would put every clone red the
 * moment a maintainer edited the policy without a credential to hand, which is
 * the ignored-red-suite this whole file exists to avoid.
 */
function headCommit(): string | null {
  try {
    return execFileSync('git', ['rev-parse', '--short', 'HEAD'], {
      cwd: harnessRoot(),
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
  } catch {
    return null
  }
}

/** What the record says right now, in the two forms a run needs to print it. */
export interface ProbeStanding {
  /** Whether anyone, on any machine, has ever completed it. */
  readonly everCompleted: boolean
  /** Days since the last completion, or null for never. */
  readonly daysSince: number | null
  /** Old enough that it should be re-run before being quoted. */
  readonly stale: boolean
  /** One line, short enough to be a test name. */
  readonly headline: string
  /** The block a run prints where a person is actually looking. */
  readonly banner: string
}

const RULE = '─'.repeat(78)

export function sdkToolProbeStanding(
  attestation: ProbeAttestation = readProbeAttestation(),
  now: string = today(),
): ProbeStanding {
  const entry = attestation.sdkTools
  const path = probeAttestationPath()

  if (entry.lastCompleted === null) {
    return {
      everCompleted: false,
      daysSince: null,
      stale: true,
      headline: 'NEVER COMPLETED on any machine — a green suite has not measured the SDK’s own tools',
      banner: [
        RULE,
        '  NOT MEASURED — containment probe 6 has never completed, on any machine.',
        '',
        "  What is unmeasured: the Agent SDK's own Read, Grep and Glob, running in",
        '  the Claude Code process the SDK starts. Probe 1 covers the same syscalls',
        '  in the agent process under the same policy and is what the boundary claims',
        '  actually rest on. Probe 6 is the confirmation, and it has never run.',
        '',
        '  A green "bun test packages" therefore does not mean the boundary was',
        '  measured in full. It means everything runnable without a credential ran.',
        '',
        `  The record:  ${path}`,
        '               "lastCompleted": null',
        '  To change it:  export ANTHROPIC_API_KEY=…   (or CLAUDE_CODE_OAUTH_TOKEN)',
        '                 bun run probe',
        '',
        '  bun run probe does not skip. It fails when it cannot measure, which is why',
        '  it is a separate command from the suite that must stay green on a fresh',
        '  clone. Commit the file it writes — that is the evidence.',
        RULE,
      ].join('\n'),
    }
  }

  const daysSince = daysBetween(entry.lastCompleted, now)
  const stale = daysSince !== null && daysSince > STALE_AFTER_DAYS
  const where = `${entry.lastCompleted}${entry.commit === null ? '' : ` at commit ${entry.commit}`}${entry.platform === null ? '' : ` on ${entry.platform}`}`
  const age = daysSince === null ? '' : daysSince === 0 ? ' (today)' : ` (${daysSince} days ago)`

  if (!stale) {
    return {
      everCompleted: true,
      daysSince,
      stale,
      headline: `last completed ${where}${age}`,
      banner: `containment probe 6 last completed ${where}${age}. Recorded in ${PROBE_ATTESTATION_FILENAME}.`,
    }
  }

  return {
    everCompleted: true,
    daysSince,
    stale,
    headline: `STALE — last completed ${where}${age}, over ${STALE_AFTER_DAYS} days`,
    banner: [
      RULE,
      `  STALE — containment probe 6 last completed ${where}${age}.`,
      '',
      '  Still a measurement, and nothing here has failed. But the policy, agent.ts',
      '  and the SDK have all had that long to move underneath it, so re-run before',
      "  quoting the README's boundary claims:",
      '',
      '    export ANTHROPIC_API_KEY=…   (or CLAUDE_CODE_OAUTH_TOKEN)',
      '    bun run probe',
      RULE,
    ].join('\n'),
  }
}

/**
 * Write a completion into the record. Returns whether the file changed.
 *
 * Called from the probe itself, after its last assertion, so the only thing that
 * can produce a record is a run that measured the boundary and found it held.
 * The date is to the day rather than the second precisely so that running the
 * suite twice in an afternoon is not two diffs.
 */
export function recordSdkToolProbeCompletion(verdicts: ProbeVerdicts): boolean {
  const path = probeAttestationPath()
  const attestation = readProbeAttestation()
  const updated: ProbeAttestation = {
    ...attestation,
    sdkTools: {
      ...attestation.sdkTools,
      lastCompleted: today(),
      commit: headCommit(),
      platform: `${process.platform}-${process.arch}`,
      verdicts,
    },
  }
  const content = `${JSON.stringify(updated, null, 2)}\n`
  if (existsSync(path) && readFileSync(path, 'utf8') === content) return false
  writeFileSync(path, content, 'utf8')
  return true
}
