import { describe, expect, test } from 'bun:test'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, sep } from 'node:path'
import {
  DEFAULT_ALLOWED_HOSTS,
  GIT_EXECUTABLE_CONFIG,
  HOST_INVOKED_SCRIPTS,
  MACHINE_KEYCHAIN_DIR,
  MEASURED_SYSTEM_READ_PATHS,
  PRIVATE_LINK_PATHS,
  SANDBOX_BASELINE_FILENAME,
  claudeScratchDirFor,
  CLAUDE_CWD_MARKER_GLOB,
  SANDBOX_POLICY_FILENAME,
  TRACKED_HOOKS_DIR,
  UNREADABLE_BINARIES,
  describeSandboxPolicy,
  describeSandboxViolation,
  ensureSandboxPolicy,
  establishSandbox,
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
const EXEC = '/Users/dev/.bun/bin/bun'
const SDK = '/Users/dev/code/varnick/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs'
const TOOLS = '/Applications/Xcode.app/Contents/Developer/usr/bin'

/*
  A whole machine, rather than a home directory on its own.

  The read allowlist holds the interpreter's install root, and that usually sits
  *inside* the home directory — `~/.bun` here. So a fixture that moves `homeDir`
  and leaves the allowlist pointing at this laptop's real `~/.bun` describes a
  machine no generator would ever produce, and the inconsistency then reads as a
  boundary change when the clone is carried somewhere else. Every policy below
  is built through here so that it is a function of its arguments and of nothing
  this file is running on.
*/
const machine = (input: { cloneRoot: string; homeDir: string; tmpDir?: string }) => ({
  ...input,
  readAllowlist: readAllowlistFor({
    cloneRoot: input.cloneRoot,
    execPath: `${input.homeDir}/.bun/bin/bun`,
    sdkEntry: `${input.cloneRoot}/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs`,
    developerToolsBin: TOOLS,
  }),
})

const policy = () => sandboxPolicyFor(machine({ cloneRoot: CLONE, homeDir: HOME, tmpDir: TMP }))

/** Does `allowed` re-open `path`, either exactly or as an ancestor directory? */
const reopens = (allowed: string, path: string) =>
  allowed === path || path.startsWith(allowed.endsWith(sep) ? allowed : allowed + sep)

/**
 * Would this `denyWrite` entry refuse a write to `path`?
 *
 * The list holds three shapes — a literal file, a directory, and a glob — and a
 * developer reading it asks one question of all three. Deliberately generous:
 * it is used to assert that something is *not* denied, so a matcher that
 * under-matched would let a denial grow past what the test claims to bound.
 */
const coversWrite = (denied: string, path: string) =>
  denied === path ||
  path.startsWith(denied.endsWith(sep) ? denied : denied + sep) ||
  new Bun.Glob(denied).match(path)

describe('what the policy denies', () => {
  test('reads are denied by default, and the root is what says so', () => {
    // Ticket 18. `denyRead` used to be a deny list with everything outside it
    // readable, which left a repository on /opt, /srv, /Volumes or an external
    // disk open in full. The filesystem root is now denied and `allowRead` is
    // the whole of what is readable.
    expect(policy().filesystem.denyRead).toContain(sep)
  })

  test('the home directory and every sibling home are named anyway', () => {
    /*
      Not redundant under the denied root, and this is the test that says why.
      Three things read this list rather than the root: srt re-emits these
      denials when an allowance contains them, `isUnexpectedViolation` decides
      from them which kernel refusals are the fence working, and a developer
      reads them to learn what varnick *meant* to deny as opposed to what the
      root happens to cover.
    */
    const { denyRead } = policy().filesystem
    expect(denyRead).toContain(HOME)
    // The parent of home is what covers *other* repositories: another user's
    // checkout, and anything of mine that lives outside the clone.
    expect(denyRead).toContain('/Users')
  })

  test('the clone is read back out of the denied root', () => {
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

  test('the allowlist does contain the denied binaries, and they stay denied', () => {
    /*
      This assertion is the inverse of the one it replaces, and the inversion is
      the ticket.

      Before the root was denied, `allowRead` held one entry and the rule was
      "nothing in it may cover a denied path" — `/usr` would have handed back all
      four binaries, so the test forbade `/usr`. Under a denied root `/usr` is
      not optional: nothing starts without it. So the property moved from the
      list's *shape* to srt's *behaviour*, and this asserts the precondition that
      behaviour has.

      `generateReadRules` emits `(allow file-read*)`, then the denies, then the
      allows — last match wins, so `/usr` would beat the deny on
      `/usr/bin/security`. A final pass re-emits any **literal** deny that sits
      strictly inside an allowed subpath, which puts the specific rule last again.
      Two things have to hold for that to reach these four, and both are checked
      here: each is named in `denyRead`, and each is a literal path rather than a
      glob. Glob denies are deliberately not re-emitted — srt's own comment says
      so, and `denyReadAlways` is its lever for that case — so writing one of
      these as a pattern would silently hand the binary back.

      The kernel half is probe 2 and sandbox.boundary.test.ts; this is what fails
      first, in a file with no keychain dump in it.
    */
    const { allowRead, denyRead } = policy().filesystem

    for (const binary of UNREADABLE_BINARIES) {
      const covering = allowRead.filter((allowed) => reopens(allowed, binary))
      expect(covering).toContain('/usr')
      expect(denyRead).toContain(binary)
      expect(binary).not.toMatch(/[*?[\]]/)
      // srt's condition verbatim: `normalized.startsWith(allowed + '/')`. An
      // allowance equal to the denial would not be re-emitted, and would win.
      for (const allowed of covering) expect(binary.startsWith(`${allowed}${sep}`)).toBe(true)
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

  test('the allowlist contains the machine-wide keychains too, and they stay denied', () => {
    // Same inversion, and the entry with the most behind it: `/Library` is in
    // the allowlist because the developer toolchain and the system frameworks
    // live there, and /Library/Keychains is the directory ticket 16 denied after
    // dumping 37 generic passwords out of it. It is denied by being named, being
    // literal, and being strictly inside `/Library` — the three conditions srt's
    // re-emission pass needs.
    const { allowRead, denyRead } = policy().filesystem
    const covering = allowRead.filter((allowed) => reopens(allowed, MACHINE_KEYCHAIN_DIR))

    expect(covering).toContain('/Library')
    expect(denyRead).toContain(MACHINE_KEYCHAIN_DIR)
    expect(MACHINE_KEYCHAIN_DIR).not.toMatch(/[*?[\]]/)
    for (const allowed of covering) {
      expect(MACHINE_KEYCHAIN_DIR.startsWith(`${allowed}${sep}`)).toBe(true)
    }
  })

  test('every denial an allowance contains is re-emittable, whatever the list grows into', () => {
    /*
      The two tests above name the paths that are covered today. This one is the
      rule, and it is the one that catches an entry nobody thought about: any
      future `denyRead` path that ends up inside a future `allowRead` path has to
      be a literal, strictly nested, or srt will not re-emit it and the deny is
      simply lost. The filesystem root is excluded because it is the mechanism
      rather than a denial anyone means — it is *equal* to no allowance and
      contains all of them.
    */
    const { allowRead, denyRead } = policy().filesystem
    for (const denied of denyRead.filter((path) => path !== sep)) {
      for (const allowed of allowRead) {
        if (!reopens(allowed, denied)) continue
        expect(denied).not.toMatch(/[*?[\]]/)
        expect(denied.startsWith(`${allowed}${sep}`)).toBe(true)
      }
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

  test('the host that enforces the boundary is unwritable', () => {
    /*
      The fourth thing that can change the fence on the next launch, and the one
      that was missed. `src-tauri` reads the credential, spawns the agent under
      srt, and decides what the window may ask for — outside the Sandbox, and
      recompiled on every `bun tauri dev`. An agent that edits it cannot run what
      it wrote; the developer does, and by then the spawn may not wrap anything.

      ADR-0005 already routes Core changes through a Clone and a reviewed
      Collect. This is that being enforced rather than assumed.
    */
    expect(policy().filesystem.denyWrite).toContain(`${CLONE}/src-tauri/**`)
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
    expect(policy().filesystem.allowWrite).toEqual([
      CLONE,
      TMP,
      claudeScratchDirFor(process.getuid?.() ?? 0),
      CLAUDE_CWD_MARKER_GLOB,
    ])
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
    expect(network.allowAllUnixSockets).toBe(false)
  })

  test('the agent may bind a local port, and that is not an egress widening', () => {
    /*
      ADR-0015. `allowLocalBinding` was `false` with no comment beside it —
      srt's default carried through rather than a decision — and it cost the
      agent the whole of its ability to observe its own work: no dev server, no
      test server, no headless browser, no CDP.

      Measured in srt 0.0.67, the flag adds exactly three Seatbelt rules:
      `network-bind` and `network-inbound` on `(local ip "*:*")`, and
      `network-outbound` on `(remote ip "localhost:*")`. The last is the one
      that matters here: srt uses the `localhost` form on purpose so that the
      egress allowlist stays enforced under this flag (its issues #225, #88).

      So the three assertions below travel together on purpose. The flag is only
      admissible while the allowlist beside it is untouched, and a change that
      widened egress to buy local binding would fail here rather than in a probe.
    */
    const { network } = policy()
    expect(network.allowLocalBinding).toBe(true)
    expect(network.allowedDomains).toEqual([...DEFAULT_ALLOWED_HOSTS])
    expect(network.strictAllowlist).toBe(true)
    // Unix sockets are a second inbound channel and are *not* what this buys.
    expect(network.allowAllUnixSockets).toBe(false)
  })

  test("git's own executable configuration is unwritable", () => {
    /*
      ADR-0016. `.git` is the one part of the repository no diff ever shows, so
      a write there executes ahead of the review gate rather than behind it: a
      `pre-commit` the agent planted runs unconfined on the developer's next
      commit, including the merge commit that was supposed to be the gate.

      Both entries or neither. `.git/config` holds `core.hooksPath`, so denying
      the hooks directory alone is decorative — the agent redirects hooks to a
      directory it can still write — and the same file defines the
      `filter.<name>.clean`/`.smudge` commands `.gitattributes` invokes.
    */
    const { denyWrite } = policy().filesystem
    for (const entry of GIT_EXECUTABLE_CONFIG) {
      expect(denyWrite).toContain(`${CLONE}/${entry}`)
    }
    // Named as a pair rather than assumed to be one: a future edit that drops
    // `.git/config` and keeps the hooks directory fails here.
    expect([...GIT_EXECUTABLE_CONFIG]).toEqual(['.git/hooks/**', '.git/config*'])
    // `config*`, so the lock goes with the file. Measured during review: the
    // agent could write `.git/config.lock` under the bare spelling. That was a
    // nuisance and not an escalation — git writes the lock and renames it over
    // the target, and the rename is what the deny catches — but a stale lock
    // the agent could not finish with fails the *developer's* next `git config`.
    expect(GIT_EXECUTABLE_CONFIG[1]).toBe('.git/config*')
  })

  test('the scripts the root manifest runs are unwritable', () => {
    /*
      `package.json` at the root is denied because its scripts run on the
      developer's machine. Found while reviewing ticket 45, which added a
      `postinstall` reading `sh scripts/use-tracked-git-hooks.sh`: denying the
      manifest while leaving the script it names writable is the same
      decorative deny the test above rejects for `.git/hooks` without
      `.git/config`. The agent would never touch a denied file — it would
      rewrite what the denied file invokes.
    */
    const { denyWrite } = policy().filesystem
    expect(denyWrite).toContain(`${CLONE}/${HOST_INVOKED_SCRIPTS}`)
    expect(denyWrite).toContain(`${CLONE}/package.json`)
  })

  test('what a worktree, a commit and a merge write inside .git stays writable', () => {
    /*
      The measured half of ADR-0016, asserted so the deny above cannot quietly
      grow into the whole of `.git` and take the Worktree model with it.

      `git worktree add` does not write `.git/config` — md5 identical before and
      after. What it and every commit and merge do write is below, and none of
      it is denied.
    */
    const { denyWrite } = policy().filesystem
    for (const needed of [
      `${CLONE}/.git/worktrees/some-worktree/HEAD`,
      `${CLONE}/.git/objects/ab/cdef`,
      `${CLONE}/.git/refs/heads/main`,
      `${CLONE}/.git/index`,
      `${CLONE}/.git/COMMIT_EDITMSG`,
      // The tracked hooks directory git is pointed at instead. It is Userspace
      // as far as the boundary is concerned: the agent writes hooks freely and
      // they arrive through a diff a human read.
      `${CLONE}/${TRACKED_HOOKS_DIR}/pre-commit`,
    ]) {
      expect(denyWrite.some((denied) => coversWrite(denied, needed))).toBe(false)
    }
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

  test('the description says what local binding grants and what it does not', () => {
    /*
      Someone reads the generated file before they read ADR-0015, and
      `"allowLocalBinding": true` on its own reads like a network widening. The
      comment block is where that is settled: the two things it grants named
      rather than glossed, and the one thing it does not.
    */
    const text = describeSandboxPolicy(policy())
    expect(text).toContain('allowLocalBinding')
    // Ingress on any interface, not loopback — srt's bind rule is `local ip
    // "*:*"`, because a dual-stack runtime binds 127.0.0.1 as ::ffff:127.0.0.1
    // and Seatbelt's `localhost` token does not match that.
    expect(text.toLowerCase()).toContain('any interface')
    // And the half that is not widened, which is the reason the flag is
    // admissible at all.
    expect(text.toLowerCase()).toContain('egress')
  })

  test("the description says why git's own directory is denied", () => {
    // The only two denials in the file whose reason is "no diff shows this".
    // A developer who deletes them should have read that first.
    const text = describeSandboxPolicy(policy())
    expect(text).toContain('.git/hooks')
    expect(text).toContain('.git/config')
    expect(text).toContain(TRACKED_HOOKS_DIR)
    expect(text).toContain('core.hooksPath')
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

  /**
   * The policy as the generator produced it before ADR-0015 and ADR-0016 —
   * local binding off, and `.git` writable.
   *
   * A second plant beside `olderGenerator`, because ticket 45 ships a
   * strengthening and a widening in the same release and they reach an existing
   * clone by different routes. The three tests below are the measurement ticket
   * 17's rule asks for.
   */
  const beforeTicket45 = (clone: string): SandboxPolicy => {
    const older = sandboxPolicyFor({ cloneRoot: clone })
    older.network.allowLocalBinding = false
    older.filesystem.denyWrite = older.filesystem.denyWrite.filter(
      (path) => !GIT_EXECUTABLE_CONFIG.some((entry) => path === `${clone}/${entry}`),
    )
    return older
  }

  const plant45 = (clone: string, options: { recordBaseline: boolean }) => {
    const older = beforeTicket45(clone)
    if (options.recordBaseline) {
      writeFileSync(
        sandboxBaselinePath(clone),
        `${JSON.stringify(normalizeSandboxPolicy(older, { cloneRoot: clone }), null, 2)}\n`,
      )
    }
    writeFileSync(sandboxPolicyPath(clone), `${JSON.stringify(older, null, 2)}\n`)
  }

  test("the .git denials reach a clone whose baseline predates them", () => {
    /*
      Ticket 17's rule applied to ticket 45's strengthening. `filesystem.denyWrite`
      strengthens by growing, so a clone that never disagreed about it takes the
      generator's current list — which is the whole of the fix reaching an
      existing clone rather than new ones only.
    */
    withClone((clone) => {
      plant45(clone, { recordBaseline: true })

      const { policy, report } = ensureSandboxPolicy({ cloneRoot: clone })

      for (const entry of GIT_EXECUTABLE_CONFIG) {
        expect(policy.filesystem.denyWrite).toContain(`${clone}/${entry}`)
      }
      expect(report.outcome).toBe('updated')
      // Said in words on stderr as well as written to the file.
      expect(report.lines.join('\n')).toContain('.git/hooks')
    })
  })

  test('the .git denials reach a clone with no baseline at all, by the union', () => {
    // The unattributable clone, which can credit nothing to anybody and so
    // takes the stronger side of every difference. For a denial that is the
    // union, so the two new entries land here too.
    withClone((clone) => {
      plant45(clone, { recordBaseline: false })

      const { policy, report } = ensureSandboxPolicy({ cloneRoot: clone })

      expect(report.unattributed).toBe(true)
      for (const entry of GIT_EXECUTABLE_CONFIG) {
        expect(policy.filesystem.denyWrite).toContain(`${clone}/${entry}`)
      }
    })
  })

  test('local binding is a widening, so it reaches only a clone that can attribute it', () => {
    /*
      The finding ticket 45's "watch for" asks about, and it is the *other*
      half. `network.allowLocalBinding` strengthens by being false, so it is a
      widening and the merge treats it as one — which is right, and it means the
      two changes in this release reach an existing clone by different routes.

      **Attributable clone: it lands.** The developer never touched the field,
      so the generator's current value wins, and the widening is reported as
      `[weaker]` where they will read it rather than found in a diff.

      **Unattributable clone: it does not, and it never will.** Nothing can be
      credited to anybody, so the stronger side of every difference wins, and
      for this field the stronger side is `false`. That run then records a
      baseline saying `true`, so from the next launch on the difference reads as
      the developer's own edit and is kept exactly. A clone that has never
      recorded a baseline therefore keeps `allowLocalBinding: false` for good.

      That is the merge working, not a defect: "nothing is ever resolved to the
      weaker side" is the rule this whole mechanism exists to keep, and forcing
      a widening past it to make a dev server work would be exactly the trade
      the rule forbids. The fix for such a clone is one hand edit, or deleting
      `sandbox-policy.json` and letting it be generated again. It is written
      down here because the alternative is somebody rediscovering it as "the dev
      server works on my machine and not on this one".
    */
    withClone((clone) => {
      plant45(clone, { recordBaseline: true })
      const attributable = ensureSandboxPolicy({ cloneRoot: clone })
      expect(attributable.policy.network.allowLocalBinding).toBe(true)
      expect(
        attributable.report.ours.some(
          (c) => c.field === 'network.allowLocalBinding' && c.direction === 'weaker',
        ),
      ).toBe(true)
      expect(attributable.report.lines.join('\n')).toContain('weaker')
    })

    withClone((clone) => {
      plant45(clone, { recordBaseline: false })
      const first = ensureSandboxPolicy({ cloneRoot: clone })
      expect(first.report.unattributed).toBe(true)
      expect(first.policy.network.allowLocalBinding).toBe(false)
      // And it stays that way once a baseline exists, because by then the
      // difference is indistinguishable from a developer's own narrowing.
      const second = ensureSandboxPolicy({ cloneRoot: clone })
      expect(second.policy.network.allowLocalBinding).toBe(false)
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
      const first = ensureSandboxPolicy(machine({ cloneRoot: clone, homeDir: '/Users/before' }))
      expect(first.policy.filesystem.denyRead).toContain('/Users/before')

      // ...read on another, where home is somewhere else entirely.
      const second = ensureSandboxPolicy(machine({ cloneRoot: clone, homeDir: '/home/after' }))

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
      ensureSandboxPolicy(machine({ cloneRoot: clone, homeDir: '/Users/before' }))
      const edited = readSandboxPolicy(clone) as SandboxPolicy
      edited.network.allowedDomains = ['api.anthropic.com']
      writeFileSync(sandboxPolicyPath(clone), `${JSON.stringify(edited, null, 2)}\n`)

      const moved = ensureSandboxPolicy(machine({ cloneRoot: clone, homeDir: '/home/after' }))

      expect(moved.policy.network.allowedDomains).toEqual(['api.anthropic.com'])
      expect(moved.policy.filesystem.denyRead).toContain('/home/after')
      // The edit is attributed to the developer, and the move to nobody.
      expect(fields(moved.report.yours)).toEqual(['network.allowedDomains'])
      expect(moved.report.ours).toEqual([])
    })
  })

  test('the baseline records the policy in tokens and the roots separately', () => {
    withClone((clone) => {
      ensureSandboxPolicy(machine({ cloneRoot: clone, homeDir: '/Users/dev' }))

      expect(existsSync(sandboxBaselinePath(clone))).toBe(true)
      const baseline = readSandboxBaseline(clone)

      // The policy half carries no machine root. That is what makes a move
      // invisible rather than a wholesale rewrite of denyRead — and it has to
      // hold for the read allowlist too, whose first entry is the clone and
      // whose interpreter entry lives inside the home directory.
      expect(baseline?.policy.filesystem.allowRead[0]).toBe('<clone>')
      expect(baseline?.policy.filesystem.allowRead).toContain('<home>/.bun')
      expect(baseline?.policy.filesystem.allowRead.join(' ')).not.toContain(clone)
      expect(baseline?.policy.filesystem.denyRead).toContain('<home>')
      // The root, which is a root and not a machine's.
      expect(baseline?.policy.filesystem.denyRead).toContain(sep)
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

  test('a clone that predates the denied root gets the allowlist that makes it survivable', () => {
    /*
      The one place the per-field merge is wrong on its own, and ticket 18 is
      what exposed it.

      Union for a denial and intersection for an allowance are each right
      separately. Together, on a clone with no baseline — which can attribute
      nothing and so takes the stronger side of everything — they adopt
      `denyRead: ['/']` from the generator *and* intersect `allowRead` down to
      the one entry the old policy had. That denies the filesystem and reads back
      a directory: `/bin/bash` cannot be mapped and nothing runs at all, with
      `exit 133` and no message. It is not a stronger boundary, it is no product.

      So the allowlist rides with the root, and the developer is told, in the
      word that means something got wider.
    */
    withClone((clone) => {
      const before = sandboxPolicyFor({ cloneRoot: clone })
      before.filesystem.denyRead = before.filesystem.denyRead.filter((path) => path !== sep)
      before.filesystem.allowRead = [clone]
      writeFileSync(sandboxPolicyPath(clone), `${JSON.stringify(before, null, 2)}\n`)

      const { policy, report } = ensureSandboxPolicy({ cloneRoot: clone })

      expect(report.unattributed).toBe(true)
      expect(policy.filesystem.denyRead).toContain(sep)
      // Everything the generator names, not the intersection.
      for (const path of sandboxPolicyFor({ cloneRoot: clone }).filesystem.allowRead) {
        expect(policy.filesystem.allowRead).toContain(path)
      }
      expect(report.lines.join('\n')).toContain('[weaker] filesystem.allowRead')
    })
  })

  test('normalizing and materializing a policy is a round trip', () => {
    const input = machine({
      cloneRoot: '/Users/dev/code/varnick',
      homeDir: '/Users/dev',
      tmpDir: '/tmp/x',
    })
    const original = sandboxPolicyFor(input)
    const normalized = normalizeSandboxPolicy(original, input)
    // The clone is a nested path under home, which is nested under the users
    // root: the longest root has to win or the clone stops being the clone.
    expect(normalized.filesystem.allowRead[0]).toBe('<clone>')
    // And the interpreter, which is under home rather than under the clone, so
    // the two have to tokenize differently or a move rewrites one of them.
    expect(normalized.filesystem.allowRead).toContain('<home>/.bun')
    expect(normalized.filesystem.denyRead).toContain('<home>')
    expect(normalized.filesystem.denyRead).toContain('<users>')
    expect(materializeSandboxPolicy(normalized, input)).toEqual(original)
  })
})

// ---------------------------------------------------------------------------
// The read allowlist the denied root needs — computed, and in the policy
// ---------------------------------------------------------------------------

describe('the read allowlist the denied root needs', () => {
  /*
    Ticket 18. Inverting reads means naming everything the toolchain has to
    reach, and the list is not the same on two machines: this one runs `~/.bun`,
    the next runs node out of Homebrew or nvm. So the parts that vary are derived
    from the process that is already running and only the parts that do not are
    constants.

    This is now what `sandboxPolicyFor` puts in `allowRead`, and the last two
    tests in this block are the pair that changed when it was wired in. They used
    to assert that adding the list would re-open both keychains and all four
    binaries, and that the policy therefore still read back only the clone. It
    does re-open them by containment, and they are denied anyway — see
    "the allowlist does contain the denied binaries" above for the mechanism.
  */

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

  test('the system paths are the eleven that were measured, and are still constants', () => {
    // Measured on this machine by dropping each one and watching something fail
    // with the path in the message — see the comment on
    // MEASURED_SYSTEM_READ_PATHS, which records what each one broke. They are
    // constants because they are the same on every macOS install; everything
    // above is a function because it is not.
    expect([...MEASURED_SYSTEM_READ_PATHS]).toEqual([
      '/usr',
      '/bin',
      '/System',
      '/Library',
      '/dev',
      '/etc',
      '/private/etc',
      '/tmp',
      '/var',
      '/private/var/db',
      '/private/var/select',
    ])
    for (const path of MEASURED_SYSTEM_READ_PATHS) expect(allowlist()).toContain(path)
  })

  test('the three root symlinks are named in both spellings, and that is not duplication', () => {
    /*
      `/etc`, `/tmp` and `/var` are symlinks into `/private`, and the kernel
      canonicalizes a real access below one of them — so a rule naming the link
      matches the link and nothing else. Both spellings therefore have to be in
      the list, because different code inside the same program reaches the same
      file by different names:

        drop /etc          curl: CAfile /etc/ssl/cert.pem
        drop /private/etc  curl: /private/etc/ssl/openssl.cnf

      Measured under the shipped policy. `PRIVATE_LINK_PATHS` is what stops the
      redundancy pass below treating the pair as one.
    */
    expect([...PRIVATE_LINK_PATHS]).toEqual(['/etc', '/tmp', '/var'])
    for (const link of PRIVATE_LINK_PATHS) {
      expect(allowlist()).toContain(link)
      expect(MEASURED_SYSTEM_READ_PATHS).toContain(link)
    }
    expect(allowlist()).toContain('/private/etc')
  })

  test('no entry is contained by another, except through a root symlink', () => {
    // An allowlist that names a directory and something inside it says the same
    // thing twice, and the second copy is what a reader has to check against
    // the deny list for nothing. The exception is the point of the test above:
    // `/var` reads as containing `/private/var/db` to nobody, and as containing
    // the OS temp directory to a string comparison — and dropping that entry was
    // measured to break `touch` in $TMPDIR.
    const list = allowlist()
    for (const outer of list) {
      if ((PRIVATE_LINK_PATHS as readonly string[]).includes(outer)) continue
      for (const inner of list) {
        if (outer === inner) continue
        expect(reopens(outer, inner)).toBe(false)
      }
    }
  })

  test('every writable tree is readable, because a tree you cannot stat you cannot write', () => {
    /*
      `touch` stats before it creates and `mkdir -p` stats every component on the
      way down, so a write grant with no matching read is not a grant. Under
      allow-by-default reads this was free; under the denied root it was two
      measured failures, the second of which is ticket 27 over again:

        touch $TMPDIR/x                Operation not permitted
        mkdir -p /tmp/claude-<uid>/x   Operation not permitted

      Asserted over the policy rather than the allowlist function, because this
      is a fact about the two lists agreeing with each other.
    */
    const { allowRead, allowWrite } = policy().filesystem
    for (const writable of allowWrite) {
      expect(allowRead.some((allowed) => reopens(allowed, writable))).toBe(true)
    }
  })

  test('it contains every one of the six denied paths, and none of them is re-opened', () => {
    /*
      The inverted assertion, and the load-bearing one.

      Its predecessor said that adding this list to the policy would re-open
      /Library/Keychains and all four UNREADABLE_BINARIES, and that this was why
      it was not wired in. The containment half of that is still exactly true —
      `/usr` covers the binaries and `/Library` covers the keychains, and the
      first half of this test asserts it path by path rather than softening it.

      What changed is the conclusion. Under a denied root `/usr` and `/Library`
      are not optional, so the denials cannot be kept by keeping the list out;
      they are kept by srt re-emitting each nested literal deny after the allows,
      which is the property the second half checks the precondition of. Both
      halves are here in one test because the danger is that somebody satisfies
      one of them by weakening the other.
    */
    const list = allowlist()
    const denied = [MACHINE_KEYCHAIN_DIR, ...UNREADABLE_BINARIES]

    const contained = denied.filter((path) => list.some((allowed) => reopens(allowed, path)))
    expect(contained).toEqual(denied)

    const { denyRead } = policy().filesystem
    for (const path of denied) {
      expect(denyRead).toContain(path)
      expect(path).not.toMatch(/[*?[\]]/)
      const covering = list.filter((allowed) => reopens(allowed, path))
      for (const allowed of covering) expect(path.startsWith(`${allowed}${sep}`)).toBe(true)
    }
  })

  test('so the policy reads back the clone first and then exactly this list', () => {
    // The other inverted assertion: `allowRead` was `[CLONE]` and is now the
    // computed list, with the two writable trees the previous test's rule adds.
    const { allowRead } = policy().filesystem
    expect(allowRead[0]).toBe(CLONE)
    for (const path of allowlist()) expect(allowRead).toContain(path)
    expect(allowRead).toContain(TMP)
    expect(allowRead).toContain(claudeScratchDirFor(process.getuid?.() ?? 0))
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

  test('the denied root does not silence the monitor', () => {
    /*
      Written before the inversion landed, against a policy this test had to
      build for itself. It now reads the shipped one, which is the whole point:
      `denyRead` names `/`, so every path in the filesystem is under a denial,
      and a filter that asked only "is this path denied?" would be silent at
      exactly the moment it becomes the only thing that says why the agent will
      not start.

      The root is the mechanism, not an intention. What varnick means to deny is
      the named list beside it, and that is what stays silent. The control is the
      line below it: with the root removed, the *same* event is still news, so
      this is not measuring a filter that says yes to everything.
    */
    const shipped = policy()
    expect(shipped.filesystem.denyRead).toContain(sep)

    expect(isUnexpectedViolation(shipped, parseSandboxViolation(READ_OUTSIDE))).toBe(true)
    expect(isUnexpectedViolation(shipped, parseSandboxViolation(READ_HOME))).toBe(false)

    const withoutTheRoot: SandboxPolicy = {
      ...shipped,
      filesystem: {
        ...shipped.filesystem,
        denyRead: shipped.filesystem.denyRead.filter((path) => path !== sep),
      },
    }
    expect(isUnexpectedViolation(withoutTheRoot, parseSandboxViolation(READ_OUTSIDE))).toBe(true)
    expect(isUnexpectedViolation(withoutTheRoot, parseSandboxViolation(READ_HOME))).toBe(false)
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

// ---------------------------------------------------------------------------
// Which root the boundary is drawn around
// ---------------------------------------------------------------------------

describe('which root the boundary is drawn around', () => {
  /*
    The clone root used to arrive as a working directory and nothing named it.
    These tests are the two halves of fixing that: the root is checked before a
    Sandbox is established for it, and every entry in the policy is built from
    the root it was *given* rather than from the process's own cwd.

    See docs/adr/0012-the-clone-root-is-an-input.md and clone-root.ts.
  */

  test('a Sandbox is never established for a directory that is not there', async () => {
    // The failure this replaces: a policy generated for a moved checkout, and a
    // Sandbox reported available for a directory that no longer existed.
    await expect(establishSandbox({ cloneRoot: '/Users/dev/moved-away-1234' })).rejects.toThrow(
      /no directory at \/Users\/dev\/moved-away-1234/,
    )
  })

  test('the root is checked before the platform is, so the reason is the root', async () => {
    // Ordering matters for the message. On a platform srt does not support, a
    // root varnick cannot use must still be reported as the root — the
    // developer fixes the path, not the operating system.
    await expect(establishSandbox({ cloneRoot: 'relative/clone' })).rejects.toThrow(
      /not an absolute path/,
    )
  })

  test('the Core/Userspace write boundary is drawn around the root it was given', () => {
    // ADR-0002's boundary, per root. Two roots on one machine get two
    // boundaries, and neither of them is the process's working directory.
    const one = sandboxPolicyFor({ cloneRoot: '/opt/a', homeDir: HOME, tmpDir: TMP })
    const two = sandboxPolicyFor({ cloneRoot: '/opt/b', homeDir: HOME, tmpDir: TMP })

    expect(one.filesystem.denyWrite).toContain('/opt/a/packages/core/**')
    expect(one.filesystem.denyWrite).toContain('/opt/a/packages/harness/**')
    expect(one.filesystem.denyWrite.join(' ')).not.toContain('/opt/b')
    expect(two.filesystem.denyWrite).toContain('/opt/b/packages/core/**')
    expect(two.filesystem.denyWrite.join(' ')).not.toContain('/opt/a')

    // And the writable tree is that root, never the one varnick was built from.
    expect(one.filesystem.allowWrite).toContain('/opt/a')
    expect(one.filesystem.allowWrite).not.toContain(process.cwd())
  })

  test('a second root cannot write the first', () => {
    // The half of "two roots cannot reach each other" that this policy does
    // settle. Reads are the half it does not — see ADR-0012.
    const second = sandboxPolicyFor({ cloneRoot: '/opt/b', homeDir: HOME, tmpDir: TMP })
    expect(second.filesystem.allowWrite.some((path) => path.startsWith('/opt/a'))).toBe(false)
  })
})
