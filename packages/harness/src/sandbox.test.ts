import { describe, expect, test } from 'bun:test'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, sep } from 'node:path'
import {
  DEFAULT_ALLOWED_HOSTS,
  MACHINE_KEYCHAIN_DIR,
  MEASURED_SYSTEM_READ_PATHS,
  SANDBOX_BASELINE_FILENAME,
  claudeScratchDirFor,
  SANDBOX_POLICY_FILENAME,
  UNREADABLE_BINARIES,
  describeSandboxPolicy,
  describeSandboxViolation,
  ensureSandboxPolicy,
  interpreterRoot,
  isUnexpectedViolation,
  materializeSandboxPolicy,
  normalizeSandboxPolicy,
  packageStoreRoot,
  parseSandboxViolation,
  readAllowlistFor,
  readSandboxBaseline,
  readSandboxPolicy,
  sandboxBaselinePath,
  sandboxPolicyFor,
  sandboxPolicyPath,
  validateSandboxPolicy,
  type SandboxPolicy,
} from './sandbox.ts'

/*
  The seam is the policy the generator produces, never how it assembles it.
  Every assertion below reads a field a developer could read in the generated
  file — see docs/agents/stage-contracts.md, stage 6.

  The boundary itself is proved by a real sandboxed process in
  sandbox.boundary.test.ts. These tests prove the policy says what it must;
  that one proves the kernel agrees.
*/

const HOME = '/Users/dev'
const CLONE = '/Users/dev/code/varnick'
const TMP = '/var/folders/xx/T'

const policy = () => sandboxPolicyFor({ cloneRoot: CLONE, homeDir: HOME, tmpDir: TMP })

/** Does `allowed` re-open `path`, either exactly or as an ancestor directory? */
const reopens = (allowed: string, path: string) =>
  allowed === path || path.startsWith(allowed.endsWith(sep) ? allowed : allowed + sep)

