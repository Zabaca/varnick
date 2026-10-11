// Varnick's text helper (docs/problems/text-generation-ignores-the-claude-subscription/options/01-*.md).
//
// Reads requests from standard input, one JSON line each, until it closes; answers each in JSON lines on standard output:
// `ready` once the request is read, `text` for every piece as it is written, then one `result`. Nothing else is written to
// standard output, and nothing of a prompt, a reply or the account to standard error. Varnick decides everything that varies (the prompt, the model, the
// user's `claude`, the reminders filter's folder and the working folder), so this file holds no choices of its own beyond
// `minimalOptions()`.
import type { SpawnedProcess } from '@anthropic-ai/claude-agent-sdk'
import { type ChildProcess, spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { createInterface } from 'node:readline'
import { minimalOptions, run } from '@zabaca/agent'

type Request = { prompt: string; model: string; claude: string; filter: string; cwd: string }

type Failure = { kind: string; stopReason?: string }

const send = process.stdout.write.bind(process.stdout)
const emit = (line: object) => void send(`${JSON.stringify(line)}\n`)
// A library's stray console.log would corrupt the protocol.
console.log = console.info = console.debug = () => {}

const controllers = new Set<AbortController>()
const children = new Set<ChildProcess>()

/** `claude` rewrites shared state (`~/.claude.json`, under a lock) as it starts and stops, so it is asked to stop, not killed. */
const stopGrace = 600

function killChildren(): void {
  for (const child of children) child.kill('SIGKILL')
}
/** No `claude` may outlive a request that was cancelled, timed out or failed: SIGTERM, then SIGKILL for any left after the grace. */
async function stopChildren(): Promise<void> {
  for (const child of children) child.kill('SIGTERM')
  const until = Date.now() + stopGrace
  while (children.size > 0 && Date.now() < until) await new Promise((resolve) => setTimeout(resolve, 20))
  killChildren()
}
// The last resort, when this process goes without having stopped them.
process.on('exit', killChildren)

// Varnick sends SIGTERM when a request is cancelled or passes its deadline, and kills this process a second later.
process.on('SIGTERM', () => {
  for (const controller of controllers) controller.abort()
  void stopChildren().then(() => process.exit(143))
})

/** What went wrong, as a kind that is safe to log: never the SDK's message, which can hold what was said. */
function failureOf(error: unknown): Failure {
  const text = error instanceof Error ? `${error.name} ${error.message}` : ''
  if (/not found|ENOENT|EACCES|spawn/i.test(text)) return { kind: 'claude did not start' }
  if (/abort/i.test(text)) return { kind: 'aborted' }
  return { kind: 'error' }
}

/** Whether a retrying request is retrying a login or an account that will not work, however many times it tries. */
function isLoginError(error: string, status: number | null): boolean {
  return ['authentication_failed', 'oauth_org_not_allowed', 'billing_error'].includes(error) || status === 401 || status === 403
}

/** Runs that have sent their result and may still be shutting `claude` down. */
const winding: Promise<unknown>[] = []

async function answer(request: Request): Promise<void> {
  const hooksFile = `${request.filter}/hooks/hooks.json`
  // `claude` skips a plugin path that does not exist with only a log line and runs without the filter, which would quietly
  // send every reminder again.
  if (!existsSync(hooksFile)) return emit({ type: 'result', ok: false, kind: 'filter missing' })

  const abortController = new AbortController()
  controllers.add(abortController)
  let failure: Failure | undefined
  let text = ''
  let firstTokenMs: number | undefined
  let settled = false
  let settle!: () => void
  const finished = new Promise<void>((resolve) => (settle = resolve))
  /** The one `result` of a request, sent the moment it is known: `claude` shutting down is no part of the answer or its deadline. */
  const finish = (line: object) => {
    if (settled) return
    settled = true
    emit({ type: 'result', ...line })
    settle()
  }

  const running = run(
    request.prompt,
    {
      // Effort low is what stops Haiku 5.5 thinking: `thinking: disabled`, which minimalOptions() also sets, is accepted and ignored.
      ...minimalOptions({ model: request.model, effort: 'low', abortController }),
      pathToClaudeCodeExecutable: request.claude,
      persistSession: false,
      includePartialMessages: true,
      cwd: request.cwd,
      // The SDK's own spawn, except that the child is known here, so it can be stopped. Its standard error goes nowhere.
      spawnClaudeCodeProcess: ({ command, args, cwd, env, signal }) => {
        const child = spawn(command, args, { cwd, env, signal, stdio: ['pipe', 'pipe', 'ignore'] })
        children.add(child)
        child.once('exit', () => children.delete(child))
        return child as unknown as SpawnedProcess
      },
      // Varnick's folder replaces the package's own, which is worked out from where this file sits.
      plugins: [{ type: 'local', path: request.filter }],
    },
    {
      onMessage(message) {
        if (message.type === 'stream_event') {
          const event = message.event
          if (event.type === 'content_block_delta' && event.delta.type === 'text_delta') {
            emit({ type: 'text', text: event.delta.text })
          }
          if (message.ttft_ms !== undefined) firstTokenMs = message.ttft_ms
        } else if (message.type === 'assistant') {
          if (message.error) failure ??= { kind: message.error }
          for (const block of message.message?.content ?? []) if (block.type === 'text') text += block.text
        } else if (message.type === 'system' && message.subtype === 'api_retry' && isLoginError(message.error, message.error_status)) {
          // A login that does not work retries for minutes, far past Varnick's deadline: end it now, so Gemma answers sooner.
          // Any other retry (overloaded, a server error, a rate limit) goes on under the deadline.
          failure ??= { kind: `retrying: ${message.error}` }
          finish({ ok: false, ...failure })
          void stopChildren()
          abortController.abort()
        } else if (message.type === 'result') {
          if (failure) finish({ ok: false, ...failure, stopReason: message.subtype })
          else if (message.is_error || message.subtype !== 'success') finish({ ok: false, kind: 'error result', stopReason: message.subtype })
          else {
            finish({ ok: true, text: text.trim(), firstTokenMs, durationMs: message.duration_ms, apiMs: message.duration_api_ms, stopReason: message.subtype })
          }
        }
      },
    },
  ).then(
    // The stream ended with no result message.
    (outcome) => finish({ ok: false, ...(failure ?? { kind: 'no result' }), stopReason: outcome.stopReason }),
    (error) => finish({ ok: false, ...(failure ?? failureOf(error)) }),
  )
  winding.push(running.finally(() => controllers.delete(abortController)))
  await finished
}

const pending: Promise<void>[] = []
const input = createInterface({ input: process.stdin })
input.on('line', (line) => {
  if (!line.trim()) return
  let request: Request
  try {
    request = JSON.parse(line)
    if (![request.prompt, request.model, request.claude, request.filter, request.cwd].every((v) => typeof v === 'string' && v)) {
      throw new Error('incomplete')
    }
  } catch {
    return emit({ type: 'result', ok: false, kind: 'bad request' })
  }
  // The request is read: what is left until this line is Bun's start and the load of this file.
  emit({ type: 'ready' })
  pending.push(answer(request))
})
input.on('close', async () => {
  await Promise.all(pending)
  // `claude` ends by itself once its input closes; what is still running after a moment is stopped.
  await Promise.race([Promise.allSettled(winding), new Promise((resolve) => setTimeout(resolve, 400))])
  await stopChildren()
  process.exit(0)
})
