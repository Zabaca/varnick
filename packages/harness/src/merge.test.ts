import { describe, expect, test } from 'bun:test'
import {
  commitMessage,
  liveTreeIsDirty,
  mergeBriefing,
  RESTART_STILL_OWED,
  mergeWorktree,
  type CwdHolder,
  type CwdProbe,
} from './merge.ts'
import type { GitAttempt, GitAttemptResult, GitRunner } from './worktrees.ts'

/*
  The seam: what varnick does to the developer's clone, and in what order.

  Nothing here runs git and nothing here has a filesystem. That is not a
  convenience — this is the one module in the product that *writes* the tree it
  is describing, so a test that ran the real thing would be a test that merges
  branches into this repository while it runs.

  What is asserted is almost entirely **ordering**: which questions are asked
  before anything is written, which are asked again afterwards, and what is
  left alone when one of them answers badly. A merge that lands is the easy
  half; the half worth testing is every path where something is not deleted.
*/

const CLONE = '/Users/dev/code/varnick'
const WORKTREE = `${CLONE}/.claude/worktrees/49`
const REF = 'refs/heads/ticket/49'

/**
 * The tree object the live branch is at once the squash has landed.
 *
 * A merge of the branch that produces this same tree is a merge that would
 * change nothing, which is how `squashCarried` knows the content went in.
 */
const LANDED_TREE = '3333333333333333333333333333333333333333'

const listing = () =>
  [
    `worktree ${CLONE}\nHEAD 1111111111111111111111111111111111111111\nbranch refs/heads/main`,
    `worktree ${WORKTREE}\nHEAD 2222222222222222222222222222222222222222\nbranch ${REF}`,
  ].join('\n\n') + '\n'

/** The reads a merge makes before it decides anything. Clean tree, one branch. */
const READS: Record<string, string> = {
  'status --porcelain': '',
  'worktree list --porcelain': listing(),
  [`rev-list --count HEAD..${REF}`]: '2\n',
  [`rev-list --count ${REF}..HEAD`]: '0\n',
  [`log --format=%s --reverse HEAD..${REF}`]: 'first go\nthe fix\n',
  'rev-parse --short HEAD': 'a1b2c3d\n',
  // The tree the live branch is at, and the tree a re-merge would produce. Equal
  // here, which is what "the squash carried everything" means — see
  // `squashCarried`. A test that wants the other answer overrides the write.
  'rev-parse HEAD^{tree}': `${LANDED_TREE}\n`,
}

/** The writes it makes once it has. All succeed unless a test says otherwise. */
const WRITES: Record<string, GitAttemptResult> = {
  [`merge --squash ${REF}`]: ok(),
  [`merge-tree --write-tree HEAD ${REF}`]: ok(`${LANDED_TREE}\n`),
  [`worktree remove ${WORKTREE}`]: ok(),
  'branch -D ticket/49': ok(),
  // The recovery, declared with the writes rather than only in the tests that
  // provoke it: it is what a failure between the squash and the commit runs,
  // and a script that had no answer for it would turn "the tree was put back"
  // into "the fake git was surprised".
  'reset --hard HEAD': ok(),
}

function ok(stdout = ''): GitAttemptResult {
  return { code: 0, stdout, stderr: '' }
}
function failed(code: number, stderr: string): GitAttemptResult {
  return { code, stdout: '', stderr }
}

/**
 * A git that answers from a script, and records the order it was asked in.
 *
 * One `asked` list across both ports, because the property under most of these
 * tests is a *sequence* — a check before a write, a write before a delete — and
 * two lists would lose the interleaving that is the whole point.
 *
 * A `commit` is matched loosely, on its first argument, because the message it
 * carries is composed from the branch and asserting on it here would make every
 * test in this file depend on the wording.
 */
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

/** Nobody is standing in the directory. */
const empty: CwdProbe = async () => []
/** Somebody is. */
const holding = (...holders: CwdHolder[]): CwdProbe => async () => holders

