import { afterAll, expect, test } from 'bun:test'
import {
  accessSync,
  constants,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { SandboxManager } from '@anthropic-ai/sandbox-runtime'
import { CREDENTIAL_ENV_VAR_NAMES, SELFTEST_MARKER, agentCommand } from './agent.ts'
import {
  PROBE_ATTESTATION_FILENAME,
  probeAttestationPath,
  readProbeAttestation,
  recordSdkToolProbeCompletion,
  sdkToolProbeStanding,
} from './probe-attestation.ts'
import {
  UNREADABLE_BINARIES,
  DEFAULT_ALLOWED_HOSTS,
  claudeScratchDirFor,
  describeSandboxViolation,
  establishSandbox,
  isUnexpectedViolation,
  releaseSandbox,
  ensureSandboxPolicy,
  sandboxPolicyFor,
  sandboxPolicyPath,
  sandboxViolations,
  type EstablishedSandbox,
  type SandboxPolicy,
} from './sandbox.ts'

/*
  The containment probes — ticket 04, and the only suite in this project whose
  job is to *measure* rather than to assert.

  Everything below runs a real process under the real kernel policy on the real
  machine and reports what it reached. That is slow and machine-dependent, and
  both are accepted: a fast version of this suite is a version that proves
  nothing, and this project has now been wrong three times about what the
  Sandbox stops — each time by reasoning instead of running a command.

  Three rules hold in every test here.

  1. **Every denial has a positive control beside it.** The same operation,
     succeeding where it is allowed to. Without one, a broken wrapper and a
     working boundary are indistinguishable and the suite reports green either
     way. Each control is named in a comment at the point it is used.

  2. **Nothing here weakens the policy to make a result tidier.** Where the
     shipped policy does not do what the documentation claimed, the measurement
     is recorded and the policy is left alone — see the UNREADABLE_BINARIES matrix,
     which is the second suite in this repo to write down that denying read is
     not denying execution.

  3. **It skips with a printed reason rather than failing** where the platform,
     the network, or a missing credential make a probe unrunnable. A red suite
     everyone learns to ignore is worse than a skipped one, but a silent skip is
     worse than both, so every skip prints why.

     That rule is right and it was not enough — ticket 26. Probe 6 needs a
     credential, skipped from the day it was written, and printed its reason on
     every single run; behind it sat a real defect (ticket 27) and a fictional
     one that cost most of a day. A printed reason answers "why is this skipped
     today", and nobody was ever asking that. The question nobody could ask was
     "has this ever run at all", because a skip taken this morning and a skip
     taken every morning since the file was written look identical.

     So the skip now carries a fourth thing. `probe-attestation.json` is a
     committed record of the last end-to-end completion, written by the probe
     itself and by nothing else, and the standing test below reports it whether
     it skips or not. A machine's inability to measure stays a skip; the
     repository's never having measured is a fact in the repository. And the
     failing half moved to where it belongs — `bun run probe` (probe-cli.ts)
     has no skip in it, fails when it cannot measure, and is what a maintainer
     runs before quoting the README's *Where confinement stops*.

  This file never touches the developer's keychain. It creates no keychain, adds
  no item, and changes no search list; the login-Keychain assertion lives in
  sandbox.boundary.test.ts and is deliberately not duplicated or relaxed here.
*/

// ---------------------------------------------------------------------------
// Whether this machine can run any of it
// ---------------------------------------------------------------------------

function unrunnableBecause(): string | null {
  if (!SandboxManager.isSupportedPlatform()) {
    return `sandbox-runtime does not support ${process.platform}`
  }
  const deps = SandboxManager.checkDependencies()
  return deps.errors.length > 0 ? `missing dependencies: ${deps.errors.join(', ')}` : null
}

const blocked = unrunnableBecause()

/**
 * This repository, used as the clone.
 *
 * The agent entry needs its dependencies resolvable, so a bare `mkdtemp` cannot
 * host it. Establishing a Sandbox here generates `sandbox-policy.json` exactly
 * as a first launch does; it is gitignored, and removed below if this run is
 * what created it.
 */
const repoRoot = resolve(import.meta.dir, '../../..')
const hadPolicy = blocked ? true : existsSync(sandboxPolicyPath(repoRoot))

/**
 * Outside the boundary: a directory under `$HOME`, which `denyRead` covers.
 *
 * A directory rather than a lone file because two of the four probes are
 * enumerations — `Glob` walks a directory and `Grep` searches one — and a probe
 * that only ever names a single path cannot measure either.
 */
const outsideDir = blocked ? '' : mkdtempSync(join(homedir(), '.varnick-probe-outside-'))
const outsideFile = blocked ? '' : join(outsideDir, 'probe.txt')

/**
 * Inside the boundary: the control, in the one tree the policy reads back out.
 *
 * Every denial below is paired against this directory. It has to live inside the
 * clone, because the clone is the only thing `allowRead` names.
 */
const insideDir = blocked ? '' : join(repoRoot, `.varnick-probe-inside-${process.pid}`)
const insideFile = blocked ? '' : join(insideDir, 'probe.txt')

if (!blocked) {
  writeFileSync(outsideFile, SELFTEST_MARKER, 'utf8')
  mkdirSync(insideDir, { recursive: true })
  writeFileSync(insideFile, SELFTEST_MARKER, 'utf8')
}

afterAll(async () => {
  if (blocked) return
  await releaseSandbox()
  rmSync(outsideDir, { recursive: true, force: true })
  rmSync(insideDir, { recursive: true, force: true })
  if (!hadPolicy) rmSync(sandboxPolicyPath(repoRoot), { force: true })
})

// ---------------------------------------------------------------------------
// Running things under the policy
// ---------------------------------------------------------------------------

interface Ran {
  readonly code: number
  readonly stdout: string
  readonly stderr: string
}

/**
 * Run a command the way the Rust host runs the agent.
 *
 * The overlay is *added* to this process's environment rather than replacing it,
 * and the working directory is the one the wrapper named — both of which are the
 * contract `src-tauri/src/agent.rs` spawns against. A probe that spawned
 * differently would be measuring a boundary nothing else crosses.
 */
function runner(sandbox: EstablishedSandbox) {
  return async (command: string): Promise<Ran> => {
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

/**
 * A fresh Sandbox for this clone.
 *
 * `SandboxManager.initialize` returns early once a Sandbox exists — it does not
 * replace the policy — so a suite that establishes more than one has to tear the
 * previous one down or it silently measures the first. Worth knowing beyond this
 * file: a second `check-sandbox` keeps the first policy rather than adopting an
 * edited one.
 */
async function freshSandbox(cloneRoot: string) {
  await releaseSandbox()
  return establishSandbox({ cloneRoot })
}

/** The suite's output, printed as one block per probe so it can be quoted. */
function report(title: string, rows: readonly (readonly [string, string])[]): void {
  const width = Math.max(...rows.map(([label]) => label.length))
  const lines = rows.map(([label, value]) => `  ${label.padEnd(width)}  ${value}`)
  console.log([`\n${title}`, ...lines, ''].join('\n'))
}

/**
 * One line of evidence, trimmed to something a report can hold.
 *
 * Non-printing bytes are collapsed rather than quoted: one of these commands
 * succeeds by handing back the contents of a Mach-O binary, and a report that
 * pasted those into a terminal would be unreadable and unquotable.
 */
function outcome(ran: Ran): string {
  const raw = (ran.stdout + ran.stderr).trim()
  const printable = raw.replace(/[^\x20-\x7e\n]+/g, '·')
  // The clone's absolute path is this machine's, is long, and is the same on
  // every line. Shortened so the part that differs — what the kernel said — is
  // what survives the truncation.
  const said = (printable.split('\n')[0] ?? '').replaceAll(repoRoot, '<clone>')
  return `exit ${ran.code}${said === '' ? '' : ` — ${said.slice(0, 100)}`}`
}

// ---------------------------------------------------------------------------
// 1. Bash, Read, Grep and Glob, measured against the same file
// ---------------------------------------------------------------------------

test.skipIf(blocked !== null)(
  'a file outside the boundary is unreachable by Bash, Read, Grep and Glob alike',
  async () => {
    /*
      The criterion this ticket exists for. `Read`, `Grep` and `Glob` are the
      three that walked past the Agent SDK's own `sandbox` option — they are
      JavaScript in the agent's process calling `fs`, so nothing ever hands them
      to the kernel — and they are the reason ADR-0003 moved containment onto the
      whole process tree with `srt`.

      Measuring them therefore cannot mean running `cat`. It means running those
      calls inside the real agent entry, under the real wrapping, which is what
      `agent.ts --selftest` does: `readFileSync` for Read, `readdirSync` for what
      Glob walks, a pattern match over that walk for Glob, and a content match
      over it for Grep.

      What this does *not* claim: it does not execute the SDK's own tool
      implementations, which live in the Claude Code process the SDK starts and
      need a credential to reach. That probe is the last test in this file and it
      skips without one. The two are the same syscalls under the same kernel
      policy in the same process tree, which is why this one is the load-bearing
      measurement and that one is the confirmation.
    */
    const sandbox = await freshSandbox(repoRoot)
    const run = runner(sandbox)

    const probe = await run(
      `${agentCommand({ cloneRoot: repoRoot })} --selftest ${JSON.stringify(outsideFile)} ${JSON.stringify(insideFile)}`,
    )
    if (probe.stdout.trim() === '') throw new Error(`the agent probe said nothing: ${probe.stderr}`)
    const answers = JSON.parse(probe.stdout.trim().split('\n').at(-1) ?? '{}') as Record<
      string,
      string
    >

    // Bash, from the same Sandbox, so all four are measured against one file.
    const bashOutside = await run(`cat ${JSON.stringify(outsideFile)}`)
    const bashInside = await run(`cat ${JSON.stringify(insideFile)}`)

    report('probe 1 — one file outside the clone, four ways to ask for it', [
      ['Agent SDK loaded inside the Sandbox', answers.sdk ?? '(nothing)'],
      ['', ''],
      ['Bash  cat  outside', outcome(bashOutside)],
      ['Read  readFileSync  outside', `${answers.read} (${answers.readWhy})`],
      ['Glob  readdir+match  outside', `${answers.glob} (${answers.globWhy})`],
      ['Grep  content match  outside', `${answers.grep} (${answers.grepWhy})`],
      ['      readdir  outside', `${answers.list} (${answers.listWhy})`],
      ['', ''],
      ['Bash  cat  inside  (control)', outcome(bashInside)],
      ['Read  readFileSync  inside  (control)', `${answers.readControl} (${answers.readControlWhy})`],
      ['Glob  readdir+match  inside  (control)', `${answers.globControl} (${answers.globControlWhy})`],
      ['Grep  content match  inside  (control)', `${answers.grepControl} (${answers.grepControlWhy})`],
      ['      readdir  inside  (control)', `${answers.listControl} (${answers.listControlWhy})`],
    ])

    // The controls first, because they are what make the denials mean anything.
    // The process started, the SDK loaded from inside the Sandbox, and all four
    // operations succeed where the policy allows them.
    expect(answers.sdk).toBe('loaded')
    expect(answers.readControl).toBe('permitted')
    expect(answers.listControl).toBe('permitted')
    expect(answers.globControl).toBe('permitted')
    expect(answers.grepControl).toBe('permitted')
    expect(bashInside.code).toBe(0)
    expect(bashInside.stdout).toContain(SELFTEST_MARKER)

    // The boundary. Same marker, same shapes, one directory to the side.
    expect(answers.read).toBe('denied')
    expect(answers.list).toBe('denied')
    expect(answers.glob).toBe('denied')
    expect(answers.grep).toBe('denied')
    expect(bashOutside.code).not.toBe(0)
    expect(bashOutside.stdout).not.toContain(SELFTEST_MARKER)

    // And the marker never appears anywhere in what the probe printed, which is
    // the one assertion that would catch a probe reporting `denied` while having
    // read the bytes anyway.
    expect(probe.stdout).not.toContain(SELFTEST_MARKER)
  },
  180_000,
)

// ---------------------------------------------------------------------------
// 2. Every entry in UNREADABLE_BINARIES, measured
// ---------------------------------------------------------------------------

/**
 * A harmless way to ask each denied binary whether it ran.
 *
 * Every one is chosen to have an observable answer and no effect: `security
 * help` prints usage, `osascript` evaluates arithmetic, `open --help` fails with
 * its own usage error, `sudo -V` prints a version and asks for no privilege.
 * Nothing here creates, reads or modifies a keychain item, and nothing here
 * prompts.
 */
const EXECUTION_PROBES: Readonly<Record<string, string>> = {
  '/usr/bin/security': '/usr/bin/security help',
  '/usr/bin/osascript': "/usr/bin/osascript -e 'return 6*7'",
  '/usr/bin/open': '/usr/bin/open --help',
  '/usr/bin/sudo': '/usr/bin/sudo -V',
}

/** Run a command with no Sandbox at all — the control side of probe 2. */
async function runUnconfined(command: string): Promise<Ran> {
  const child = Bun.spawn({
    cmd: ['/bin/bash', '-c', command],
    cwd: repoRoot,
    env: process.env,
    stdout: 'pipe',
    stderr: 'pipe',
  })
  const [stdout, stderr] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ])
  return { code: await child.exited, stdout, stderr }
}

/**
 * Did the binary answer in its own voice?
 *
 * Not an exit code: `open --help` and several of the others fail on purpose. The
 * question is whether the process got as far as producing its own output rather
 * than the kernel's refusal.
 */
function spoke(ran: Ran): boolean {
  return !/not permitted|Permission denied|No such file|command not found/i.test(
    ran.stderr + ran.stdout,
  )
}

test.skipIf(blocked !== null)(
  'every entry in UNREADABLE_BINARIES is measured, and three of the four still execute',
  async () => {
    /*
      The criterion this ticket had to correct. It originally read "each denied
      binary reports as not found"; that is false, and the false version was
      believed for three rounds.

      `srt` has no execute allowlist, so `UNREADABLE_BINARIES` blocks a binary by
      making it unreadable. Denying read is not denying execution: srt's profile
      carries an unconditional `(allow process-exec)` while `denyRead` emits
      `file-read-data` denials, and those are different operations. `security`,
      `osascript` and `open` all run. Only `sudo` is stopped, and for a reason of
      its own — it is setuid, and a setuid binary the kernel will not let the
      process read is a setuid binary it will not let the process exec.

      This measures all four and asserts what is true rather than what was
      wished. The entries stay: they are still worth having, because they stop
      the *contents* of those binaries being read, and because removing them
      would be a policy change made to tidy a test.
    */
    const sandbox = await freshSandbox(repoRoot)
    const run = runner(sandbox)

    // The first control, inside the Sandbox: execution works at all. A binary
    // that is not on the list runs, so a denial below is about the denial rather
    // than about a wrapper that cannot start anything.
    const echo = await run('/bin/echo sandbox-can-exec')
    expect(echo.code).toBe(0)
    expect(echo.stdout).toContain('sandbox-can-exec')

    const rows: [string, string][] = [['/bin/echo  exec  (control)', outcome(echo)], ['', '']]
    const executed: Record<string, boolean> = {}

    for (const binary of UNREADABLE_BINARIES) {
      // The second control, outside the Sandbox: this exact command answers on
      // this machine. It is what makes a refusal inside mean the Sandbox rather
      // than a missing binary, a wrong flag, or a machine that never had it.
      const control = await runUnconfined(EXECUTION_PROBES[binary] ?? binary)
      expect(spoke(control)).toBe(true)

      const read = await run(`cat ${JSON.stringify(binary)}`)
      const exec = await run(EXECUTION_PROBES[binary] ?? binary)
      executed[binary] = spoke(exec)

      // Whether the file was readable *before* the policy ever applied. Recorded
      // rather than asserted, because `/usr/bin/sudo` is mode `-r-s--x--x` and so
      // is unreadable to every non-root process on the machine — which means its
      // `denyRead` entry denies nothing that was not already denied.
      let readableOutside = true
      try {
        accessSync(binary, constants.R_OK)
      } catch {
        readableOutside = false
      }

      rows.push([`${binary}  exec, no Sandbox  (control)`, outcome(control)])
      rows.push([
        `${binary}  readable to this user at all`,
        readableOutside ? 'yes' : 'no — mode denies it before any policy does',
      ])
      rows.push([`${binary}  read, sandboxed`, outcome(read)])
      rows.push([
        `${binary}  exec, sandboxed`,
        `${executed[binary] ? 'RUNS ANYWAY' : 'blocked'} — ${outcome(exec)}`,
      ])
      rows.push(['', ''])

      // The half of the claim that is true: the bytes of the binary are denied.
      expect(read.code).not.toBe(0)
      expect(read.stderr).toMatch(/not permitted|Permission denied|No such file/i)
    }

    report('probe 2 — UNREADABLE_BINARIES: read is denied, execution mostly is not', rows)

    // The half that is not, written down as an assertion so that a future srt
    // release which *does* block execution fails here and gets noticed, instead
    // of quietly making ADR-0003's correction stale.
    expect(executed['/usr/bin/security']).toBe(true)
    expect(executed['/usr/bin/osascript']).toBe(true)
    expect(executed['/usr/bin/open']).toBe(true)
    expect(executed['/usr/bin/sudo']).toBe(false)
  },
  180_000,
)

test.skipIf(blocked !== null)(
  'sudo is stopped by being setuid, not by being on the denied list',
  async () => {
    /*
      ADR-0003 says sudo is blocked "for its own setuid reason". That sentence
      was reasoned, not measured, and reasoning is what this project has been
      wrong about three times — so here is the measurement.

      A throwaway clone gets the same policy with `UNREADABLE_BINARIES` lifted out of
      `denyRead` and nothing else changed. If sudo runs under it, the deny is
      what stopped it. If sudo is still refused, the deny was never what stopped
      it, and removing those entries would not hand sudo back.

      **This changes no shipped policy.** `sandboxPolicyFor` is pure and the
      variant is written into a temp directory that is deleted below; the product
      still generates the list it always did. The variant exists to answer a
      question about the list, which is the opposite of loosening it to make a
      result tidier.
    */
    await releaseSandbox()
    const clone = mkdtempSync(join(homedir(), '.varnick-probe-nodeny-'))
    try {
      const base = sandboxPolicyFor({ cloneRoot: clone })
      const variant = {
        ...base,
        filesystem: {
          ...base.filesystem,
          denyRead: base.filesystem.denyRead.filter(
            (path) => !(UNREADABLE_BINARIES as readonly string[]).includes(path),
          ),
        },
      }
      expect(variant.filesystem.denyRead.length).toBe(base.filesystem.denyRead.length - 4)

      // Generate the policy *and its baseline* first, then apply the variant on
      // top. Ticket 17 merges a policy forward against its baseline, and a clone
      // with no baseline can attribute nothing, so it takes the stronger side of
      // every difference — which would put the four entries straight back and
      // make this probe measure the shipped policy under another name. With the
      // baseline recorded and untouched, lifting them out is attributable as an
      // edit, and an edit is kept. That is ticket 17's contract, used rather
      // than worked around.
      ensureSandboxPolicy({ cloneRoot: clone })
      writeFileSync(sandboxPolicyPath(clone), JSON.stringify(variant), 'utf8')

      const sandbox = await establishSandbox({ cloneRoot: clone })
      const run = runner(sandbox)

      // The control: with the entry lifted, the binary's bytes are readable
      // again. That is what proves this variant policy is the one in force —
      // without it, "sudo still blocked" could just mean the policy never
      // changed.
      const readSecurity = await run('cat /usr/bin/security')
      const readSudo = await run('cat /usr/bin/sudo')
      const execSudo = await run(EXECUTION_PROBES['/usr/bin/sudo'] ?? '')

      report('probe 2b — the same policy with the denied binaries lifted out', [
        ['/usr/bin/security  read  (control)', outcome(readSecurity)],
        ['/usr/bin/sudo  read', outcome(readSudo)],
        ['/usr/bin/sudo  exec', `${spoke(execSudo) ? 'RUNS' : 'blocked'} — ${outcome(execSudo)}`],
      ])

      expect(readSecurity.code).toBe(0)

      // And sudo is refused anyway. The denied list is not what stops it; being
      // setuid is, and its own file mode already forbids the read besides.
      expect(spoke(execSudo)).toBe(false)
    } finally {
      await releaseSandbox()
      rmSync(clone, { recursive: true, force: true })
    }
  },
  180_000,
)

// ---------------------------------------------------------------------------
// 3. The network allowlist
// ---------------------------------------------------------------------------

const ALLOWED_HOST = DEFAULT_ALLOWED_HOSTS[0]
const UNLISTED_HOST = 'example.com'

test.skipIf(blocked !== null)(
  'an allowlisted host is reachable and an unlisted one is not',
  async () => {
    /*
      `strictAllowlist` with no ask callback registered, so an unlisted host is a
      denial rather than a question.

      Reaching api.anthropic.com's root without a credential answers 404, and
      that is the proof: a 404 is the host having replied. What is measured is
      whether bytes crossed, never whether a request succeeded — which is why the
      verdict is "did curl get a status code at all" rather than a particular
      one. `000` is curl's own word for never having connected.
    */
    const sandbox = await freshSandbox(repoRoot)
    const run = runner(sandbox)

    const curl = (host: string) =>
      run(`/usr/bin/curl -sS -o /dev/null -m 25 -w '%{http_code}' https://${host}/`)

    const allowed = await curl(ALLOWED_HOST)
    const unlisted = await curl(UNLISTED_HOST)

    report('probe 3 — the network allowlist', [
      [`${ALLOWED_HOST}  (allowlisted, control)`, outcome(allowed)],
      [`${UNLISTED_HOST}  (not on the list)`, outcome(unlisted)],
    ])

    // The control. If this machine is offline the probe cannot tell a denial
    // from a dead link, so it says so and stops rather than reporting a boundary
    // it did not observe.
    if (allowed.code !== 0 || !/^\d{3}$/.test(allowed.stdout.trim())) {
      console.log(
        `network probe skipped — the allowlisted host ${ALLOWED_HOST} did not answer, so an unreachable host proves nothing: ${outcome(allowed)}`,
      )
      return
    }
    expect(allowed.stdout.trim()).not.toBe('000')

    // The boundary.
    const reachedUnlisted = unlisted.code === 0 && /^[1-3]\d\d$/.test(unlisted.stdout.trim())
    expect(reachedUnlisted).toBe(false)
  },
  180_000,
)

// ---------------------------------------------------------------------------
// 4. No path that proceeds without a Sandbox
// ---------------------------------------------------------------------------

test.skipIf(blocked !== null)(
  'a clone whose policy cannot be established gets no agent, not an unconfined one',
  async () => {
    /*
      The product's only real claim: there is no fallback to running unconfined.
      No flag, no environment variable, no debug path. This measures the failure
      rather than reading the code for it — a clone carrying a policy srt's own
      schema rejects, which is what an edited `sandbox-policy.json` produces.
    */
    await releaseSandbox()
    const clone = mkdtempSync(join(homedir(), '.varnick-probe-policy-'))
    try {
      // The control: the same clone, with the policy the generator writes,
      // establishes and wraps. Without it a rejection proves only that the
      // directory was wrong.
      const good = await establishSandbox({ cloneRoot: clone })
      const wrapped = await good.wrap('/bin/echo ok')
      expect(wrapped.argv.length).toBeGreaterThan(0)
      expect(wrapped.cwd).toBe(clone)
      await releaseSandbox()

      // The boundary: a policy the schema refuses. `establishSandbox` has three
      // ways to fail and no way to degrade, so this must raise.
      writeFileSync(
        sandboxPolicyPath(clone),
        JSON.stringify({ network: { allowedDomains: 'nope' } }),
        'utf8',
      )
      let raised: unknown = null
      try {
        await establishSandbox({ cloneRoot: clone })
      } catch (error) {
        raised = error
      }

      report('probe 4 — a policy that cannot be established', [
        ['valid policy  (control)', 'established, and wrapped a command'],
        [
          'policy the schema rejects',
          raised instanceof Error ? `raised — ${raised.message.split('\n')[0]}` : String(raised),
        ],
      ])

      expect(raised).toBeInstanceOf(Error)
      expect((raised as Error).message).toMatch(/allowedDomains|not a policy/i)
    } finally {
      await releaseSandbox()
      rmSync(clone, { recursive: true, force: true })
    }
  },
  120_000,
)

// ---------------------------------------------------------------------------
// 5. The write boundary, including the two gaps left open on purpose
// ---------------------------------------------------------------------------

test.skipIf(blocked !== null)(
  'Core is unwritable, and the two gaps ADR-0002 left open are still open',
  async () => {
    /*
      ADR-0002 says the Core/Userspace split is enforced by the policy rather
      than by convention, and names two holes it left open deliberately —
      "measured by the probes in ticket 04 rather than quietly assumed shut".
      This is that measurement, and it is here because a probe suite that
      reported only good news would be worth nothing.

      Every write below goes to a path that either does not exist or is restored
      afterwards; nothing in the repository is left modified.
    */
    const sandbox = await freshSandbox(repoRoot)
    const run = runner(sandbox)

    // Written through `sh -c` inside the Sandbox rather than from this process,
    // because this process is not confined and would succeed at all six.
    const write = (path: string) => run(`/bin/echo probe > ${JSON.stringify(path)}`)
    // Absolute paths pass through: `allowWrite` names two trees and only one of
    // them is the clone, so the second cannot be written as a relative path.
    const scratch = (path: string) => (path.startsWith('/') ? path : join(repoRoot, path))

    const targets: [string, string, 'denied' | 'open'][] = [
      // Core, and the fence's own generator. Denied.
      ['packages/core/.varnick-probe-write', 'Core', 'denied'],
      ['packages/harness/.varnick-probe-write', 'the Harness', 'denied'],
      ['package.json', 'the root package.json', 'denied'],
      ['sandbox-policy.json', 'the generated policy', 'denied'],
      // The entry ADR-0002 keeps for a file that does not exist yet.
      ['vite.config.ts', 'a root vite.config', 'denied'],
      // Gap one: Userspace's own manifest, whose postinstall runs on the host.
      ['packages/userspace/package.json', "Userspace's package.json", 'open'],
      // The control: ordinary Userspace work, which must stay possible.
      ['packages/userspace/surfaces/.varnick-probe-write', 'a Userspace Surface', 'open'],
      /*
        The second writable tree, which had never been measured while the README
        claimed the clone and this one were the only two. `tmpdir()` is not
        `/private/tmp` on macOS — it is the per-user `/var/folders/...` directory
        `$TMPDIR` points at — and probe 7 writes into `/private/tmp` and is
        refused, so the pair is what shows the allowlist is a path list rather
        than the word "temp".
      */
      [join(tmpdir(), '.varnick-probe-write'), 'the OS temp directory', 'open'],
    ]

    const before = new Map<string, string | null>()
    for (const [relative] of targets) {
      const path = scratch(relative)
      before.set(path, existsSync(path) ? readFileSync(path, 'utf8') : null)
    }

    try {
      const rows: [string, string][] = []
      const results = new Map<string, boolean>()
      for (const [relative, label, expected] of targets) {
        const ran = await write(scratch(relative))
        const wrote = ran.code === 0
        results.set(relative, wrote)
        rows.push([
          `${label}  (${expected === 'open' ? 'open on purpose' : 'denied'})`,
          `${wrote ? 'WRITABLE' : 'refused'} — ${outcome(ran)}`,
        ])
      }
      report('probe 5 — the write boundary, and what it deliberately does not cover', rows)

      // The control first: Userspace is writable, so a refusal above is the
      // policy rather than a read-only checkout or a broken redirect.
      expect(results.get('packages/userspace/surfaces/.varnick-probe-write')).toBe(true)

      // The boundary.
      expect(results.get('packages/core/.varnick-probe-write')).toBe(false)
      expect(results.get('packages/harness/.varnick-probe-write')).toBe(false)
      expect(results.get('package.json')).toBe(false)
      expect(results.get('sandbox-policy.json')).toBe(false)
      expect(results.get('vite.config.ts')).toBe(false)

      // The gap, asserted as open so that closing it is a decision someone makes
      // rather than a change nobody notices. `packages/userspace/package.json`
      // is writable, and a `postinstall` written there runs on the host at the
      // next install — ADR-0002 accepts that, because closing it would also stop
      // the agent adding a Userspace dependency, which is ordinary work.
      expect(results.get('packages/userspace/package.json')).toBe(true)

      // The other writable tree. Asserted here so "the clone and the OS temp
      // directory are the only writable trees" has both halves measured: this
      // one succeeds, and probe 7's write outside both is refused.
      expect(results.get(join(tmpdir(), '.varnick-probe-write'))).toBe(true)
    } finally {
      for (const [path, contents] of before) {
        if (contents === null) rmSync(path, { force: true })
        else writeFileSync(path, contents, 'utf8')
      }
    }
  },
  180_000,
)

// ---------------------------------------------------------------------------
// 6. The Agent SDK's own Read, Grep and Glob tools
// ---------------------------------------------------------------------------

/**
 * Why the real-tool probe cannot run, or null when it can.
 *
 * It needs a credential, because it opens a real Session and asks the model to
 * call the tools. There is deliberately no way to fake one: the Sandbox denies
 * local binding and every unlisted host, so a stub API is unreachable from
 * inside, and widening the policy to reach one would be widening the policy to
 * make a probe pass.
 */
const CREDENTIAL_VARIABLES = CREDENTIAL_ENV_VAR_NAMES.join(' or ')

const toolProbeBlocked =
  blocked ??
  // Either kind opens a Session — an API key or a subscription token. The probe
  // does not care which authenticated it, only that something did.
  (CREDENTIAL_ENV_VAR_NAMES.some((name) => process.env[name])
    ? null
    : `no ${CREDENTIAL_VARIABLES} in the environment, so no Session can be opened`)

/**
 * Whether *this* run got probe 6 all the way through.
 *
 * Set at the probe's last line and read by the standing test at the bottom of
 * the file. It is not the same question as the suite's exit code: probe 6 has a
 * legitimate bail-out — a Session that never authenticated produces the same
 * empty shape as one whose every tool was denied, so it reports and returns
 * rather than asserting a denial nobody observed — and that path exits green
 * having measured nothing. This flag is what tells the two apart.
 */
let sdkToolProbeCompleted = false

test.skipIf(toolProbeBlocked !== null)(
  "the Agent SDK's own Read, Grep and Glob tools are denied the same file",
  async () => {
    /*
      The confirmation for probe 1. Probe 1 runs the syscalls those tools make,
      in the agent process, under the same policy; this runs the tools
      themselves, in the Claude Code process the SDK starts, which is inside the
      same process tree and therefore inside the same Sandbox.

      It is the confirmation rather than the measurement because it is the less
      reliable of the two: it depends on a model choosing to call a tool, and a
      model that declines produces a denial-shaped answer for the wrong reason.
      The controls below are what separate those — the same tools, against the
      clone, must come back with the marker.
    */
    const sandbox = await freshSandbox(repoRoot)
    const run = runner(sandbox)

    const probe = await run(
      `${agentCommand({ cloneRoot: repoRoot })} --toolprobe ${JSON.stringify(outsideFile)} ${JSON.stringify(insideFile)}`,
    )
    if (probe.stdout.trim() === '') throw new Error(`the tool probe said nothing: ${probe.stderr}`)
    const answers = JSON.parse(probe.stdout.trim().split('\n').at(-1) ?? '{}') as Record<
      string,
      string
    >

    report("probe 6 — the SDK's own tools, driven by a real Session", [
      ['how the Session ended', answers.session ?? '(no result message)'],
      ['', ''],
      ['Read  outside', answers.read ?? '(nothing)'],
      ['Grep  outside', answers.grep ?? '(nothing)'],
      ['Glob  outside', answers.glob ?? '(nothing)'],
      ['', ''],
      ['Read  inside  (control)', answers.readControl ?? '(nothing)'],
      ['Grep  inside  (control)', answers.grepControl ?? '(nothing)'],
      ['Glob  inside  (control)', answers.globControl ?? '(nothing)'],
      ['', ''],
      ['tools the Session actually called', answers.called || '(none)'],
      ...(['read', 'grep', 'glob'] as const).flatMap((tool) => {
        // What a tool answered when it did not reach the file. Printed only when
        // there is something to print, because the first time a control here
        // failed, the report said "denied" and nothing else — and the tool had
        // in fact succeeded and answered with a relative path.
        const why = answers[`${tool}ControlAnswered`]
        return why === undefined ? [] : [[`${tool} control answered`, why] as const]
      }),
    ])

    // A Session that could not run is not a boundary result. Reported and
    // stopped, rather than asserted into a denial it never observed — a refused
    // credential and a contained agent produce the identical empty answer.
    if (answers.session === undefined || !answers.session.startsWith('ok')) {
      console.log(
        `containment probe 6 stopped — the Session ended as "${answers.session ?? 'no result'}", so it never reached a tool. Nothing about the boundary was measured here; probes 1-5 are what stand.`,
      )
      return
    }

    // The controls: each tool ran and reached the marker where it is allowed to.
    expect(answers.readControl).toBe('permitted')
    expect(answers.grepControl).toBe('permitted')
    expect(answers.globControl).toBe('permitted')

    // The boundary.
    expect(answers.read).toBe('denied')
    expect(answers.grep).toBe('denied')
    expect(answers.glob).toBe('denied')
    expect(probe.stdout).not.toContain(SELFTEST_MARKER)

    /*
      And the record — ticket 26, and the last line of the probe on purpose.

      Everything above has passed, so this is the one place in the project that
      can say the SDK's own tools were measured. It writes the date, the commit
      and the six verdicts into `probe-attestation.json`, which is committed, is
      under the tree the sandbox policy denies the agent, and is the only thing
      that distinguishes "skipped this morning" from "never once run since the
      probe was written". A printed reason could not, and that is what let this
      probe hide two defects for the life of the project.

      Recorded rather than asserted against: a run that gets here has measured
      the boundary, and refusing to write that down because the previous record
      was old would be the tail wagging the dog.
    */
    sdkToolProbeCompleted = true
    // Every one of these is asserted above, so the fallback is unreachable. It
    // is here rather than a cast because a record that quietly lost a key would
    // be a record that says less than it looks like it says.
    const verdict = (key: string): string => answers[key] ?? '(absent from the probe output)'
    const wrote = recordSdkToolProbeCompletion({
      read: verdict('read'),
      grep: verdict('grep'),
      glob: verdict('glob'),
      readControl: verdict('readControl'),
      grepControl: verdict('grepControl'),
      globControl: verdict('globControl'),
      session: verdict('session'),
    })
    console.log(
      wrote
        ? `probe 6 completed and updated ${probeAttestationPath()} — commit that change, it is the evidence.`
        : `probe 6 completed; ${PROBE_ATTESTATION_FILENAME} already said so for today at this commit.`,
    )
  },
  600_000,
)

test.skipIf(blocked !== null)(
  'a repository outside a home directory is unreadable now, and writes to it still are',
  async () => {
    /*
      The probe that carried ADR-0003's fourth correction, inverted by ticket 18.

      It used to measure the asymmetry and report it: `denyRead` was a deny list
      naming /Users, the home directory, /Library/Keychains and four binaries,
      and everything outside it — a repository on /opt, /srv, /Volumes or an
      external disk — was readable in full. Writes were already a real allowlist
      and held. The two halves of the boundary did not describe each other, and
      this is where that was visible.

      `denyRead` now names the filesystem root and `allowRead` is the whole of
      what is readable, so the read below is refused for the same reason the
      write is. **The measurement is unchanged and the verdict is inverted** —
      the same repository, planted in the same place, asked the same question.

      Its control had to change with it. "The same read under $HOME is refused"
      distinguished nothing once both are refused, so the control is now a read
      *inside* the clone, which is what separates a boundary from a broken
      wrapper. The old control stays beside it, because $HOME being denied by a
      name of its own rather than by the root is still worth measuring.
    */
    const outside = mkdtempSync('/private/tmp/varnick-outside-home-')
    // The control's file, created rather than assumed. This used to read
    // `~/.zshrc`, which meant that on a machine without one `cat` exited
    // non-zero for "No such file" and the control proved nothing — a probe that
    // passes for the wrong reason is worse than one that fails. Writing the
    // marker here makes the assertion about the *bytes* rather than about an
    // exit code, so a missing file can no longer stand in for a denial.
    const insideHome = mkdtempSync(join(homedir(), '.varnick-probe-control-'))
    try {
      mkdirSync(join(outside, '.git'), { recursive: true })
      writeFileSync(join(outside, 'secret.txt'), SELFTEST_MARKER, 'utf8')

      const run = runner(await establishSandbox({ cloneRoot: repoRoot }))

      // The control, and the one this probe gained when its verdict flipped: the
      // same `cat`, on an identical file inside the clone, hands back the marker.
      // Without it every line below is equally true of a wrapper that cannot run
      // anything at all.
      const insideClone = await run(`cat ${JSON.stringify(insideFile)}`)
      expect(insideClone.code).toBe(0)
      expect(insideClone.stdout).toContain(SELFTEST_MARKER)

      // The read, which is now refused. A repository here is protected by the
      // denied root rather than left open by a deny list that never named it.
      const read = await run(`cat ${JSON.stringify(join(outside, 'secret.txt'))}`)
      expect(read.code).not.toBe(0)
      expect(read.stdout).not.toContain(SELFTEST_MARKER)

      // The control this probe was written with, kept: a read under a home
      // directory is refused by a denial varnick *names*, not only by the root.
      const controlFile = join(insideHome, 'secret.txt')
      writeFileSync(controlFile, SELFTEST_MARKER, 'utf8')
      const underHome = await run(`cat ${JSON.stringify(controlFile)}`)
      expect(underHome.code).not.toBe(0)
      expect(underHome.stdout).not.toContain(SELFTEST_MARKER)

      // And the write, which is refused. allowWrite is a real allowlist.
      const write = await run(`touch ${JSON.stringify(join(outside, 'written'))}`)
      expect(write.code).not.toBe(0)
      expect(write.stderr).toMatch(/not permitted|Permission denied/i)
      expect(existsSync(join(outside, 'written'))).toBe(false)

      report('probe 7 — a repository outside a home directory', [
        ['read  secret.txt', `${read.code === 0 ? 'READABLE' : 'denied'} — exit ${read.code}`],
        ['read  under $HOME  (control)', `${underHome.code === 0 ? 'READABLE' : 'denied'} — exit ${underHome.code}`],
        ['read  inside the clone  (control)', `${insideClone.code === 0 ? 'READABLE' : 'denied'} — exit ${insideClone.code}`],
        ['write into it', `${write.code === 0 ? 'WRITABLE' : 'refused'} — exit ${write.code}`],
      ])
    } finally {
      rmSync(outside, { recursive: true, force: true })
      rmSync(insideHome, { recursive: true, force: true })
      await releaseSandbox()
    }
  },
  120_000,
)

// ---------------------------------------------------------------------------
// 8. The root above every home directory
// ---------------------------------------------------------------------------

test.skipIf(blocked !== null)(
  '/Users is denied above the home directory, not only inside it',
  async () => {
    /*
      `denyRead` names the home directory *and* the root that holds it, and only
      the first half had ever been measured — every probe that reached for a
      denied path reached for one under `$HOME`. That left "and so is /Users
      above it" resting on the policy's own word, in a README section whose
      heading promises a measurement.

      `/Users/Shared` is the path that separates the two claims: it is under
      /Users, it is under no home directory, and it is on every macOS install.
    */
    const run = runner(await freshSandbox(repoRoot))
    try {
      const usersRoot = await run('ls /Users')
      const shared = await run('ls -a /Users/Shared')

      // The controls. Both listings with no Sandbox at all, so a refusal above
      // is the policy and not a path that was never there.
      const usersRootControl = await runUnconfined('ls /Users')
      const sharedControl = await runUnconfined('ls -a /Users/Shared')

      report('probe 8 — the root above every home directory', [
        ['/Users  list', outcome(usersRoot)],
        ['/Users  list, no Sandbox  (control)', outcome(usersRootControl)],
        ['/Users/Shared  list  (under no home directory)', outcome(shared)],
        ['/Users/Shared  list, no Sandbox  (control)', outcome(sharedControl)],
      ])

      // The controls first: both paths exist and this user can list them.
      expect(usersRootControl.code).toBe(0)
      expect(sharedControl.code).toBe(0)

      // The boundary. The second line is the one that is not about `$HOME`.
      expect(usersRoot.code).not.toBe(0)
      expect(usersRoot.stderr).toMatch(/not permitted/i)
      expect(shared.code).not.toBe(0)
      expect(shared.stderr).toMatch(/not permitted/i)
    } finally {
      await releaseSandbox()
    }
  },
  120_000,
)

// ---------------------------------------------------------------------------
// 9. Apple Events
// ---------------------------------------------------------------------------

test.skipIf(blocked !== null)(
  'an Apple Event does not reach another application, and neither does open',
  async () => {
    /*
      "Apple Events are separately denied, which is what actually declaws `open`
      and `osascript`" was the only load-bearing mitigation in the README's
      *Where confinement stops* with no probe behind it — and every other time
      this project asserted a mitigation it had not run, it was wrong.

      Measuring it needs one distinction first. `osascript` executes under the
      policy (probe 2), and AppleScript answers a *static* property of an
      application specifier — `get name`, `get version` — out of the target's
      bundle without sending anything at all. Those succeed inside the Sandbox
      and would have made a careless probe report the opposite of the truth. So
      what is asked for here is a round trip: a property only the running
      application can answer, and a Launch Services open request.

      `allowAppleEvents: false` is what generates this. It withholds
      `(allow appleevent-send)`, `(allow lsopen)` and the mach services behind
      them from a profile that opens `(deny default)`, which is why the failures
      below are connection errors rather than a permission message.

      Nothing here launches an application on a green run — that is the result
      being asserted. A run where these stopped being denied would open
      Calculator once, and go red.
    */
    const run = runner(await freshSandbox(repoRoot))
    try {
      // The control: osascript itself runs, with no application involved.
      const arithmetic = await run("/usr/bin/osascript -e 'return 6*7'")

      // Reported, not asserted: the answer AppleScript gives without sending an
      // event. It is here so the next reader does not measure this and conclude
      // Apple Events work.
      const staticProperty = await run(
        `/usr/bin/osascript -e 'tell application "Finder" to get version'`,
      )

      // The round trips. Only a running Finder can count its windows, and only
      // a running System Events can enumerate processes.
      const countWindows = await run(
        `/usr/bin/osascript -e 'tell application "Finder" to count windows'`,
      )
      const processes = await run(
        `/usr/bin/osascript -e 'tell application "System Events" to get name of every process'`,
      )

      // And the Launch Services half, which is `lsopen` rather than
      // `appleevent-send` — the operation `open` actually needs.
      const opened = await run('/usr/bin/open -a Calculator')

      report('probe 9 — Apple Events, and the open request beside them', [
        ["osascript  'return 6*7'  (control)", outcome(arithmetic)],
        ['osascript  Finder version  (no event sent)', outcome(staticProperty)],
        ['osascript  Finder count windows', outcome(countWindows)],
        ['osascript  System Events process list', outcome(processes)],
        ['open  -a Calculator', outcome(opened)],
      ])

      // The control: the binary runs, so the three refusals below are about the
      // event and not about osascript being unreachable.
      expect(arithmetic.code).toBe(0)
      expect(arithmetic.stdout.trim()).toBe('42')

      // The boundary.
      expect(countWindows.code).not.toBe(0)
      expect(processes.code).not.toBe(0)
      expect(opened.code).not.toBe(0)
    } finally {
      await releaseSandbox()
    }
  },
  120_000,
)

// ---------------------------------------------------------------------------
// 9b. The scratch directory every Bash command needs
// ---------------------------------------------------------------------------

test.skipIf(blocked !== null)(
  "the agent can create Claude Code's scratch directory, and still cannot write /tmp itself",
  async () => {
    /*
      Ticket 27, as a boundary rather than a bug report.

      Claude Code writes its scratch to `/tmp/claude-<uid>/…`, which is not
      `os.tmpdir()`. Without that path in `allowWrite` every Bash command failed
      at `mkdir` before running, so the agent could read files and execute
      nothing — and the first Turn ever run in the application opened by saying
      so. Nothing in the suite could see it: Bash is the agent's tool, the agent
      needs a Session, and the only probe with a Session skips without a
      credential.

      Both halves are asserted, because the grant is only defensible if it is the
      subdirectory and not the parent. `/tmp` is world-writable and shared with
      every process on the machine; `/tmp/claude-<uid>` is one per-user scratch
      path, which is what `os.tmpdir()` already grants elsewhere.
    */
    const scratch = claudeScratchDirFor(process.getuid?.() ?? 0)
    const mine = join(scratch, `varnick-probe-${process.pid}`)

    try {
      const run = runner(await freshSandbox(repoRoot))

      const allowed = await run(`mkdir -p ${JSON.stringify(mine)} && touch ${JSON.stringify(join(mine, 'probe'))}`)
      const parent = await run(`touch ${JSON.stringify(`/private/tmp/varnick-probe-${process.pid}`)}`)

      report('probe 9b — the scratch directory Bash needs', [
        [`write ${scratch}/…`, outcome(allowed)],
        ['write /private/tmp directly', outcome(parent)],
      ])

      // The grant: without this the agent cannot run a single command.
      expect(allowed.code).toBe(0)
      // And its limit: the parent stays refused.
      expect(parent.code).not.toBe(0)
      expect(existsSync(`/private/tmp/varnick-probe-${process.pid}`)).toBe(false)
    } finally {
      rmSync(mine, { recursive: true, force: true })
      await releaseSandbox()
    }
  },
  120_000,
)

// ---------------------------------------------------------------------------
// 10. A listening socket
// ---------------------------------------------------------------------------

test.skipIf(blocked !== null)(
  'the agent cannot open a listening socket, and that is what allowLocalBinding buys',
  async () => {
    /*
      `allowLocalBinding: false` is one line in sandbox.ts and nothing held it to
      the kernel. It matters more than it looks: a listener is how a confined
      process accepts an *inbound* connection, which is a channel the allowlist
      says nothing about — the allowlist bounds where the agent may reach, not
      who may reach the agent.

      Measured because ticket 25 looked as though it needed the opposite answer.
      `claude setup-token` finishes by bouncing the browser to
      `http://localhost:<ephemeral>/callback`, so minting a token *confined*
      would have required binding, and that command's policy would have had to
      set this true where the agent's leaves it false.

      **It did not come to that, and this probe outlived the reason it was
      written.** Ticket 25 mints on the host: the installed `claude` is a
      self-extracting executable that has to read itself, so it cannot run under
      any policy denying `$HOME`, and the widening that would have bought was
      far larger than local binding. The exception is bounded in ADR-0003 and
      uses no policy at all, so nothing anywhere sets `allowLocalBinding: true`
      and the deny below is the whole of the story again.

      The probe stays, and it is worth more now than when it was written: it was
      one line in sandbox.ts that nothing held to the kernel, and it guards a
      channel the allowlist says nothing about — the allowlist bounds where the
      agent may reach, not who may reach the agent.
    */
    const listener = join(insideDir, 'listen.py')
    writeFileSync(
      listener,
      [
        'import http.server, sys',
        'try:',
        "    s = http.server.HTTPServer(('127.0.0.1', 0), http.server.BaseHTTPRequestHandler)",
        'except Exception as e:',
        "    print('BIND-REFUSED', type(e).__name__, flush=True); sys.exit(1)",
        "print('BOUND', s.server_address[1], flush=True)",
      ].join('\n'),
      'utf8',
    )

    try {
      const run = runner(await freshSandbox(repoRoot))

      // The control: python runs, so a refusal below is about the bind rather
      // than about the interpreter being unreachable.
      const control = await run('python3 -c "print(6*7)"')
      expect(control.code).toBe(0)
      expect(control.stdout.trim()).toBe('42')

      const bind = await run(`python3 ${JSON.stringify(listener)}`)

      report('probe 10 — a listening socket under the shipped policy', [
        ['python3 runs at all  (control)', outcome(control)],
        ['bind 127.0.0.1:0', outcome(bind)],
      ])

      // The boundary. The agent may not listen.
      expect(bind.stdout).not.toContain('BOUND')
      expect(bind.stdout).toContain('BIND-REFUSED')
    } finally {
      rmSync(listener, { force: true })
      await releaseSandbox()
    }
  },
  120_000,
)

// 10b. The violation monitor
// ---------------------------------------------------------------------------

test.skipIf(blocked !== null)(
  'the kernel denials reach varnick, and only the unintended ones are said out loud',
  async () => {
    /*
      Ticket 18's first prerequisite, measured rather than reasoned. `srt` has
      watched the kernel's deny log all along and varnick never listened, so a
      missing read allowlist entry has been `exit 133` and nothing else — the
      failure shape this project has already lost a day to.

      Two halves, and the second is the one that keeps the first usable.

      **It sees them.** `establishSandbox` starts the monitor, so the events
      below come out of the shipped path rather than out of a watcher this test
      set up for itself.

      **And it says almost nothing.** Measured here: every command run under
      the policy trips `sysctl-read kern.iossupportversion` twice — once for the
      wrapping shell, once for the command — so an unfiltered monitor is two
      lines of noise per command before anything has gone wrong. A read under
      `$HOME` is refused too, and that is the product working rather than news.

      The control for the reporting half is the same real kernel event
      classified against a policy that did *not* name `$HOME` — a fork that
      narrowed `denyRead`, which is a policy that can exist. It speaks there,
      which is what makes the silence above a decision instead of a dead pipe.
    */
    const sandbox = await freshSandbox(repoRoot)
    const run = runner(sandbox)

    const denied = await run(`cat ${JSON.stringify(join(homedir(), '.zshrc'))}`)
    expect(denied.code).not.toBe(0)

    // `log stream` is a child process reading a system log, so the event
    // arrives after the command has exited. Polled rather than slept on, so a
    // fast machine does not pay for a slow one.
    const deadline = Date.now() + 30_000
    const reads = () =>
      sandboxViolations().filter((violation) => violation.operation.startsWith('file-read'))
    while (reads().length === 0 && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 250))
    }

    const observed = sandboxViolations()
    const said = observed.filter((violation) => isUnexpectedViolation(sandbox.policy, violation))

    // A policy that never denied the home directory. Same events, different
    // intent — this is the control, not a policy anything establishes.
    const narrowed: SandboxPolicy = {
      ...sandbox.policy,
      filesystem: {
        ...sandbox.policy.filesystem,
        denyRead: sandbox.policy.filesystem.denyRead.filter(
          (path) => !homedir().startsWith(path),
        ),
      },
    }
    const saidIfHomeWereOpen = observed.filter((violation) =>
      isUnexpectedViolation(narrowed, violation),
    )

    report('probe 10 — the kernel denials varnick now hears', [
      ['denials observed in this run', String(observed.length)],
      ['  of which file reads', String(reads().length)],
      [
        '  of which the sysctl every command trips',
        String(observed.filter((v) => v.operation === 'sysctl-read').length),
      ],
      ['reported to the developer  (the policy is correct)', String(said.length)],
      [
        'the same events, under a policy that never denied $HOME  (control)',
        String(saidIfHomeWereOpen.length),
      ],
      [
        'what one reads like',
        (saidIfHomeWereOpen[0] === undefined
          ? '(none)'
          : describeSandboxViolation(saidIfHomeWereOpen[0]).split('\n')[1] ?? ''
        ).trim(),
      ],
    ])

    // The pipe is live: the read that was refused is a denial varnick can see.
    expect(reads().length).toBeGreaterThan(0)
    expect(reads().some((violation) => violation.subject.startsWith(homedir()))).toBe(true)

    // And nothing was said, because nothing went wrong. This is what a
    // developer sees on a correct policy: no line at all.
    expect(said).toEqual([])

    // The control. The same real denial, under a policy that did not intend it,
    // is reported — so the silence above is a judgement and not a dead channel.
    expect(saidIfHomeWereOpen.length).toBeGreaterThan(0)
  },
  120_000,
)

