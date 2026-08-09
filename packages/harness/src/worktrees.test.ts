import { describe, expect, test } from 'bun:test'
import {
  listPendingWorktrees,
  parseWorktreeList,
  readPendingWorktreeDiff,
  type GitRunner,
} from './worktrees.ts'

/*
  The seam: what git said, turned into what varnick knows.

  Every test here supplies its own {@link GitRunner}. Nothing in this file runs
  git, and that is the point of the port rather than a convenience — the whole
  claim of this module is that the answer comes from git and not from anything
  that composes prose, and a test that ran the real thing would be asserting
  against this repository's own history.
*/

const CLONE = '/Users/dev/code/varnick'

/** The porcelain listing, as `git worktree list --porcelain` prints one. */
const listing = (...blocks: string[]) => `${blocks.join('\n\n')}\n`

const main = `worktree ${CLONE}\nHEAD 1111111111111111111111111111111111111111\nbranch refs/heads/main`

const linked = (name: string, head = '2222222222222222222222222222222222222222') =>
  `worktree ${CLONE}/.claude/worktrees/${name}\nHEAD ${head}\nbranch refs/heads/ticket/${name}`

/**
 * A git that answers from a script, and records what it was asked.
 *
 * `answers` is keyed by the whole argv, so a test that changes which question
 * is asked has to say so rather than silently falling through to a default.
 */
function fakeGit(answers: Record<string, string>) {
  const asked: string[][] = []
  const git: GitRunner = async (args) => {
    asked.push([...args])
    const key = args.join(' ')
    const answer = answers[key]
    if (answer === undefined) throw new Error(`git ${key} was not expected`)
    return answer
  }
  return { git, asked }
}

describe('reading the listing git prints', () => {
  test('a worktree is its path, its HEAD and its branch', () => {
    const [entry] = parseWorktreeList(listing(main))
    expect(entry).toEqual({
      path: CLONE,
      head: '1111111111111111111111111111111111111111',
      branch: 'refs/heads/main',
      bare: false,
    })
  })

  test('a path with a space in it is one path', () => {
    // The field is the rest of the line, not the next token. A developer whose
    // checkout lives under "Code Projects" is not an edge case worth losing.
    const [entry] = parseWorktreeList('worktree /Users/dev/Code Projects/varnick\nHEAD abc\n')
    expect(entry?.path).toBe('/Users/dev/Code Projects/varnick')
  })

  test('a detached worktree has no branch', () => {
    const [entry] = parseWorktreeList('worktree /w/one\nHEAD abc\ndetached\n')
    expect(entry?.branch).toBeNull()
  })

  test('a bare repository says so', () => {
    const [entry] = parseWorktreeList('worktree /w/bare\nbare\n')
    expect(entry?.bare).toBe(true)
  })

  test('the blocks are the worktrees, in the order git listed them', () => {
    const entries = parseWorktreeList(listing(main, linked('a'), linked('b')))
    expect(entries.map((entry) => entry.branch)).toEqual([
      'refs/heads/main',
      'refs/heads/ticket/a',
      'refs/heads/ticket/b',
    ])
  })
})

