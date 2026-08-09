/*
  Noticing that the process that started us is gone.

  **The only layer of the shutdown story that survives a `kill -9`.** varnick
  now tears its children down on ⌘Q and on SIGTERM, and neither of those can
  help with a SIGKILL or a crash: the host is simply not there any more, and
  nothing it registered ever runs. What was measured before any of this existed
  was fifteen orphaned harness processes on one machine, the oldest five and a
  half hours old, several still holding live Claude Code processes — because
  every development restart went through a signal the host did not handle.

  So the children watch instead. On Unix an orphan is reparented to init, which
  means `process.ppid` becomes 1 and stays there — a fact about the process
  table rather than a message anyone has to remember to send, and therefore the
  one signal that cannot be skipped by the way the parent died.

  Polled rather than pushed, because there is nothing to push: the parent is
  gone. A second is far below the cost of noticing, and far above the rate at
  which a parent can die twice.
*/

/** How often to look, when nobody says otherwise. */
export const ORPHAN_CHECK_MS = 1_000

/**
 * Whether this process has outlived whoever started it.
 *
 * `1` is init. Deliberately not "the pid I was started by has gone", which
 * needs a pid to have been recorded at start-up and is wrong in the one case it
 * matters: a pid can be reused, and a watcher comparing against a stale one
 * would either miss a death or invent one.
 *
 * A pid of `0` — which is what a platform without parents reports — is not
 * orphaned. Nothing started us, so nothing has left.
 */
export function orphaned(parentPid: number): boolean {
  return parentPid === 1
}

export interface OrphanWatch {
  /** Asked each tick. `process.ppid` in a real run. */
  readonly parentPid: () => number
  /** Run once, when the parent has gone. Awaited before the process ends. */
  readonly teardown: () => void | Promise<void>
  /** Called after teardown. `process.exit` in a real run. */
  readonly exit: () => void
  /** Milliseconds between checks. */
  readonly every?: number
  /** Schedules the next check. Injected so a test needs no real clock. */
  readonly schedule?: (run: () => void, ms: number) => unknown
}

/**
 * Watch until the parent dies, then tear down and go.
 *
 * Everything is injected because the alternative is a test that spawns
 * processes to observe an exit — and this module exists to stop processes
 * outliving their reason to run, so it is the last place to be casual about
 * starting more.
 *
 * Teardown runs exactly once even if the timer fires again while it is still
 * running: it is a kill and a release, and doing either twice is at best noise.
 */
export function watchForOrphaning(watch: OrphanWatch): void {
  const every = watch.every ?? ORPHAN_CHECK_MS
  const schedule =
    watch.schedule ??
    ((run, ms) => {
      const timer = setTimeout(run, ms)
      // Node keeps the event loop alive for a pending timer, which would hold
      // a runtime open that had otherwise finished. This watch is a background
      // condition, not a reason to stay.
      ;(timer as { unref?: () => void }).unref?.()
      return timer
    })

  let going = false
  const tick = () => {
    if (going) return
    if (!orphaned(watch.parentPid())) {
      schedule(tick, every)
      return
    }
    going = true
    void (async () => {
      try {
        await watch.teardown()
      } catch {
        // Nothing can be reported to a parent that is gone, and a teardown that
        // threw must still end the process — that is the whole point of it.
      }
      watch.exit()
    })()
  }

  schedule(tick, every)
}
