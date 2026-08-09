// The record's own tests. Pure, fast, and running everywhere.
//
// Worth having for a reason particular to ticket 26: the reporting around a
// probe is now load-bearing, and unreported reporting is how this file's subject
// went wrong in the first place. If `sdkToolProbeStanding` quietly returned an
// empty string for "never", the suite would print nothing and read as fine.

import { expect, test } from 'bun:test'
import {
  PROBE_ATTESTATION_FILENAME,
  STALE_AFTER_DAYS,
  probeAttestationPath,
  readProbeAttestation,
  sdkToolProbeStanding,
  type ProbeAttestation,
} from './probe-attestation.ts'

/** The committed record, which is the one this repository actually ships. */
test('the committed record parses and names the probe it stands for', () => {
  const attestation = readProbeAttestation()
  expect(probeAttestationPath().endsWith(PROBE_ATTESTATION_FILENAME)).toBe(true)
  expect(attestation.sdkTools.probe).toContain('probe 6')
  // The credential requirement is part of the record, so a reader who finds
  // `lastCompleted: null` learns why in the same file rather than in a comment
  // three directories away.
  expect(attestation.sdkTools.needs).toContain('ANTHROPIC_API_KEY')
})

function fixture(lastCompleted: string | null): ProbeAttestation {
  return {
    note: [],
    sdkTools: {
      probe: 'containment probe 6',
      measures: 'the SDK’s own tools',
      needs: 'ANTHROPIC_API_KEY',
      lastCompleted,
      commit: lastCompleted === null ? null : 'abc1234',
      platform: lastCompleted === null ? null : 'darwin-arm64',
      verdicts: null,
    },
  }
}

test('never completed is the loud case, and says so in both the headline and the banner', () => {
  const standing = sdkToolProbeStanding(fixture(null), '2026-08-08')
  expect(standing.everCompleted).toBe(false)
  expect(standing.daysSince).toBe(null)
  expect(standing.headline).toContain('NEVER COMPLETED')
  // The sentence the README also has to make. A green suite is not a measurement.
  expect(standing.banner).toContain('bun test packages')
  expect(standing.banner).toContain('bun run probe')
  expect(standing.banner).toContain(probeAttestationPath())
})

test('a recent completion is quiet, and carries the date, commit and platform', () => {
  const standing = sdkToolProbeStanding(fixture('2026-08-05'), '2026-08-08')
  expect(standing.everCompleted).toBe(true)
  expect(standing.daysSince).toBe(3)
  expect(standing.stale).toBe(false)
  expect(standing.headline).toContain('2026-08-05')
  expect(standing.headline).toContain('abc1234')
  expect(standing.headline).toContain('darwin-arm64')
  expect(standing.headline).not.toContain('NEVER')
})

test('a completion older than the staleness window says re-run, and still counts as measured', () => {
  const old = new Date(Date.parse('2026-08-08') - (STALE_AFTER_DAYS + 5) * 86_400_000)
    .toISOString()
    .slice(0, 10)
  const standing = sdkToolProbeStanding(fixture(old), '2026-08-08')
  // Measured is measured. A boundary does not decay on a calendar, so this is a
  // prompt rather than a retraction — the same reason `bun test packages` never
  // goes red over it.
  expect(standing.everCompleted).toBe(true)
  expect(standing.stale).toBe(true)
  expect(standing.headline).toContain('STALE')
  expect(standing.banner).toContain('bun run probe')
})

test('the same day is not stale and reads as today', () => {
  const standing = sdkToolProbeStanding(fixture('2026-08-08'), '2026-08-08')
  expect(standing.daysSince).toBe(0)
  expect(standing.stale).toBe(false)
  expect(standing.headline).toContain('(today)')
})