describe('what the policy denies', () => {
  test('the home directory and every sibling home are unreadable', () => {
    const { denyRead } = policy().filesystem
    expect(denyRead).toContain(HOME)
    // The parent of home is what covers *other* repositories: another user's
    // checkout, and anything of mine that lives outside the clone.
    expect(denyRead).toContain('/Users')
  })

  test('the clone is read back out of the denied home', () => {
    const { allowRead } = policy().filesystem
    expect(allowRead).toContain(CLONE)
  })

  test('security, osascript, open and sudo cannot be opened for reading', () => {
    const { denyRead } = policy().filesystem
    for (const binary of [
      '/usr/bin/security',
      '/usr/bin/osascript',
      '/usr/bin/open',
      '/usr/bin/sudo',
    ]) {
      expect(denyRead).toContain(binary)
    }
    expect(UNREADABLE_BINARIES.length).toBe(4)
  })

  test('no allowRead entry re-opens an unreadable binary', () => {
    // allowRead beats denyRead, so a broad allow of `/` or `/usr` would silently
    // hand every one of these back. The deny is not what stops them running —
    // containment.probe.test.ts measures that three of the four execute anyway —
    // but it is what keeps their contents out of reach, and an allow that
    // reopened them would undo the one thing the entry does achieve.

    const { allowRead } = policy().filesystem
    for (const allowed of allowRead) {
      for (const binary of UNREADABLE_BINARIES) {
        expect(reopens(allowed, binary)).toBe(false)
      }
    }
  })

  test('the machine-wide keychain directory is unreadable', () => {
    // /Library/Keychains is outside $HOME, so the denial that covers the login
    // Keychain does not reach it. Without this entry System.keychain — 37
    // generic-password items on this machine, Wi-Fi network passwords among
    // them — is readable and dumpable from inside. See ADR-0003.
    expect(policy().filesystem.denyRead).toContain(MACHINE_KEYCHAIN_DIR)
    expect(MACHINE_KEYCHAIN_DIR).toBe('/Library/Keychains')
  })

  test('no allowRead entry re-opens the machine-wide keychains', () => {
    for (const allowed of policy().filesystem.allowRead) {
      expect(reopens(allowed, MACHINE_KEYCHAIN_DIR)).toBe(false)
    }
  })

  test('Core, the build config and package scripts are unwritable', () => {
    const { denyWrite } = policy().filesystem
    expect(denyWrite).toContain(`${CLONE}/packages/core/**`)
    expect(denyWrite).toContain(`${CLONE}/vite.config.*`)
    expect(denyWrite).toContain(`${CLONE}/package.json`)
  })

  test('the policy file itself is unwritable', () => {
    // Otherwise the first thing an agent that wants out edits is its own fence.
    expect(policy().filesystem.denyWrite).toContain(`${CLONE}/${SANDBOX_POLICY_FILENAME}`)
  })

  test('the recorded baseline is unwritable too', () => {
    // The baseline is what the next launch believes varnick generated. An agent
    // that can write it can present its own widening as varnick's own work and
    // have it kept, which is the policy file's hole one step removed.
    expect(policy().filesystem.denyWrite).toContain(`${CLONE}/${SANDBOX_BASELINE_FILENAME}`)
  })

  test('writes reach the clone, the temp directory, and one scratch path — nothing else', () => {
    /*
      The third entry is the one that needs justifying, and it was added against
      a measurement rather than a preference.

      Claude Code writes its scratch to `/tmp/claude-<uid>`, which is not
      `os.tmpdir()`. Without it every Bash command the agent ran failed at
      `mkdir` before executing, so the agent could read files and run nothing —
      ticket 27, found when the product was first driven under a real credential.
      `TMPDIR` does not move it; that was measured too.

      Asserted as an exact list because the danger is drift upward. `/tmp` itself
      is world-writable and shared with every process on the machine; this is one
      per-user subdirectory of it, which is the same kind of access `TMP` above
      already grants. A future edit that reaches for the parent fails here.
    */
    expect(policy().filesystem.allowWrite).toEqual([CLONE, TMP, claudeScratchDirFor(process.getuid?.() ?? 0)])
  })

  test('the scratch grant is the subdirectory, never the whole of /tmp', () => {
    // The line above would still pass if `claudeScratchDirFor` started
    // answering `/private/tmp`, since both sides read from it. This one does
    // not: it names the parent literally.
    const writable = policy().filesystem.allowWrite
    expect(writable).not.toContain('/private/tmp')
    expect(writable).not.toContain('/tmp')
    expect(claudeScratchDirFor(501)).toBe('/private/tmp/claude-501')
  })

  test('the network is denied except for the allowlist', () => {
    const { network } = policy()
    expect(network.allowedDomains).toEqual([...DEFAULT_ALLOWED_HOSTS])
    // A host matching neither list must be denied outright rather than fall
    // through to a callback that could say yes.
    expect(network.strictAllowlist).toBe(true)
    expect(network.allowLocalBinding).toBe(false)
    expect(network.allowAllUnixSockets).toBe(false)
  })

  test('the allowlist stays minimal', () => {
    // Any allowed host is an exfiltration path. This asserts the size of the
    // blast radius, and is meant to be argued with when it changes.
    expect(DEFAULT_ALLOWED_HOSTS).toEqual(['api.anthropic.com', 'registry.npmjs.org'])
  })

  test('a wildcard denial never shadows the allowlist', () => {
    // deniedDomains is checked first, so `*` here would deny api.anthropic.com
    // too and the agent would never authenticate.
    expect(policy().network.deniedDomains).not.toContain('*')
  })
})

describe('no way to run unconfined', () => {
  test('every weakening option is off', () => {
    const p = policy()
    expect(p.allowAppleEvents).toBe(false)
    expect(p.enableWeakerNestedSandbox).toBe(false)
    expect(p.enableWeakerNetworkIsolation).toBe(false)
  })

  test('the filesystem policy cannot be disabled', () => {
    expect(policy().filesystem).not.toHaveProperty('disabled')
  })
})

describe('the policy srt is handed', () => {
  test('validates against sandbox-runtime own schema', () => {
    expect(() => validateSandboxPolicy(policy())).not.toThrow()
  })

  test('a broken policy is rejected with the real reason', () => {
    expect(() => validateSandboxPolicy({ network: { allowedDomains: 'nope' } })).toThrow(
      /allowedDomains/,
    )
  })
})