describe('which worktrees are pending', () => {
  test('one holding commits the live tree does not is listed, with its branch and path', async () => {
    const { git } = fakeGit({
      'worktree list --porcelain': listing(main, linked('49')),
      'rev-list --count HEAD..refs/heads/ticket/49': '3\n',
      'diff --name-only -z HEAD...refs/heads/ticket/49':
        'packages/core/src/machines/harness.ts\0packages/core/src/domain.ts\0',
    })

    const pending = await listPendingWorktrees({ git, cloneRoot: CLONE })

    expect(pending).toEqual([
      {
        path: `${CLONE}/.claude/worktrees/49`,
        branch: 'ticket/49',
        commits: 3,
        changed: ['packages/core/src/machines/harness.ts', 'packages/core/src/domain.ts'],
        touchesFence: false,
      },
    ])
  })

  test('one whose branch has no commits yet is not pending', async () => {
    /*
      An agent that has started, not one that has finished. A worktree exists
      from the moment `EnterWorktree` runs, and listing it as pending would put
      a row in front of the developer for every subagent currently thinking.
    */
    const { git } = fakeGit({
      'worktree list --porcelain': listing(main, linked('49')),
      'rev-list --count HEAD..refs/heads/ticket/49': '0\n',
    })

    expect(await listPendingWorktrees({ git, cloneRoot: CLONE })).toEqual([])
  })

  test('nothing pending is an empty list, and an empty list is not a failure', async () => {
    // The distinction the machine keeps as two states: `review.empty` is this,
    // and `review.listFailed` is the rejection below. Nothing here may collapse
    // the second into the first.
    const { git } = fakeGit({ 'worktree list --porcelain': listing(main) })
    expect(await listPendingWorktrees({ git, cloneRoot: CLONE })).toEqual([])
  })

  test('a git that fails rejects, carrying what it said', async () => {
    const git: GitRunner = async () => {
      throw new Error('fatal: not a git repository')
    }
    await expect(listPendingWorktrees({ git, cloneRoot: CLONE })).rejects.toThrow(
      'fatal: not a git repository',
    )
  })

  test('the live tree is never pending against itself', async () => {
    const { git } = fakeGit({ 'worktree list --porcelain': listing(main) })
    expect(await listPendingWorktrees({ git, cloneRoot: CLONE })).toEqual([])
  })

  test('and neither is the clone this varnick is running from', async () => {
    /*
      A Preview runs from a worktree, so its clone root is a *linked* worktree
      and the main tree is somewhere else. Both are excluded: the first because
      it is this varnick's own tree, the second because it is the tree everything
      else is measured against.
    */
    const preview = `${CLONE}/.claude/worktrees/49`
    const { git } = fakeGit({
      'worktree list --porcelain': listing(main, linked('49')),
    })
    expect(await listPendingWorktrees({ git, cloneRoot: preview })).toEqual([])
  })

  test('a bare repository is not a worktree anybody authored in', async () => {
    const { git } = fakeGit({
      'worktree list --porcelain': listing(main, 'worktree /w/bare\nbare'),
    })
    expect(await listPendingWorktrees({ git, cloneRoot: CLONE })).toEqual([])
  })

  test('a detached worktree is listed by the commit it is on', async () => {
    const head = '3333333333333333333333333333333333333333'
    const { git } = fakeGit({
      'worktree list --porcelain': listing(main, `worktree /w/detached\nHEAD ${head}\ndetached`),
      [`rev-list --count HEAD..${head}`]: '1\n',
      [`diff --name-only -z HEAD...${head}`]: 'README.md\0',
    })

    const [entry] = await listPendingWorktrees({ git, cloneRoot: CLONE })
    expect(entry?.branch).toBeNull()
    expect(entry?.commits).toBe(1)
  })
})

describe('what an entry says about the Fence', () => {
  test('a worktree that changed the host is Fence', async () => {
    const { git } = fakeGit({
      'worktree list --porcelain': listing(main, linked('48')),
      'rev-list --count HEAD..refs/heads/ticket/48': '1\n',
      'diff --name-only -z HEAD...refs/heads/ticket/48':
        'packages/core/src/App.tsx\0src-tauri/src/bridge.rs\0',
    })

    const [entry] = await listPendingWorktrees({ git, cloneRoot: CLONE })
    expect(entry?.touchesFence).toBe(true)
  })

  test('a worktree that changed Core but not the Fence is not', async () => {
    const { git } = fakeGit({
      'worktree list --porcelain': listing(main, linked('50')),
      'rev-list --count HEAD..refs/heads/ticket/50': '2\n',
      'diff --name-only -z HEAD...refs/heads/ticket/50':
        'packages/core/src/App.tsx\0vite.config.ts\0',
    })

    const [entry] = await listPendingWorktrees({ git, cloneRoot: CLONE })
    expect(entry?.touchesFence).toBe(false)
  })
})

