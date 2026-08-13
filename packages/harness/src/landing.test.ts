import { describe, expect, test } from 'bun:test'
import { landWorktree } from './landing.ts'
import { mergeWorktree } from './merge.ts'
import { PROTECTED_PATHS, ROOT_MANIFEST } from './fence.ts'
import { readAllowlistFor, sandboxPolicyFor } from './sandbox.ts'
import type { CwdProbe } from './merge.ts'
import type { GitAttempt, GitAttemptResult, GitRunner } from './worktrees.ts'

/*
  The gate on the agent's own landing: what it refuses, and that it refuses
  before anything is written.

  Nothing here runs git and nothing here has a filesystem, for the reason
  merge.test.ts gives one module over — this is the path that *writes* the tree
  it is describing, so a test that ran the real thing would merge branches into
  this repository while it ran.

  **The assertions are about the caller, not the predicate.** `unattendedLanding`
  is the most-tested function in the repo and fence.test.ts proves what it
  answers; a tool that forgot to ask it would pass every one of those tests. So
  each protected entry is refused *through `landWorktree`* here, and every
  refusal is checked twice: that the answer says so, and that no merge was
  attempted.
*/

const CLONE = '/Users/dev/code/varnick'
const WORKTREE = `${CLONE}/.claude/worktrees/49`
const REF = 'refs/heads/ticket/49'
/** The commit the branch is at when it is checked, and still at when it is merged. */
const COMMIT = '2222222222222222222222222222222222222222'
const LANDED_TREE = '3333333333333333333333333333333333333333'

const listing = () =>
  `${[
    `worktree ${CLONE}\nHEAD 1111111111111111111111111111111111111111\nbranch refs/heads/main`,
    `worktree ${WORKTREE}\nHEAD 2222222222222222222222222222222222222222\nbranch ${REF}`,
  ].join('\n\n')}\n`

/** The diff a landing asks for, as one key. The flags are part of the question. */
const DIFF = `diff -z --no-renames --name-only HEAD...${COMMIT}`

/** A `-z` listing: every entry NUL-terminated, including the last. */
const nulTerminated = (...paths: string[]) => paths.map((path) => `${path}\0`).join('')

/** A manifest with the lifecycle fields a real one has. */
const manifest = (scripts: Record<string, string>) =>
  JSON.stringify({ name: 'varnick', scripts: { dev: 'vite', ...scripts } })

const READS: Record<string, string> = {
  'status --porcelain': '',
  [`rev-parse ${REF}`]: `${COMMIT}\n`,
  'worktree list --porcelain': listing(),
  [`rev-list --count HEAD..${REF}`]: '2\n',
  [`rev-list --count ${COMMIT}..HEAD`]: '0\n',
  // Asked twice by two callers: the gate probes the pinned commit, and
  // `mergeWorktree` probes the ref it resolved for itself.
  [`rev-list --count ${REF}..HEAD`]: '0\n',
  [DIFF]: nulTerminated('packages/core/src/App.tsx', 'README.md'),
  [`log --format=%s --reverse HEAD..${REF}`]: 'the fix\n',
  'rev-parse --short HEAD': 'a1b2c3d\n',
  'rev-parse HEAD^{tree}': `${LANDED_TREE}\n`,
  [`merge-base HEAD ${COMMIT}`]: '1111111111111111111111111111111111111111\n',
  [`show 1111111111111111111111111111111111111111:${ROOT_MANIFEST}`]: manifest({
    postinstall: 'sh scripts/use-tracked-git-hooks.sh',
  }),
  [`show ${COMMIT}:${ROOT_MANIFEST}`]: manifest({
    postinstall: 'sh scripts/use-tracked-git-hooks.sh',
  }),
}

const WRITES: Record<string, GitAttemptResult> = {
  [`merge --squash ${REF}`]: ok(),
  [`merge-tree --write-tree HEAD ${REF}`]: ok(`${LANDED_TREE}\n`),
  [`worktree remove ${WORKTREE}`]: ok(),
  'branch -D ticket/49': ok(),
  'reset --hard HEAD': ok(),
}

function ok(stdout = ''): GitAttemptResult {
  return { code: 0, stdout, stderr: '' }
}

