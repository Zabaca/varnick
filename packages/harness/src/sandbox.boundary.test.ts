import { afterAll, expect, test } from 'bun:test'
import { accessSync, constants, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { SandboxManager } from '@anthropic-ai/sandbox-runtime'
import { establishSandbox, releaseSandbox, type EstablishedSandbox } from './sandbox.ts'
import { SECRETS_KEYCHAIN_SERVICE, SECRETS_INDEX_ACCOUNT } from './secrets.ts'

/*
  The slow suite. Everything here runs a real process under a real kernel
  sandbox, which is the only way to learn anything about a containment
  boundary — a mocked sandbox proves the policy compiles, not that it holds.

  Two probes live here. Ticket 01's: a command run under the policy cannot read
  the home directory. Ticket 10's: it cannot open the Secrets Store, which is
  the system keychain. The full matrix — Read, Grep and Glob denied the same
  paths as Bash, denied binaries, reachable and unreachable hosts — is ticket
  04, which needs a running agent.

  It skips, loudly, when the platform cannot run it. A boundary test that fails
  on Linux CI for want of bubblewrap teaches nobody anything, and a red suite
  everyone learns to ignore is worse than a skipped one.
*/

const SECRET = 'varnick-boundary-probe-secret'

function unrunnableBecause(): string | null {
  if (!SandboxManager.isSupportedPlatform()) {
    return `sandbox-runtime does not support ${process.platform}`
  }
  const deps = SandboxManager.checkDependencies()
  return deps.errors.length > 0 ? `missing dependencies: ${deps.errors.join(', ')}` : null
}

const blocked = unrunnableBecause()

// Both files live under the home directory, which is the topology the real
// thing has: the clone sits inside the denied region and is read back out of
// it. A probe that put the clone somewhere else would prove the deny without
// proving the allow that makes the product usable.
const clone = blocked ? '' : mkdtempSync(join(homedir(), '.varnick-boundary-'))
const insideClone = join(clone, 'inside.txt')
const outsideClone = join(homedir(), `.varnick-boundary-probe-${process.pid}.txt`)

// One sandbox for the file, established on first use. srt initialises process
// globals and starts proxies; two independent establishments in one process
// would be testing the manager rather than the policy.
let established: Promise<EstablishedSandbox> | null = null
const sandbox = (): Promise<EstablishedSandbox> =>
  (established ??= establishSandbox({ cloneRoot: clone }))

async function run(command: string) {
  const { argv, env } = await (await sandbox()).wrap(command)
  const child = Bun.spawn({ cmd: argv, env, stdout: 'pipe', stderr: 'pipe' })
  const [stdout, stderr] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ])
  return { code: await child.exited, stdout, stderr }
}

afterAll(async () => {
  if (blocked) return
  await releaseSandbox()
  rmSync(clone, { recursive: true, force: true })
  rmSync(outsideClone, { force: true })
})

test.skipIf(blocked !== null)(
  'a command under the policy cannot read the home directory, but can read the clone',
  async () => {
    writeFileSync(insideClone, SECRET, 'utf8')
    writeFileSync(outsideClone, SECRET, 'utf8')

    // The control. Without it, a denial proves only that the wrapper is broken.
    const allowed = await run(`cat ${JSON.stringify(insideClone)}`)
    expect(allowed.stdout).toContain(SECRET)
    expect(allowed.code).toBe(0)

    // The boundary.
    const denied = await run(`cat ${JSON.stringify(outsideClone)}`)
    expect(denied.stdout).not.toContain(SECRET)
    expect(denied.code).not.toBe(0)
    expect(denied.stderr).toMatch(/not permitted|No such file|Permission denied/i)
  },
  120_000,
)

test.skipIf(blocked !== null)(
  'the keychain files are unreadable under the policy',
  async () => {
    // The half of the Secrets Store's containment that holds. The keychain
    // databases live under the home directory, which is denied, so nothing
    // under the policy can open the files themselves.
    const listed = await run(`ls ${JSON.stringify(join(homedir(), 'Library/Keychains'))}`)
    expect(listed.code).not.toBe(0)
    expect(listed.stdout).not.toContain('keychain')

    const opened = await run(
      `cat ${JSON.stringify(join(homedir(), 'Library/Keychains/login.keychain-db'))}`,
    )
    expect(opened.code).not.toBe(0)
    expect(opened.stderr).toMatch(/not permitted|No such file|Permission denied/i)
  },
  120_000,
)

test.skipIf(blocked !== null)(
  'security is unreadable and runs anyway, so the Secrets Store is NOT closed by the policy',
  async () => {
    /*
      This probe was written to prove the Secrets Store unreadable from inside
      the sandbox. It measured the opposite, and the measurement is kept here
      because that is what a boundary suite is for.

      ADR-0003 says denying execution means denying read: srt has no execute
      allowlist, so `/usr/bin/security` is blocked by making it unreadable. The
      first half is true — `cat` on it is refused. The second half does not
      follow. srt's generated macOS profile contains an unconditional
      `(allow process-exec)`, and `denyRead` emits `file-read-data` denials,
      which is a different operation from exec. So the binary is unopenable and
      fully runnable at the same time.

      It also does not matter that the keychain *files* are denied: `security`
      does not read them. It asks securityd over Mach, and srt's policy has no
      surface for Mach services. Measured on Darwin 25.5 with srt 0.0.67 by
      storing a value in a throwaway keychain and reading it back from inside
      the sandbox: it came back in plaintext, with no prompt, exit 0.

      Nothing here creates a keychain item — this suite never touches the
      developer's real keychain. Reaching securityd is enough: a search that
      answers "no such item" is a search that ran.

      What this does not mean: it is not a reason to widen the policy, and it is
      not fixed by adding entries to DENIED_BINARIES, because that list is
      denyRead and denyRead is already what is failing. Closing it needs either
      an execute deny srt does not have, or a store that is a file under the
      denied home directory rather than a daemon behind an IPC boundary. That is
      a decision above this ticket. Ticket 04 measures, ticket 13 writes it down.

      The assertions below are inverted on purpose. If a future srt or policy
      closes this, this test goes red and whoever closed it gets to delete a
      caveat from three documents — which is exactly the moment to notice.
    */

    // The control, outside the sandbox: the binary is there and is executable.
    // Without it a denial would be indistinguishable from a machine that has no
    // `security` at all.
    accessSync('/usr/bin/security', constants.R_OK | constants.X_OK)

    // Holds: the file cannot be opened.
    const read = await run('cat /usr/bin/security')
    expect(read.code).not.toBe(0)
    expect(read.stderr).toMatch(/not permitted|Permission denied|No such file/i)

    // Does not hold: it runs, and it reaches the store.
    const searched = await run(
      `/usr/bin/security find-generic-password -s ${SECRETS_KEYCHAIN_SERVICE} -a ${SECRETS_INDEX_ACCOUNT} -w`,
    )
    // 44 is `security`'s own "item not found", and that string is securityd's
    // own error text. Both mean the program ran and the query was answered.
    expect(searched.code).toBe(44)
    expect(searched.stderr).toContain('SecKeychainSearchCopyNext')
    expect(searched.stderr).not.toMatch(/Operation not permitted/i)

    console.log(
      'boundary probe: /usr/bin/security is unreadable under the policy and executes anyway —' +
        ' the Secrets Store is reachable from inside the sandbox. See the comment in' +
        ' packages/harness/src/sandbox.boundary.test.ts and ADR-0003.',
    )
  },
  120_000,
)

if (blocked) {
  console.log(`sandbox boundary probe skipped — ${blocked}`)
}
