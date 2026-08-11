#!/usr/bin/env bun
/**
 * The Harness runtime, as a process.
 *
 * Started by the Tauri host (src-tauri/src/bridge.rs) and spoken to over stdio.
 * Deliberately small: everything worth testing is in ./runtime.ts, tested one
 * line in and one line out, and nothing that needs a real stdin belongs above
 * that seam.
 *
 * stdout is the wire. Anything that writes to it that is not a reply
 * desynchronises the pipe, so diagnostics go to stderr, which the host inherits.
 *
 * ## The arguments
 *
 *     bun packages/harness/src/serve.ts <clone-root> [policy-root]
 *
 * The clone the agent works in, resolved by the host from `VARNICK_CLONE_ROOT`
 * or from the path varnick was built at, and passed here explicitly. It is
 * deliberately *not* taken from the working directory, even though the host
 * still sets one: that inheritance is what ticket 28 removed. A runtime started
 * without it refuses and says how to start it, rather than quietly adopting
 * `process.cwd()` — see ./clone-root.ts.
 *
 * The second is whose policy confines the agent, and it is absent from every
 * launch but one: a **Preview**, which works in a Worktree and is fenced by the
 * live tree. Absent means "this clone's own", which is what every varnick a
 * developer starts gets. It is checked in ./clone-root.ts and read in
 * ./sandbox.ts; nothing here interprets it, for the reason nothing here
 * interprets the first.
 *
 * A refusal here goes to stderr and exits non-zero. It cannot be a reply,
 * because it happens before any call has been read and there is no id to
 * address an answer to; the host sees the process end and reports `no-runtime`.
 */

import { cloneRootFromLaunch } from './clone-root.ts'
import { watchForOrphaning } from './orphan.ts'
import { hostCapabilities, serveHarness } from './runtime.ts'
import { releaseSandbox } from './sandbox.ts'

let cloneRoot: string
try {
  cloneRoot = cloneRootFromLaunch(process.argv[2])
} catch (error) {
  process.stderr.write(`varnick: ${error instanceof Error ? error.message : String(error)}\n`)
  process.exit(2)
}

/*
  Go when the host goes, however it went.

  This runtime holds the Sandbox, and the Sandbox is not only this process: srt
  runs proxies, and the violation monitor is a `log stream` child. Exiting
  without `releaseSandbox` leaves those behind even when the runtime itself
  ends, which is why the teardown is a call rather than a bare exit.

  The host closes stdin on a clean shutdown and this would end anyway. What this
  covers is the other exits — a SIGKILL, a crash, a debugger stop — where
  nothing the host registered ever runs and the pipe is simply never closed.
*/
watchForOrphaning({
  parentPid: () => process.ppid,
  teardown: () => releaseSandbox(),
  exit: () => process.exit(0),
})

/*
  stderr, for the reason the header gives: stdout is the wire. The host inherits
  this, so a developer running `bun run dev:app` sees every act the runtime
  performs, in order, with what it said when one failed.

  Added after a merge that wrote nothing left nothing to read — see `traceLine`.
*/
await serveHarness(
  process.stdin,
  (reply) => process.stdout.write(reply),
  hostCapabilities({ cloneRoot, policyRoot: process.argv[3] }),
  (line) => process.stderr.write(line),
)