/** A git that answers from a script and records the order it was asked in. */
function fakeGit(
  reads: Record<string, string> = READS,
  writes: Record<string, GitAttemptResult> = WRITES,
) {
  const asked: string[] = []
  const git: GitRunner = async (args) => {
    const key = args.join(' ')
    asked.push(key)
    const answer = reads[key]
    if (answer === undefined) throw new Error(`git ${key} was not expected`)
    return answer
  }
  const attempt: GitAttempt = async (args) => {
    const key = args.join(' ')
    asked.push(args[0] === 'commit' ? 'commit' : key)
    if (args[0] === 'commit') return writes['commit'] ?? ok()
    const answer = writes[key]
    if (answer === undefined) throw new Error(`git ${key} was not expected`)
    return answer
  }
  return { git, attempt, asked }
}

const nobody: CwdProbe = async () => []

/** One landing, with the changed paths a test cares about and everything else ordinary. */
async function land(
  over: {
    changed?: string[]
    reads?: Record<string, string>
    writes?: Record<string, GitAttemptResult>
    path?: string
    /** Reads to take away, so the fake git rejects them the way a real one would. */
    withhold?: readonly string[]
  } = {},
) {
  const reads: Record<string, string> = {
    ...READS,
    ...(over.changed === undefined ? {} : { [DIFF]: nulTerminated(...over.changed) }),
    ...over.reads,
  }
  for (const key of over.withhold ?? []) delete reads[key]
  const { git, attempt, asked } = fakeGit(reads, { ...WRITES, ...over.writes })
  const answer = await landWorktree({
    git,
    attempt,
    holders: nobody,
    cloneRoot: CLONE,
    path: over.path ?? WORKTREE,
  })
  return { answer, asked }
}

/** Did anything at all get written to the developer's clone? */
const merged = (asked: readonly string[]) =>
  asked.some((call) => call.startsWith('merge --squash') || call === 'commit')

// ---------------------------------------------------------------------------
// What may not be landed without a human
// ---------------------------------------------------------------------------

