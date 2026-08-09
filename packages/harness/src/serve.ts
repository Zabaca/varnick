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
 * ## The one argument
 *
 *     bun packages/harness/src/serve.ts <clone-root>
 *
 * The clone the agent works in, resolved by the host from `VARNICK_CLONE_ROOT`
 * or from the path varnick was built at, and passed here explicitly. It is
 * deliberately *not* taken from the working directory, even though the host
 * still sets one: that inheritance is what ticket 28 removed. A runtime started
 * without it refuses and says how to start it, rather than quietly adopting
 * `process.cwd()` — see ./clone-root.ts.
 *
 * A refusal here goes to stderr and exits non-zero. It cannot be a reply,
 * because it happens before any call has been read and there is no id to
 * address an answer to; the host sees the process end and reports `no-runtime`.
 */

import { cloneRootFromLaunch } from './clone-root.ts'
import { hostCapabilities, serveHarness } from './runtime.ts'

let cloneRoot: string
try {
  cloneRoot = cloneRootFromLaunch(process.argv[2])
} catch (error) {
  process.stderr.write(`varnick: ${error instanceof Error ? error.message : String(error)}\n`)
  process.exit(2)
}

await serveHarness(process.stdin, (reply) => process.stdout.write(reply), hostCapabilities({ cloneRoot }))
