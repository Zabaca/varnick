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
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'
import { SandboxManager } from '@anthropic-ai/sandbox-runtime'
import { CREDENTIAL_ENV_VAR_NAME, SELFTEST_MARKER, agentCommand } from './agent.ts'
import {
  UNREADABLE_BINARIES,
  DEFAULT_ALLOWED_HOSTS,
  establishSandbox,
  releaseSandbox,
  ensureSandboxPolicy,
  sandboxPolicyFor,
  sandboxPolicyPath,
  type EstablishedSandbox,
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
    const scratch = (relative: string) => join(repoRoot, relative)

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
const toolProbeBlocked =
  blocked ??
  (process.env[CREDENTIAL_ENV_VAR_NAME]
    ? null
    : `no ${CREDENTIAL_ENV_VAR_NAME} in the environment, so no Session can be opened`)

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
  },
  600_000,
)

test.skipIf(blocked !== null)(
  'a repository outside a home directory is readable, and writes to it are not',
  async () => {
    /*
      The fourth thing this project believed without measuring. Three documents
      said the Sandbox put "other repositories" out of reach. It puts
      repositories *under a home directory* out of reach, which is where they
      usually are and not where they must be.

      srt's reads are allow-by-default: `denyRead` is a deny list — /Users, the
      home directory, /Library/Keychains, and four binaries — and everything
      outside it is readable. Probe 2b already demonstrated this without anyone
      noticing, since lifting /usr/bin/security out of denyRead only makes `cat`
      work if /usr/bin was readable all along.

      Writes are the opposite and hold: `allowWrite` is a genuine allowlist, so
      the clone and the temp directory are writable and nothing else is.

      This probe exists so the asymmetry is measured rather than derivable. It
      is not an argument for widening anything — it is the claim the README now
      makes, held to the kernel.
    */
    const outside = mkdtempSync('/private/tmp/varnick-outside-home-')
    try {
      mkdirSync(join(outside, '.git'), { recursive: true })
      writeFileSync(join(outside, 'secret.txt'), SELFTEST_MARKER, 'utf8')

      const run = runner(await establishSandbox({ cloneRoot: repoRoot }))

      // The read, which succeeds. A repository here is not protected.
      const read = await run(`cat ${JSON.stringify(join(outside, 'secret.txt'))}`)
      expect(read.code).toBe(0)
      expect(read.stdout).toContain(SELFTEST_MARKER)

      // The control that makes the line above mean something: the same read
      // under a home directory is refused, so this is about location and not
      // about the wrapper being broken.
      const underHome = await run(`cat ${JSON.stringify(join(homedir(), '.zshrc'))}`)
      expect(underHome.code).not.toBe(0)

      // And the write, which is refused. allowWrite is a real allowlist.
      const write = await run(`touch ${JSON.stringify(join(outside, 'written'))}`)
      expect(write.code).not.toBe(0)
      expect(write.stderr).toMatch(/not permitted|Permission denied/i)
      expect(existsSync(join(outside, 'written'))).toBe(false)

      report('probe 7 — a repository outside a home directory', [
        ['read  secret.txt', `${read.code === 0 ? 'READABLE' : 'denied'} — exit ${read.code}`],
        ['read  under $HOME  (control)', `${underHome.code === 0 ? 'READABLE' : 'denied'} — exit ${underHome.code}`],
        ['write into it', `${write.code === 0 ? 'WRITABLE' : 'refused'} — exit ${write.code}`],
      ])
    } finally {
      rmSync(outside, { recursive: true, force: true })
      await releaseSandbox()
    }
  },
  120_000,
)

if (blocked) {
  console.log(`containment probes skipped — ${blocked}`)
} else if (toolProbeBlocked) {
  console.log(
    `containment probe 6 skipped — ${toolProbeBlocked}. Every other probe ran; probe 1 is what covers Read, Grep and Glob without one. To run this last one, export ${CREDENTIAL_ENV_VAR_NAME} and re-run this file.`,
  )
}