describe('the tool refuses everything the predicate refuses', () => {
  test('every protected entry is refused through the tool, and nothing is merged', async () => {
    /*
      One case per entry on `PROTECTED_PATHS`, generated from the list itself
      rather than written out — a new entry that this caller does not honour
      fails here without anybody remembering to add a case.

      A directory entry is exercised by a file *inside* it, which is the shape a
      real diff has: `git diff --name-only` names files, never directories, so
      an implementation that matched only the literal entry would pass a
      handwritten test and land every real branch.
    */
    for (const entry of PROTECTED_PATHS) {
      const changed = entry.endsWith('/**')
        ? `${entry.slice(0, -'/**'.length)}/planted.ts`
        : entry
      const { answer, asked } = await land({ changed: ['README.md', changed] })

      expect(answer.outcome).toBe('refused')
      // The sentence names both the path and the rule, because a run report
      // prints this and "it would not land" is not something a developer can
      // act on at seven in the morning.
      expect(answer.detail).toContain(changed)
      expect(answer.detail).toContain(entry)
      expect(merged(asked)).toBe(false)
    }
  })

  test('a branch that touches none of them lands, and says what happened to it', async () => {
    // The other half of the same claim: the gate is a gate rather than a wall.
    // `packages/core/**` is the whole point of the feature — denied in the live
    // tree so a broken edit cannot take the conversation down, which is a reason
    // to review a change and not a reason to need a person awake for it.
    const { answer, asked } = await land({
      changed: ['packages/core/src/App.tsx', 'vite.config.ts', 'docs/adr/0023-x.md'],
    })

    expect(answer.outcome).toBe('landed')
    expect(merged(asked)).toBe(true)
    expect(answer.detail).toContain('ticket/49')
    expect(answer.detail).toContain('a1b2c3d')
    // The clause that stops an agent reasoning "it merged, therefore it is
    // running". It is the sentence a developer's own merge ends with too.
    expect(answer.detail).toContain('has not restarted')
  })

  test('the manifest lands for its dependencies and refuses for its lifecycle scripts', async () => {
    const dependenciesOnly = await land({
      changed: [ROOT_MANIFEST],
      reads: {
        [`show ${COMMIT}:${ROOT_MANIFEST}`]: manifest({
          postinstall: 'sh scripts/use-tracked-git-hooks.sh',
        }),
      },
    })
    expect(dependenciesOnly.answer.outcome).toBe('landed')

    for (const [what, scripts] of [
      ['changed', { postinstall: 'sh scripts/mine.sh' }],
      ['removed', {}],
      ['added', { postinstall: 'sh scripts/use-tracked-git-hooks.sh', prepare: 'sh x.sh' }],
    ] as const) {
      const { answer, asked } = await land({
        changed: [ROOT_MANIFEST, 'README.md'],
        reads: { [`show ${COMMIT}:${ROOT_MANIFEST}`]: manifest(scripts) },
      })
      expect(answer.outcome, `a ${what} lifecycle script`).toBe('refused')
      expect(answer.detail).toContain('install time')
      expect(merged(asked)).toBe(false)
    }
  })

  test('a manifest that cannot be read is refused rather than read as having no scripts', async () => {
    /*
      The failing-closed case, and the one an implementation gets wrong by being
      tidy: `{}` for "I could not parse it" is indistinguishable from "it has no
      lifecycle scripts", and the second lands. The predicate has a refusal for
      exactly this — `manifest-not-read` — and reaching it means passing
      `undefined` rather than an empty object.
    */
    for (const unreadable of ['{ not json', '"a string"', '{"scripts":{"postinstall":42}}']) {
      const { answer, asked } = await land({
        changed: [ROOT_MANIFEST],
        reads: { [`show ${COMMIT}:${ROOT_MANIFEST}`]: unreadable },
      })
      expect(answer.outcome, unreadable).toBe('refused')
      expect(answer.detail).toContain('were not read')
      expect(merged(asked)).toBe(false)
    }
  })

  test('an unreadable manifest refuses even when the base side has no lifecycle scripts', async () => {
    /*
      The hole this closed, and it is the one that opens the gate.

      Treating a failed `git show` as "there is no manifest at that revision"
      makes a failure indistinguishable from an absence, and the two want
      opposite answers. With the base side holding no lifecycle fields — an
      ordinary thing for a manifest to be — a failed read on the branch side made
      both sides `{}`, the diff showed no change, and a branch that **added** a
      `postinstall` landed unattended.

      It was unreachable in this repository on the day it was written, because
      `package.json` here has a `postinstall` and the base side therefore had
      fields. That is the part worth keeping: the hole was closed by a fact about
      a file's current contents rather than by the code, and one human-merged
      branch dropping that field would have opened it with nothing failing.

      So the base here has **no** lifecycle scripts, which is the configuration
      that made it reachable.
    */
    const { answer, asked } = await land({
      changed: [ROOT_MANIFEST],
      reads: {
        // A base manifest with nothing that runs at install time.
        [`show 1111111111111111111111111111111111111111:${ROOT_MANIFEST}`]: manifest({}),
      },
      // And a branch side git will not answer for. Withheld rather than made
      // empty, because an empty answer is a manifest that parsed.
      withhold: [`show ${COMMIT}:${ROOT_MANIFEST}`],
    })

    expect(answer.outcome).toBe('refused')
    expect(answer.detail).toContain('were not read')
    expect(merged(asked)).toBe(false)
  })

  test('the same branch, read successfully, refuses for the lifecycle script it adds', async () => {
    // The control for the test above: same base with no lifecycle fields, same
    // branch adding a `postinstall`, and this time git answers. It must refuse
    // by naming the field rather than by failing to read it — otherwise the test
    // above would pass against an implementation that refuses everything.
    const { answer, asked } = await land({
      changed: [ROOT_MANIFEST],
      reads: {
        [`show 1111111111111111111111111111111111111111:${ROOT_MANIFEST}`]: manifest({}),
        [`show ${COMMIT}:${ROOT_MANIFEST}`]: manifest({ postinstall: 'sh scripts/mine.sh' }),
      },
    })

    expect(answer.outcome).toBe('refused')
    expect(answer.detail).toContain('install time')
    expect(answer.detail).toContain('postinstall')
    expect(merged(asked)).toBe(false)
  })
})

// ---------------------------------------------------------------------------
// What was checked is what lands
// ---------------------------------------------------------------------------