describe('readable without reading the source', () => {
  test('the description names every permitted path and host', () => {
    const text = describeSandboxPolicy(policy())
    expect(text).toContain(CLONE)
    expect(text).toContain('api.anthropic.com')
    expect(text).toContain('/usr/bin/security')
    // The honest limit, stated where the allowlist is read.
    expect(text.toLowerCase()).toContain('exfiltration')
  })

  test('the description does not claim the denied binaries cannot run', () => {
    // The wording this replaced said they were "blocked", which a reader would
    // take as an execute denial. Three of the four run. A description that
    // overstates the boundary is the one failure mode this file exists to stop.
    const text = describeSandboxPolicy(policy()).toLowerCase()
    expect(text).toContain('still run')
    expect(text).not.toContain('denying execution')
  })
})

describe('generated once, then editable in the clone', () => {
  const withClone = (body: (clone: string) => void) => {
    const clone = mkdtempSync(join(tmpdir(), 'varnick-policy-'))
    try {
      body(clone)
    } finally {
      rmSync(clone, { recursive: true, force: true })
    }
  }

  test('the first run writes the policy where a developer will find it', () => {
    withClone((clone) => {
      const result = ensureSandboxPolicy({ cloneRoot: clone })
      expect(result.generated).toBe(true)
      expect(result.path).toBe(join(clone, SANDBOX_POLICY_FILENAME))
      expect(readFileSync(result.path, 'utf8')).toContain('api.anthropic.com')
    })
  })

  test('an edit to the file survives the next run', () => {
    withClone((clone) => {
      const first = ensureSandboxPolicy({ cloneRoot: clone })
      const edited = {
        ...first.policy,
        network: { ...first.policy.network, allowedDomains: ['example.internal'] },
      }
      writeFileSync(sandboxPolicyPath(clone), JSON.stringify(edited, null, 2))

      const second = ensureSandboxPolicy({ cloneRoot: clone })
      expect(second.generated).toBe(false)
      expect(second.policy.network.allowedDomains).toEqual(['example.internal'])
    })
  })

  test('a policy broken on purpose fails loudly and names the file', () => {
    withClone((clone) => {
      writeFileSync(sandboxPolicyPath(clone), '{ "network": { "allowedDomains": 3 } }')
      expect(() => ensureSandboxPolicy({ cloneRoot: clone })).toThrow(
        new RegExp(SANDBOX_POLICY_FILENAME),
      )
    })
  })

  test('unparseable JSON fails loudly too', () => {
    withClone((clone) => {
      writeFileSync(sandboxPolicyPath(clone), 'not json at all')
      expect(() => ensureSandboxPolicy({ cloneRoot: clone })).toThrow()
    })
  })

  test('reading a clone with no policy yet returns nothing rather than inventing one', () => {
    withClone((clone) => {
      expect(readSandboxPolicy(clone)).toBeNull()
    })
  })
})

