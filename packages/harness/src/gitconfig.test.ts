import { describe, expect, test } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import {
  EXECUTING_GIT_KEYS,
  GIT_CONFIG_GLOBAL_ENV_VAR,
  PROJECTED_GITCONFIG_RELATIVE_PATH,
  PROJECTED_GIT_KEYS,
  agentGitConfigPath,
  isProjectableValue,
  projectGitConfig,
  projectedGitConfigReport,
  readGlobalGitConfigValue,
  renderProjectedGitConfig,
  writeProjectedGitConfig,
} from './gitconfig.ts'

const CLONE = '/Users/dev/varnick'

/** A developer with an ordinary global config. */
const identity = (key: string): string | null =>
  ({ 'user.name': 'Ada Lovelace', 'user.email': 'ada@example.invalid' })[key] ?? null

/** A machine with nothing to project: no config, or none the host can read. */
const nothing = (): string | null => null

/**
 * What git actually reads — the file with its comment lines taken off.
 *
 * The header is prose about executing keys and says the words `alias`,
 * `credential.helper` and `core.hooksPath` out loud, on purpose: it is what a
 * developer who finds the file reads. Asserting over the whole text would make
 * the prose fail the security test, and the fix would be to soften the prose.
 */
const effective = (projected: string): string =>
  projected
    .split('\n')
    .filter((line) => !line.startsWith('#'))
    .join('\n')

describe('what crosses from the developer’s config into the agent’s', () => {
  test('the identity does', () => {
    const projected = projectGitConfig(identity)
    expect(projected).toContain('[user]')
    expect(projected).toContain('name = "Ada Lovelace"')
    expect(projected).toContain('email = "ada@example.invalid"')
  })

  test('the allowlist is two keys, and adding a third is a decision', () => {
    /*
      Asserted as a literal because that is the whole of the security argument.
      The rejected alternative is a *denylist* of the keys that execute, and
      ADR-0018's reasoning applies exactly: such a list is complete the day it is
      written and stale the next time git adds a key, and the failure is silent —
      the key lands in the file every git command in the Sandbox reads.

      A change here is a change to what the agent can make the developer's
      machine do. It should fail this test and be argued in the diff.
    */
    expect([...PROJECTED_GIT_KEYS]).toEqual(['user.name', 'user.email'])
  })

  test('nothing that can execute does', () => {
    /*
      The assertion this file exists for, and it is written against the *bytes*
      rather than against the entry list — a rendered file is what git reads, and
      a key that arrived inside a value would be invisible to a test that
      inspected the entries.

      The reader here answers *every* key, which is the machine this is really
      about: a developer's real config has aliases and credential helpers in it,
      and the projection must not be a function of how many of them there are.

      Proved to bite. Adding `core.hooksPath` to PROJECTED_GIT_KEYS makes this
      fail on `hooksPath`, which is the failure a future widening should hit.
    */
    const projected = effective(projectGitConfig((key) => identity(key) ?? '/tmp/anything'))
    for (const executes of EXECUTING_GIT_KEYS) {
      // The bare key name as well as the qualified one: `core.hooksPath` would
      // be rendered as `hooksPath = …` under a `[core]` header, so asserting
      // only the dotted spelling would miss the very thing it is looking for.
      expect(projected).not.toContain(executes)
      expect(projected).not.toContain(executes.split('.').pop() as string)
    }
  })

  test('a key is asked for by name, so an executing one is never even read', () => {
    // The allowlist is enforced by what is asked rather than by what is
    // filtered. A reader that would happily answer `core.hooksPath` is never
    // asked, which is a stronger claim than dropping the answer afterwards.
    const asked: string[] = []
    projectGitConfig((key) => {
      asked.push(key)
      return null
    })
    expect(asked).toEqual([...PROJECTED_GIT_KEYS])
  })

  test('a value cannot smuggle a section in behind it', () => {
    /*
      Measured rather than imagined: git config values really do carry newlines.
      `name = "a\nb"` parses and `git config --get user.name` prints two lines. So
      a projection that pasted a value through would let a `user.name` of
      `x\n[core]\n\thooksPath = /tmp` put an executing key into a file built to
      have none.
    */
    const projected = effective(
      projectGitConfig((key) =>
        key === 'user.name' ? 'x\n[core]\n\thooksPath = /tmp/evil' : 'ada@example.invalid',
      ),
    )
    expect(projected).not.toContain('hooksPath')
    expect(projected).not.toContain('[core]')
    // Dropped whole rather than truncated at the newline, which would leave a
    // plausible-looking name nobody chose.
    expect(projected).not.toContain('name =')
    // And the rest of the projection survives. One bad value is not a reason to
    // hand the agent no identity at all.
    expect(projected).toContain('email = "ada@example.invalid"')
  })

  test('a quote or a backslash survives instead of breaking the file', () => {
    // git's own escaping, inside quotes, and it round-trips — measured with
    // `git config --global --get` against a file written this way.
    const projected = projectGitConfig((key) =>
      key === 'user.name' ? 'A \\ B " C' : 'ada@example.invalid',
    )
    expect(projected).toContain('name = "A \\\\ B \\" C"')
  })

  test('a control character is refused, and an empty value is not a value', () => {
    expect(isProjectableValue('Ada Lovelace')).toBe(true)
    expect(isProjectableValue('')).toBe(false)
    expect(isProjectableValue('a\nb')).toBe(false)
    expect(isProjectableValue('a\rb')).toBe(false)
    expect(isProjectableValue('a\u0000b')).toBe(false)
    expect(isProjectableValue('a\u007fb')).toBe(false)
  })

  test('a key with a subsection cannot be expressed at all', () => {
    // The shape every executing credential and filter key has —
    // `credential.<url>.helper`, `filter.<name>.clean`. Dropped by the renderer
    // as well as by the allowlist, so a future caller that asked differently
    // still could not write one.
    const rendered = effective(
      renderProjectedGitConfig([{ key: 'credential.https://x.helper', value: '!sh' }]),
    )
    expect(rendered).not.toContain('helper')
  })

  test('an entry outside the allowlist is dropped by the renderer too', () => {
    const rendered = effective(
      renderProjectedGitConfig([{ key: 'core.hooksPath', value: '/tmp/evil' }]),
    )
    expect(rendered).not.toContain('hooksPath')
  })
})