describe('the commit the predicate judged is the commit that merges', () => {
  test('a branch that moves between the check and the merge is refused, and nothing is merged', async () => {
    /*
      Time-of-check-to-time-of-use, in the one function whose whole job is that
      the check binds the use.

      The agent may write its own Worktree freely and can run git there from a
      background `Bash`, so it can add a commit after the predicate has read what
      the branch changed. A merge of the *ref* would then carry paths nothing
      checked — including protected ones.

      Here git answers a different SHA the second time it is asked, which is that
      race. Nothing may be merged.
    */
    const moved = '9999999999999999999999999999999999999999'
    let asks = 0
    const reads: Record<string, string> = {
      ...READS,
      [DIFF]: nulTerminated('packages/core/src/App.tsx'),
    }
    const asked: string[] = []
    const git: GitRunner = async (args) => {
      const key = args.join(' ')
      asked.push(key)
      // The branch grows a commit the moment the verdict is in.
      if (key === `rev-parse ${REF}`) {
        asks += 1
        return asks === 1 ? `${COMMIT}\n` : `${moved}\n`
      }
      const answer = reads[key]
      if (answer === undefined) throw new Error(`git ${key} was not expected`)
      return answer
    }
    const attempt: GitAttempt = async (args) => {
      asked.push(args[0] === 'commit' ? 'commit' : args.join(' '))
      return ok()
    }

    const answer = await landWorktree({
      git,
      attempt,
      holders: nobody,
      cloneRoot: CLONE,
      path: WORKTREE,
    })

    expect(answer.outcome).toBe('branch-moved')
    expect(merged(asked)).toBe(false)
    // Distinct from a refusal, because nobody decided anything about this
    // branch: an orchestrator parks a refusal and stops, and this one is asked
    // again.
    expect(answer.outcome).not.toBe('refused')
  })

  test('the merge itself refuses a moved ref, so the bind does not depend on the caller checking', async () => {
    /*
      The half of the binding that has to live at the merge. The check above is
      still a check with a gap after it — only the code performing the merge can
      close the gap, by refusing at the last moment it is able to.

      Asserted through `mergeWorktree` directly, with a pin that never matches,
      because that is the path a future caller would reach without going through
      the gate at all.
    */
    const { git, attempt, asked } = fakeGit()
    await expect(
      mergeWorktree({
        git,
        attempt,
        holders: nobody,
        cloneRoot: CLONE,
        path: WORKTREE,
        expectedCommit: '9999999999999999999999999999999999999999',
      }),
    ).rejects.toThrow('is not what would land')
    expect(merged(asked)).toBe(false)
  })

  test('the predicate is asked about the commit, not about the branch name', async () => {
    // What makes the pin real rather than decorative: the diff and both manifest
    // reads name the resolved commit. A diff of `HEAD...refs/heads/x` would be a
    // verdict about whatever that ref points at when git got round to it.
    const { asked } = await land({ changed: [ROOT_MANIFEST] })
    expect(asked).toContain(`diff -z --no-renames --name-only HEAD...${COMMIT}`)
    expect(asked).toContain(`merge-base HEAD ${COMMIT}`)
    expect(asked).toContain(`show ${COMMIT}:${ROOT_MANIFEST}`)
    expect(asked.filter((call) => call.startsWith('diff') && call.includes(REF))).toEqual([])
  })
})

// ---------------------------------------------------------------------------
// Where the paths come from
// ---------------------------------------------------------------------------