// ---------------------------------------------------------------------------
// 11. The standing of the one probe a machine can be unable to run
// ---------------------------------------------------------------------------

/*
  Ticket 26's surviving box, and the only test in this file that never skips.

  It runs on Linux, on a fresh clone, on CI, with no credential and no kernel
  support — because what it checks is not a boundary. It checks the *record* of
  whether the boundary's last unmeasured corner has ever been measured, and that
  record is a property of the repository rather than of the machine reading it.
  A fresh clone inherits whatever the last maintainer's run committed.

  Its name carries the verdict, and that was measured before it was relied on:
  Bun's default reporter prints *nothing* for a passing or skipped test, so the
  name is visible under `--reporter=junit`, in an IDE, and in `bun test
  --verbose`, and nowhere else. It is written this way because a name is free and
  costs nothing when unread; the banner below and the committed record are what
  carry this when the reporter is quiet.

  Last in the file so that it runs after probe 6 and can see whether this run
  completed it.
*/
test(`probe 6, the one probe a machine can be unable to run — on record: ${sdkToolProbeStanding().headline}`, () => {
  // Throws if the record is missing or malformed, which is a red everywhere and
  // should be: losing the record is louder than anything it could have said.
  const attestation = readProbeAttestation()
  expect(attestation.sdkTools.probe).toContain('probe 6')

  /*
    The one assertion here that can fail, and note who it can fail for: a
    machine that supports the Sandbox *and* has a credential exported — which
    is to say, somebody who asked for the measurement. A fresh clone, CI, and a
    machine with no credential all have `toolProbeBlocked` set and never reach
    it, so this cannot produce the red-suite-everyone-ignores the header warns
    about.

    What it catches is the hole under the skip: probe 6 exiting green having
    measured nothing. It returns early when the Session did not end `ok`, which
    is the right call — a refused credential and a contained agent produce the
    identical empty answer — but until now that early return was indistinguishable
    from a pass, and this is the second time in this file that two different
    things looked the same and the wrong one was believed.
  */
  if (toolProbeBlocked === null) {
    expect(sdkToolProbeCompleted).toBe(true)
  }

  /*
    And the one that fails *everywhere*, which was deliberately not shipped
    until it could be cleared.

    This is red on a fresh clone, on CI, on Linux, with no credential — for
    exactly as long as the repository says nobody has ever completed this probe.
    That sounds like the ignored-red-suite the header forbids, and it is not,
    because of one property: it is a fact about the repository, it is cleared
    permanently by a single real run committed once, and after that it never
    fires again unless someone deletes the evidence.

    It was written and rejected once for the right reason — the author had no
    credential, so shipping it meant shipping a red nobody present could clear,
    and the only way to make it green would have been to fabricate an
    attestation, which is precisely the sin this ticket exists to prevent. It
    ships now because the probe has actually been run: probe 6 completed under a
    real subscription credential and its six verdicts are in the record beside
    this line.

    What it buys, and it is narrow but it is the whole ticket: the repository can
    never again be in the state "nobody has ever measured this" while the suite
    is green. Someone has to notice the record, rather than having to notice a
    line of output that scrolled past.
  */
  expect(sdkToolProbeStanding().everCompleted).toBe(true)
})