const merge = (over: Partial<Parameters<typeof mergeWorktree>[0]> = {}) => {
  const { git, attempt, asked } = fakeGit()
  return {
    asked,
    run: () =>
      mergeWorktree({ git, attempt, holders: empty, cloneRoot: CLONE, path: WORKTREE, ...over }),
  }
}

describe('a merge that goes in', () => {
  test('one commit lands, the worktree goes, the branch goes', async () => {
    const { git, attempt, asked } = fakeGit()
    const report = await mergeWorktree({
      git,
      attempt,
      holders: empty,
      cloneRoot: CLONE,
      path: WORKTREE,
    })

    expect(report).toEqual({
      branch: 'ticket/49',
      commit: 'a1b2c3d',
      squashed: 2,
      worktreeRemoved: true,
      branchDeleted: true,
      heldBy: [],
      leftOver: null,
    })
    // Squash, never a merge commit: what the live branch carries is what
    // changed and why, once, and not a worktree's working record.
    expect(asked).toContain(`merge --squash ${REF}`)
    expect(asked.some((call) => call === `merge ${REF}`)).toBe(false)
  })

  test('nothing is written before every refusal has had its chance', async () => {
    /*
      The ordering that is the design rather than an implementation detail. The
      dirty check, the selector, and the mergeability probe all happen before
      the squash — so a merge that is going to be refused is refused having
      written nothing at all.
    */
    const { asked, run } = merge()
    await run()

    const squash = asked.indexOf(`merge --squash ${REF}`)
    expect(asked.indexOf('status --porcelain')).toBeLessThan(squash)
    expect(asked.indexOf('worktree list --porcelain')).toBeLessThan(squash)
    expect(asked.indexOf(`rev-list --count ${REF}..HEAD`)).toBeLessThan(squash)
  })

  test('and nothing is deleted before the content is checked', async () => {
    // The squash makes the branch a non-ancestor, so `merge-base` would say the
    // work is unmerged seconds after it was merged. The content check is the
    // one that answers the question that was asked, and it gates both deletes.
    const { asked, run } = merge()
    await run()

    const carried = asked.indexOf(`merge-tree --write-tree HEAD ${REF}`)
    expect(carried).toBeGreaterThan(asked.indexOf('commit'))
    expect(asked.indexOf(`worktree remove ${WORKTREE}`)).toBeGreaterThan(carried)
    expect(asked.indexOf('branch -D ticket/49')).toBeGreaterThan(carried)
  })

  test('the branch is deleted with -D, because after a squash -d always refuses', async () => {
    const { asked, run } = merge()
    await run()
    expect(asked).toContain('branch -D ticket/49')
    expect(asked).not.toContain('branch -d ticket/49')
  })

  test('a clean merge cleans up too, and not only a fast-forward', async () => {
    /*
      The case the rest of this file did not have, and the reason it matters.

      Every other test here leaves `rev-list --count <ref>..HEAD` at zero, which
      is `fast-forward` — the live tree holds nothing the branch does not. A
      `clean` merge is the opposite by definition, and it is the ordinary one:
      main moved while the agent worked.

      The check that used to gate the cleanup was `diff --quiet HEAD <ref>`, and
      it is empty only for a fast-forward. For a clean merge the live tree
      carries both sides and the branch carries one, so the diff is never empty
      and the cleanup was unreachable — a squashed branch would report itself as
      not having landed, every time, and nothing would ever be removed. The fake
      git could not catch it because it answered that diff `ok()` and only ever
      drove the fast-forward path.
    */
    const { git, attempt, asked } = fakeGit(
      { ...READS, [`rev-list --count ${REF}..HEAD`]: '3\n' },
      {
        ...WRITES,
        // The probe `mergeabilityOf` runs to call it clean in the first place.
        [`merge-tree --write-tree --name-only HEAD ${REF}`]: ok(),
      },
    )

    const report = await mergeWorktree({
      git,
      attempt,
      holders: empty,
      cloneRoot: CLONE,
      path: WORKTREE,
    })

    expect(report.worktreeRemoved).toBe(true)
    expect(report.branchDeleted).toBe(true)
    expect(report.leftOver).toBe(null)
    expect(asked).toContain(`worktree remove ${WORKTREE}`)
  })
})