describe('a strengthening reaches a clone that already has a policy', () => {
  /*
    Ticket 17. `ensureSandboxPolicy` used to generate the file when absent and
    read it when present, so a clone kept the policy it was born with and every
    security fix shipped to new clones only. Found for real: ticket 16 denied
    /Library/Keychains, and its own probe failed on merge because this
    repository already held a policy generated an hour earlier. Deleting the
    file made it pass, and nobody deletes that file in a real clone.

    Every case below is written against the same one strengthening — the
    keychain deny — because that is the one that actually happened.
  */

  const withClone = (body: (clone: string) => void) => {
    const clone = mkdtempSync(join(tmpdir(), 'varnick-freshness-'))
    try {
      body(clone)
    } finally {
      rmSync(clone, { recursive: true, force: true })
    }
  }

  /** The policy as the generator produced it before /Library/Keychains was denied. */
  const olderGenerator = (clone: string): SandboxPolicy => {
    const older = sandboxPolicyFor({ cloneRoot: clone })
    older.filesystem.denyRead = older.filesystem.denyRead.filter(
      (path) => path !== MACHINE_KEYCHAIN_DIR,
    )
    return older
  }

  /**
   * Plant a clone as it stood before the strengthening.
   *
   * `recordBaseline: false` is the clone made before varnick recorded one at
   * all — every clone in existence when this shipped. `edit` is the developer's
   * own change on top, which is the thing that must survive.
   */
  const plant = (
    clone: string,
    options: { recordBaseline: boolean; edit?: (policy: SandboxPolicy) => void },
  ) => {
    const older = olderGenerator(clone)
    if (options.recordBaseline) {
      writeFileSync(
        sandboxBaselinePath(clone),
        `${JSON.stringify(normalizeSandboxPolicy(older, { cloneRoot: clone }), null, 2)}\n`,
      )
    }
    const inForce = structuredClone(older)
    options.edit?.(inForce)
    writeFileSync(sandboxPolicyPath(clone), `${JSON.stringify(inForce, null, 2)}\n`)
  }

  const fields = (changes: readonly { field: string }[]) => changes.map((c) => c.field)

  test('a policy generated before the keychain deny does not silently keep it', () => {
    // The regression this ticket is named after, at the unit level. The kernel
    // half is in sandbox.boundary.test.ts.
    withClone((clone) => {
      plant(clone, { recordBaseline: false })

      const { policy, report } = ensureSandboxPolicy({ cloneRoot: clone })

      expect(policy.filesystem.denyRead).toContain(MACHINE_KEYCHAIN_DIR)
      expect(report.outcome).toBe('updated')
      // And the file on disk says so, not just the value this call returned.
      expect(readSandboxPolicy(clone)?.filesystem.denyRead).toContain(MACHINE_KEYCHAIN_DIR)
    })
  })

  test('a clone with no baseline is told the difference could not be attributed', () => {
    withClone((clone) => {
      plant(clone, { recordBaseline: false })

      const { report } = ensureSandboxPolicy({ cloneRoot: clone })

      expect(report.unattributed).toBe(true)
      // Nothing is claimed about who wrote what, because nothing can be.
      expect(report.yours).toEqual([])
      expect(report.ours).toEqual([])
      expect(report.lines.join('\n')).toContain(MACHINE_KEYCHAIN_DIR)
      // ...and it happens once. The baseline is recorded on the way out.
      const second = ensureSandboxPolicy({ cloneRoot: clone })
      expect(second.report.unattributed).toBe(false)
      expect(second.report.outcome).toBe('unchanged')
      expect(second.report.lines).toEqual([])
    })
  })

  test("an edit of the developer's is kept while the strengthening still lands", () => {
    // The case the ticket exists for. A fork narrowed its allowlist before the
    // keychain deny existed; the deny must arrive, the narrowing must survive.
    withClone((clone) => {
      plant(clone, {
        recordBaseline: true,
        edit: (policy) => {
          policy.network.allowedDomains = ['api.anthropic.com']
        },
      })

      const { policy, report } = ensureSandboxPolicy({ cloneRoot: clone })

      expect(policy.network.allowedDomains).toEqual(['api.anthropic.com'])
      expect(policy.filesystem.denyRead).toContain(MACHINE_KEYCHAIN_DIR)
      expect(report.outcome).toBe('updated')
    })
  })

  test('the report says which side changed what', () => {
    withClone((clone) => {
      plant(clone, {
        recordBaseline: true,
        edit: (policy) => {
          policy.network.allowedDomains = ['api.anthropic.com']
        },
      })

      const { report } = ensureSandboxPolicy({ cloneRoot: clone })

      // "You changed this" — the allowlist, and only the allowlist.
      expect(fields(report.yours)).toEqual(['network.allowedDomains'])
      expect(report.yours[0]?.direction).toBe('stronger')
      // "We changed this" — the keychain deny, and only that.
      expect(fields(report.ours)).toEqual(['filesystem.denyRead'])
      expect(report.ours[0]?.detail).toContain(MACHINE_KEYCHAIN_DIR)
      expect(report.ours[0]?.direction).toBe('stronger')

      const text = report.lines.join('\n')
      expect(text).toContain('You changed this')
      expect(text).toContain('We changed this')
    })
  })

  test('a widening of the generator is never applied by taking the weaker side of an edit', () => {
    // Both sides moved the same field: the developer dropped the users-root
    // deny, varnick added the keychain deny. Neither is discarded and the
    // result is the stronger of the two, because resolving a conflict downwards
    // is the one thing this may not do on a developer's behalf.
    withClone((clone) => {
      const older = olderGenerator(clone)
      const droppedByHand = older.filesystem.denyRead[0] as string
      plant(clone, {
        recordBaseline: true,
        edit: (policy) => {
          policy.filesystem.denyRead = policy.filesystem.denyRead.filter(
            (path) => path !== droppedByHand,
          )
        },
      })

      const { policy, report } = ensureSandboxPolicy({ cloneRoot: clone })

      expect(policy.filesystem.denyRead).toContain(MACHINE_KEYCHAIN_DIR)
      expect(policy.filesystem.denyRead).toContain(droppedByHand)
      // And the developer is told their weakening was overruled, in the words
      // that say it was theirs.
      expect(report.yours.some((c) => c.direction === 'weaker')).toBe(true)
      expect(report.lines.join('\n')).toContain('weaker')
    })
  })

  test('a policy weaker than the generator is surfaced, not only written to a file', () => {
    withClone((clone) => {
      plant(clone, { recordBaseline: false })
      const { report } = ensureSandboxPolicy({ cloneRoot: clone })
      // The lines `establishSandbox` prints to stderr. src-tauri/src/bridge.rs
      // inherits the runtime's stderr, so this is varnick's own output.
      expect(report.lines.length).toBeGreaterThan(0)
      expect(report.lines.join('\n')).toContain(sandboxPolicyPath(clone))
    })
  })

  test('moving a clone between home directories is not reported as tampering', () => {
    withClone((clone) => {
      // Generated on one machine...
      const first = ensureSandboxPolicy({ cloneRoot: clone, homeDir: '/Users/before' })
      expect(first.policy.filesystem.denyRead).toContain('/Users/before')

      // ...read on another, where home is somewhere else entirely.
      const second = ensureSandboxPolicy({ cloneRoot: clone, homeDir: '/home/after' })

      expect(second.report.yours).toEqual([])
      expect(second.report.ours).toEqual([])
      expect(second.report.unattributed).toBe(false)
      // Not "unchanged": the paths did move, and a policy still denying the old
      // home would deny nothing that exists. Rewritten is the honest word.
      expect(second.report.outcome).toBe('rewritten')
      expect(second.report.lines).toEqual([])
      expect(second.policy.filesystem.denyRead).toContain('/home/after')
      expect(second.policy.filesystem.denyRead).not.toContain('/Users/before')
    })
  })

  test('a clone moved to another directory keeps the edits it was carrying', () => {
    withClone((clone) => {
      ensureSandboxPolicy({ cloneRoot: clone, homeDir: '/Users/before' })
      const edited = readSandboxPolicy(clone) as SandboxPolicy
      edited.network.allowedDomains = ['api.anthropic.com']
      writeFileSync(sandboxPolicyPath(clone), `${JSON.stringify(edited, null, 2)}\n`)

      const moved = ensureSandboxPolicy({ cloneRoot: clone, homeDir: '/home/after' })

      expect(moved.policy.network.allowedDomains).toEqual(['api.anthropic.com'])
      expect(moved.policy.filesystem.denyRead).toContain('/home/after')
      // The edit is attributed to the developer, and the move to nobody.
      expect(fields(moved.report.yours)).toEqual(['network.allowedDomains'])
      expect(moved.report.ours).toEqual([])
    })
  })

  test('the baseline records the policy in tokens and the roots separately', () => {
    withClone((clone) => {
      ensureSandboxPolicy({ cloneRoot: clone, homeDir: '/Users/dev' })

      expect(existsSync(sandboxBaselinePath(clone))).toBe(true)
      const baseline = readSandboxBaseline(clone)

      // The policy half carries no machine root. That is what makes a move
      // invisible rather than a wholesale rewrite of denyRead.
      expect(baseline?.policy.filesystem.allowRead).toEqual(['<clone>'])
      expect(baseline?.policy.filesystem.denyRead).toContain('<home>')
      // The paths that are not machine-specific stay literal, because they are.
      expect(baseline?.policy.filesystem.denyRead).toContain(MACHINE_KEYCHAIN_DIR)

      // The roots are recorded on their own, because the *policy file* holds
      // absolute paths and tokenizing it needs to know which ones to look for.
      expect(baseline?.roots).toEqual({
        clone,
        home: '/Users/dev',
        users: '/Users',
        tmp: tmpdir(),
      })

      // And it says what it is for, in the file, to whoever opens it next.
      expect(readFileSync(sandboxBaselinePath(clone), 'utf8')).toContain('attributed')
    })
  })

  test('a baseline nobody can parse costs attribution, not the run', () => {
    // It enforces nothing. Refusing to start over it would be trading a real
    // boundary for a bookkeeping file.
    withClone((clone) => {
      plant(clone, { recordBaseline: false })
      writeFileSync(sandboxBaselinePath(clone), 'not json at all')

      expect(readSandboxBaseline(clone)).toBeNull()
      const { policy, report } = ensureSandboxPolicy({ cloneRoot: clone })
      expect(report.unattributed).toBe(true)
      expect(policy.filesystem.denyRead).toContain(MACHINE_KEYCHAIN_DIR)
    })
  })

  test('an untouched clone is silent, and stays silent', () => {
    withClone((clone) => {
      expect(ensureSandboxPolicy({ cloneRoot: clone }).report.outcome).toBe('generated')
      const again = ensureSandboxPolicy({ cloneRoot: clone })
      expect(again.report.outcome).toBe('unchanged')
      expect(again.report.lines).toEqual([])
      expect(again.generated).toBe(false)
    })
  })

  test('normalizing and materializing a policy is a round trip', () => {
    const input = { cloneRoot: '/Users/dev/code/varnick', homeDir: '/Users/dev', tmpDir: '/tmp/x' }
    const original = sandboxPolicyFor(input)
    const normalized = normalizeSandboxPolicy(original, input)
    // The clone is a nested path under home, which is nested under the users
    // root: the longest root has to win or the clone stops being the clone.
    expect(normalized.filesystem.allowRead).toEqual(['<clone>'])
    expect(normalized.filesystem.denyRead).toContain('<home>')
    expect(normalized.filesystem.denyRead).toContain('<users>')
    expect(materializeSandboxPolicy(normalized, input)).toEqual(original)
  })
})

