import { describe, expect, test } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'

import { AGENT_ENTRY_RELATIVE_PATH } from './agent.ts'
import {
  CLONE_ROOT_ENV_VAR,
  POLICY_ROOT_ENV_VAR,
  cloneRootFromLaunch,
  requireCloneRoot,
  requirePolicyRoot,
} from './clone-root.ts'

/*
  The root the agent works in, checked before anything is established for it.

  Every assertion here is about a *message*: the defect this module was written
  for was not that the root could be wrong, it was that a wrong one said
  nothing. So the tests read what a developer would read.
*/

const nowhere = { isDirectory: () => false, isFile: () => false }
const anywhere = { isDirectory: () => true, isFile: () => true }

describe('the root the Sandbox is established for', () => {
  test('a root that does not exist is refused, naming the path', () => {
    expect(() => requireCloneRoot('/Users/dev/moved-away', nowhere)).toThrow(
      /no directory at \/Users\/dev\/moved-away/,
    )
  })

  test('the refusal names the variable that would fix it', () => {
    expect(() => requireCloneRoot('/gone', nowhere)).toThrow(new RegExp(CLONE_ROOT_ENV_VAR))
  })

  test('a relative root is refused rather than resolved against a working directory', () => {
    // The whole point. A root that means one thing from the checkout and
    // another from `/` is the unnamed root this module removes.
    expect(() => requireCloneRoot('../varnick', anywhere)).toThrow(/not an absolute path/)
  })

  test('an empty root is refused before anything tries to use it', () => {
    expect(() => requireCloneRoot('', anywhere)).toThrow(/empty clone root/)
  })

  test('a directory that is there is handed back unchanged', () => {
    expect(requireCloneRoot('/Users/dev/code/varnick', anywhere)).toBe('/Users/dev/code/varnick')
  })
})

describe('the root as the launch seam resolves it', () => {
  test('no argument at all says so, rather than falling back to the working directory', () => {
    // Falling back to `process.cwd()` is exactly the defect ticket 28 names:
    // the root arriving by accident and nothing saying where from.
    expect(() => cloneRootFromLaunch(undefined, anywhere)).toThrow(/without a clone root/)
  })

  test('a directory that is not a varnick clone is refused, and says what is missing', () => {
    expect(() =>
      cloneRootFromLaunch('/Users/dev/Documents', { isDirectory: () => true, isFile: () => false }),
    ).toThrow(new RegExp(AGENT_ENTRY_RELATIVE_PATH.replaceAll('/', '\\/')))
  })

  test('a real clone is accepted', () => {
    const root = mkdtempSync(join(tmpdir(), 'varnick-clone-root-'))
    try {
      const entry = join(root, AGENT_ENTRY_RELATIVE_PATH)
      mkdirSync(dirname(entry), { recursive: true })
      writeFileSync(entry, '', 'utf8')
      expect(cloneRootFromLaunch(root)).toBe(root)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('a path that is a file rather than a directory is refused as a directory', () => {
    const root = mkdtempSync(join(tmpdir(), 'varnick-clone-root-'))
    try {
      const file = join(root, 'notes.md')
      writeFileSync(file, '', 'utf8')
      expect(() => cloneRootFromLaunch(file)).toThrow(/no directory at/)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

/*
  And the second root, which only a **Preview** has.

  It answers "whose policy confines this agent", and the three refusals below are
  the ones that would each hand the fence back in their own way — see
  docs/adr/0019-a-preview-is-confined-by-the-live-trees-policy.md.
*/
describe('the root whose policy confines the agent', () => {
  const live = '/Users/dev/code/varnick'
  const worktree = '/Users/dev/code/varnick/.claude/worktrees/agent-one'

  test('no policy root at all means this clone’s own, which is every ordinary launch', () => {
    // The default has to be silent and has to be *this* clone: a varnick a
    // developer started is confined by the policy in its own tree, exactly as
    // it was before Previews were confined.
    expect(requirePolicyRoot(undefined, live, anywhere)).toBe(live)
    // Empty, because the Rust host passes an empty argument rather than leaving
    // a hole in a positional list. Same answer, and it has to be: a launch that
    // read that as a path would refuse every non-preview varnick.
    expect(requirePolicyRoot('', live, anywhere)).toBe(live)
  })

  test('the live tree confines a worktree inside it', () => {
    expect(requirePolicyRoot(live, worktree, anywhere)).toBe(live)
    // A trailing separator is the same directory, not a different one.
    expect(requirePolicyRoot(`${live}/`, worktree, anywhere)).toBe(live + '/')
  })

  test('a policy root that does not hold the clone root is refused', () => {
    /*
      The load-bearing check, and it is not a copy of the clone root's.

      The policy names the tree it was generated for in `allowRead` and
      `allowWrite`. A clone root outside that tree gets an agent that cannot
      read its own working directory — an interpreter that dies naming nothing,
      which is the failure ticket 28 spent a day on. Refusing here is what makes
      "the live tree's policy is a usable fence for a Preview" a checked claim
      rather than a hope about where worktrees live.
    */
    expect(() => requirePolicyRoot('/Users/dev/code/other', worktree, anywhere)).toThrow(
      /does not contain/,
    )
    // The near miss, which a string prefix test would accept: a sibling clone
    // whose path starts with the same characters.
    expect(() => requirePolicyRoot(live, '/Users/dev/code/varnick-notes', anywhere)).toThrow(
      /does not contain/,
    )
  })

  test('a relative or missing policy root is refused, naming the variable', () => {
    expect(() => requirePolicyRoot('../varnick', worktree, anywhere)).toThrow(
      /not an absolute path/,
    )
    expect(() => requirePolicyRoot(live, worktree, nowhere)).toThrow(
      new RegExp(POLICY_ROOT_ENV_VAR),
    )
  })

  test('there is no falling back to the tree being previewed', () => {
    // Every refusal above throws, and that is the whole of it: a policy root
    // that could quietly become the clone root would confine a Preview by the
    // policy the agent just wrote, which is the escalation ADR-0019 closes.
    for (const bad of ['../varnick', '/Users/dev/code/other']) {
      expect(() => requirePolicyRoot(bad, worktree, anywhere)).toThrow()
    }
  })
})