describe('what an entry carries, and what it deliberately does not', () => {
  test('names, counts and one flag — no hunks', async () => {
    /*
      The decision this ticket had to make, asserted rather than described.

      An entry is a summary: which branch, where it is, how far ahead, which
      paths changed, and whether any of them is Fence. The hunks are ticket 50's,
      fetched for the one worktree a developer opened. A list that read every
      diff of every branch to draw a row would spend the whole of a large branch
      before showing anything, and a list is the thing you look at to decide
      which branch to open.
    */
    const { git } = fakeGit({
      'worktree list --porcelain': listing(main, linked('49')),
      'rev-list --count HEAD..refs/heads/ticket/49': '3\n',
      'diff --name-only -z HEAD...refs/heads/ticket/49': 'packages/core/src/domain.ts\0',
    })

    const [entry] = await listPendingWorktrees({ git, cloneRoot: CLONE })
    expect(Object.keys(entry ?? {}).sort()).toEqual([
      'branch',
      'changed',
      'commits',
      'path',
      'touchesFence',
    ])
  })

  test('nothing but the paths is read out of the diff', async () => {
    // `--name-only` is the whole of the request. The assertion is on the argv
    // rather than on the answer, because the cost is paid when git runs.
    const { git, asked } = fakeGit({
      'worktree list --porcelain': listing(main, linked('49')),
      'rev-list --count HEAD..refs/heads/ticket/49': '1\n',
      'diff --name-only -z HEAD...refs/heads/ticket/49': 'README.md\0',
    })

    await listPendingWorktrees({ git, cloneRoot: CLONE })
    expect(asked.every((args) => args.includes('--name-only') || !args.includes('diff'))).toBe(true)
  })

  test('every command asked of git only reads', async () => {
    /*
      This module runs git on the developer's own clone, host-side and
      unconfined. The list of subcommands it may use is short and closed: a
      `checkout`, a `merge` or a `fetch` reaching this path would make a read-only
      review surface into something that changes the tree it is describing.
    */
    const { git, asked } = fakeGit({
      'worktree list --porcelain': listing(main, linked('49')),
      'rev-list --count HEAD..refs/heads/ticket/49': '2\n',
      'diff --name-only -z HEAD...refs/heads/ticket/49': 'README.md\0',
    })

    await listPendingWorktrees({ git, cloneRoot: CLONE })
    expect(asked.length).toBeGreaterThan(0)
    for (const args of asked) {
      expect(['worktree', 'rev-list', 'diff']).toContain(args[0] ?? '')
    }
  })

  test('an empty diff is an empty list of paths, not one empty path', async () => {
    // `-z` terminates every entry, so a naive split leaves a trailing empty
    // string — which would be classified, rendered, and counted as a file.
    const { git } = fakeGit({
      'worktree list --porcelain': listing(main, linked('49')),
      'rev-list --count HEAD..refs/heads/ticket/49': '1\n',
      'diff --name-only -z HEAD...refs/heads/ticket/49': '',
    })

    const [entry] = await listPendingWorktrees({ git, cloneRoot: CLONE })
    expect(entry?.changed).toEqual([])
  })
})

