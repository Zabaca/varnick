import { describe, expect, test } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'

import { AGENT_ENTRY_RELATIVE_PATH } from './agent.ts'
import {
  CLONE_ROOT_ENV_VAR,
  cloneRootFromLaunch,
  requireCloneRoot,
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
