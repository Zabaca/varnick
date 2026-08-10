/**
 * What a stored transcript entry is, and how one is read back.
 *
 * ## Why this is its own module
 *
 * The mirror lives in ./session.ts, which has a filesystem and a `node:crypto`
 * — it is host-side by nature. **These declarations are not.** They describe the
 * shape of a line, and both ends of the wire need them: the runtime writes them,
 * and ./bridge.ts rebuilds them on the way into Core.
 *
 * ./bridge.ts is one of the three Harness entries Core is allowed to import,
 * because it reaches no Node built-in. That is a property of its whole import
 * graph rather than of its own first line, and it stopped being true the moment
 * it imported a parser out of ./session.ts: Vite externalises `node:crypto` for
 * the browser, the webview threw on the first access, and **the window rendered
 * blank** — no chat, no error on screen, nothing but a white rectangle. The
 * failure is far from the cause and says nothing about it.
 *
 * So the pure half lives here, in a leaf that imports nothing at all, and
 * ./session.ts re-exports it for the callers that already had it. Same rule the
 * fence and the turn already follow, and the same reason ADR-0004 gives one
 * level up: what Core can reach must not be able to drag the host in behind it.
 */

/**
 * One tool call, as the mirror stores it.
 *
 * Declared in the Harness rather than in Core because the Harness must not
 * import Core, and structurally what Core calls a tool on a `Message`.
 */
export interface StoredToolCall {
  readonly id: string
  readonly name: string
  readonly argument?: string
  readonly result?: string
  readonly detail?: string
  readonly status: 'pending' | 'success' | 'error'
}

/**
 * Read a tool call back out of whatever was on the line, or `null`.
 *
 * Every field is checked and nothing is reconstructed from a partial record: a
 * half-parsed tool call rendered in a transcript is a claim about what the agent
 * did, and the mirror's whole purpose is to be the copy that can be trusted.
 *
 * `null` rather than a throw, because the caller is reading a file that may have
 * been written by an older build, and one unreadable entry must not cost the
 * transcript around it.
 */
export function parseStoredTool(value: unknown): StoredToolCall | null {
  if (typeof value !== 'object' || value === null) return null
  const { id, name, argument, result, detail, status } = value as Record<string, unknown>
  if (typeof id !== 'string' || id.length === 0) return null
  if (typeof name !== 'string' || name.length === 0) return null
  if (status !== 'pending' && status !== 'success' && status !== 'error') return null
  const optional = (field: unknown): string | undefined =>
    typeof field === 'string' ? field : undefined
  return {
    id,
    name,
    ...(optional(argument) !== undefined ? { argument: optional(argument) as string } : {}),
    ...(optional(result) !== undefined ? { result: optional(result) as string } : {}),
    ...(optional(detail) !== undefined ? { detail: optional(detail) as string } : {}),
    status,
  }
}
