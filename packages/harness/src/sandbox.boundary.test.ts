import { afterAll, expect, test } from 'bun:test'
import { accessSync, constants, existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'
import { SandboxManager } from '@anthropic-ai/sandbox-runtime'
import { agentCommand } from './agent.ts'
import {
  establishSandbox,
  releaseSandbox,
  sandboxPolicyPath,
  type EstablishedSandbox,
} from './sandbox.ts'

/*
  The slow suite. Everything here runs a real process under a real kernel
  sandbox, which is the only way to learn anything about a containment
  boundary — a mocked sandbox proves the policy compiles, not that it holds.

  This file carries the single probe ticket 01 owes: a command run under the
  policy cannot read the home directory. The full matrix — Read, Grep and Glob
  denied the same paths as Bash, denied binaries, reachable and unreachable
  hosts — is ticket 04, which needs a running agent.

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

/**
 * This repository, used as the clone for the agent probe.
 *
 * The agent entry needs its dependencies, so a `mkdtemp` with nothing in it
 * cannot host it. Establishing a Sandbox here generates `sandbox-policy.json`
 * exactly as a first launch does — it is gitignored, and removed below if this
 * run is what created it.
 */
const repoRoot = resolve(import.meta.dir, '../../..')
const hadPolicy = blocked ? true : existsSync(sandboxPolicyPath(repoRoot))

/**
 * Run a command the way the Rust host runs the agent.
 *
 * The overlay is *added* to this process's environment rather than replacing
 * it, and the working directory is the one the wrapper named — both of which
 * are the contract src-tauri/src/agent.rs spawns against. A probe that spawned
 * differently would be measuring a boundary nothing else crosses.
 */
function runner(sandbox: EstablishedSandbox) {
  return async (command: string) => {
    const { argv, env, cwd } = await sandbox.wrap(command)
    const child = Bun.spawn({
      cmd: argv,
      cwd,
      env: { ...process.env, ...env },
      stdout: 'pipe',
      stderr: 'pipe',
    })
    const [stdout, stderr] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ])
    return { code: await child.exited, stdout, stderr }
  }
}

afterAll(async () => {
  if (blocked) return
  await releaseSandbox()
  rmSync(clone, { recursive: true, force: true })
  rmSync(outsideClone, { force: true })
  if (!hadPolicy) rmSync(sandboxPolicyPath(repoRoot), { force: true })
})

test.skipIf(blocked !== null)(
  'a command under the policy cannot read the home directory, but can read the clone',
  async () => {
    writeFileSync(insideClone, SECRET, 'utf8')
    writeFileSync(outsideClone, SECRET, 'utf8')

    const sandbox = await establishSandbox({ cloneRoot: clone })
    const run = runner(sandbox)

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
  'the real agent entry runs under the policy, and is contained when it does',
  async () => {
    // The probe ticket 03 owes. Every earlier boundary measurement here ran
    // `cat`, which proves the wrapper works and nothing about the thing the
    // product actually starts. This runs the real agent host — the same entry,
    // the same interpreter, the same wrapping the Rust host spawns — and asks
    // it what it can reach.
    //
    // `--selftest` opens no session and needs no credential, so this runs on a
    // machine that has never stored one. What it proves is the pair that
    // matters: the process can load the Agent SDK inside the Sandbox, and it
    // still cannot read outside the clone once it has.
    writeFileSync(outsideClone, SECRET, 'utf8')

    // One Sandbox per process, and `SandboxManager.initialize` returns early
    // once there is one — it does not replace the policy. The previous test
    // established a Sandbox for a different clone, so without this the probe
    // would run against that policy and fail for the wrong reason. Worth
    // knowing beyond this file: a second `check-sandbox` keeps the first
    // policy rather than adopting an edited one.
    await releaseSandbox()

    const sandbox = await establishSandbox({ cloneRoot: repoRoot })
    const run = runner(sandbox)

    const probe = await run(
      `${agentCommand({ cloneRoot: repoRoot })} --selftest ${JSON.stringify(outsideClone)}`,
    )
    if (probe.stdout.trim() === '') throw new Error(`the agent probe said nothing: ${probe.stderr}`)

    const report = JSON.parse(probe.stdout.trim().split('\n').at(-1) ?? '{}') as Record<
      string,
      string
    >

    // The control: the interpreter ran, and the Agent SDK loaded from inside
    // the Sandbox. Without this a denial below would only prove the process
    // never started.
    expect(report.sdk).toBe('loaded')
    // The boundary, measured from inside the real agent process.
    expect(report.read).toBe('denied')
    expect(probe.stdout).not.toContain(SECRET)
  },
  180_000,
)

test.skipIf(blocked !== null)(
  'security runs despite being unreadable, and still cannot reach the login Keychain',
  async () => {
    /*
      Two claims, measured separately, because conflating them cost this project
      three rounds of wrong corrections.

      1. Denying read does not deny execution. ADR-0003 said `srt` has no execute
         allowlist, so a binary is blocked by making it unreadable. The first half
         is true — `cat` on it is refused. The second half does not follow: srt's
         profile carries an unconditional `(allow process-exec)`, while `denyRead`
         emits `file-read-data` denials, a different operation. Denying binaries
         could not have worked anyway, since the Security framework links
         in-process and needs no binary at all.

      2. The Keychain is protected regardless, by `denyRead` on $HOME. That is
         where the login Keychain file lives, and it is what actually stops the
         agent — not the denied binary, and not srt's Mach allowlist, which still
         permits com.apple.securityd.xpc and makes no difference either way.

      The second assertion is load-bearing, because the protection is incidental.
      Nothing was designed to put the Keychain out of reach; it is out of reach
      because of where Apple stores it. A policy that later adds a read-allow
      covering $HOME reopens it silently. This test is what makes that loud.

      Nothing here creates a Keychain item. This suite never touches the
      developer's real Keychain.
    */
    const sandbox = await establishSandbox({ cloneRoot: clone })
    const run = runner(sandbox)

    // The control, outside the sandbox: the binary is there and is executable.
    accessSync('/usr/bin/security', constants.R_OK | constants.X_OK)

    // 1. Unreadable, and runs anyway.
    const read = await run('cat /usr/bin/security')
    expect(read.code).not.toBe(0)
    expect(read.stderr).toMatch(/not permitted|Permission denied|No such file/i)

    const ran = await run('/usr/bin/security help')
    expect(ran.stderr + ran.stdout).toMatch(/keychain|Usage/i)

    // 2. And still cannot see the login Keychain. `list-keychains` reports the
    //    search list this process actually has.
    const listed = await run('/usr/bin/security list-keychains')
    expect(listed.code).toBe(0)
    expect(listed.stdout).not.toContain('login.keychain')
    expect(listed.stdout).toContain('System.keychain')

    // The file itself. Belt and braces: true for as long as $HOME is denied.
    const file = await run(
      `cat ${JSON.stringify(join(homedir(), 'Library/Keychains/login.keychain-db'))}`,
    )
    expect(file.code).not.toBe(0)
    expect(file.stderr).toMatch(/not permitted|Permission denied|No such file/i)
  },
  120_000,
)

if (blocked) {
  console.log(`sandbox boundary probe skipped — ${blocked}`)
}