describe('a merge that is refused, having written nothing', () => {
  test('a live tree with uncommitted work in it', async () => {
    const { git, attempt, asked } = fakeGit({
      ...READS,
      'status --porcelain': ' M packages/core/src/App.tsx\n?? notes.md\n',
    })

    await expect(
      mergeWorktree({ git, attempt, holders: empty, cloneRoot: CLONE, path: WORKTREE }),
    ).rejects.toThrow(/packages\/core\/src\/App.tsx/)
    // Not a git command was run beyond the question that refused it.
    expect(asked).toEqual(['status --porcelain'])
  })

  test('an untracked file counts, because a merge would write over it', async () => {
    const { git, attempt } = fakeGit({
      ...READS,
      'status --porcelain': '?? packages/harness/src/widen.ts\n',
    })
    await expect(
      mergeWorktree({ git, attempt, holders: empty, cloneRoot: CLONE, path: WORKTREE }),
    ).rejects.toThrow(/widen.ts/)
  })

  test('a path that is not a Worktree git listed', async () => {
    const { git, attempt } = fakeGit()
    await expect(
      mergeWorktree({ git, attempt, holders: empty, cloneRoot: CLONE, path: '/tmp/elsewhere' }),
    ).rejects.toThrow(/not a Worktree with unmerged commits/)
  })

  test('the live tree itself, which is never a Worktree to merge from', async () => {
    const { git, attempt } = fakeGit()
    await expect(
      mergeWorktree({ git, attempt, holders: empty, cloneRoot: CLONE, path: CLONE }),
    ).rejects.toThrow(/not a Worktree with unmerged commits/)
  })

  test('a branch that conflicts, with the files and whose job the fix is', async () => {
    const { git, attempt, asked } = fakeGit(
      { ...READS, [`rev-list --count ${REF}..HEAD`]: '4\n' },
      {
        ...WRITES,
        [`merge-tree --write-tree --name-only HEAD ${REF}`]: {
          code: 1,
          stdout: `444\npackages/harness/src/sandbox.ts\n\nCONFLICT (content)\n`,
          stderr: '',
        },
      },
    )

    await expect(
      mergeWorktree({ git, attempt, holders: empty, cloneRoot: CLONE, path: WORKTREE }),
    ).rejects.toThrow(/merge main down/)
    expect(asked).not.toContain(`merge --squash ${REF}`)
  })

  test('a branch git could not answer about', async () => {
    // `unknown` is not a merge to attempt on the chance that it works. The
    // whole point of the state is that nobody established anything.
    const { git, attempt, asked } = fakeGit(
      { ...READS, [`rev-list --count ${REF}..HEAD`]: '4\n' },
      {
        ...WRITES,
        [`merge-tree --write-tree --name-only HEAD ${REF}`]: failed(128, 'fatal: bad object'),
      },
    )

    await expect(
      mergeWorktree({ git, attempt, holders: empty, cloneRoot: CLONE, path: WORKTREE }),
    ).rejects.toThrow(/could not say whether/)
    expect(asked).not.toContain(`merge --squash ${REF}`)
  })

  test('a mergeability that changed since the listing is caught here, not there', async () => {
    // Core's guard reads a listing that is as old as the last Turn. This is the
    // check on facts that are current, and it is the one that decides.
    const { git, attempt } = fakeGit(
      { ...READS, [`rev-list --count ${REF}..HEAD`]: '1\n' },
      {
        ...WRITES,
        [`merge-tree --write-tree --name-only HEAD ${REF}`]: {
          code: 1,
          stdout: `444\nREADME.md\n\nCONFLICT\n`,
          stderr: '',
        },
      },
    )
    await expect(
      mergeWorktree({ git, attempt, holders: empty, cloneRoot: CLONE, path: WORKTREE }),
    ).rejects.toThrow(/README.md/)
  })
})

