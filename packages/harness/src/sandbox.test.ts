import { describe, expect, test } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, sep } from 'node:path'
import {
  DEFAULT_ALLOWED_HOSTS,
  DENIED_BINARIES,
  SANDBOX_POLICY_FILENAME,
  describeSandboxPolicy,
  ensureSandboxPolicy,
  readSandboxPolicy,
  sandboxPolicyFor,
  sandboxPolicyPath,
  validateSandboxPolicy,
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

  test('security, osascript, open and sudo are denied by denying read', () => {
    const { denyRead } = policy().filesystem
    for (const binary of [
      '/usr/bin/security',
      '/usr/bin/osascript',
      '/usr/bin/open',
      '/usr/bin/sudo',
    ]) {
      expect(denyRead).toContain(binary)
    }
    expect(DENIED_BINARIES.length).toBe(4)
  })

  test('no allowRead entry re-opens a denied binary', () => {
    // allowRead beats denyRead, so a broad allow of `/` or `/usr` would silently
    // hand every one of these back. The deny is not what stops them running —
    // containment.probe.test.ts measures that three of the four execute anyway —
    // but it is what keeps their contents out of reach, and an allow that
    // reopened them would undo the one thing the entry does achieve.
    const { allowRead } = policy().filesystem
    for (const allowed of allowRead) {
      for (const binary of DENIED_BINARIES) {
        expect(reopens(allowed, binary)).toBe(false)
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

  test('writes reach the clone and the temp directory and nothing else', () => {
    expect(policy().filesystem.allowWrite).toEqual([CLONE, TMP])
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