/*
  The hunks, for the one worktree a developer opened.

  The summary above is what a list is read for; this is what is read after
  choosing one. Everything in this block is about the same property, stated two
  ways: the diff is git's, and the only thing the caller decides is *which* of
  the worktrees git already reported it wants. A path is compared against that
  listing and is never an argument — so there is no version of this where a name
  the renderer composed selects what git is asked about.
*/
describe('the diff of one pending worktree', () => {
  const HUNKS = [
    'diff --git a/src-tauri/src/bridge.rs b/src-tauri/src/bridge.rs',
    '@@ -1,2 +1,2 @@',
    '-let denied = false;',
    '+let denied = true;',
    '',
  ].join('\n')

  const opened = (name: string) => `${CLONE}/.claude/worktrees/${name}`

  test("is git's own, for the ref git itself named", async () => {
    const { git } = fakeGit({
      'worktree list --porcelain': listing(main, linked('48')),
      'rev-list --count HEAD..refs/heads/ticket/48': '1\n',
      'diff --no-color HEAD...refs/heads/ticket/48': HUNKS,
    })

    expect(await readPendingWorktreeDiff({ git, cloneRoot: CLONE, path: opened('48') })).toBe(HUNKS)
  })

  test('the three dots are the branch since it diverged, not two trees compared', async () => {
    /*
      The same range the name list uses, and it has to be: a worktree branched a
      week ago is not responsible for what the live tree did in the meantime, and
      a two-dot diff would show the developer their own merged work as though
      the agent had proposed it.
    */
    const { git, asked } = fakeGit({
      'worktree list --porcelain': listing(main, linked('48')),
      'rev-list --count HEAD..refs/heads/ticket/48': '1\n',
      'diff --no-color HEAD...refs/heads/ticket/48': HUNKS,
    })

    await readPendingWorktreeDiff({ git, cloneRoot: CLONE, path: opened('48') })
    expect(asked.some((args) => args.includes('HEAD...refs/heads/ticket/48'))).toBe(true)
    expect(asked.some((args) => args.includes('HEAD..refs/heads/ticket/48'))).toBe(true)
  })

  test('a path nobody listed is refused, and never reaches git', async () => {
    /*
      The refusal that matters. This is the one call on the review path that
      takes an argument from the renderer, so the argument is a *selector*
      against git's own listing rather than something git is handed. A path that
      matches no entry produces no diff command at all — which is what makes
      `../../..`, a sibling clone, or anything else composed elsewhere unable to
      choose what is read.
    */
    const invented = '/Users/dev/code/other-project'
    const { git, asked } = fakeGit({ 'worktree list --porcelain': listing(main, linked('48')) })

    await expect(
      readPendingWorktreeDiff({ git, cloneRoot: CLONE, path: invented }),
    ).rejects.toThrow(/not a worktree/i)

    for (const args of asked) {
      for (const arg of args) expect(arg).not.toContain(invented)
    }
  })

  test('the main worktree cannot be opened, because it is what everything is measured against', async () => {
    const { git } = fakeGit({ 'worktree list --porcelain': listing(main, linked('48')) })
    await expect(readPendingWorktreeDiff({ git, cloneRoot: CLONE, path: CLONE })).rejects.toThrow(
      /not a worktree/i,
    )
  })

  test('and neither can the tree varnick is running from', async () => {
    // A Preview runs from a worktree. Opening its own tree would be varnick
    // offering to review the code it is running.
    const preview = opened('48')
    const { git } = fakeGit({ 'worktree list --porcelain': listing(main, linked('48')) })
    await expect(
      readPendingWorktreeDiff({ git, cloneRoot: preview, path: preview }),
    ).rejects.toThrow(/not a worktree/i)
  })

  test('a worktree with no commits yet has no diff to open', async () => {
    // The same rule the list follows: an agent that has started is not an agent
    // that has finished, and it is left out rather than opened onto nothing.
    const { git, asked } = fakeGit({
      'worktree list --porcelain': listing(main, linked('48')),
      'rev-list --count HEAD..refs/heads/ticket/48': '0\n',
    })

    await expect(
      readPendingWorktreeDiff({ git, cloneRoot: CLONE, path: opened('48') }),
    ).rejects.toThrow(/not a worktree/i)
    expect(asked.some((args) => args[0] === 'diff')).toBe(false)
  })

  test('a git that fails rejects, carrying what it said', async () => {
    const git: GitRunner = async () => {
      throw new Error('fatal: bad revision')
    }
    await expect(
      readPendingWorktreeDiff({ git, cloneRoot: CLONE, path: opened('48') }),
    ).rejects.toThrow('fatal: bad revision')
  })

  test('every command asked of git only reads', async () => {
    const { git, asked } = fakeGit({
      'worktree list --porcelain': listing(main, linked('48')),
      'rev-list --count HEAD..refs/heads/ticket/48': '1\n',
      'diff --no-color HEAD...refs/heads/ticket/48': HUNKS,
    })

    await readPendingWorktreeDiff({ git, cloneRoot: CLONE, path: opened('48') })
    expect(asked.length).toBeGreaterThan(0)
    for (const args of asked) {
      expect(['worktree', 'rev-list', 'diff']).toContain(args[0] ?? '')
    }
  })

  test('colour is refused, so what crosses is text rather than terminal escapes', async () => {
    // `color.ui = always` in a developer's own config would otherwise put ANSI
    // sequences through the bridge and into a renderer that draws its own
    // colours — and the one colour in that view means Fence.
    const { git, asked } = fakeGit({
      'worktree list --porcelain': listing(main, linked('48')),
      'rev-list --count HEAD..refs/heads/ticket/48': '1\n',
      'diff --no-color HEAD...refs/heads/ticket/48': HUNKS,
    })

    await readPendingWorktreeDiff({ git, cloneRoot: CLONE, path: opened('48') })
    expect(asked.find((args) => args[0] === 'diff')).toContain('--no-color')
  })

  test('a detached worktree is opened by the commit it is on', async () => {
    const head = '3333333333333333333333333333333333333333'
    const { git } = fakeGit({
      'worktree list --porcelain': listing(main, `worktree /w/detached\nHEAD ${head}\ndetached`),
      [`rev-list --count HEAD..${head}`]: '1\n',
      [`diff --no-color HEAD...${head}`]: HUNKS,
    })

    expect(await readPendingWorktreeDiff({ git, cloneRoot: CLONE, path: '/w/detached' })).toBe(HUNKS)
  })

  test('a diff with nothing in it is an empty diff, not a refusal', async () => {
    // A branch that is ahead by a commit that changed nothing tracked. Rare and
    // real; the surface says the file list is empty rather than that the read
    // failed.
    const { git } = fakeGit({
      'worktree list --porcelain': listing(main, linked('48')),
      'rev-list --count HEAD..refs/heads/ticket/48': '1\n',
      'diff --no-color HEAD...refs/heads/ticket/48': '',
    })

    expect(await readPendingWorktreeDiff({ git, cloneRoot: CLONE, path: opened('48') })).toBe('')
  })
})
