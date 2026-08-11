/**
 * The Harness's half of a Preview: the round trip that carries a request out of
 * the Sandbox and an answer back in.
 *
 * The spawn is not here and cannot be — it is the host's, in
 * `src-tauri/src/preview.rs`, and no test in this repository starts a second
 * varnick. What is here is what can be decided from text.
 *
 * **Two things used to be here and are not.** The Fence classification of a
 * changed path moved to ./fence.test.ts, which is where the one definition
 * lives; and `fenceHunks` — the diff the approval dialog showed — went with the
 * dialog when a Preview stopped being an escalation (ADR-0019). The claim that
 * replaced them is not an assertion at all: `containment.probe.test.ts` runs a
 * command under the policy a Preview's agent gets and reports what it reached.
 */

import { describe, expect, test } from 'bun:test'
import {
  LAUNCH_PREVIEW_DESCRIPTION,
  PREVIEW_OUTCOMES,
  encodePreviewRequest,
  isPreviewOutcome,
  previewOutcomeMessage,
  previewToolResult,
} from './preview.ts'
import { parseControlRequest } from './turn.ts'

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

  test('there is no outcome for a developer saying no, because nobody is asked', () => {
    /*
      The dialog is deleted rather than made skippable, and this is what that
      means on the wire: `declined` is not an outcome this build knows, so a
      host that somehow wrote one is not answering — it falls through
      `isPreviewOutcome` and the tool call fails rather than being read as some
      neighbouring refusal. A dialog that fires on nothing is worse than no
      dialog, and an outcome nothing produces is the same mistake in the
      protocol.
    */
    expect(PREVIEW_OUTCOMES).not.toContain('declined')
    expect(isPreviewOutcome('declined')).toBe(false)
    expect(parseControlRequest('{"kind":"preview-answer","requestId":"p1","outcome":"declined"}')).toBeNull()
  })

  test('whether there is a window is a flag rather than prose to interpret', () => {
    // One outcome opens a window and three do not. An agent that read the
    // sentence and guessed would eventually describe a preview nobody has.
    expect(previewToolResult('launched').launched).toBe(true)
    expect(previewToolResult('unknown-worktree').launched).toBe(false)
    expect(previewToolResult('no-worktrees').launched).toBe(false)
    expect(previewToolResult('no-launch').launched).toBe(false)
  })

  test('the tool tells the agent it takes a name, so a path is a call never made', () => {
    expect(LAUNCH_PREVIEW_DESCRIPTION).toContain('name')
    expect(LAUNCH_PREVIEW_DESCRIPTION).toContain('not a path')
    expect(LAUNCH_PREVIEW_DESCRIPTION).toContain('not a command')
  })

  test('the tool says nothing is asked of the developer, and what confines the preview', () => {
    /*
      Both halves of ADR-0019, in the one place the agent reads. The first stops
      an agent hedging about a dialog that no longer exists; the second stops it
      spending a Turn on why the `sandbox.ts` it just edited had no effect in
      the window it is looking at. Neither is an instruction — they are true
      sentences about the mechanism, which is the only kind a tool description
      can be trusted to carry.
    */
    expect(LAUNCH_PREVIEW_DESCRIPTION).toContain('Nothing is asked of the developer')
    expect(LAUNCH_PREVIEW_DESCRIPTION).toContain('in force in the live clone')
    expect(LAUNCH_PREVIEW_DESCRIPTION).not.toContain('dialog')
  })
})