describe('a machine with nothing to project', () => {
  test('the file is written anyway, and it is well defined', () => {
    /*
      The developer with no `~/.gitconfig` at all — which is the machine this
      whole failure was invisible on. There is nothing to carry across, and the
      file is still written: `GIT_CONFIG_GLOBAL` naming a real and empty file is
      a git that works with no identity, which is exactly what that developer
      already had.

      Absent would also work — git treats a missing global config as empty — and
      it is rejected because "not there" and "varnick could not write it" would
      then look the same to anyone reading the clone.
    */
    const projected = projectGitConfig(nothing)
    expect(effective(projected)).not.toContain('[user]')
    expect(projected).toContain('# Generated by varnick')
  })

  test('the header says what the file is, because someone will want their alias back', () => {
    const projected = projectGitConfig(identity)
    expect(projected).toContain('projection')
    expect(projected).toContain('rewritten on the next launch')
  })
})

describe('the file, on disk', () => {
  test('it is inside the clone, beside the other machine-local state', () => {
    expect(agentGitConfigPath(CLONE)).toBe(`${CLONE}/.varnick/gitconfig`)
    expect(PROJECTED_GITCONFIG_RELATIVE_PATH).toBe('.varnick/gitconfig')
  })

  test('the variable is git’s own name for it', () => {
    // Sufficient on its own, measured: there is no `/etc/gitconfig` on this
    // machine, the real system config is at `/opt/homebrew/etc/gitconfig` which
    // `allowRead` does not name, and git skips an unreadable *system* config
    // silently. Only the global one is fatal, so there is no GIT_CONFIG_SYSTEM.
    expect(GIT_CONFIG_GLOBAL_ENV_VAR).toBe('GIT_CONFIG_GLOBAL')
  })

  test('writing creates the directory the deny needs to already exist', () => {
    /*
      Not tidiness. srt denies `file-write-create` on every ancestor of a denied
      literal path, so once `.varnick/gitconfig` is in `denyWrite` the confined
      process cannot create `.varnick/` — and it is the confined process that
      makes `.varnick/claude` and `.varnick/tmp`. This write happens in the
      unconfined runtime, before the wrapper exists.
    */
    const clone = mkdtempSync(join(tmpdir(), 'varnick-gitconfig-'))
    try {
      const outcome = writeProjectedGitConfig(clone, { read: identity })
      expect(outcome.kind).toBe('written')
      expect(outcome.path).toBe(join(clone, PROJECTED_GITCONFIG_RELATIVE_PATH))
      expect(readFileSync(outcome.path, 'utf8')).toContain('name = "Ada Lovelace"')
      // Nothing to say when it worked. A launch that printed a line about its
      // git config every time would be a launch nobody reads the output of.
      expect(projectedGitConfigReport(outcome)).toBeNull()
    } finally {
      rmSync(clone, { recursive: true, force: true })
    }
  })

  test('a second launch picks up an identity that changed', () => {
    // Rewritten every launch, like the `node` shim, so a developer who changes
    // their name gets it on the next start. The agent cannot have edited it in
    // between — that is what the deny is for.
    const clone = mkdtempSync(join(tmpdir(), 'varnick-gitconfig-'))
    try {
      writeProjectedGitConfig(clone, { read: identity })
      const outcome = writeProjectedGitConfig(clone, {
        read: (key) => (key === 'user.name' ? 'Ada Byron' : identity(key)),
      })
      const contents = readFileSync(outcome.path, 'utf8')
      expect(contents).toContain('name = "Ada Byron"')
      expect(contents).not.toContain('Ada Lovelace')
    } finally {
      rmSync(clone, { recursive: true, force: true })
    }
  })

  test('a write that fails is survivable, and says which alternative it fell into', () => {
    /*
      The benign failure: `.varnick/` exists and the file could not be written.
      git still runs — a `GIT_CONFIG_GLOBAL` naming a file that is not there is
      an empty config, not a fatal one — and the only casualty is authorship.

      Which is exactly the outcome `GIT_CONFIG_GLOBAL=/dev/null` was rejected
      for, so it is said out loud. Both reviewers arrived at this function from
      opposite sides and the shared complaint was the silence: a design that
      rejects an alternative and then falls into it quietly is worse off than
      one that chose it, because at least choosing would have been a decision.
    */
    const outcome = writeProjectedGitConfig(CLONE, {
      read: identity,
      mkdir: () => {},
      write: () => {
        throw new Error('EACCES: permission denied')
      },
    })
    expect(outcome.kind).toBe('unwritten')
    expect(outcome.path).toBe(`${CLONE}/.varnick/gitconfig`)

    const said = projectedGitConfigReport(outcome) ?? ''
    expect(said).toContain('varnick:')
    expect(said).toContain('EACCES: permission denied')
    // The rejected alternative, named. Someone reading this line should be able
    // to tell what changed about their commits without reading gitconfig.ts.
    expect(said).toContain('GIT_CONFIG_GLOBAL=/dev/null')
    expect(said).toContain('auto-detects')
  })

  test('a directory that cannot be created is a different and much worse failure', () => {
    /*
      And this is the distinction the first version of this function did not
      make. Its comment justified swallowing *both* failures with "a git that
      works with no identity" — true above, false here.

      If `.varnick/` does not exist, the confined Claude Code cannot create
      `.varnick/claude` either, because the deny on the file makes
      `file-write-create` on its ancestors a denial too. So the agent does not
      start, and the sentence varnick prints must be about that rather than
      about git. A comment promising degradation where the real outcome is a
      launch that never happens is the failure this test exists to prevent.
    */
    const outcome = writeProjectedGitConfig(CLONE, {
      read: identity,
      mkdir: () => {
        throw new Error('EROFS: read-only file system')
      },
    })
    expect(outcome.kind).toBe('uncreatable')

    const said = projectedGitConfigReport(outcome) ?? ''
    expect(said).toContain('EROFS: read-only file system')
    // It names the directory rather than the file, and says the agent is the
    // casualty rather than the authorship.
    expect(said).toContain(`${CLONE}/.varnick`)
    expect(said).toContain('session store')
    expect(said).not.toContain('GIT_CONFIG_GLOBAL=/dev/null')
  })
})

describe('reading the developer’s real config', () => {
  test('an unset key is null rather than an empty string', () => {
    // Asked of git itself, on this machine, for a key nobody sets. Null covers
    // "not set", "no config" and "git would not run" because all three have one
    // consequence: nothing to project.
    expect(readGlobalGitConfigValue('varnick.thisKeyIsNotSet')).toBeNull()
  })

  test('it asks git rather than parsing a path, because --global is two files', () => {
    /*
      `~/.gitconfig` *and* `$XDG_CONFIG_HOME/git/config`, and a good many people
      keep their identity in the second. Measured: with `$HOME` empty and only
      the XDG file present, `git config --global --get user.name` answers from
      it. A hand parser of one hardcoded path would produce a silently empty
      projection for those developers.

      Asserted by behaviour rather than by reading the source: what this returns
      is what git reports for the same key, on whatever machine is running it.
    */
    const mine = readGlobalGitConfigValue('user.email')
    const git = Bun.spawnSync({ cmd: ['git', 'config', '--global', '--get', 'user.email'] })
    const expected = git.exitCode === 0 ? git.stdout.toString().trim() : ''
    expect(mine ?? '').toBe(expected)
  })
})
