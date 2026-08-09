/**
 * The Harness's half of a Preview: which changed paths are Fence, and the round
 * trip that carries a request out of the Sandbox and an answer back in.
 *
 * The spawn and the dialog are not here and cannot be — they are the host's, in
 * `src-tauri/src/preview.rs`, and no test in this repository opens a dialog or
 * starts a second varnick. What is here is what can be decided from text.
 */

import { describe, expect, test } from 'bun:test'
import {
  FENCE_BASELINE_FILE,
  LAUNCH_PREVIEW_DESCRIPTION,
  PREVIEW_OUTCOMES,
  encodePreviewRequest,
  fenceHunks,
  isFencePath,
  isPreviewOutcome,
  previewOutcomeMessage,
  previewToolResult,
} from './preview.ts'
import { SANDBOX_BASELINE_FILENAME } from './sandbox.ts'
import { parseControlRequest } from './turn.ts'

// ---------------------------------------------------------------------------
// The Fence classification of a changed path
// ---------------------------------------------------------------------------

describe('what a change to a path means', () => {
  test('the three things that decide what the agent may do are Fence', () => {
    // CONTEXT.md's list, and the reason each is on it: the generator, the host,
    // and the record a widening would otherwise be hidden in.
    expect(isFencePath('packages/harness/src/sandbox.ts')).toBe(true)
    expect(isFencePath('packages/harness/package.json')).toBe(true)
    expect(isFencePath('src-tauri/src/credential.rs')).toBe(true)
    expect(isFencePath('src-tauri/Cargo.toml')).toBe(true)
    expect(isFencePath('sandbox-policy.baseline.json')).toBe(true)
  })

  test('Core is denied for a different reason and is not Fence', () => {
    /*
      The distinction the dialog rests on. These are `denyWrite` because a broken
      edit must not take the conversation down with it, not because they decide
      the boundary — so a Preview of them launches silently. A dialog on every
      Core preview is a dialog nobody reads by the second week.
    */
    expect(isFencePath('packages/core/src/App.tsx')).toBe(false)
    expect(isFencePath('packages/core/vite.config.ts')).toBe(false)
    expect(isFencePath('vite.config.ts')).toBe(false)
    expect(isFencePath('package.json')).toBe(false)
    expect(isFencePath('packages/userspace/surfaces/notes.tsx')).toBe(false)
    expect(isFencePath('CONTEXT.md')).toBe(false)
    expect(isFencePath('docs/adr/0014-core-is-authored-in-a-worktree.md')).toBe(false)
  })

  test('a path that only starts like a Fence path is not one', () => {
    // A prefix test without the separator would call every one of these Fence,
    // and the failure of that mistake is silent in the safe direction until
    // somebody names a directory `src-tauri-notes`.
    expect(isFencePath('packages/harnessed/x.ts')).toBe(false)
    expect(isFencePath('packages/harness-notes/x.ts')).toBe(false)
    expect(isFencePath('src-tauri-notes/x.rs')).toBe(false)
    expect(isFencePath('sandbox-policy.baseline.json.bak')).toBe(false)
    expect(isFencePath('docs/sandbox-policy.baseline.json')).toBe(false)
    expect(isFencePath('userspace/packages/harness/x.ts')).toBe(false)
  })

  test('the policy in force is not on this list and the baseline is', () => {
    /*
      `sandbox-policy.json` is denied and is not Fence. It is deliberately
      editable — the file says so itself — and it is per machine, so a diff of it
      is a developer's own boundary rather than the code that draws one. The
      *baseline* beside it is Fence, because it is what tells an edit from an
      upgrade, and an agent that can write it can have its own widening believed.
    */
    expect(isFencePath('sandbox-policy.json')).toBe(false)
    expect(FENCE_BASELINE_FILE).toBe(SANDBOX_BASELINE_FILENAME)
  })
})

// ---------------------------------------------------------------------------
// The hunks
// ---------------------------------------------------------------------------

const CORE_SECTION = [
  'diff --git a/packages/core/src/App.tsx b/packages/core/src/App.tsx',
  'index 1111111..2222222 100644',
  '--- a/packages/core/src/App.tsx',
  '+++ b/packages/core/src/App.tsx',
  '@@ -1,3 +1,3 @@',
  '-const title = "varnick"',
  '+const title = "varnick!"',
  '',
].join('\n')

const FENCE_SECTION = [
  'diff --git a/packages/harness/src/sandbox.ts b/packages/harness/src/sandbox.ts',
  'index 3333333..4444444 100644',
  '--- a/packages/harness/src/sandbox.ts',
  '+++ b/packages/harness/src/sandbox.ts',
  '@@ -500,7 +500,6 @@',
  '-        join(clone, \'packages/harness/**\'),',
  '',
].join('\n')

