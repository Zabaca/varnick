// `bun run probe` — the command that measures the boundary and cannot skip.
//
// Ticket 26 split one thing that was doing two jobs badly. `bun test packages`
// has to stay green on a fresh clone, on CI, and on a machine with no
// credential, so every probe it cannot run has to skip; that is right, and it is
// also why the one probe that opens a real Session went unrun for the life of
// the project without anyone noticing.
//
// This is the other half. It has no skip in it. On a machine that cannot measure
// — wrong platform, missing dependency, no credential — it fails and says which,
// because a maintainer who ran this asked to measure and an answer of "fine,
// nothing happened" is the answer that caused the ticket.
//
// The division to keep in mind:
//
//   bun test packages   must be green on every machine. Green means "everything
//                       runnable here ran", which is not the same as measured.
//   bun run probe       is what a maintainer runs before trusting the README's
//                       *Where confinement stops*. Red means not measured.
//
// It ends by checking that the run actually recorded a completion, rather than
// trusting the suite's exit code. Probe 6 has a legitimate bail-out — a Session
// that never authenticated produces the same empty shape as one whose every tool
// was denied, so it reports and returns rather than asserting a denial it did not
// observe — and that bail-out exits zero. Reading the record instead of the exit
// code is what makes this command mean what its name says.

import { resolve } from 'node:path'
import { SandboxManager } from '@anthropic-ai/sandbox-runtime'
import { CREDENTIAL_ENV_VAR_NAMES } from './agent.ts'
import {
  probeAttestationPath,
  readProbeAttestation,
  sdkToolProbeStanding,
} from './probe-attestation.ts'

const PROBE_FILE = 'packages/harness/src/containment.probe.test.ts'
const CREDENTIALS = CREDENTIAL_ENV_VAR_NAMES.join(' or ')

function die(message: string): never {
  process.stderr.write(`\nbun run probe — not measured.\n\n${message}\n\n`)
  process.exit(1)
}

/** Everything this machine would have to have, checked before anything is run. */
function requireThisMachineCanMeasure(): void {
  if (!SandboxManager.isSupportedPlatform()) {
    die(
      `sandbox-runtime does not support ${process.platform}. The probes are Darwin measurements and the README claims nothing else; there is no version of this command that runs here. Use "bun test packages", which skips them.`,
    )
  }

  const deps = SandboxManager.checkDependencies()
  if (deps.errors.length > 0) {
    die(`sandbox-runtime is missing dependencies: ${deps.errors.join(', ')}`)
  }

  if (!CREDENTIAL_ENV_VAR_NAMES.some((name) => process.env[name])) {
    die(
      [
        `No ${CREDENTIALS} in the environment, so no Session can be opened and probe 6 cannot run.`,
        '',
        'There is deliberately no way to fake one. The Sandbox denies local binding and',
        'every unlisted host, so a stub API is unreachable from inside — and widening the',
        'policy to reach one would be widening the policy to make a probe pass.',
        '',
        `  export ${CREDENTIAL_ENV_VAR_NAMES[0]}=…`,
        '  bun run probe',
      ].join('\n'),
    )
  }
}

function main(): void {
  // Resolved from this file rather than from `process.cwd()`, so the command
  // means the same thing run from anywhere inside the clone.
  const cloneRoot = resolve(import.meta.dir, '../../..')

  process.stdout.write(
    [
      '',
      'bun run probe — the real-kernel containment probes, with no skip in them.',
      '',
      `  before this run:  ${sdkToolProbeStanding().headline}`,
      '',
    ].join('\n'),
  )

  requireThisMachineCanMeasure()

  const suite = Bun.spawnSync({
    cmd: ['bun', 'test', PROBE_FILE],
    cwd: cloneRoot,
    env: process.env,
    stdout: 'inherit',
    stderr: 'inherit',
    stdin: 'inherit',
  })

  if (suite.exitCode !== 0) {
    die(`${PROBE_FILE} failed. The output above is the measurement; read it rather than re-running.`)
  }

  // The exit code is not the question. Probe 6 can end green having measured
  // nothing at all — a Session that failed to open reports and returns — so what
  // is checked is whether a completion was written.
  const standing = sdkToolProbeStanding()
  if (!standing.everCompleted || standing.daysSince !== 0) {
    die(
      [
        'The suite passed and probe 6 recorded no completion, which means it did not reach',
        'the tools. Read its report above: a Session that ends as anything but "ok" never',
        'called one, and that is a credential or a model problem rather than a boundary',
        'result.',
        '',
        `  ${probeAttestationPath()}`,
        `  "lastCompleted": ${JSON.stringify(readProbeAttestation().sdkTools.lastCompleted)}`,
      ].join('\n'),
    )
  }

  process.stdout.write(
    [
      '',
      `bun run probe — measured. ${standing.banner}`,
      '',
      `The record changed: ${probeAttestationPath()}`,
      'Commit it. A dirty tree here is the evidence, and an uncommitted one leaves the',
      'repository still saying nobody has ever run this.',
      '',
    ].join('\n'),
  )
}

main()
