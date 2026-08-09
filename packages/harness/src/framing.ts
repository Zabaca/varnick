/**
 * The framing on varnick's stdio pipes.
 *
 * One JSON document per line, on both of them: the Rust host to the Harness
 * runtime (./runtime.ts, src-tauri/src/bridge.rs) and the Rust host to the agent
 * host inside the Sandbox (./agent.ts, src-tauri/src/agent.rs). `JSON.stringify`
 * and `serde_json` both escape newlines, so nothing inside a message can split
 * it across two lines — that is what makes "one per line" a framing rather than
 * a hope, and it is load-bearing: a reader that loses its place answers one call
 * with another call's reply.
 *
 * This reader existed twice, character for character, once in each of the two
 * modules above. Neither process can test the other, so a fix to one would
 * silently not have reached the other — which is the whole reason it is one
 * function now. It reaches no Node built-in, holds no state between calls and
 * knows nothing about either protocol; what a line means is the caller's.
 */

/**
 * Read newline-delimited lines out of a stream of chunks.
 *
 * Chunks are not lines. A write is delivered in whatever pieces the pipe felt
 * like, so a request can arrive in two chunks and two requests can arrive in
 * one — the buffer is what makes the difference invisible to the caller.
 *
 * `onLine` is awaited before the next line is read, so lines are handled in
 * order and one at a time. Both callers need that: the runtime holds a Sandbox
 * two callers must not race to establish, and the agent host's control channel
 * decides against state a previous line may have changed.
 */
export async function readLines(
  input: AsyncIterable<Uint8Array | string>,
  onLine: (line: string) => Promise<void>,
): Promise<void> {
  const decoder = new TextDecoder()
  let pending = ''

  for await (const chunk of input) {
    pending += typeof chunk === 'string' ? chunk : decoder.decode(chunk, { stream: true })

    let newline = pending.indexOf('\n')
    while (newline !== -1) {
      const line = pending.slice(0, newline)
      pending = pending.slice(newline + 1)
      // Blank is not a message. A writer that flushes a newline of its own, or
      // a stream that ends in one, would otherwise deliver an empty line to a
      // parser that has to answer "malformed" to it.
      if (line.trim().length > 0) await onLine(line)
      newline = pending.indexOf('\n')
    }
  }

  // A last line with no newline after it. The stream ending is the only thing
  // that could terminate it, and dropping it would lose a whole call.
  if (pending.trim().length > 0) await onLine(pending)
}
