/**
 * The Harness's half of the agent's two asks: the round trip that carries a
 * request out of the Sandbox and an answer back in.
 *
 * Neither the merge nor the release is here and neither can be. The merge is
 * proved in ./landing.test.ts against ports, with no repository; the release is
 * a spawn the runtime makes; and the routing between them is
 * src-tauri/src/unattended.rs, which has its own tests for the parse, the
 * answer line and the rule that this host composes no prose. What is here is
 * what can be decided from text.
 */

import { describe, expect, test } from 'bun:test'
import {
  CUT_PRE_RELEASE_DESCRIPTION,
  LANDING_OUTCOMES,
  LAND_WORKTREE_DESCRIPTION,
  RELEASE_OUTCOMES,
  encodeLandingRequest,
  encodeReleaseRequest,
  isFeatureSlug,
  isOutcome,
  landingOutcomeMessage,
  landingToolResult,
  releaseOutcomeMessage,
  releaseToolResult,
} from './unattended.ts'
import { MAX_ANSWER_DETAIL, parseControlRequest } from './turn.ts'

// ---------------------------------------------------------------------------
// The control-request round trip
// ---------------------------------------------------------------------------

describe('what the agent asks and what it is told', () => {
  test('a landing request is a kind, a request id and a name, and has no field for a path list', () => {
    /*
      The failure this shape exists to prevent. A request that could carry what
      the branch changed would be the agent answering the protected-path
      question about itself — so there is one name, and the host reads the paths
      out of git.
    */
    const line = encodeLandingRequest('l1', 'agent-one')
    expect(line.endsWith('\n')).toBe(true)
    expect(line.split('\n').filter((one) => one.length > 0)).toHaveLength(1)
    expect(JSON.parse(line) as unknown).toEqual({
      kind: 'land-worktree',
      requestId: 'l1',
      worktree: 'agent-one',
    })
  })

  test('a release request is a kind, a request id and a slug, and cannot name a version', () => {
    expect(JSON.parse(encodeReleaseRequest('r1', 'autonomous-runs')) as unknown).toEqual({
      kind: 'cut-release',
      requestId: 'r1',
      feature: 'autonomous-runs',
    })
  })

  test('an answer is rebuilt to its fields, so nothing rides in beside them', () => {
    // The same rule `describe-secrets` and `preview-answer` follow on the way
    // in. This one is read inside the Sandbox holding a live session, and it is
    // the only answer here that carries prose — so what may ride with the prose
    // matters more, not less.
    expect(
      parseControlRequest(
        '{"kind":"landing-answer","requestId":"l1","outcome":"landed","detail":"it landed as a1b2c3d.","command":"sh","path":"/etc"}',
      ),
    ).toEqual({
      kind: 'landing-answer',
      requestId: 'l1',
      outcome: 'landed',
      detail: 'it landed as a1b2c3d.',
    })
    expect(
      parseControlRequest('{"kind":"release-answer","requestId":"r1","outcome":"cut"}'),
    ).toEqual({ kind: 'release-answer', requestId: 'r1', outcome: 'cut' })
  })

  test('an outcome this build does not know is not an answer', () => {
    for (const line of [
      '{"kind":"landing-answer","requestId":"l1","outcome":"probably"}',
      '{"kind":"landing-answer","requestId":"l1","outcome":"cut"}',
      '{"kind":"landing-answer","requestId":"l1"}',
      '{"kind":"landing-answer","outcome":"landed"}',
      '{"kind":"landing-answer","requestId":"","outcome":"landed"}',
      '{"kind":"release-answer","requestId":"r1","outcome":"landed"}',
      '{"kind":"release-answer","requestId":"r1","outcome":null}',
    ]) {
      expect(parseControlRequest(line), line).toBeNull()
    }
  })

  test('a detail that is blank or oversized is dropped, and the answer still arrives', () => {
    /*
      Dropped rather than refused, and that is the decision worth keeping: the
      tag's own sentence is a complete answer, and refusing the whole request
      would leave the tool call waiting for an answer that has already been sent
      — a Turn lost over a sentence.

      Over-long is dropped rather than truncated for the other half of the same
      argument: half a sentence is a sentence nobody wrote.
    */
    const long = 'x'.repeat(MAX_ANSWER_DETAIL + 1)
    for (const detail of ['', '   ', long, 42]) {
      expect(
        parseControlRequest(
          `{"kind":"landing-answer","requestId":"l1","outcome":"refused","detail":${JSON.stringify(detail)}}`,
        ),
      ).toEqual({ kind: 'landing-answer', requestId: 'l1', outcome: 'refused' })
    }
    // And one exactly at the limit is kept, so the bound is a bound rather than
    // an off-by-one nobody notices until a reason goes missing.
    const atTheLimit = 'x'.repeat(MAX_ANSWER_DETAIL)
    expect(
      parseControlRequest(
        `{"kind":"landing-answer","requestId":"l1","outcome":"refused","detail":${JSON.stringify(atTheLimit)}}`,
      ),
    ).toEqual({ kind: 'landing-answer', requestId: 'l1', outcome: 'refused', detail: atTheLimit })
  })

  test('every outcome either side can write has a sentence of its own', () => {
    // The rule `previewOutcomeMessage` follows: the tag crosses and the prose is
    // authored here. A tag with no sentence would reach the agent as a tool
    // result nobody wrote.
    const said = new Set<string>()
    for (const outcome of LANDING_OUTCOMES) {
      expect(isOutcome(outcome, LANDING_OUTCOMES)).toBe(true)
      said.add(landingOutcomeMessage(outcome))
    }
    // Distinct, which is the real property — a tag that fell through to another
    // tag's sentence would tell the agent the wrong thing about its own branch,
    // and a length check would not notice.
    expect(said.size).toBe(LANDING_OUTCOMES.length)

    const releases = new Set(RELEASE_OUTCOMES.map(releaseOutcomeMessage))
    expect(releases.size).toBe(RELEASE_OUTCOMES.length)

    // The lists are not each other's: a release tag checked against the landing
    // list is refused, which is what stops one kind's answer reading as another's.
    expect(isOutcome('landed?', LANDING_OUTCOMES)).toBe(false)
    expect(isOutcome('landed', RELEASE_OUTCOMES)).toBe(false)
    expect(isOutcome('cut', LANDING_OUTCOMES)).toBe(false)
  })

  test('whether the branch is in the live tree is a flag rather than prose to interpret', () => {
    /*
      Six of the seven mean nothing was merged. An agent that read the sentence
      and guessed would eventually report a ticket delivered on the strength of a
      merge that never happened — which is the one mistake here that a developer
      does not find out about until the morning.
    */
    expect(landingToolResult({ outcome: 'landed', detail: null }).landed).toBe(true)
    for (const outcome of LANDING_OUTCOMES.filter((one) => one !== 'landed')) {
      expect(landingToolResult({ outcome, detail: null }).landed, outcome).toBe(false)
    }

    expect(releaseToolResult({ outcome: 'cut', detail: null }).cut).toBe(true)
    for (const outcome of RELEASE_OUTCOMES.filter((one) => one !== 'cut')) {
      expect(releaseToolResult({ outcome, detail: null }).cut, outcome).toBe(false)
    }
  })

  test('an answer that could not be got does not claim nothing happened', () => {
    /*
      The host's wait is bounded (`RUNTIME_WAIT`, 90s) and the work behind these
      two is not instantaneous — a merge, and a release that runs a build. A
      timeout answers the tag that means *no answer*, and the runtime goes on
      working: the merge can complete, the release can tag and write its pending
      record.

      So neither sentence may say nothing happened. The one that did said "so
      nothing was cut, tagged or announced", and an agent reading that cuts a
      second time — which is the one way this feature could damage a developer's
      clone rather than merely fail to help it.
    */
    for (const message of [landingOutcomeMessage('no-landing'), releaseOutcomeMessage('no-release')]) {
      expect(message).toContain('gave no answer')
      expect(message).not.toContain('Nothing was merged')
      expect(message).not.toContain('nothing was cut')
      // And each says what to do instead of assuming.
      expect(message.toLowerCase()).toMatch(/check|read/)
    }
  })

  test('a branch that moved is its own answer, and it is not a refusal', () => {
    // The agent can add a commit to its own Worktree between the check and the
    // merge. That is a race with its own background work rather than a decision
    // about the branch, so it must not read as one — an orchestrator parks a
    // refused branch and stops, and this one should simply be asked again.
    const moved = landingToolResult({ outcome: 'branch-moved', detail: null })
    expect(moved.landed).toBe(false)
    expect(moved.text).toContain('ask again')
    expect(moved.text).not.toContain('protected')
  })

  test('the refusal reason reaches the agent whole, in words a report can print', () => {
    // What the predicate wrote, carried rather than summarised. `landing-cli.ts`
    // prints the same sentence for a developer, which is the point: one wording
    // for the machine and the person.
    const reason =
      'src-tauri/src/bridge.rs is protected — src-tauri/** may not be landed without a human.'
    const result = landingToolResult({ outcome: 'refused', detail: reason })

    expect(result.landed).toBe(false)
    expect(result.text).toContain(reason)
    expect(result.text.startsWith(landingOutcomeMessage('refused'))).toBe(true)
    // No leftover punctuation where a detail would have been, so the sentence
    // reads whole when there is none.
    expect(landingToolResult({ outcome: 'refused', detail: null }).text).toBe(
      landingOutcomeMessage('refused'),
    )
    expect(landingToolResult({ outcome: 'landed', detail: '  spaced.  ' }).text).toBe(
      `${landingOutcomeMessage('landed')} spaced.`,
    )
  })

  test('the tool descriptions say what will refuse, so the cheapest refusal is the call never made', () => {
    expect(LAND_WORKTREE_DESCRIPTION).toContain('name')
    expect(LAND_WORKTREE_DESCRIPTION).toContain('not a path')
    expect(LAND_WORKTREE_DESCRIPTION).toContain('packages/harness/**')
    expect(LAND_WORKTREE_DESCRIPTION).toContain('src-tauri/**')
    // And the clause that stops the wrong Turn rather than a wasted one: a
    // branch that merged is not a change that is running.
    expect(LAND_WORKTREE_DESCRIPTION).toContain('Do not assume the change is live')

    expect(CUT_PRE_RELEASE_DESCRIPTION).toContain('slug')
    // Promotion is the developer's and stays the developer's.
    expect(CUT_PRE_RELEASE_DESCRIPTION).toContain('does not promote')
  })
})

// ---------------------------------------------------------------------------
// The one string that becomes an argument
// ---------------------------------------------------------------------------

describe('a feature slug is checked where it becomes an argument', () => {
  test('the shapes that could climb, flag or hide are refused', () => {
    for (const shapeless of [
      '',
      '.',
      '..',
      '../..',
      '-f',
      '--json',
      '.hidden',
      'runs/../..',
      'a b',
      'a;rm -rf /',
      'a\nb',
      'a\0b',
      '/etc',
      'x'.repeat(101),
    ]) {
      expect(isFeatureSlug(shapeless), JSON.stringify(shapeless)).toBe(false)
    }
  })

  test('the slugs a run is actually named by are accepted', () => {
    for (const slug of ['autonomous-runs', 'ticket_18', 'v0.0.2', 'a']) {
      expect(isFeatureSlug(slug), slug).toBe(true)
    }
  })
})
