import { afterAll, expect, test } from 'bun:test'
import { accessSync, constants, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { SandboxManager } from '@anthropic-ai/sandbox-runtime'
import { establishSandbox, releaseSandbox, type EstablishedSandbox } from './sandbox.ts'

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
  'security runs despite being unreadable, and still cannot reach the login Keychain',
  async () => {
    /*
      Two claims, measured separately, because conflating them cost this project
      two wrong corrections.

      1. Denying read does not deny execution. ADR-0003 said `srt` has no execute
         allowlist, so a binary is blocked by making it unreadable. The first half
         is true — `cat` on it is refused. The second half does not follow: srt's
         generated macOS profile carries an unconditional `(allow process-exec)`,
         while `denyRead` emits `file-read-data` denials, a different operation.
         So the binary is unopenable and fully runnable at once. Denying binaries
         could not have worked anyway, since the Security framework links
         in-process.

      2. The Keychain is protected regardless, by `denyRead` on $HOME. That is
         where the login Keychain file lives, and it is what actually stops the
         agent — not the denied binary, and not srt's Mach allowlist, which still
         permits com.apple.securityd.xpc and makes no difference either way.

      The load-bearing assertion is the second one, and it is load-bearing
      because the protection is incidental. Nothing was designed to put the
      Keychain out of reach; it is out of reach because of where Apple stores it.
      A future policy that adds a read-allow covering $HOME — and there is real
      pressure toward that, since a runtime under ~/.bun is unreadable for the
      same reason — would reopen it silently. This test is what makes that loud.

      Nothing here creates a Keychain item. This suite never touches the
      developer's real Keychain.
    */

    // The control, outside the sandbox: the binary is there and is executable.
    // Without it a denial would be indistinguishable from a machine that has no
    // `security` at all.
    accessSync('/usr/bin/security', constants.R_OK | constants.X_OK)

    // 1. Unreadable, and runs anyway.
    const read = await run('cat /usr/bin/security')
    expect(read.code).not.toBe(0)
    expect(read.stderr).toMatch(/not permitted|Permission denied|No such file/i)

    const ran = await run('/usr/bin/security help')
    expect(ran.stderr + ran.stdout).toMatch(/keychain|Usage/i)

    // 2. And still cannot see the login Keychain. `list-keychains` reports the
    //    search list this process actually has; the login Keychain is absent
    //    from it because its file is under a denied path.
    const listed = await run('/usr/bin/security list-keychains')
    expect(listed.code).toBe(0)
    expect(listed.stdout).not.toContain('login.keychain')
    expect(listed.stdout).toContain('System.keychain')

    // The file itself, directly. Belt and braces: if the search list ever stops
    // being a reliable signal, this stays true for as long as $HOME is denied.
    const file = await run(
      `cat ${JSON.stringify(join(homedir(), 'Library/Keychains/login.keychain-db'))}`,
    )
    expect(file.code).not.toBe(0)
    expect(file.stderr).toMatch(/not permitted|Permission denied|No such file/i)

    console.log(
      'boundary probe: /usr/bin/security is unreadable and executes anyway, but the login' +
        ' Keychain is not in the sandboxed search list and its file cannot be opened.' +
        ' The Keychain is protected by denyRead on $HOME — see ADR-0003.',
    )
  },
  120_000,
)

test.skipIf(blocked !== null)(
  'the machine-wide keychains cannot be opened or dumped either',
  async () => {
    /*
      The other keychain, and the one `denyRead` on $HOME never covered:
      /Library/Keychains sits outside every home directory. ADR-0003 recorded it
      as readable and called its contents "system certificates, not user
      secrets". That was wrong on this machine — dumping it listed 37 generic
      passwords, and the Wi-Fi networks this laptop has joined were among the
      labels. So it is denied outright now, and this is the probe that says so.

      Denying it costs nothing measurable: TLS to both allowlisted hosts still
      completes, and `codesign -v` already failed inside the Sandbox for an
      unrelated reason before this entry existed. The measurements are in
      ADR-0003.

      Read-only throughout. Nothing here creates or modifies a keychain item.
    */

    // The control, outside the sandbox: the file is there and is world-readable,
    // so a denial below means the policy did it and not the filesystem.
    accessSync('/Library/Keychains/System.keychain', constants.R_OK)

    const opened = await run('cat /Library/Keychains/System.keychain')
    expect(opened.code).not.toBe(0)
    expect(opened.stderr).toMatch(/not permitted|Permission denied|No such file/i)

    // The path that does not need the file to be openable by name: `security`
    // runs, and asking it to dump the keychain is how the contents leaked
    // before. It must come back with nothing.
    const dumped = await run('/usr/bin/security dump-keychain /Library/Keychains/System.keychain')
    expect(dumped.stdout).not.toContain('genp')
    expect(dumped.stdout).not.toContain('System.keychain')

    // The positive control for the two assertions above: `security` still runs
    // under the policy and still answers. Without this, a wrapper that silently
    // produced nothing at all would pass every "not.toContain" here.
    const listed = await run('/usr/bin/security list-keychains')
    expect(listed.code).toBe(0)
    expect(listed.stdout).toContain('System.keychain')

    // And the login Keychain is still absent from the search list — the deny
    // added here must not have changed how that is reached.
    expect(listed.stdout).not.toContain('login.keychain')

    console.log(
      'boundary probe: /Library/Keychains is denied — System.keychain cannot be opened' +
        ' and dump-keychain returns nothing. It is not covered by denyRead on $HOME.',
    )
  },
  120_000,
)

/*
  The one probe here that needs the internet. Measured against the host first,
  outside the sandbox: on a machine that is offline, or behind a proxy that eats
  these hosts, a red test would say "the policy broke TLS" when it did not. Same
  reasoning as `blocked` above — skip loudly, do not fail misleadingly.
*/
const offline = blocked
  ? 'the sandbox itself is unrunnable'
  : await fetch('https://registry.npmjs.org/left-pad', { method: 'HEAD' }).then(
      () => null,
      (cause) => `the host cannot reach registry.npmjs.org: ${cause}`,
    )

test.skipIf(offline !== null)(
  'the allowlisted hosts stay reachable with the keychains denied',
  async () => {
    /*
      The other half of the System.keychain decision. Denying a keychain that
      the TLS stack might consult is the kind of change that breaks the product
      quietly — the agent stops being able to authenticate, weeks later, and the
      policy is the last place anyone looks. So the deny ships with the check.

      405 rather than 200 from api.anthropic.com is the point: an HTTP status at
      all means the TLS handshake completed. The request is unauthenticated and
      carries no credential.
    */
    const anthropic = await run(
      'curl -sS -o /dev/null -w "%{http_code}" https://api.anthropic.com/v1/messages',
    )
    expect(anthropic.code).toBe(0)
    expect(anthropic.stdout.trim()).toMatch(/^[45]\d\d$/)

    const npm = await run(
      'curl -sS -o /dev/null -w "%{http_code}" https://registry.npmjs.org/left-pad',
    )
    expect(npm.code).toBe(0)
    expect(npm.stdout.trim()).toBe('200')
  },
  120_000,
)

if (blocked) {
  console.log(`sandbox boundary probe skipped — ${blocked}`)
} else if (offline) {
  console.log(`sandbox network probe skipped — ${offline}`)
}