describe('a merge that failed halfway puts the tree back', () => {
  test('a squash git would not do', async () => {
    const { git, attempt, asked } = fakeGit(READS, {
      ...WRITES,
      [`merge --squash ${REF}`]: failed(1, 'error: could not apply'),
    })

    await expect(
      mergeWorktree({ git, attempt, holders: empty, cloneRoot: CLONE, path: WORKTREE }),
    ).rejects.toThrow(/could not apply/)
    // The dirty check is what makes this safe: a tree with nothing in it has
    // nothing to lose when it is reset.
    expect(asked).toContain('reset --hard HEAD')
  })

  test('a commit a hook refused, after the squash had staged everything', async () => {
    const { git, attempt, asked } = fakeGit(READS, { ...WRITES, commit: failed(1, 'pre-commit failed') })

    await expect(
      mergeWorktree({ git, attempt, holders: empty, cloneRoot: CLONE, path: WORKTREE }),
    ).rejects.toThrow(/pre-commit failed/)
    expect(asked).toContain('reset --hard HEAD')
    expect(asked).not.toContain(`worktree remove ${WORKTREE}`)
  })
})

describe('a merge that landed with something left over', () => {
  test('a squash that did not carry deletes nothing', async () => {
    const { git, attempt, asked } = fakeGit(READS, {
      ...WRITES,
      // Exit 1 is git saying the merge would conflict, which after a squash
      // means the branch still holds something the live tree does not.
      [`merge-tree --write-tree HEAD ${REF}`]: failed(1, ''),
    })

    const report = await mergeWorktree({
      git,
      attempt,
      holders: empty,
      cloneRoot: CLONE,
      path: WORKTREE,
    })
    expect(report.worktreeRemoved).toBe(false)
    expect(report.branchDeleted).toBe(false)
    expect(report.leftOver).toContain('could not confirm')
    expect(asked).not.toContain('branch -D ticket/49')
  })

  test('a directory somebody is standing in is left alone, and they are named', async () => {
    /*
      The measurement this whole arrangement comes from. Removing a worktree an
      agent is standing in is not recoverable by the agent: the SDK treats a
      missing cwd as a terminal error before it can report the problem, ask, or
      step back to the clone root. So the branch lands and the directory stays.
    */
    const { git, attempt, asked } = fakeGit()
    const report = await mergeWorktree({
      git,
      attempt,
      holders: holding({ pid: 52236, command: 'claude' }),
      cloneRoot: CLONE,
      path: WORKTREE,
    })

    expect(report.commit).toBe('a1b2c3d')
    expect(report.worktreeRemoved).toBe(false)
    expect(report.heldBy).toEqual([{ pid: 52236, command: 'claude' }])
    expect(report.leftOver).toContain('pid 52236')
    expect(asked).not.toContain(`worktree remove ${WORKTREE}`)
  })

  test('a probe that could not run is not permission to delete', async () => {
    // "Nobody is in there" is the sentence that authorises removing a
    // directory, and a probe that did not run must never produce it.
    const { git, attempt, asked } = fakeGit()
    const report = await mergeWorktree({
      git,
      attempt,
      holders: async () => {
        throw new Error('lsof: command not found')
      },
      cloneRoot: CLONE,
      path: WORKTREE,
    })

    expect(report.commit).toBe('a1b2c3d')
    expect(report.worktreeRemoved).toBe(false)
    expect(report.leftOver).toContain('lsof: command not found')
    expect(asked).not.toContain(`worktree remove ${WORKTREE}`)
  })

  test('a branch ref that would not delete still reports the merge that landed', async () => {
    const { git, attempt } = fakeGit(READS, {
      ...WRITES,
      'branch -D ticket/49': failed(1, 'error: update of config-file failed'),
    })
    const report = await mergeWorktree({
      git,
      attempt,
      holders: empty,
      cloneRoot: CLONE,
      path: WORKTREE,
    })

    expect(report.worktreeRemoved).toBe(true)
    expect(report.branchDeleted).toBe(false)
    expect(report.leftOver).toContain('update of config-file failed')
  })
})

