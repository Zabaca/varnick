import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { ORPHAN_CHECK_MS, orphaned, watchForOrphaning } from './orphan.ts'

/*
  Nothing here starts a process, and that is the rule rather than a convenience.
  This module exists because processes outlived their reason to run; a test that
  spawned some to watch them die would be the same mistake with a stopwatch.

  The clock is injected, so the whole of a watch runs in one synchronous pass.
*/

/** Run the watch against a scripted sequence of parent pids. */
function play(pids: readonly number[]) {
  const seen: number[] = []
  let ended = false
  const teardowns: number[] = []
  let pending: (() => void) | null = null
  let index = 0

  watchForOrphaning({
    parentPid: () => {
      const pid = pids[Math.min(index, pids.length - 1)] ?? 1
      seen.push(pid)
      index += 1
      return pid
    },
    teardown: () => {
      teardowns.push(1)
    },
    exit: () => {
      ended = true
    },
    schedule: (run) => {
      pending = run
      return 0
    },
  })

  return {
    seen,
    get ended() {
      return ended
    },
    get teardowns() {
      return teardowns.length
    },
    tick: async () => {
      const run = pending
      pending = null
      run?.()
      // The teardown may be a promise; let it settle before anything is asserted.
      await Promise.resolve()
      await Promise.resolve()
    },
  }
}

describe('an orphan is a process whose parent has gone', () => {
  test('init is the parent of an orphan, and of nothing else', () => {
    expect(orphaned(1)).toBe(true)
    expect(orphaned(4242)).toBe(false)
  })

  test('no parent at all is not an orphan', () => {
    // Nothing started this process, so nothing has left it. Reading `0` as
    // orphaned would make a runtime started by hand kill itself on its first
    // tick.
    expect(orphaned(0)).toBe(false)
  })
})

describe('what the watch does about it', () => {
  test('a live parent is checked again rather than acted on', async () => {
    const run = play([900, 900, 900])
    await run.tick()
    await run.tick()
    expect(run.teardowns).toBe(0)
    expect(run.ended).toBe(false)
    expect(run.seen.length).toBe(2)
  })

  test('a parent that goes takes this process with it', async () => {
    const run = play([900, 1])
    await run.tick()
    expect(run.ended).toBe(false)
    await run.tick()
    expect(run.teardowns).toBe(1)
    expect(run.ended).toBe(true)
  })

  test('the teardown runs once, however many times the timer fires', async () => {
    const run = play([1])
    await run.tick()
    await run.tick()
    await run.tick()
    expect(run.teardowns).toBe(1)
  })

  test('a teardown that throws still ends the process', async () => {
    // The whole job is to stop a process outliving its reason to run. A release
    // that failed is a reason to exit anyway, not a reason to stay.
    let ended = false
    const scheduled: (() => void)[] = []
    watchForOrphaning({
      parentPid: () => 1,
      teardown: () => {
        throw new Error('the sandbox would not release')
      },
      exit: () => {
        ended = true
      },
      schedule: (run) => {
        scheduled.push(run)
        return 0
      },
    })
    scheduled.shift()?.()
    await Promise.resolve()
    await Promise.resolve()
    expect(ended).toBe(true)
  })

  test('the interval is a constant rather than a number in two files', () => {
    expect(ORPHAN_CHECK_MS).toBeGreaterThan(0)
  })
})

describe('both processes that can be orphaned are watching', () => {
  /*
    Read from the files rather than exercised, because exercising them means
    starting them: `serve.ts` opens a Sandbox and `agent.ts` starts a Claude Code
    process, which is the one thing ADR-0003 says never happens in a test.

    Asserted at all because the watch is the only layer that survives a `kill
    -9`, and an entry point that quietly stopped calling it would leak exactly
    the processes this exists to stop leaking — silently, and only on the exits
    nobody tests.
  */
  const source = (name: string) => readFileSync(new URL(name, import.meta.url), 'utf8')

  test('the runtime watches, and releases the Sandbox when it goes', () => {
    const serve = source('./serve.ts')
    expect(serve).toContain('watchForOrphaning')
    expect(serve).toContain('releaseSandbox')
  })

  test('the agent host watches, and takes its whole group with it', () => {
    const agent = source('./agent.ts')
    expect(agent).toContain('watchForOrphaning')
    // The group, not this process. The tree is the wrapper, sandbox-exec, this
    // host and Claude Code; killing only this one strands the rest.
    expect(agent).toContain("process.kill(0, 'SIGKILL')")
  })
})