// ---------------------------------------------------------------------------
// The read allowlist a denied root would need — computed, and deliberately not
// in the policy
// ---------------------------------------------------------------------------

describe('the read allowlist a denied root would need', () => {
  /*
    Ticket 18's first prerequisite. Inverting reads means naming everything the
    toolchain has to reach, and the list is not the same on two machines: this
    one runs `~/.bun`, the next runs node out of Homebrew or nvm. So the parts
    that vary are derived from the process that is already running and only the
    parts that do not are constants.

    Nothing here is wired into `sandboxPolicyFor`. The last two tests in this
    block are why, and they are the judgement the ticket asked for rather than a
    note in a report: under allow-by-default reads these entries buy nothing —
    every one of them is already readable — and cost the four denied binaries
    and both keychains, because `allowRead` beats `denyRead`.
  */

  const EXEC = '/Users/dev/.bun/bin/bun'
  const SDK = '/Users/dev/code/varnick/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs'
  const TOOLS = '/Applications/Xcode.app/Contents/Developer/usr/bin'

  const allowlist = (overrides: Partial<Parameters<typeof readAllowlistFor>[0]> = {}) =>
    readAllowlistFor({
      cloneRoot: CLONE,
      execPath: EXEC,
      sdkEntry: SDK,
      developerToolsBin: TOOLS,
      ...overrides,
    })

  test('the clone comes first, because it is the one entry the policy already has', () => {
    expect(allowlist()[0]).toBe(CLONE)
  })

  test("the interpreter is derived from the running process, not named", () => {
    // The whole reason this is a function. `~/.bun` is this machine's answer;
    // a clone with node under Homebrew or nvm has a different one, and a
    // constant would be right here and wrong there.
    expect(allowlist()).toContain('/Users/dev/.bun')
    expect(interpreterRoot('/Users/dev/.bun/bin/bun')).toBe('/Users/dev/.bun')
    expect(interpreterRoot('/opt/homebrew/bin/node')).toBe('/opt/homebrew')
    // An interpreter that is not in a `bin` directory keeps its own directory
    // rather than handing back its parent, which would be a wider allow than
    // anything measured.
    expect(interpreterRoot('/opt/weird/bun')).toBe('/opt/weird')
  })

  test('the SDK is allowed through the node_modules it was installed into', () => {
    // `agentSdkEntry()` resolves a file; what the resolver needs is the tree it
    // sits in, because the SDK's own dependencies are its siblings there.
    expect(packageStoreRoot(SDK)).toBe('/Users/dev/code/varnick/node_modules')
    expect(packageStoreRoot('/opt/pkgs/sdk/index.js')).toBe('/opt/pkgs/sdk')
  })

  test('an SDK inside the clone adds nothing, because the clone already covers it', () => {
    // The usual case, and the one that would otherwise put a second entry in
    // the file naming a subdirectory of the first.
    expect(allowlist().filter((path) => path.startsWith(CLONE))).toEqual([CLONE])
  })

  test('the developer toolchain is derived too, and survives an Xcode install', () => {
    // `/Library/Developer/CommandLineTools/usr/bin` is swallowed by the
    // measured `/Library`; an Xcode.app install is not under any measured path,
    // so deriving it is what keeps `git` reachable on that machine.
    expect(allowlist()).toContain(TOOLS)
    expect(allowlist({ developerToolsBin: '/Library/Developer/CommandLineTools/usr/bin' })).not
      .toContain('/Library/Developer/CommandLineTools/usr/bin')
    // A machine with no developer tools at all is not an error; it is a machine
    // where the agent cannot run git, which is its own visible problem.
    expect(allowlist({ developerToolsBin: null }).length).toBe(allowlist().length - 1)
  })

  test('the system paths are the eight that were measured, and are still constants', () => {
    // Measured on this machine by dropping each one and watching the agent
    // fail — see the comment on MEASURED_SYSTEM_READ_PATHS. They are constants
    // because they are the same on every macOS install; everything above is a
    // function because it is not.
    expect([...MEASURED_SYSTEM_READ_PATHS]).toEqual([
      '/usr',
      '/bin',
      '/System',
      '/Library',
      '/etc',
      '/dev',
      '/private/var/db',
      '/private/var/select',
    ])
    for (const path of MEASURED_SYSTEM_READ_PATHS) expect(allowlist()).toContain(path)
  })

  test('no entry is contained by another', () => {
    // An allowlist that names a directory and something inside it says the same
    // thing twice, and the second copy is what a reader has to check against
    // the deny list for nothing.
    const list = allowlist()
    for (const outer of list) {
      for (const inner of list) {
        if (outer === inner) continue
        expect(reopens(outer, inner)).toBe(false)
      }
    }
  })

  test('adding it to the policy today would re-open both keychains and all four binaries', () => {
    /*
      The judgement. `allowRead` beats `denyRead`, so `/usr` hands back
      /usr/bin/security, /usr/bin/osascript, /usr/bin/open and /usr/bin/sudo,
      and `/Library` hands back /Library/Keychains — the directory ticket 16
      denied after dumping 37 generic passwords out of it.

      Under allow-by-default reads that is a pure loss: every one of these paths
      is *already* readable, so the entries buy nothing and cost the denials.
      This test exists so that wiring the list in fails here with the reason
      rather than in a probe with a keychain dump.
    */
    const list = allowlist()
    const reopened = [MACHINE_KEYCHAIN_DIR, ...UNREADABLE_BINARIES].filter((denied) =>
      list.some((allowed) => reopens(allowed, denied)),
    )
    expect(reopened).toEqual([MACHINE_KEYCHAIN_DIR, ...UNREADABLE_BINARIES])
  })

  test('so the policy still reads back exactly the clone and nothing else', () => {
    expect(policy().filesystem.allowRead).toEqual([CLONE])
  })
})

