// Varnick's text helper (docs/problems/text-generation-ignores-the-claude-subscription/options/01-*.md).
//
// Reads requests from standard input, one JSON line each, until it closes; answers each in JSON lines on standard output:
// `text` for every piece as it is written, then one `result`. Nothing else is written to standard output, and nothing of a
// prompt, a reply or the account to standard error. Varnick decides everything that varies (the prompt, the model, the
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

/** No `claude` may outlive a request that was cancelled, timed out or failed: killed outright, not asked to wind down. */
function killChildren(): void {
  for (const child of children) child.kill('SIGKILL')
}
process.on('exit', killChildren)

// Varnick sends SIGTERM when a request is cancelled or passes its deadline, and kills this process a second later.
process.on('SIGTERM', () => {
  killChildren()
  for (const controller of controllers) controller.abort()
  setTimeout(() => process.exit(143), 100)
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

async function answer(request: Request): Promise<void> {
  const hooksFile = `${request.filter}/hooks/hooks.json`
  // `claude` skips a plugin path that does not exist with only a log line and runs without the filter, which would quietly
  // send every reminder again.
  if (!existsSync(hooksFile)) return emit({ type: 'result', ok: false, kind: 'filter missing' })

  const abortController = new AbortController()
  controllers.add(abortController)
  let failure: Failure | undefined
  let firstTokenMs: number | undefined
  let reported: { durationMs?: number; apiMs?: number } = {}
  try {
    const outcome = await run(
      request.prompt,
      {
        // Effort low is what stops Haiku 5.5 thinking: `thinking: disabled`, which minimalOptions() also sets, is accepted and ignored.
        ...minimalOptions({ model: request.model, effort: 'low', abortController }),
        pathToClaudeCodeExecutable: request.claude,
        persistSession: false,
        includePartialMessages: true,
        cwd: request.cwd,
        // The SDK's own spawn, except that the child is known here, so it can be ended at once. Its standard error goes nowhere.
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
          } else if (message.type === 'assistant' && message.error) {
            failure ??= { kind: message.error }
          } else if (message.type === 'system' && message.subtype === 'api_retry' && isLoginError(message.error, message.error_status)) {
            // A login that does not work retries for minutes, far past Varnick's deadline: end it now, so Gemma answers sooner.
            // Any other retry (overloaded, a server error, a rate limit) goes on under the deadline.
            failure ??= { kind: `retrying: ${message.error}` }
            killChildren()
            abortController.abort()
          } else if (message.type === 'result') {
            reported = { durationMs: message.duration_ms, apiMs: message.duration_api_ms }
          }
        },
      },
    )
    if (failure) return emit({ type: 'result', ok: false, ...failure, stopReason: outcome.stopReason })
    if (outcome.isError) return emit({ type: 'result', ok: false, kind: 'error result', stopReason: outcome.stopReason })
    emit({ type: 'result', ok: true, text: outcome.text, firstTokenMs, ...reported, stopReason: outcome.stopReason })
  } catch (error) {
    emit({ type: 'result', ok: false, ...(failure ?? failureOf(error)) })
  } finally {
    controllers.delete(abortController)
  }
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
  pending.push(answer(request))
})
input.on('close', async () => {
  await Promise.all(pending)
  process.exit(0)
})