describe('the lock is not the signal, in either direction', () => {
  test('a lock left behind by a session that ended is cleared and the removal retried', async () => {
    /*
      Only ever after the probe. A lock is a file git left behind, and once
      nothing is standing in the directory it is litter — refusing on it would
      strand every worktree whose session ended in a crash or a restart.
    */
    let removals = 0
    const { git, attempt, asked } = fakeGit(READS, {
      ...WRITES,
      [`worktree unlock ${WORKTREE}`]: ok(),
    })
    const counting: GitAttempt = async (args) => {
      if (args[0] === 'worktree' && args[1] === 'remove') {
        removals += 1
        return removals === 1
          ? failed(1, `fatal: '${WORKTREE}' is locked, reason: claude session (pid 52236)`)
          : ok()
      }
      return attempt(args)
    }

    const report = await mergeWorktree({
      git,
      attempt: counting,
      holders: empty,
      cloneRoot: CLONE,
      path: WORKTREE,
    })

    expect(report.worktreeRemoved).toBe(true)
    expect(removals).toBe(2)
    expect(asked).toContain(`worktree unlock ${WORKTREE}`)
  })

  test('a worktree with no lock at all is still not removed while a process has it', async () => {
    // The other direction, and the one that is easy to miss: a session that
    // ended in a restart leaves no lock behind while its agent is still there.
    const { git, attempt, asked } = fakeGit()
    const report = await mergeWorktree({
      git,
      attempt,
      holders: holding({ pid: 4242, command: 'claude' }),
      cloneRoot: CLONE,
      path: WORKTREE,
    })

    expect(report.worktreeRemoved).toBe(false)
    expect(asked).not.toContain(`worktree unlock ${WORKTREE}`)
    expect(asked).not.toContain(`worktree remove ${WORKTREE}`)
  })

  test('a removal that failed for any other reason is reported, not forced past', async () => {
    const { git, attempt, asked } = fakeGit(READS, {
      ...WRITES,
      [`worktree remove ${WORKTREE}`]: failed(1, 'fatal: contains modified or untracked files'),
    })
    const report = await mergeWorktree({
      git,
      attempt,
      holders: empty,
      cloneRoot: CLONE,
      path: WORKTREE,
    })

    expect(report.worktreeRemoved).toBe(false)
    expect(report.leftOver).toContain('modified or untracked files')
    expect(asked).not.toContain(`worktree unlock ${WORKTREE}`)
  })
})

describe('what the one commit says', () => {
  test('a branch with a single commit keeps the sentence its author wrote', () => {
    const [subject, body] = commitMessage('ticket/49', ['Every pending branch says whether it goes'])
    expect(subject).toBe('Every pending branch says whether it goes')
    expect(body).toContain('ticket/49')
  })

  test('a branch with several is named, with its working record underneath', () => {
    const [subject, body] = commitMessage('ticket/49', ['first go', 'the fix', 'the rebase'])
    expect(subject).toBe('Merge ticket/49')
    expect(body).toContain('* first go')
    expect(body).toContain('* the rebase')
  })

  test('the branch is named either way, because it is about to be deleted', () => {
    expect(commitMessage('ticket/49', ['one'])[1]).toContain('ticket/49')
    expect(commitMessage('ticket/49', [])[1]).toContain('ticket/49')
  })
})