describe('what the branch changed is git’s answer, and git is asked properly', () => {
  test('the diff is asked with the three flags that stopped protected paths landing', async () => {
    const { asked } = await land()
    /*
      `-z`, `--no-renames` and `HEAD...` are not style. Each closed a hole that
      produced a landing for a protected path, and the two tests below are what
      those holes look like when the flag is missing — so this asserts the exact
      question rather than that a diff happened.
    */
    expect(asked).toContain(DIFF)
    expect(asked.some((call) => call.startsWith('diff') && !call.includes('-z'))).toBe(false)
  })

  test('a quoted path is refused rather than landed, whatever produced it', async () => {
    /*
      What real git prints for a non-ASCII path with the default
      `core.quotePath=true`. `-z` is what stops it arriving, and this is the
      belt: the leading `"` matches no entry in `PROTECTED_PATHS`, so an
      implementation that lost the flag would land `scripts/café.sh` silently.
    */
    const { answer, asked } = await land({
      changed: [String.raw`"scripts/caf\303\251.sh"`],
    })
    expect(answer.outcome).toBe('refused')
    expect(answer.detail).toContain('not a repository-relative path')
    expect(merged(asked)).toBe(false)
  })

  test('a rename out of a protected tree is refused, because both sides are reported', async () => {
    // With `--no-renames` a rename is a delete and an add, so the *source* is on
    // the list and refuses. This is the branch that moves the baseline out of
    // the way, which is the whole reason the flag is passed.
    const both = await land({
      changed: ['sandbox-policy.baseline.json', 'baseline.json'],
    })
    expect(both.answer.outcome).toBe('refused')
    expect(both.answer.detail).toContain('sandbox-policy.baseline.json')

    // And the same branch as rename detection would report it: the destination
    // only. It lands, which is what makes `--no-renames` load-bearing rather
    // than tidy.
    const destinationOnly = await land({ changed: ['baseline.json'] })
    expect(destinationOnly.answer.outcome).toBe('landed')
  })

  test('a rename into a protected tree is refused too', async () => {
    const { answer } = await land({ changed: ['notes.md', 'scripts/notes.md'] })
    expect(answer.outcome).toBe('refused')
    expect(answer.detail).toContain('scripts/notes.md')
  })

  test('the ref that reaches git is the one git printed, not the string the caller sent', async () => {
    /*
      The property the whole design rests on, asserted on a landing that
      *succeeds* — because a refusal proves nothing here: it never gets as far as
      running a command with a ref in it.

      The selector is deliberately not equal to what git printed. It matches the
      entry (a trailing slash is not a different worktree) and then never appears
      again: every command naming a branch names git's own `REF`, and the only
      path any command carries is the one out of the listing. A caller that
      wanted a different branch diffed, or a different directory removed, has
      nowhere to put it.
    */
    const supplied = `${WORKTREE}/`
    const { answer, asked } = await land({ path: supplied })
    expect(answer.outcome).toBe('landed')

    const naming = asked.filter((call) => call.includes('refs/heads/'))
    expect(naming.length).toBeGreaterThan(0)
    for (const call of naming) expect(call).toContain(REF)

    expect(asked.filter((call) => call.includes(supplied))).toEqual([])
    expect(asked.filter((call) => call.includes(WORKTREE))).toEqual([
      `worktree remove ${WORKTREE}`,
    ])
  })

  test('a selector naming a path git did not list resolves to nothing at all', async () => {
    // The other direction: a path that is not one of git's entries matches no
    // entry, so there is no ref and nothing to merge. Nothing is joined, nothing
    // is canonicalised, and nothing is passed — it is a key that is not in the
    // table, which is the same answer for all four of these.
    for (const hostile of [
      `${WORKTREE}/../../..`,
      '/etc',
      `${CLONE}/.claude/worktrees/49/..`,
      'ticket/49',
    ]) {
      const { answer, asked } = await land({ path: hostile })
      expect(answer.outcome, hostile).toBe('unknown-worktree')
      expect(asked.filter((call) => call.includes(hostile))).toEqual([])
      expect(merged(asked)).toBe(false)
    }
  })
})

// ---------------------------------------------------------------------------
// The refusals that are not about the branch's contents
// ---------------------------------------------------------------------------

