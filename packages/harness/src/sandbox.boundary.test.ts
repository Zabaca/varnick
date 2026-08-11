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
import { CLAUDE_CONFIG_RELATIVE_PATH, SELFTEST_MARKER, agentCommand } from './agent.ts'

import {
  MACHINE_KEYCHAIN_DIR,
  TRACKED_HOOKS_DIR,
  establishSandbox,
  releaseSandbox,
  sandboxBaselinePath,
  sandboxPolicyFor,
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
const hadBaseline = blocked ? true : existsSync(sandboxBaselinePath(repoRoot))

/**
 * A clone as it stood before `/Library/Keychains` was denied.
 *
 * Ticket 17's regression, planted rather than described. This is the exact
 * state this repository was in when ticket 16's probe failed on merge: a policy
 * generated an hour before the strengthening, with no baseline beside it
 * because baselines did not exist yet either. The old fix was to delete the
 * file, and nobody deletes that file in a real clone.
 */
const staleClone = blocked ? '' : mkdtempSync(join(homedir(), '.varnick-boundary-stale-'))
if (!blocked) {
  const older = sandboxPolicyFor({ cloneRoot: staleClone })
  older.filesystem.denyRead = older.filesystem.denyRead.filter((p) => p !== MACHINE_KEYCHAIN_DIR)
  writeFileSync(sandboxPolicyPath(staleClone), `${JSON.stringify(older, null, 2)}\n`, 'utf8')
}

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
  rmSync(staleClone, { recursive: true, force: true })
  rmSync(outsideClone, { force: true })
  if (!hadPolicy) rmSync(sandboxPolicyPath(repoRoot), { force: true })
  // Generated beside the policy, and removed on the same condition. Left
  // behind, it would tell the *next* run that this repository's policy was
  // hand-edited into whatever this suite last established.
  if (!hadBaseline) rmSync(sandboxBaselinePath(repoRoot), { force: true })
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
    //
    // The file carries the probe's own marker as well as this suite's secret,
    // because `--selftest` answers `denied` for a file it could not read *and*
    // for one whose contents did not carry the marker. Without the marker here
    // the denial would be true for the wrong reason. The full matrix — all four
    // tool shapes, each against a control inside the clone — is ticket 04's, in
    // containment.probe.test.ts.
    writeFileSync(outsideClone, `${SELFTEST_MARKER}\n${SECRET}`, 'utf8')

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

    /*
      Configuration isolation, measured in the same process rather than only in
      a unit test — ADR-0010.

      `inherited` counts the variables named for Claude Code or the Anthropic
      client that this run was handed. It is reported rather than asserted: it
      depends entirely on the terminal varnick was launched from, and the run
      that started this work saw nine. `isolated` is what survives the scrub,
      and it must be none — that is the claim, and it is the one thing here
      that does not vary by machine.
    */
    expect(report.isolated).toBe('0')
    expect(Number(report.inherited)).toBeGreaterThanOrEqual(0)

    // And the config directory is inside the clone, which is the only place the
    // Sandbox lets Claude Code write one. A default of ~/.claude is a process
    // that cannot write its own state.
    expect(report.configDir).toBe(join(repoRoot, CLAUDE_CONFIG_RELATIVE_PATH))
    console.log(
      `boundary probe: the confined process was handed ${report.inherited} inherited` +
        ` Claude Code / Anthropic variables, and isolation left ${report.isolated}.`,
    )
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

    const run = runner(await establishSandbox({ cloneRoot: clone }))

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
    const run = runner(await establishSandbox({ cloneRoot: clone }))

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

test.skipIf(blocked !== null)(
  "git's own executable configuration is refused by the kernel, and the rest of .git is not",
  async () => {
    /*
      ADR-0016, measured rather than asserted about the generated file.

      `.git` is the one part of a repository no diff shows, so a `pre-commit`
      the agent planted executes ahead of the review gate — including on the
      merge commit that was supposed to *be* the gate. `.git/config` goes with
      it: it holds `core.hooksPath`, which makes denying the hooks directory
      alone decorative, and it defines the filter commands `.gitattributes`
      invokes.

      The second half is what stops this from being a denial of `.git` outright.
      A worktree, a commit and a merge write `.git/worktrees`, `.git/objects`,
      `.git/refs` and the index, and every one of them stays writable — which is
      what ADR-0014's whole model rests on. Measured for ADR-0016: `git worktree
      add` does not write `.git/config` at all, md5 identical before and after.
    */
    await releaseSandbox()

    /*
      A real repository rather than a `.git` skeleton, because the interesting
      question is not whether a shell redirect is refused. It is whether *git*
      is: `git config` writes through `.git/config.lock` and renames it into
      place, which is a path the deny has to hold on the destination of rather
      than on the write itself. It does, measured below, and the file is
      unchanged after.
    */
    const gitDir = join(clone, '.git')
    const q = JSON.stringify(clone)
    for (const argv of [
      ['init', '-q', '-b', 'main', clone],
      ['-C', clone, 'config', 'user.email', 'probe@varnick.invalid'],
      ['-C', clone, 'config', 'user.name', 'varnick boundary probe'],
    ]) {
      const init = Bun.spawnSync({ cmd: ['git', ...argv], cwd: clone })
      expect(init.exitCode).toBe(0)
    }
    writeFileSync(join(clone, 'tracked.txt'), 'a\n', 'utf8')
    Bun.spawnSync({ cmd: ['git', '-C', clone, 'add', '-A'] })
    Bun.spawnSync({ cmd: ['git', '-C', clone, 'commit', '-q', '-m', 'first'], cwd: clone })
    mkdirSync(join(clone, TRACKED_HOOKS_DIR), { recursive: true })

    /*
      A Worktree, made from outside the Sandbox on purpose.

      It stands for the tree the agent authors a hook in, and the question asked
      of it below is only whether the *write* is permitted there — which is the
      one thing `denyWrite` decides. Whether the agent can run `git worktree
      add` itself is a different claim with its own assertions further down, and
      putting the two in one step would leave a hook-boundary result that a
      failure in git could take with it.
    */
    const authored = join(clone, '.claude/worktrees/authored')
    const addWorktree = Bun.spawnSync({
      cmd: ['git', '-C', clone, 'worktree', 'add', '-q', authored, '-b', 'authored'],
      cwd: clone,
    })
    expect(addWorktree.exitCode).toBe(0)

    const configBefore = readFileSync(join(gitDir, 'config'), 'utf8')

    const run = runner(await establishSandbox({ cloneRoot: clone }))

    // The control, and it is the one that makes the denials mean something: the
    // clone is writable, so a refusal below is these two paths and not the
    // wrapper.
    const control = await run(`printf x > ${JSON.stringify(join(clone, 'writable.txt'))}`)
    expect(control.code).toBe(0)

    // The boundary. A hook the agent plants would run unconfined at commit time.
    const hook = await run(
      `printf '#!/bin/sh\\necho pwned\\n' > ${JSON.stringify(join(gitDir, 'hooks', 'pre-commit'))}`,
    )
    expect(hook.code).not.toBe(0)
    expect(hook.stderr).toMatch(/not permitted|Permission denied|read-only/i)
    expect(existsSync(join(gitDir, 'hooks', 'pre-commit'))).toBe(false)

    // And the redirect that would make the line above decorative — asked for
    // twice, because git does not write this file the way a shell does.
    const redirected = await run(
      `printf '[core]\\n\\thooksPath = /tmp\\n' > ${JSON.stringify(join(gitDir, 'config'))}`,
    )
    expect(redirected.code).not.toBe(0)
    expect(redirected.stderr).toMatch(/not permitted|Permission denied|read-only/i)

    const viaGit = await run(`cd ${q} && git config core.hooksPath /tmp/evil`)
    expect(viaGit.code).not.toBe(0)
    expect(viaGit.stderr).toMatch(/could not write config file|not permitted/i)
    expect(readFileSync(join(gitDir, 'config'), 'utf8')).toBe(configBefore)

    /*
      And the directory `core.hooksPath` was pointed at, which is the same
      denial one step out.

      `.githooks/` is tracked, and that was the argument for moving hooks here:
      a tracked file reaches the developer through a diff they read. Tracked
      says where a file *can* be reviewed, not that it was — a hook written into
      the live tree is on no branch and in no diff, and git runs it on the next
      commit exactly as a planted `.git/hooks/pre-commit` would. So the live
      tree's copy is refused too.
    */
    const liveHook = join(clone, TRACKED_HOOKS_DIR, 'pre-commit')
    const trackedHook = await run(
      `printf '#!/bin/sh\\necho pwned\\n' > ${JSON.stringify(liveHook)}`,
    )
    expect(trackedHook.code).not.toBe(0)
    expect(trackedHook.stderr).toMatch(/not permitted|Permission denied|read-only/i)
    expect(existsSync(liveHook)).toBe(false)

    /*
      And the tree the agent writes it in instead. ADR-0014: the deny above
      names an absolute live-tree path, so the same relative path inside a
      Worktree matches nothing and the hook is authored there under the ordinary
      Profile. `mkdir -p` is part of the assertion — the directory does not
      exist in a fresh worktree, and a policy that refused creating it would
      leave the agent unable to write the hook it is being pointed at.
    */
    const wroteInWorktree = await run(
      `mkdir -p ${JSON.stringify(join(authored, TRACKED_HOOKS_DIR))}` +
        ` && printf '#!/bin/sh\\necho HOOK-RAN >&2\\n' >` +
        ` ${JSON.stringify(join(authored, TRACKED_HOOKS_DIR, 'pre-commit'))}`,
    )
    expect(wroteInWorktree.code).toBe(0)
    expect(existsSync(join(authored, TRACKED_HOOKS_DIR, 'pre-commit'))).toBe(true)

    /*
      And git still runs what it finds in the live tree's copy — the half that
      says this denies authorship rather than the mechanism. The hook is planted
      from outside the Sandbox, which is what a merge is: the human put it
      there, and the agent's own commit runs it.

      `GIT_CONFIG_GLOBAL=/dev/null` because of something measured while writing
      this, and it is about the machine rather than about hooks: git *fatals*
      when it cannot stat `~/.gitconfig`, and `$HOME` is denied by design —
      `fatal: unable to access '…/.gitconfig': Operation not permitted`, exit
      128, on every git command including the worktree and merge steps below.
      So a developer who has a global config sees this whole probe fail for a
      reason that has nothing to do with `.git` or `.githooks`. Pinned here so
      that the assertion measures the hook rather than the home directory; the
      finding itself is bigger than this file and is not this ticket's.
    */
    writeFileSync(liveHook, '#!/bin/sh\necho HOOK-RAN >&2\n', { encoding: 'utf8', mode: 0o755 })
    const ranHook = await run(
      `cd ${q} && GIT_CONFIG_GLOBAL=/dev/null` +
        ` git -c core.hooksPath=${TRACKED_HOOKS_DIR} commit -q --allow-empty -m hooked`,
    )
    expect(ranHook.code).toBe(0)
    expect(ranHook.stderr).toContain('HOOK-RAN')

    /*
      What a worktree, a commit and a merge need, asked of git itself for the
      same reason. This is ADR-0014's whole model: the agent authors Core in a
      worktree under `.claude/worktrees/`, and a deny that grew into the rest of
      `.git` would take that with it — failing in a developer's `git commit` a
      week later rather than here.
    */
    const worktree = await run(`cd ${q} && git worktree add -q .claude/worktrees/probe -b probe`)
    expect(worktree.code).toBe(0)

    const committed = await run(
      `cd ${q}/.claude/worktrees/probe && printf b > b.txt && git add -A && git commit -q -m second`,
    )
    expect(committed.code).toBe(0)

    const merged = await run(`cd ${q} && git merge --no-ff -m merged probe`)
    expect(merged.code).toBe(0)

    // Nothing in all of that touched the one file the deny is about.
    expect(readFileSync(join(gitDir, 'config'), 'utf8')).toBe(configBefore)

    console.log(
      'boundary probe: .git/hooks, .git/config and the tracked' +
        ` ${TRACKED_HOOKS_DIR}/ are refused by the kernel — including through git's own` +
        ' lock-and-rename — while worktree add, commit, merge, a hook authored in a' +
        ' worktree and a hook git runs from the live tree all still work.',
    )
  },
  120_000,
)

test.skipIf(blocked !== null)(
  'the agent can bind a local port, and the egress allowlist is unchanged by it',
  async () => {
    /*
      ADR-0015, at the kernel. `allowLocalBinding: true` is what buys the agent a
      dev server, a test server and a headless browser — the whole of its
      ability to observe its own work.

      The two halves ship together because the first is only admissible while
      the second holds. srt's flag adds `network-bind` and `network-inbound` on
      `(local ip "*:*")` and `network-outbound` on `(remote ip "localhost:*")` —
      the last written that way on purpose so the allowlist stays enforced
      (srt #225, #88). This measures both against the same policy in the same
      run, so a future release that traded egress for binding fails here.

      The listener is python's stdlib rather than a dependency, for the same
      reason probe 10 in containment.probe.test.ts uses it: it is on the machine
      and it is not part of what is being measured.
    */
    await releaseSandbox()

    const listener = join(clone, 'listen.py')
    writeFileSync(
      listener,
      [
        'import http.server, sys, threading, urllib.request',
        'try:',
        "    s = http.server.HTTPServer(('127.0.0.1', 0), http.server.SimpleHTTPRequestHandler)",
        'except Exception as e:',
        "    print('BIND-REFUSED', type(e).__name__, flush=True); sys.exit(1)",
        "print('BOUND', s.server_address[1], flush=True)",
        'threading.Thread(target=s.handle_request, daemon=True).start()',
        'try:',
        '    code = urllib.request.urlopen(',
        '        "http://127.0.0.1:%d/" % s.server_address[1], timeout=5).status',
        "    print('SERVED', code, flush=True)",
        'except Exception as e:',
        "    print('SERVE-FAILED', type(e).__name__, flush=True)",
      ].join('\n'),
      'utf8',
    )

    try {
      const run = runner(await establishSandbox({ cloneRoot: clone }))

      // The control: python runs, so anything below is about the network and
      // not about an unreachable interpreter.
      const control = await run('python3 -c "print(6*7)"')
      expect(control.code).toBe(0)
      expect(control.stdout.trim()).toBe('42')

      // Half one: it binds, and it serves over what it bound. A bind that
      // succeeded and could not be connected to would be no dev server.
      const bound = await run(`python3 ${JSON.stringify(listener)}`)
      expect(bound.stdout).toContain('BOUND')
      expect(bound.stdout).not.toContain('BIND-REFUSED')
      expect(bound.stdout).toContain('SERVED 200')

      // Half two, in the same sandbox: an unlisted host is still refused. This
      // is the assertion that keeps the first one admissible.
      const unlisted = await run(
        'curl -sS -o /dev/null -w "%{http_code}" --max-time 20 https://example.com/',
      )
      expect(unlisted.code).not.toBe(0)
      expect(unlisted.stdout.trim()).not.toMatch(/^2\d\d$/)

      console.log(
        'boundary probe: the agent bound an ephemeral port and served over it, and' +
          ' example.com was still refused in the same sandbox.',
      )
    } finally {
      rmSync(listener, { force: true })
    }
  },
  120_000,
)

test.skipIf(blocked !== null)(
  'a clone whose policy predates the keychain deny is contained by it anyway',
  async () => {
    /*
      Ticket 17, measured against the kernel rather than against the generator.

      The unit suite proves `ensureSandboxPolicy` puts /Library/Keychains back
      into a policy that lacks it. That is the policy *saying* the right thing.
      This asks the only question that settles it: with a pre-strengthening
      `sandbox-policy.json` sitting in the clone — not deleted, not edited, not
      touched by anybody — does the kernel refuse the read?

      That is the regression the ticket is named after. Ticket 16's probe failed
      here, on a real repository, for exactly this reason, and passed once
      someone deleted the file by hand.

      Read-only throughout. Nothing here creates or modifies a keychain item.
    */
    accessSync('/Library/Keychains/System.keychain', constants.R_OK)

    // One Sandbox per process, and `initialize` returns early rather than
    // replacing the policy — see the note in the agent probe above.
    await releaseSandbox()

    const sandbox = await establishSandbox({ cloneRoot: staleClone })
    const run = runner(sandbox)

    // What the merge did, before asking the kernel whether it took.
    expect(sandbox.policy.filesystem.denyRead).toContain(MACHINE_KEYCHAIN_DIR)
    // Nothing was discarded to get there: the clone is still readable, which is
    // the allowance every other probe in this file depends on.
    expect(sandbox.policy.filesystem.allowRead).toContain(staleClone)
    // And the developer is told, in words, on stderr — not only in the file.
    expect(sandbox.report.unattributed).toBe(true)
    expect(sandbox.report.lines.join('\n')).toContain(MACHINE_KEYCHAIN_DIR)

    const opened = await run('cat /Library/Keychains/System.keychain')
    expect(opened.code).not.toBe(0)
    expect(opened.stderr).toMatch(/not permitted|Permission denied|No such file/i)

    const dumped = await run('/usr/bin/security dump-keychain /Library/Keychains/System.keychain')
    expect(dumped.stdout).not.toContain('genp')

    // The positive control, as above: `security` still runs and still answers,
    // so the two denials mean something.
    const listed = await run('/usr/bin/security list-keychains')
    expect(listed.code).toBe(0)
    expect(listed.stdout).toContain('System.keychain')

    console.log(
      'boundary probe: a clone carrying a policy generated before the keychain deny' +
        ' is contained by it on the next launch, with nothing deleted by hand.',
    )
  },
  120_000,
)

if (blocked) {
  console.log(`sandbox boundary probe skipped — ${blocked}`)
} else if (offline) {
  console.log(`sandbox network probe skipped — ${offline}`)
}