describe('the Fence part of a diff', () => {
  test('a worktree touching only Core has no Fence hunks', () => {
    expect(fenceHunks({ patch: CORE_SECTION })).toBe('')
  })

  test('a worktree touching the generator has the generator’s hunks and nothing else', () => {
    const hunks = fenceHunks({ patch: `${CORE_SECTION}${FENCE_SECTION}` })
    expect(hunks).toContain('packages/harness/src/sandbox.ts')
    expect(hunks).toContain("-        join(clone, 'packages/harness/**'),")
    expect(hunks).not.toContain('packages/core/src/App.tsx')
  })

  test('what comes out is what git wrote, rather than a count of it', () => {
    /*
      The whole reason the dialog exists rather than an approval prompt: the
      developer approves bytes. A summary here would be varnick paraphrasing a
      change the agent made, which is the sentence prompt injection produces.
    */
    const hunks = fenceHunks({ patch: FENCE_SECTION })
    for (const line of FENCE_SECTION.trimEnd().split('\n')) {
      expect(hunks).toContain(line)
    }
  })

  test('a line inside a hunk that looks like a header does not start a section', () => {
    // A diff of a file *containing* a diff — a fixture, a test, this file — is
    // ordinary, and a scanner that split on the string anywhere would attribute
    // the rest of a Core change to whatever path that line named.
    const sneaky = [
      'diff --git a/packages/core/src/fixture.ts b/packages/core/src/fixture.ts',
      '@@ -1,2 +1,2 @@',
      "+const sample = 'diff --git a/src-tauri/src/credential.rs b/src-tauri/src/credential.rs'",
      '',
    ].join('\n')
    expect(fenceHunks({ patch: sneaky })).toBe('')
  })

  test('a rename out of the Fence is a change to the Fence', () => {
    const renamed = [
      'diff --git a/src-tauri/src/credential.rs b/notes/credential.rs',
      'similarity index 100%',
      'rename from src-tauri/src/credential.rs',
      'rename to notes/credential.rs',
      '',
    ].join('\n')
    expect(fenceHunks({ patch: renamed })).toContain('rename from src-tauri/src/credential.rs')
  })

  test('a new Fence file git does not track yet is still shown', () => {
    /*
      The hole this closes, and it is exactly the shape of the thing the dialog
      exists to catch: `git diff` says nothing about a file that was never added,
      so a fresh `packages/harness/src/widen.ts` would produce an empty diff and
      launch with no dialog at all.
    */
    const hunks = fenceHunks({
      patch: CORE_SECTION,
      untracked: ['packages/harness/src/widen.ts', 'packages/userspace/notes.ts'],
      readUntracked: (path) =>
        path === 'packages/harness/src/widen.ts' ? "export const denyWrite = []\n" : 'unrelated',
    })
    expect(hunks).toContain('packages/harness/src/widen.ts')
    expect(hunks).toContain('+export const denyWrite = []')
    expect(hunks).not.toContain('packages/userspace/notes.ts')
  })

  test('an untracked Fence file nobody could read is named rather than dropped', () => {
    const hunks = fenceHunks({
      patch: '',
      untracked: ['src-tauri/src/widen.rs'],
      readUntracked: () => null,
    })
    expect(hunks).toContain('src-tauri/src/widen.rs')
    expect(hunks).toContain('could not read it')
  })

  test('an empty diff is an empty answer, which is what launches without asking', () => {
    expect(fenceHunks({ patch: '' })).toBe('')
    expect(fenceHunks({ patch: '\n\n' })).toBe('')
  })
})

// ---------------------------------------------------------------------------
// The control-request round trip
// ---------------------------------------------------------------------------

describe('what the agent asks and what it is told', () => {
  test('a request is a kind, a request id and a name — and there is no field for anything else', () => {
    const line = encodePreviewRequest('p1', 'agent-one')
    expect(line.endsWith('\n')).toBe(true)
    expect(line.split('\n').filter((one) => one.length > 0)).toHaveLength(1)
    expect(JSON.parse(line) as unknown).toEqual({
      kind: 'launch-preview',
      requestId: 'p1',
      worktree: 'agent-one',
    })
  })

  test('an answer is rebuilt to three fields, so nothing rides in beside them', () => {
    // The same rule `describe-secrets` follows on the way in. A request the
    // agent host reads loosely is a request shape something can put a field on,
    // and this one is read inside the Sandbox holding a live session.
    expect(
      parseControlRequest(
        '{"kind":"preview-answer","requestId":"p1","outcome":"launched","command":"sh","port":1421}',
      ),
    ).toEqual({ kind: 'preview-answer', requestId: 'p1', outcome: 'launched' })
  })

  test('an outcome this build does not know is not an answer', () => {
    for (const line of [
      '{"kind":"preview-answer","requestId":"p1","outcome":"probably"}',
      '{"kind":"preview-answer","requestId":"p1"}',
      '{"kind":"preview-answer","outcome":"launched"}',
      '{"kind":"preview-answer","requestId":"","outcome":"launched"}',
      '{"kind":"preview-answer","requestId":"p1","outcome":null}',
    ]) {
      expect(parseControlRequest(line)).toBeNull()
    }
  })

  test('every outcome the host can write has a sentence, and none of them is the host’s', () => {
    /*
      The rule `turnFailureMessage` follows, and it matters more here: the host
      is the process holding the Credential and the one that spawns things, so
      an error message it composed is the string most likely to have an
      environment or a path in it. Nothing crosses but a tag.
    */
    for (const outcome of PREVIEW_OUTCOMES) {
      expect(isPreviewOutcome(outcome)).toBe(true)
      expect(previewOutcomeMessage(outcome).length).toBeGreaterThan(20)
    }
    expect(isPreviewOutcome('launched?')).toBe(false)
  })

  test('declining is a fact the agent can act on rather than prose to interpret', () => {
    expect(previewToolResult('declined').launched).toBe(false)
    expect(previewToolResult('declined').text).toContain('declined')
    expect(previewToolResult('launched').launched).toBe(true)
    expect(previewToolResult('unknown-worktree').launched).toBe(false)
  })

  test('the tool tells the agent it takes a name, so a path is a call never made', () => {
    expect(LAUNCH_PREVIEW_DESCRIPTION).toContain('name')
    expect(LAUNCH_PREVIEW_DESCRIPTION).toContain('not a path')
    expect(LAUNCH_PREVIEW_DESCRIPTION).toContain('not a command')
  })
})