// ---------------------------------------------------------------------------
// What the kernel refused, and which refusals are news
// ---------------------------------------------------------------------------

describe('sandbox violations', () => {
  /*
    Ticket 18's second prerequisite. srt watches the kernel's deny events and
    varnick never listened, so a missing allowlist entry is `exit 133` and
    nothing else — the failure shape this project has already lost a day to.

    Every line below is one srt's monitor really produced on this machine,
    copied out of its callback rather than invented.
  */

  const READ_OUTSIDE = 'cat(28194) deny(1) file-read-data /opt/toolchain/lib/libthing.dylib'
  const READ_HOME = 'cat(28194) deny(1) file-read-data /Users/uptown/.zshrc'
  const SYSCTL = 'bash(28194) deny(1) sysctl-read kern.iossupportversion'

  test('a violation line is read into the operation and what it was refused on', () => {
    const violation = parseSandboxViolation(READ_HOME, 'cat "/Users/uptown/.zshrc"')
    expect(violation.operation).toBe('file-read-data')
    expect(violation.subject).toBe('/Users/uptown/.zshrc')
    expect(violation.command).toBe('cat "/Users/uptown/.zshrc"')
    // The raw line is kept, because the classification below can be wrong and
    // the line is the evidence.
    expect(violation.line).toBe(READ_HOME)
  })

  test('a denial the policy asked for is not news', () => {
    // `denyRead` names $HOME. A refusal there is the fence working, and a
    // developer who is told about it on every launch stops reading the channel
    // this exists to use.
    expect(isUnexpectedViolation(policy(), parseSandboxViolation(READ_HOME))).toBe(false)
  })

  test('a read the policy never meant to deny is', () => {
    expect(isUnexpectedViolation(policy(), parseSandboxViolation(READ_OUTSIDE))).toBe(true)
  })

  test('the sysctl denial every wrapped command produces is silent', () => {
    /*
      Measured, and the reason this is filtered at all: *every* command run
      under the policy produces two of these, one for the wrapping bash and one
      for the command itself. An unfiltered monitor is therefore two lines of
      noise per command before anything has gone wrong.
    */
    expect(isUnexpectedViolation(policy(), parseSandboxViolation(SYSCTL))).toBe(false)
  })

  test('a denied host and a refused Apple Event are silent too', () => {
    // Both are what the policy asks for — `strictAllowlist` and
    // `allowAppleEvents: false` — so neither is a gap in the read allowlist.
    for (const line of [
      'curl(1) deny(1) network-outbound example.com:443',
      'osascript(1) deny(1) appleevent-send com.apple.finder',
    ]) {
      expect(isUnexpectedViolation(policy(), parseSandboxViolation(line))).toBe(false)
    }
  })

  test('a denied root does not silence the monitor', () => {
    /*
      The property that has to hold *after* reads are inverted, asserted before
      the inversion lands. `denyRead: ['/']` puts every path in the filesystem
      under a denial, so a filter that asked only "is this path denied?" would
      go quiet at exactly the moment it starts being the only thing that says
      why the agent will not start.

      The root is the mechanism, not an intention. What varnick means to deny is
      the named list beside it, and that is what stays silent.
    */
    const inverted = policy()
    inverted.filesystem.denyRead = [sep, ...inverted.filesystem.denyRead]

    expect(isUnexpectedViolation(inverted, parseSandboxViolation(READ_OUTSIDE))).toBe(true)
    expect(isUnexpectedViolation(inverted, parseSandboxViolation(READ_HOME))).toBe(false)
  })

  test('a line nothing can parse is reported when it mentions a read', () => {
    // Swallowing it would be the failure this whole mechanism exists to stop,
    // one format change later.
    const odd = parseSandboxViolation('something new deny file-read-data somewhere')
    expect(isUnexpectedViolation(policy(), odd)).toBe(true)
    expect(isUnexpectedViolation(policy(), parseSandboxViolation('unrecognisable'))).toBe(false)
  })

  test('what a developer is told names the path, the command, and what to do', () => {
    const text = describeSandboxViolation(
      parseSandboxViolation(READ_OUTSIDE, 'bun /clone/packages/harness/src/agent.ts'),
    )
    expect(text).toContain('/opt/toolchain/lib/libthing.dylib')
    expect(text).toContain('file-read-data')
    expect(text).toContain('agent.ts')
    expect(text).toContain(SANDBOX_POLICY_FILENAME)
  })
})
