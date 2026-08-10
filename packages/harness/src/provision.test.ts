import { describe, expect, test } from 'bun:test'
import {
  BUN_CACHE_ENV_VAR,
  bunCacheDir,
  isWorktreeOf,
  provisionCommandFor,
  provisionFailureMessage,
} from './provision.ts'
import { agentEnvironment } from './agent.ts'

const CLONE = '/Users/you/varnick'
const WORKTREE = `${CLONE}/.claude/worktrees/plugin-hooks`

/*
  A Worktree is a fresh checkout and `node_modules` is gitignored, so every one
  starts with nothing installed. ADR-0014 makes a Worktree the required path for
  every Core change, so this runs on all of them.

  Measured before it was fixed: one subagent spent seventeen `ln -s` calls
  across three node_modules directories before touching its ticket, and linking
  is the wrong answer anyway — it puts the dependencies outside the Worktree's
  own Sandbox boundary, where a Preview cannot read them.
*/

describe('which directories get provisioned', () => {
  const nothingExists = () => false

  test('a Worktree with no node_modules is installed into', () => {
    expect(provisionCommandFor(CLONE, WORKTREE, nothingExists)).toEqual({
      command: 'bun',
      args: ['install', '--frozen-lockfile'],
      cwd: WORKTREE,
    })
  })

  test('the lockfile may not change — a checkout installs what was committed', () => {
    // A plain install would let entering a directory rewrite what the project
    // depends on.
    const plan = provisionCommandFor(CLONE, WORKTREE, nothingExists)
    expect(plan?.args).toContain('--frozen-lockfile')
  })

  test('a Worktree that already has them is left alone', () => {
    // Re-entering is ordinary. An install every time is a pause charged for
    // nothing.
    const exists = (path: string) => path === `${WORKTREE}/node_modules`
    expect(provisionCommandFor(CLONE, WORKTREE, exists)).toBeNull()
  })

  test('the live tree is never installed into', () => {
    // The developer's own node_modules. Nothing here may touch it.
    expect(provisionCommandFor(CLONE, CLONE, nothingExists)).toBeNull()
  })

  test('somewhere else entirely is never installed into', () => {
    expect(provisionCommandFor(CLONE, '/tmp/anywhere', nothingExists)).toBeNull()
  })
})

describe('what counts as this clone’s Worktree', () => {
  test('a directory under the worktree base', () => {
    expect(isWorktreeOf(CLONE, WORKTREE)).toBe(true)
  })

  test('the base itself is not one', () => {
    expect(isWorktreeOf(CLONE, `${CLONE}/.claude/worktrees`)).toBe(false)
  })

  test('a sibling directory sharing the prefix is not one', () => {
    // The trailing separator is what makes the prefix test honest.
    expect(isWorktreeOf(CLONE, `${CLONE}/.claude/worktrees-old/x`)).toBe(false)
  })

  test('another clone’s worktree is not this clone’s', () => {
    expect(isWorktreeOf(CLONE, '/Users/you/other/.claude/worktrees/x')).toBe(false)
  })
})

describe('the cache moves into the clone', () => {
  /*
    bun's default is `~/.bun/install/cache` and the Sandbox denies `$HOME`, so
    an install run by the agent fails on a path rather than on the install. Same
    problem and same answer as CLAUDE_CONFIG_DIR.
  */

  test('it is inside the clone, beside the other machine-local state', () => {
    expect(bunCacheDir(CLONE)).toBe(`${CLONE}/.varnick/bun-cache`)
  })

  test('the agent is handed it', () => {
    const env = agentEnvironment({}, { cloneRoot: CLONE, inherit: false })
    expect(env[BUN_CACHE_ENV_VAR]).toBe(`${CLONE}/.varnick/bun-cache`)
  })

  test('inheriting the developer’s environment does not restore an unreachable one', () => {
    // Their cache is under $HOME either way, so honouring their value would
    // hand the agent a path it cannot read and call that inheritance.
    const env = agentEnvironment(
      { [BUN_CACHE_ENV_VAR]: '/Users/you/.bun/install/cache' },
      { cloneRoot: CLONE, inherit: true },
    )
    expect(env[BUN_CACHE_ENV_VAR]).toBe(`${CLONE}/.varnick/bun-cache`)
  })
})

describe('a failed install is reported, never fatal', () => {
  /*
    A Worktree without dependencies is where varnick has been all along, so
    refusing to enter one would be the worse regression. Silence is the part
    that is not acceptable — it is what made ticket 58 invisible for months.
  */

  test('it quotes what bun said', () => {
    const message = provisionFailureMessage(WORKTREE, 'error: lockfile had changes\n')
    expect(message).toContain('error: lockfile had changes')
    expect(message).toContain(WORKTREE)
  })

  test('it says what will break, so a resolution error is not read as a broken change', () => {
    expect(provisionFailureMessage(WORKTREE, 'boom')).toContain('resolve modules')
  })

  test('it steers away from the fix that breaks the Sandbox boundary', () => {
    // Linking from the live tree is the obvious workaround and is wrong: the
    // dependencies end up outside this Worktree's boundary, where a Preview
    // cannot read them.
    expect(provisionFailureMessage(WORKTREE, 'boom')).toContain('Sandbox boundary')
  })

  test('a long failure is bounded', () => {
    const message = provisionFailureMessage(WORKTREE, 'x'.repeat(5_000))
    expect(message.length).toBeLessThan(800)
    expect(message).toContain('…')
  })

  test('no output at all still produces a usable sentence', () => {
    expect(provisionFailureMessage(WORKTREE, '   ')).toContain(
      `Dependencies were not installed in ${WORKTREE}.`,
    )
  })
})
