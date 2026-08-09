import { describe, expect, test } from 'bun:test'
import { FENCE_PATHS, isFencePath, touchesFence } from './fence.ts'
import { readAllowlistFor, sandboxPolicyFor, SANDBOX_BASELINE_FILENAME } from './sandbox.ts'

/*
  The seam: one pure function over one path, and nothing else.

  Three things key off this answer — the pending-worktree list (ticket 49), the
  Preview dialog (ticket 48), and the diff view's highlighting (ticket 50). The
  reason it is asserted here rather than through any of them is that all three
  would pass with three different lists, and the failure that matters is the one
  where they disagree: a widening that raises no dialog because the third list
  spelled `src-tauri` without its glob.
*/

const CLONE = '/Users/dev/code/varnick'
const HOME = '/Users/dev'

describe('what the Fence is', () => {
  test('the generator, the host and the baseline are Fence', () => {
    expect(isFencePath('packages/harness/src/sandbox.ts')).toBe(true)
    expect(isFencePath('src-tauri/src/credential.rs')).toBe(true)
    expect(isFencePath('sandbox-policy.baseline.json')).toBe(true)
  })

  test('a file directly in a Fence directory is Fence, not only a nested one', () => {
    expect(isFencePath('packages/harness/package.json')).toBe(true)
    expect(isFencePath('src-tauri/Cargo.toml')).toBe(true)
  })

  test('Core that is not Fence is not Fence', () => {
    /*
      The distinction CONTEXT.md draws and the one this function exists to keep.
      `packages/core/**`, `vite.config.*` and `package.json` are denied so a
      broken edit cannot take the conversation down — not because they decide
      the boundary. A Preview of a change to them launches without asking, and a
      dialog that appears on every Core preview is a dialog nobody reads by the
      second week.
    */
    expect(isFencePath('packages/core/src/machines/harness.ts')).toBe(false)
    expect(isFencePath('vite.config.ts')).toBe(false)
    expect(isFencePath('package.json')).toBe(false)
    expect(isFencePath('packages/userspace/surfaces/welcome/index.tsx')).toBe(false)
  })

  test('the generated policy is not Fence; the thing that generates it is', () => {
    /*
      `sandbox-policy.json` is denied in the live tree and is deliberately not on
      this list. It is an output: the launch that reads it compares it against
      the baseline, which *is* Fence, and regenerates from `packages/harness/**`,
      which is Fence too. A worktree that changes only the generated file changes
      nothing the next launch will believe.
    */
    expect(isFencePath('sandbox-policy.json')).toBe(false)
  })

  test('a path that merely starts with a Fence name is not Fence', () => {
    // The failure a `startsWith` gets wrong, and the reason the directory form
    // matches on a separator rather than on a prefix.
    expect(isFencePath('src-tauri-notes/plan.md')).toBe(false)
    expect(isFencePath('packages/harnessed/index.ts')).toBe(false)
    expect(isFencePath('sandbox-policy.baseline.json.bak')).toBe(false)
  })

  test('a Fence file is Fence where it lives and nowhere else', () => {
    // Paths are repository-relative, so the baseline is the one at the root.
    // A copy under `docs/` is a document about the fence, not the fence.
    expect(isFencePath('docs/sandbox-policy.baseline.json')).toBe(false)
  })

  test('a leading ./ is the same path', () => {
    expect(isFencePath('./src-tauri/src/lib.rs')).toBe(true)
    expect(isFencePath('./sandbox-policy.baseline.json')).toBe(true)
  })

  test('case is not a way out', () => {
    /*
      macOS filesystems are case-insensitive by default, so `Src-Tauri/lib.rs`
      and `src-tauri/lib.rs` are one file on the disk the agent is writing to.
      Comparing case-sensitively would classify one of the two as ordinary Core.

      The error this direction produces is a dialog nobody needed; the other
      direction is a widening that launched unconfined without one.
    */
    expect(isFencePath('SRC-TAURI/src/lib.rs')).toBe(true)
    expect(isFencePath('Packages/Harness/src/sandbox.ts')).toBe(true)
  })

  test('a directory named as itself is Fence, without a file under it', () => {
    // git reports files, so this is defensive rather than observed — and the
    // safe answer for a path that *is* the fence is that it is the fence.
    expect(isFencePath('src-tauri')).toBe(true)
    expect(isFencePath('packages/harness')).toBe(true)
  })

  test('nothing is not Fence', () => {
    expect(isFencePath('')).toBe(false)
  })
})

describe('a set of changed paths', () => {
  test('one Fence path among many makes the set Fence', () => {
    expect(
      touchesFence([
        'packages/userspace/surfaces/welcome/index.tsx',
        'packages/core/src/App.tsx',
        'src-tauri/src/bridge.rs',
      ]),
    ).toBe(true)
  })

  test('a set with no Fence path in it does not touch the Fence', () => {
    expect(touchesFence(['packages/core/src/App.tsx', 'README.md'])).toBe(false)
  })

  test('an empty set does not touch the Fence', () => {
    // A worktree that changed nothing is not a widening, and the caller must
    // not have to special-case it into one.
    expect(touchesFence([])).toBe(false)
  })
})

describe('the list is the same list the Sandbox denies', () => {
  test('every Fence path is a path the generated policy refuses to let the agent write', () => {
    /*
      The assertion that makes "one definition, three callers" mean something.

      This function and `denyWrite` are two readings of the same sentence in
      ADR-0014, and they are written in two files: a Fence entry that stopped
      being denied would leave this answering "Fence" about a path the agent can
      already write, and a denial that lost its entry here would leave a widening
      launching a Preview without a dialog. Either way the mechanism is quietly
      advisory, which is the failure the ticket names.
    */
    const { denyWrite } = sandboxPolicyFor({
      cloneRoot: CLONE,
      homeDir: HOME,
      readAllowlist: readAllowlistFor({
        cloneRoot: CLONE,
        execPath: `${HOME}/.bun/bin/bun`,
        sdkEntry: `${CLONE}/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs`,
        developerToolsBin: '/Applications/Xcode.app/Contents/Developer/usr/bin',
      }),
    }).filesystem

    for (const entry of FENCE_PATHS) {
      expect(denyWrite).toContain(`${CLONE}/${entry}`)
    }
  })

  test('the baseline the Fence names is the baseline the Sandbox writes', () => {
    // Two literals for one file, in two modules, is how the pair above comes
    // apart without either test failing.
    expect(FENCE_PATHS).toContain(SANDBOX_BASELINE_FILENAME)
  })
})
