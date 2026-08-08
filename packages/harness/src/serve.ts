#!/usr/bin/env bun
/**
 * The Harness runtime, as a process.
 *
 * Started by the Tauri host (src-tauri/src/bridge.rs) and spoken to over stdio.
 * Deliberately five lines: everything worth testing is in ./runtime.ts, tested
 * one line in and one line out, and nothing that needs a real stdin belongs
 * above that seam.
 *
 * stdout is the wire. Anything that writes to it that is not a reply
 * desynchronises the pipe, so diagnostics go to stderr, which the host inherits.
 */

import { serveHarness } from './runtime.ts'

await serveHarness(process.stdin, (reply) => process.stdout.write(reply))