describe('what the agent is told, because it is the author', () => {
  const landed = {
    branch: 'ticket/49',
    commit: 'a1b2c3d',
    squashed: 3,
    worktreeRemoved: true,
    branchDeleted: true,
    heldBy: [],
    leftOver: null,
  }

  test('the branch, the shape it landed in, and where it landed', () => {
    const said = mergeBriefing(landed)
    expect(said).toContain('ticket/49')
    expect(said).toContain('a1b2c3d')
    expect(said).toContain('squashed')
  })

  test('a single commit is not described as having been squashed', () => {
    // Nothing was compressed, and saying so would make the agent believe its
    // working record had been collapsed when it was one commit all along.
    expect(mergeBriefing({ ...landed, squashed: 1 })).not.toContain('squashed')
  })

  test('the worktree and the branch are named as gone', () => {
    // The two facts a list of fields cannot convey, because both are absences:
    // without them the agent goes on offering to preview a directory that has
    // been deleted.
    expect(mergeBriefing(landed)).toContain('both gone')
  })

  test('and a worktree still on disk is not reported as unmerged work', () => {
    const said = mergeBriefing({
      ...landed,
      worktreeRemoved: false,
      branchDeleted: false,
      heldBy: [{ pid: 4242, command: 'claude' }],
      leftOver: null,
    })
    expect(said).toContain('claude (pid 4242)')
    expect(said).toContain('already landed')
  })

  test('the restart clause is separate, because it is the half that expires', () => {
    /*
      It was inside the Briefing, and it had to come out.

      The fact is still the one an agent will otherwise reason itself out of —
      it merged, therefore it is live — and until a restart the running varnick
      *is* the build from before the change. What changed is when it is read.

      A Briefing is delivered by a `UserPromptSubmit` hook, and the thing varnick
      recommends immediately after a merge is a restart. So the ordinary
      sequence has no Turn between the merge and the restart, the agent host
      dies with an undelivered Briefing, and it is kept on disk and said in the
      session afterwards — where "varnick has not restarted" is false.

      Two strings, both composed here. The agent host delivers the second only
      when it is the process that received it, which is a fact about itself
      rather than a judgement about the merge.
    */
    for (const report of [landed, { ...landed, worktreeRemoved: false }, { ...landed, squashed: 1 }]) {
      expect(mergeBriefing(report)).not.toContain('not restarted')
    }
    expect(RESTART_STILL_OWED).toContain('not restarted')
    expect(RESTART_STILL_OWED).toContain('Do not assume the change is live')
  })

  test('it is a report and asks for nothing', () => {
    // Same footing as the compaction report: something the world did. An
    // instruction here would be varnick putting words in a developer's mouth,
    // in a channel the agent cannot tell apart from one.
    const said = mergeBriefing(landed)
    expect(said).not.toContain('Please')
    expect(said).not.toContain('you should')
  })
})

describe('whether the live tree is dirty, asked twice by two callers', () => {
  test('a clean tree is not', async () => {
    const git: GitRunner = async () => ''
    expect(await liveTreeIsDirty(git)).toBe(false)
  })

  test('and one with anything in it is', async () => {
    const git: GitRunner = async () => '?? notes.md\n'
    expect(await liveTreeIsDirty(git)).toBe(true)
  })

  test('it is the same question the merge refuses on', async () => {
    // One definition, two askers: this is the affordance and the merge's own
    // check is the rule. Two copies would drift on exactly the case that
    // matters — an untracked file.
    const git: GitRunner = async () => '?? packages/harness/src/widen.ts\n'
    expect(await liveTreeIsDirty(git)).toBe(true)
    const { attempt } = fakeGit()
    await expect(
      mergeWorktree({ git, attempt, holders: empty, cloneRoot: CLONE, path: WORKTREE }),
    ).rejects.toThrow(/widen.ts/)
  })
})