describe('a landing that cannot be attempted says which of the three it is', () => {
  test('an unknown worktree name refuses without asking anything about a branch', async () => {
    const { answer, asked } = await land({ path: `${CLONE}/.claude/worktrees/nowhere` })
    expect(answer.outcome).toBe('unknown-worktree')
    expect(answer.detail).toBeNull()
    // Nothing was diffed and nothing was merged: the selector matched no entry,
    // so there was no ref to ask about.
    expect(asked.some((call) => call.startsWith('diff'))).toBe(false)
    expect(merged(asked)).toBe(false)
  })

  test('the live clone is not a worktree anybody can land', async () => {
    // It is on git's listing and it is the tree being merged *into*. A landing
    // that resolved it would squash the live branch onto itself.
    const { answer } = await land({ path: CLONE })
    expect(answer.outcome).toBe('unknown-worktree')
  })

  test('a dirty live tree refuses distinctly, so the agent does not try to fix its own branch', async () => {
    const { answer, asked } = await land({
      reads: { ...READS, 'status --porcelain': ' M packages/core/src/App.tsx\n' },
    })
    expect(answer.outcome).toBe('dirty-live-tree')
    expect(merged(asked)).toBe(false)
    // Nothing about the developer's uncommitted work crosses into the Sandbox.
    // The tag's own sentence says what happened; naming their files would be
    // this process reporting on a tree the agent did not touch.
    expect(answer.detail).toBeNull()
  })

  test('a branch that conflicts refuses with the files, which is the part it can act on', async () => {
    const { answer, asked } = await land({
      reads: { ...READS, [`rev-list --count ${COMMIT}..HEAD`]: '3\n' },
      writes: {
        ...WRITES,
        [`merge-tree --write-tree --name-only HEAD ${COMMIT}`]: {
          code: 1,
          stdout: 'atree\npackages/core/src/App.tsx\n\nCONFLICT (content)\n',
          stderr: '',
        },
      },
    })
    expect(answer.outcome).toBe('unmergeable')
    expect(answer.detail).toContain('packages/core/src/App.tsx')
    expect(merged(asked)).toBe(false)
  })

  test('a merge git could not judge is unmergeable rather than merged anyway', async () => {
    const { answer, asked } = await land({
      reads: { ...READS, [`rev-list --count ${COMMIT}..HEAD`]: '3\n' },
      writes: {
        ...WRITES,
        [`merge-tree --write-tree --name-only HEAD ${COMMIT}`]: {
          code: 128,
          stdout: '',
          stderr: 'fatal: not a valid object name',
        },
      },
    })
    expect(answer.outcome).toBe('unmergeable')
    expect(merged(asked)).toBe(false)
  })

  test('a git that will not answer is no-landing, and never a refusal', async () => {
    /*
      The distinction an orchestrator acts on. `refused` means the Fence said so
      and the branch is finished work for a person; anything else means the
      machine is broken. A question that could not be put must not be reported
      as an answer — a night's work would be handed over as fenced when nothing
      looked at it.
    */
    const { answer, asked } = await land({ withhold: [DIFF] })
    expect(answer.outcome).toBe('no-landing')
    expect(merged(asked)).toBe(false)
    // And it carries git's own complaint, so a run report says which question
    // could not be put rather than "something went wrong".
    expect(answer.detail).toContain('diff')
  })
})

// ---------------------------------------------------------------------------
// The door this is not
// ---------------------------------------------------------------------------

describe('this is a second door rather than a wider one', () => {
  test('the agent still cannot write Core, the manifest or the build config in the live tree', async () => {
    /*
      ADR-0023's whole claim, as an assertion on the generated policy.

      The tempting fix for "the agent cannot land its own work" is to take these
      three out of `denyWrite`. That gives away ADR-0014: the agent could then
      edit `packages/core/**` directly in the live tree, on no branch, in no
      diff, reviewed by nobody — and the `PreToolUse` worktree-only hook is a
      convention rather than a boundary, because it lives in a file the agent can
      edit and does not see `Bash`.

      So the landing exists *and* these stay denied. If a change ever removes one
      of them, this fails here rather than in a review that did not happen.
    */
    const denyWrite = sandboxPolicyFor({
      cloneRoot: CLONE,
      homeDir: '/Users/dev',
      tmpDir: '/var/folders/xx/T',
      readAllowlist: readAllowlistFor({
        cloneRoot: CLONE,
        execPath: '/Users/dev/.bun/bin/bun',
        sdkEntry: `${CLONE}/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs`,
        developerToolsBin: '/usr/bin',
      }),
    }).filesystem.denyWrite

    expect(denyWrite).toContain(`${CLONE}/packages/core/**`)
    expect(denyWrite).toContain(`${CLONE}/${ROOT_MANIFEST}`)
    expect(denyWrite).toContain(`${CLONE}/vite.config.*`)
  })

  test('the paths a landing may carry are exactly the ones a human need not see', async () => {
    /*
      The other side of the same claim: the door is narrower than the fence it
      sits beside. `packages/core/**`, `vite.config.*` and the manifest are
      denied to the agent's *hand* and are not on `PROTECTED_PATHS`, because a
      merge of them is reviewable work rather than a change to what confines
      anybody. A gate that reused the deny list would land nothing and a gate
      that reused `isFencePath` would land `scripts/**`.
    */
    for (const notProtected of ['packages/core/**', 'vite.config.*', ROOT_MANIFEST]) {
      expect(PROTECTED_PATHS as readonly string[]).not.toContain(notProtected)
    }
    for (const protectedPath of ['packages/harness/**', 'src-tauri/**', 'scripts/**']) {
      expect(PROTECTED_PATHS as readonly string[]).toContain(protectedPath)
    }
  })
})