/*
  The banner, and where it prints is half of what ticket 26 is about.

  It used to be a bare `if (blocked) console.log(...)` at the bottom of the file,
  which reads as "at the end" and is not: Bun *evaluates* the module before
  running anything in it, so that line went out before probe 1 and was then
  pushed off the screen by ten report blocks. It said the right thing in the one
  place in the output nobody arrives at. It said it on every run for the life of
  the project and it is not on record that anyone read it.

  An `afterAll` is as late as this file can reach. Bun's default reporter prints
  nothing for a passing or a skipped test — no names, only console output and the
  final counts — so there is no such thing as a loud skip in the summary, and
  the last console output before it is the loudest position available. Registered
  after the cleanup hook above so it prints once the probes are done.

  Honest about what that buys. Today it does land as the last output before the
  counts, because this is the last of the fourteen files to print anything — but
  that is Bun's file order and not a promise, and one new talkative test file
  would put it back in the middle. It is a better position, not a solved problem,
  which is why the durable half of this ticket is a committed file and a command
  that fails rather than a nicer message.
*/
afterAll(() => {
  const lines: string[] = []
  if (blocked) lines.push(`containment probes skipped — ${blocked}`)
  else if (toolProbeBlocked) {
    lines.push(
      `containment probe 6 skipped — ${toolProbeBlocked}. Every other probe ran; probe 1 is what covers Read, Grep and Glob without one.`,
    )
  }
  try {
    lines.push(sdkToolProbeStanding().banner)
  } catch (error) {
    lines.push(`${PROBE_ATTESTATION_FILENAME} could not be read: ${String(error)}`)
  }
  console.log(`\n${lines.join('\n')}\n`)
})
