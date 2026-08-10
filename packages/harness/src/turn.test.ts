import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import {
  TURN_FAILURES,
  beginTurn,
  contextTokens,
  encodeTurnEvent,
  isCredentialRejection,
  parseControlRequest,
  parseTurnEvent,
  runtimeReportFrom,
  toolCallLine,
  hookFailureLine,
  turnFailureMessage,
  isUnpromptedTurn,
  unpromptedCauseOf,
  beginsAnAnswer,
  UNPROMPTED_TURN_PREFIX,
  UNPROMPTED_CAUSE_UNKNOWN,
  type RuntimeReport,
  type TurnEvent,
} from './turn.ts'
/*
  The one import here that is not the seam under test, and it is the other half
  of the same fact: `credentialSource` is measured in the agent host and carried
  by the report, so a test of the report that could not ask what the measurement
  answers would pin the wire and leave the reading unpinned. ./agent.ts reaches
  Node and the SDK, which is fine for a test file and is exactly why ./turn.ts
  itself must never import it — see the module note there.
*/
import { observedCredentialVariable } from './agent.ts'

/*
  The seam: what a Turn makes of the messages a Session hands it.

  Nothing here opens an Agent SDK session. It cannot — `beginTurn` takes
  messages, one at a time, and knows nothing about where they came from. That is
  the point rather than a testing convenience: a test that opened a session would
  put a Claude Code process on this machine outside srt, which is the one thing
  ADR-0003 says never happens.
*/

/*
  Assembled rather than written out: the value is invented, but its shape is one
  every secret scanner flags, and a literal of that shape blocks pushing for this
  repository and every fork of it.
*/
const LOOKS_LIKE_A_KEY = ['sk-', 'ant-api03-NEVER-LET-THIS-OUT'].join('')

const textDelta = (text: string) => ({
  type: 'stream_event',
  event: { type: 'content_block_delta', delta: { type: 'text_delta', text } },
})

const usage = {
  input_tokens: 1200,
  output_tokens: 340,
  cache_read_input_tokens: 8000,
  cache_creation_input_tokens: 100,
}

const success = (result: string) => ({
  type: 'result',
  subtype: 'success',
  is_error: false,
  result,
  usage,
})

/** Drive a whole turn and collect everything it said. */
function play(messages: readonly unknown[], turnId = 't1'): TurnEvent[] {
  const run = beginTurn(turnId)
  const events: TurnEvent[] = []
  for (const message of messages) {
    events.push(...run.accept(message))
    if (run.finished) break
  }
  return events
}

describe('an answer arrives in pieces', () => {
  test('each text delta is its own event, so working is distinguishable from hung', () => {
    const events = play([textDelta('Hel'), textDelta('lo'), success('Hello')])
    expect(events.slice(0, 2)).toEqual([
      { kind: 'delta', turnId: 't1', text: 'Hel' },
      { kind: 'delta', turnId: 't1', text: 'lo' },
    ])
  })

  test('every event carries the turn it belongs to', () => {
    // Without this an event left over from an interrupted Turn would be read as
    // the next Turn's first word.
    const events = play([textDelta('late')], 't7')
    expect(events).toEqual([{ kind: 'delta', turnId: 't7', text: 'late' }])
  })

  test('thinking is not an answer, so it is not streamed as one', () => {
    const thinking = {
      type: 'stream_event',
      event: { type: 'content_block_delta', delta: { type: 'thinking_delta', thinking: 'hmm' } },
    }
    expect(play([thinking, success('done')]).filter((e) => e.kind === 'delta')).toEqual([])
  })

  test('the completed assistant message does not repeat what already streamed', () => {
    // The SDK sends both the deltas and the assembled message. Counting both
    // would double every answer.
    const assembled = {
      type: 'assistant',
      message: { content: [{ type: 'text', text: 'Hello' }] },
    }
    const events = play([textDelta('Hello'), assembled, success('Hello')])
    expect(events.filter((e) => e.kind === 'delta')).toHaveLength(1)
  })
})

describe('tool calls are the audit trail', () => {
  test('a tool call is announced as it happens', () => {
    const call = {
      type: 'assistant',
      message: {
        content: [{ type: 'tool_use', id: 'tu_1', name: 'Read', input: { file_path: 'src/a.ts' } }],
      },
    }
    const events = play([call, success('read it')])
    expect(events[0]).toEqual({
      kind: 'tool',
      turnId: 't1',
      text: toolCallLine('Read', { file_path: 'src/a.ts' }),
      // Announced while it is still running. The result is a separate event and
      // may be minutes behind — see the `pending` cases below.
      call: { id: 'tu_1', name: 'Read', argument: 'src/a.ts', status: 'pending' },
    })
  })

  test('the line names the tool and what it was pointed at', () => {
    expect(toolCallLine('Read', { file_path: 'src/a.ts' })).toContain('Read')
    expect(toolCallLine('Read', { file_path: 'src/a.ts' })).toContain('src/a.ts')
    expect(toolCallLine('Bash', { command: 'bun test' })).toContain('bun test')
    expect(toolCallLine('Grep', { pattern: 'TODO' })).toContain('TODO')
  })

  test('a tool with nothing identifying is still announced by name', () => {
    expect(toolCallLine('TodoWrite', { todos: [] })).toContain('TodoWrite')
  })

  test('a long argument is cut, so one tool call cannot flood the transcript', () => {
    const line = toolCallLine('Bash', { command: 'x'.repeat(5000) })
    expect(line.length).toBeLessThan(200)
  })

  test('several tool calls in one message are all announced', () => {
    const call = {
      type: 'assistant',
      message: {
        content: [
          { type: 'tool_use', id: 'tu_a', name: 'Read', input: { file_path: 'a' } },
          { type: 'tool_use', id: 'tu_b', name: 'Read', input: { file_path: 'b' } },
        ],
      },
    }
    expect(play([call, success('ok')]).filter((e) => e.kind === 'tool')).toHaveLength(2)
  })

  test('a call with no id is dropped rather than left unanswerable', () => {
    // Not a shape the runtime produces — every call in the SDK's schema has an
    // id. But a call the transcript holds and no result can be matched to is a
    // tool that renders as running for the rest of the conversation, and no
    // later event could ever settle it.
    const call = {
      type: 'assistant',
      message: { content: [{ type: 'tool_use', name: 'Read', input: { file_path: 'a' } }] },
    }
    expect(play([call, success('ok')]).filter((e) => e.kind === 'tool')).toHaveLength(0)
  })

  test('the tool calls survive the Turn they were made in', () => {
    /*
      The whole claim is that unattended work is reviewable afterwards, and it
      used to be kept by the tool line being *inside* the finished answer.

      It is not any more. A tool call is its own durable event now, and `done`
      carries only the answer text after the last one — so the assertion is that
      the call is still there when the Turn ends, not that it is buried in the
      Turn's text. Reviewability is unchanged; what changed is that the call and
      the words around it are separable, which is what lets the window render
      one as a tool and the other as prose.
    */
    const call = {
      type: 'assistant',
      message: {
        content: [{ type: 'tool_use', id: 'tu_1', name: 'Read', input: { file_path: 'src/a.ts' } }],
      },
    }
    const events = play([call, textDelta('I read it.'), success('I read it.')])
    const tool = events.find((e) => e.kind === 'tool')
    expect(tool?.kind === 'tool' && tool.call.argument).toBe('src/a.ts')
    const done = events.at(-1)
    expect(done?.kind).toBe('done')
    // The tail of the answer, and only the tail: what came before the call is
    // already in the transcript as the entry above it.
    expect(done?.kind === 'done' && done.text).toBe('I read it.')
  })

  test('a tool call ends the segment of answer before it', () => {
    // Said, did, said — three entries rather than one block of text with a tool
    // line buried in it. `done` carries the last piece only.
    const call = {
      type: 'assistant',
      message: {
        content: [{ type: 'tool_use', id: 'tu_1', name: 'Bash', input: { command: 'bun test' } }],
      },
    }
    const events = play([
      textDelta('Let me run the tests.'),
      call,
      textDelta('They pass.'),
      success('ignored'),
    ])
    const done = events.at(-1)
    expect(done?.kind === 'done' && done.text).toBe('They pass.')
  })

  test('a Turn that ends on a tool call does not repost the whole answer', () => {
    /*
      The `result` field is the fallback for a Turn that streamed nothing at all
      — a cached or instant answer. A Turn whose last act was a tool call also
      arrives at `done` with an empty accumulation, and falling back there would
      post the entire answer a second time underneath the pieces already shown.
    */
    const call = {
      type: 'assistant',
      message: {
        content: [{ type: 'tool_use', id: 'tu_1', name: 'Bash', input: { command: 'ls' } }],
      },
    }
    const events = play([call, success('the whole answer again')])
    const done = events.at(-1)
    expect(done?.kind === 'done' && done.text).toBe('')
  })

  test('a Turn that streamed nothing still falls back to the result', () => {
    // The case the fallback exists for, unchanged: nothing was watched, so
    // there is nothing but `result` to report.
    const events = play([success('a cached answer')])
    const done = events.at(-1)
    expect(done?.kind === 'done' && done.text).toBe('a cached answer')
  })
})

describe('what a tool returned', () => {
  const call = (id: string, name: string, input: Record<string, unknown>) => ({
    type: 'assistant',
    message: { content: [{ type: 'tool_use', id, name, input }] },
  })
  const result = (id: string, content: unknown, isError?: boolean) => ({
    type: 'user',
    message: {
      content: [
        { type: 'tool_result', tool_use_id: id, content, ...(isError ? { is_error: true } : {}) },
      ],
    },
  })

  test('a result is reported against the call it answers', () => {
    const events = play([
      call('tu_1', 'Read', { file_path: 'a.ts' }),
      result('tu_1', 'export const a = 1'),
      success('done'),
    ])
    expect(events.find((e) => e.kind === 'tool-result')).toEqual({
      kind: 'tool-result',
      turnId: 't1',
      id: 'tu_1',
      result: 'export const a = 1',
      status: 'success',
    })
  })

  test('results are paired by id, not by the order they arrive in', () => {
    /*
      The reason the id is carried at all. A Session runs tools concurrently, so
      the n-th result is not the n-th call — `agent.ts` learned this in the
      containment probe and its comment records what it cost.
    */
    const events = play([
      call('tu_a', 'Bash', { command: 'slow' }),
      call('tu_b', 'Bash', { command: 'fast' }),
      result('tu_b', 'fast finished first'),
      result('tu_a', 'slow finished second'),
      success('done'),
    ])
    const settled = events.filter((e) => e.kind === 'tool-result')
    expect(settled.map((e) => e.kind === 'tool-result' && e.id)).toEqual(['tu_b', 'tu_a'])
    expect(settled[0]?.kind === 'tool-result' && settled[0].result).toBe('fast finished first')
  })

  test('a failed tool says so, so a reader is not left to guess from the text', () => {
    const events = play([
      call('tu_1', 'Bash', { command: 'false' }),
      result('tu_1', 'command not found', true),
      success('done'),
    ])
    const settled = events.find((e) => e.kind === 'tool-result')
    expect(settled?.kind === 'tool-result' && settled.status).toBe('error')
  })

  test('the line is what fits on one, and the rest is behind the disclosure', () => {
    const events = play([
      call('tu_1', 'Read', { file_path: 'a.ts' }),
      result('tu_1', 'first line\nsecond line\nthird line'),
      success('done'),
    ])
    const settled = events.find((e) => e.kind === 'tool-result')
    expect(settled?.kind === 'tool-result' && settled.result).toBe('first line')
    expect(settled?.kind === 'tool-result' && settled.detail).toContain('third line')
  })

  test('a one-line answer has nothing behind the disclosure', () => {
    // Otherwise every tool call offers an expansion that opens onto a repeat of
    // the line already on screen.
    const events = play([
      call('tu_1', 'Write', { file_path: 'a.ts' }),
      result('tu_1', 'wrote a.ts'),
      success('done'),
    ])
    const settled = events.find((e) => e.kind === 'tool-result')
    expect(settled?.kind === 'tool-result' && settled.detail).toBeUndefined()
  })

  test('a tool that said nothing says that, rather than answering with silence', () => {
    const events = play([
      call('tu_1', 'Bash', { command: 'true' }),
      result('tu_1', '   \n  '),
      success('done'),
    ])
    const settled = events.find((e) => e.kind === 'tool-result')
    expect(settled?.kind === 'tool-result' && settled.result).toBe('(no output)')
  })

  test('a result that came back as blocks is read for its text', () => {
    // Some tools answer with an array rather than a string. The blocks that are
    // not text contribute nothing: a base64 image in a mirror is the thing the
    // attachment count exists to avoid.
    const events = play([
      call('tu_1', 'Read', { file_path: 'a.png' }),
      result('tu_1', [
        { type: 'text', text: 'the readable part' },
        { type: 'image', source: { data: 'AAAA' } },
      ]),
      success('done'),
    ])
    const settled = events.find((e) => e.kind === 'tool-result')
    expect(settled?.kind === 'tool-result' && settled.result).toBe('the readable part')
    expect(JSON.stringify(events)).not.toContain('AAAA')
  })

  test('a huge result is cut, so one tool call cannot flood the mirror', () => {
    const events = play([
      call('tu_1', 'Read', { file_path: 'big.ts' }),
      result('tu_1', `first line\n${'x'.repeat(20_000)}`),
      success('done'),
    ])
    const settled = events.find((e) => e.kind === 'tool-result')
    const detail = settled?.kind === 'tool-result' ? (settled.detail ?? '') : ''
    expect(detail.length).toBeLessThan(5_000)
    expect(detail.endsWith('…')).toBe(true)
  })

  test('a result for a call nobody announced is still reported', () => {
    // Core matches on id and leaves an unmatched result alone — a Compaction
    // can replace the transcript while a tool is still running. Dropping it
    // here would decide that on the Harness's behalf.
    const events = play([result('tu_unknown', 'orphan'), success('done')])
    expect(events.filter((e) => e.kind === 'tool-result')).toHaveLength(1)
  })

  test('a subagent is a tool call like any other, and renders as one', () => {
    /*
      The `Task` tool is how a subagent is started, so it arrives on this path
      with no special handling — named by its description, answered by the
      report the subagent returned. That is the whole of "subagents render like
      tools": there is no second mechanism.

      The live panel and the timing line are still separate and still ephemeral
      or textual respectively — they carry elapsed time, tokens and a tool count
      that a tool result has no field for. See `RunningTask`.
    */
    const events = play([
      call('tu_1', 'Task', { description: 'review the diff', subagent_type: 'code-reviewer' }),
      result('tu_1', 'Two findings, both in worktrees.ts.'),
      success('done'),
    ])
    const started = events.find((e) => e.kind === 'tool')
    expect(started?.kind === 'tool' && started.call.name).toBe('Task')
    expect(started?.kind === 'tool' && started.call.argument).toBe('review the diff')
    const settled = events.find((e) => e.kind === 'tool-result')
    expect(settled?.kind === 'tool-result' && settled.result).toBe('Two findings, both in worktrees.ts.')
  })

  test('a user message that is not a tool result says nothing about tools', () => {
    // The same message shape carries an unprompted Turn's cause. The two
    // readings must not collide.
    const events = play([
      { type: 'user', message: { content: [{ type: 'text', text: '<task-notification>' }] } },
      success('done'),
    ])
    expect(events.filter((e) => e.kind === 'tool-result')).toHaveLength(0)
  })
})

describe('a hook that did not run says so', () => {
  /*
    Ticket 58's actual defect was silence. A plugin declared a `SessionStart`
    hook, `node` was not on the agent's PATH, the spawn failed, and nothing
    anywhere said so — not the transcript, not the runtime report, not a log.
    The only evidence was a file that never appeared.
  */

  const hookResponse = (over: Record<string, unknown> = {}) => ({
    type: 'system',
    subtype: 'hook_response',
    hook_name: 'caveman-activate',
    hook_event: 'SessionStart',
    outcome: 'error',
    exit_code: 127,
    stderr: 'env: node: No such file or directory',
    ...over,
  })

  test('a failed hook reaches the transcript', () => {
    const events = play([hookResponse(), success('answered anyway')])
    expect(events[0]?.kind).toBe('hook')
    const text = (events[0] as { text: string }).text
    expect(text).toContain('caveman-activate')
    expect(text).toContain('SessionStart')
    expect(text).toContain('127')
    expect(text).toContain('node: No such file or directory')
  })

  test('it does not fail the Turn', () => {
    // The agent answered; something beside it did not run. Collapsing the two
    // would turn a missing `node` into a refused conversation.
    const events = play([hookResponse(), success('answered anyway')])
    expect(events.some((event) => event.kind === 'failed')).toBe(false)
    expect(events.at(-1)?.kind).toBe('done')
  })

  test('it survives into the answer, like a tool call', () => {
    // Or it is a warning that existed only for whoever happened to be watching.
    const events = play([hookResponse(), success('answered anyway')])
    const done = events.at(-1) as { text: string }
    expect(done.text).toContain('did not run')
  })

  test('a hook that worked is not reported', () => {
    // Every hook reports this way. A line per success would be noise on every
    // Turn, and the fact worth surfacing is the one nobody could see.
    const events = play([hookResponse({ outcome: 'success', exit_code: 0, stderr: '' }), success('ok')])
    expect(events.some((event) => event.kind === 'hook')).toBe(false)
  })

  test('a cancelled hook is not a fault', () => {
    // Reporting a deliberate stop as a failure teaches people to ignore the
    // warning.
    const events = play([hookResponse({ outcome: 'cancelled' }), success('ok')])
    expect(events.some((event) => event.kind === 'hook')).toBe(false)
  })

  test('the line is bounded, so one hook cannot flood the transcript', () => {
    const line = hookFailureLine('h', 'SessionStart', 1, 'x'.repeat(5000))
    expect(line.length).toBeLessThan(260)
  })

  test('only the first line of stderr is quoted, not a stack trace', () => {
    const line = hookFailureLine('h', 'SessionStart', 1, 'the real reason\n  at frame one\n  at frame two')
    expect(line).toContain('the real reason')
    expect(line).not.toContain('at frame one')
  })

  test('a hook that said nothing is still named', () => {
    const line = hookFailureLine('h', 'SessionStart', undefined, '')
    expect(line).toContain('h')
    expect(line).toContain('did not run')
  })
})

describe('the token count is a measurement', () => {
  test('the whole context is counted, cache included', () => {
    // The meter says how much of the window the next Turn starts from, and a
    // cached read occupies the window exactly like an uncached one.
    expect(contextTokens(usage)).toBe(1200 + 340 + 8000 + 100)
  })

  test('a finished turn reports what it measured', () => {
    const done = play([success('hi')]).at(-1)
    expect(done).toEqual({ kind: 'done', turnId: 't1', text: 'hi', tokensUsed: contextTokens(usage) })
  })

  test('a report with no usage counts nothing rather than inventing a number', () => {
    expect(contextTokens(undefined)).toBe(0)
    expect(contextTokens({ input_tokens: 'lots' })).toBe(0)
  })
})

describe('a failure says which failure it was, and never quotes the API', () => {
  test('every failure has a sentence and none of them is empty', () => {
    for (const failure of TURN_FAILURES) {
      expect(turnFailureMessage(failure).length).toBeGreaterThan(0)
    }
  })

  test('an authentication failure is reported as a rejected credential', () => {
    const refused = { type: 'assistant', error: 'authentication_failed', message: { content: [] } }
    expect(play([refused])).toEqual([
      { kind: 'failed', turnId: 't1', failure: 'authentication' },
    ])
  })

  test('a turn that ended in an error carries the subtype, not the error text', () => {
    const failed = {
      type: 'result',
      subtype: 'error_during_execution',
      is_error: true,
      usage,
      errors: [`401 invalid x-api-key ${LOOKS_LIKE_A_KEY}`],
    }
    const events = play([failed])
    expect(events).toEqual([{ kind: 'failed', turnId: 't1', failure: 'execution' }])
    // Structural rather than remembered: the event has no field an API body
    // could travel in, so no message built from it can carry a key.
    expect(JSON.stringify(events)).not.toContain('sk-ant')
  })

  test('a result flagged as an error is a failure even when the subtype says success', () => {
    const events = play([{ type: 'result', subtype: 'success', is_error: true, usage, result: 'x' }])
    expect(events.at(-1)?.kind).toBe('failed')
  })

  test('running out of turns is a different failure from the model refusing', () => {
    expect(play([{ type: 'result', subtype: 'error_max_turns', is_error: true, usage }])).toEqual([
      { kind: 'failed', turnId: 't1', failure: 'max-turns' },
    ])
  })

  test('a rejected credential is the one failure that is more than a failed turn', () => {
    // It has to reach `credential.rejected` as well, so it is distinguishable
    // by a value rather than by reading the sentence.
    expect(isCredentialRejection('authentication')).toBe(true)
    for (const failure of TURN_FAILURES) {
      if (failure !== 'authentication') expect(isCredentialRejection(failure)).toBe(false)
    }
  })

  test('the sentence about a refused credential says what to do about it', () => {
    // `turn.failed` renders this, and the single next action is fixing the key
    // rather than retrying the conversation.
    expect(turnFailureMessage('authentication')).toContain('key')
  })

  test('this module reaches one leaf, so a Turn cannot close an import ring', () => {
    /*
      ./bridge.ts imports this file and ./credentials.ts imports ./bridge.ts, so
      a Turn reaching back for the credential module would make a cycle that
      works only because nothing in it is read at load. Asserted rather than
      remembered, because the tempting import is a one-liner.

      It used to be none at all, and a chain is now admissible on the condition
      this test enforces: it must **end**. Every module on it imports at most
      one thing and the last imports nothing, so no step can close a ring.

      The chain is turn.ts → preview.ts → fence.ts. ./preview.ts is the closed
      list of outcomes a `preview-answer` may carry, beside the sentences
      written for them; ./fence.ts is the one definition of which paths decide
      what the agent may do, which preview.ts imports rather than restating —
      it had its own copy for one afternoon, and the two spellings had already
      begun to disagree. The last assertion is the whole of what makes the
      others safe.
    */
    const runtimeImportsIn = (module: string) => {
      const source = readFileSync(new URL(`./${module}`, import.meta.url), 'utf8')
      return [...source.matchAll(/^(?:export|import) (?!type )(?:.*? from )?'(.+?)'/gm)].map(
        (match) => match[1] as string,
      )
    }
    expect(runtimeImportsIn('turn.ts')).toEqual(['./preview.ts'])
    expect(new Set(runtimeImportsIn('preview.ts'))).toEqual(new Set(['./fence.ts']))
    expect(runtimeImportsIn('fence.ts')).toHaveLength(0)
  })

  test('a failure nobody enumerated is still a failure with a sentence', () => {
    const events = play([{ type: 'result', subtype: 'error_who_knows', is_error: true, usage }])
    expect(events).toEqual([{ kind: 'failed', turnId: 't1', failure: 'unknown' }])
  })
})

describe('a turn ends exactly once', () => {
  test('nothing is said after the answer is complete', () => {
    const run = beginTurn('t1')
    run.accept(success('done'))
    expect(run.finished).toBe(true)
    expect(run.accept(textDelta('more'))).toEqual([])
  })

  test('a message the turn has no use for says nothing', () => {
    const run = beginTurn('t1')
    expect(run.accept({ type: 'system', subtype: 'init' })).toEqual([])
    expect(run.accept('not a message')).toEqual([])
    expect(run.accept(null)).toEqual([])
  })
})

describe('what the runtime says it is', () => {
  const init = {
    type: 'system',
    subtype: 'init',
    claude_code_version: '2.1.0',
    model: 'claude-opus-5',
    permissionMode: 'bypassPermissions',
    output_style: 'default',
    cwd: '/tmp/clone',
    apiKeySource: 'ANTHROPIC_API_KEY',
    tools: ['Read', 'Bash'],
    skills: [],
    slash_commands: ['compact'],
    agents: [],
    mcp_servers: [{ name: 'files', status: 'connected' }],
    plugins: [{ name: 'thing', path: '/plugins/thing' }],
  }

  test('the SDK keys are read as they are actually spelled', () => {
    // Half snake_case and half camelCase, because the init message is assembled
    // from two sides. Getting one wrong produces a panel of empty rows rather
    // than an error, which is why this is asserted rather than eyeballed.
    const report = runtimeReportFrom(init)
    expect(report.claudeCodeVersion).toBe('2.1.0')
    expect(report.outputStyle).toBe('default')
    expect(report.permissionMode).toBe('bypassPermissions')
    expect(report.slashCommands).toEqual(['compact'])
    expect(report.mcpServers).toEqual([{ name: 'files', status: 'connected' }])
  })

  test('a plugin with no version says so rather than inventing one', () => {
    expect(runtimeReportFrom(init).plugins).toEqual([
      { name: 'thing', path: '/plugins/thing', version: null },
    ])
  })

  test('a report can never fail the turn it describes', () => {
    // Every field optional on the way in. An init message this does not
    // recognise is a report full of empties — a true statement, rendered as
    // dashes — rather than a thrown error inside the message loop.
    const empty = runtimeReportFrom({ type: 'system', subtype: 'init' })
    expect(empty.model).toBe('')
    expect(empty.tools).toEqual([])
    expect(runtimeReportFrom(null).cwd).toBe('')
    expect(runtimeReportFrom({ tools: 'all of them', plugins: 7 }).tools).toEqual([])
  })

  test('nothing arrives at whatever length it was sent at', () => {
    const long = 'x'.repeat(5_000)
    expect(runtimeReportFrom({ cwd: long }).cwd).toHaveLength(200)
    expect(runtimeReportFrom({ tools: [long] }).tools[0]).toHaveLength(200)
  })

  test('the credential variable is read off the environment, under either kind', () => {
    /*
      The measurement the panel's `credential` row is made of, and the reason it
      is taken here rather than off the init message: the runtime reports which
      store answered for an API key, and under a subscription there is no API
      key to have a store. Both variables are asked about, because a row that
      only worked for one kind would be the previous bug with a smaller
      audience.
    */
    expect(observedCredentialVariable({ ANTHROPIC_API_KEY: 'x' })).toBe('ANTHROPIC_API_KEY')
    expect(observedCredentialVariable({ CLAUDE_CODE_OAUTH_TOKEN: 'x' })).toBe(
      'CLAUDE_CODE_OAUTH_TOKEN',
    )
    // Neither, which is the reading the row turns into a warning. An empty
    // value is that reading too: a variable exported as nothing authenticates
    // nothing, and reporting its name would be the panel claiming an injection
    // that did not happen.
    expect(observedCredentialVariable({})).toBe('')
    expect(observedCredentialVariable({ ANTHROPIC_API_KEY: '' })).toBe('')
    expect(observedCredentialVariable({ PATH: '/usr/bin' })).toBe('')
  })

  test('the report carries the name it was handed and never looks for one', () => {
    // An argument, like `resumed` beside it. Nothing on the init message can
    // supply it, so an init message that offers one is offering a field this
    // does not read — asserted, because the day the SDK adds a key of that name
    // is the day silently preferring it would make the row a guess again.
    expect(runtimeReportFrom(init, false, 'CLAUDE_CODE_OAUTH_TOKEN').credentialSource).toBe(
      'CLAUDE_CODE_OAUTH_TOKEN',
    )
    expect(runtimeReportFrom(init).credentialSource).toBe('')
    expect(
      runtimeReportFrom({ ...init, credentialSource: 'ANTHROPIC_API_KEY' }).credentialSource,
    ).toBe('')
    // And the SDK's own field is left exactly as the SDK sent it. varnick
    // reports beside `apiKeySource`, never over it.
    expect(runtimeReportFrom({ ...init, apiKeySource: 'none' }, false, 'ANTHROPIC_API_KEY')).toMatchObject(
      { apiKeySource: 'none', credentialSource: 'ANTHROPIC_API_KEY' },
    )
  })
})

describe('the wire between the agent host and the host', () => {
  test('an event is exactly one line, whatever is in it', () => {
    const line = encodeTurnEvent({ kind: 'delta', turnId: 't1', text: 'one\ntwo' })
    expect(line.endsWith('\n')).toBe(true)
    expect(line.match(/\n/g)).toHaveLength(1)
  })

  test('an event survives the round trip', () => {
    const event: TurnEvent = { kind: 'done', turnId: 't1', text: 'hi', tokensUsed: 12 }
    expect(parseTurnEvent(JSON.parse(encodeTurnEvent(event)))).toEqual(event)
  })

  test('an event is rebuilt rather than forwarded', () => {
    // A field nobody agreed to cannot ride into the transcript.
    const smuggled = { kind: 'delta', turnId: 't1', text: 'hi', apiKey: LOOKS_LIKE_A_KEY }
    expect(parseTurnEvent(smuggled)).toEqual({ kind: 'delta', turnId: 't1', text: 'hi' })
  })

  test('anything that is not an event is not read as one', () => {
    expect(parseTurnEvent(null)).toBeNull()
    expect(parseTurnEvent({ kind: 'delta' })).toBeNull()
    expect(parseTurnEvent({ kind: 'nope', turnId: 't1' })).toBeNull()
    expect(parseTurnEvent({ kind: 'done', turnId: 't1', text: 'x' })).toBeNull()
    expect(parseTurnEvent({ kind: 'failed', turnId: 't1', failure: 'made-up' })).toBeNull()
  })

  test('a control request is read back as what it asked for', () => {
    const line = JSON.stringify({
      kind: 'run-turn',
      turnId: 't1',
      prompt: 'hello',
      model: 'claude-opus-5',
      effort: 'xhigh',
      images: [],
    })
    expect(parseControlRequest(line)).toEqual({
      kind: 'run-turn',
      turnId: 't1',
      prompt: 'hello',
      model: 'claude-opus-5',
      effort: 'xhigh',
      images: [],
    })
    expect(parseControlRequest(JSON.stringify({ kind: 'interrupt', turnId: 't1' }))).toEqual({
      kind: 'interrupt',
      turnId: 't1',
    })
  })

  test('a compaction is not a control request at all', () => {
    // `compact` was the third kind on this channel. varnick does not ask for a
    // compaction any more — the Session performs them on its own and varnick
    // hears about them — so the word is refused like any other unknown one,
    // rather than accepted and ignored somewhere further in.
    expect(parseControlRequest(JSON.stringify({ kind: 'compact', turnId: 'c1' }))).toBeNull()
  })

  test('a finished compaction survives the round trip and is rebuilt on the way back', () => {
    const event: TurnEvent = { kind: 'compacted', turnId: 'c1', summary: 'so far…', tokensUsed: 4_000 }
    expect(parseTurnEvent(JSON.parse(encodeTurnEvent(event)))).toEqual(event)
    expect(
      parseTurnEvent({ ...event, apiKey: LOOKS_LIKE_A_KEY }),
    ).toEqual(event)
    expect(parseTurnEvent({ kind: 'compacted', turnId: 'c1', summary: 'x' })).toBeNull()
    expect(parseTurnEvent({ kind: 'compacted', turnId: 'c1', tokensUsed: 1 })).toBeNull()
  })

  test("the runtime's self-report survives the round trip", () => {
    const event: TurnEvent = {
      kind: 'runtime',
      turnId: 't1',
      report: {
        sessionId: 'aaaaaaaa-0000-0000-0000-000000000000',
        resumed: true,
        claudeCodeVersion: '2.1.0',
        model: 'claude-opus-5',
        permissionMode: 'bypassPermissions',
        outputStyle: 'default',
        cwd: '/tmp/clone',
        apiKeySource: 'ANTHROPIC_API_KEY',
        credentialSource: 'ANTHROPIC_API_KEY',
        tools: ['Read', 'Bash'],
        skills: [],
        slashCommands: ['compact'],
        agents: [],
        mcpServers: [{ name: 'files', status: 'connected' }],
        plugins: [{ name: 'thing', path: '/plugins/thing', version: '1.0.0' }],
      },
    }
    expect(parseTurnEvent(JSON.parse(encodeTurnEvent(event)))).toEqual(event)
  })

  test('the credential variable survives the wire, which is where it would be dropped', () => {
    /*
      Asserted on its own as well as inside the round trip above, because the
      failure it guards against is silent and asymmetric: `parseRuntimeReport`
      rebuilds the report field by field, so a member added to the type and not
      to that rebuild type-checks, encodes, crosses, and arrives empty. The panel
      would then show the warning over a Session whose credential was injected
      perfectly — the same class of confidently-wrong row this field was added to
      remove.
    */
    const report = runtimeReportFrom({ type: 'system', subtype: 'init' }, true, 'CLAUDE_CODE_OAUTH_TOKEN')
    const event: TurnEvent = { kind: 'runtime', turnId: 't1', report }
    const back = parseTurnEvent(JSON.parse(encodeTurnEvent(event)))
    expect(back).toEqual(event)
    expect((back as { report: RuntimeReport }).report.credentialSource).toBe(
      'CLAUDE_CODE_OAUTH_TOKEN',
    )
  })

  test('a report is rebuilt field by field, like every other event', () => {
    // Same rule as a delta, and it matters more here: this event carries the
    // largest object on the wire, so it is the most inviting place for a field
    // nobody agreed to to ride into the machine's context.
    const parsed = parseTurnEvent({
      kind: 'runtime',
      turnId: 't1',
      report: { model: 'claude-opus-5', apiKey: LOOKS_LIKE_A_KEY },
    })
    expect(JSON.stringify(parsed)).not.toContain(LOOKS_LIKE_A_KEY)
    expect(parsed).toEqual({
      kind: 'runtime',
      turnId: 't1',
      report: {
        sessionId: '',
        resumed: false,
        claudeCodeVersion: '',
        model: 'claude-opus-5',
        permissionMode: '',
        outputStyle: '',
        cwd: '',
        apiKeySource: '',
        credentialSource: '',
        tools: [],
        skills: [],
        slashCommands: [],
        agents: [],
        mcpServers: [],
        plugins: [],
      },
    })
  })

  test('a runtime event with no report is not an event', () => {
    expect(parseTurnEvent({ kind: 'runtime', turnId: 't1' })).toBeNull()
    expect(parseTurnEvent({ kind: 'runtime', turnId: 't1', report: 'all of it' })).toBeNull()
  })

  test('a control request the agent host does not understand is refused, not guessed at', () => {
    expect(parseControlRequest('not json')).toBeNull()
    expect(parseControlRequest(JSON.stringify({ kind: 'run-turn' }))).toBeNull()
    expect(parseControlRequest(JSON.stringify({ kind: 'exec', command: 'rm -rf /' }))).toBeNull()
  })

  /*
    A `read-plan-usage` kind was tested here — that it parsed, that it was
    rebuilt field by field, and that one with no `requestId` was refused. All
    three passed and the kind is gone anyway: ticket 31 established that no
    credential varnick can hold reports plan usage, so the read had nothing to
    return. The channel is untouched; a kind left it.

    The test below now covers the case those three were also covering by
    accident — that a kind this parser does not know is refused rather than
    guessed at. `read-plan-usage` is one such kind now.
  */
  test('a kind the channel no longer carries is refused like any other stranger', () => {
    expect(
      parseControlRequest(JSON.stringify({ kind: 'read-plan-usage', requestId: 'u1' })),
    ).toBeNull()
  })

  /*
    The fourth kind, and the only one that goes the other way: every other
    request asks the confined process to do something, and this one tells it a
    fact it has no way to find out — which secrets exist. ADR-0006's naming end.

    The names come off `SecretsStore.names()` in the Harness runtime, cross the
    Rust host, and land here. What follows is the assertion that a value cannot
    make that journey however it is smuggled onto the line.
  */
  test('the names of the stored secrets are a control request', () => {
    expect(
      parseControlRequest(JSON.stringify({ kind: 'describe-secrets', names: ['STRIPE_KEY'] })),
    ).toEqual({ kind: 'describe-secrets', names: ['STRIPE_KEY'] })
  })

  test('no secret value can ride in beside the names, whatever it is called', () => {
    // The load-bearing one. This request is the whole of what the running agent
    // is told about secrets, so "names are not values" has to be a property of
    // the parse rather than a rule the callers keep — the same rebuild that
    // makes a `prompt` sent beside a compaction a field that was never read.
    const parsed = parseControlRequest(
      JSON.stringify({
        kind: 'describe-secrets',
        names: ['STRIPE_KEY'],
        values: [LOOKS_LIKE_A_KEY],
        STRIPE_KEY: LOOKS_LIKE_A_KEY,
        secrets: { STRIPE_KEY: LOOKS_LIKE_A_KEY },
      }),
    )
    expect(parsed).toEqual({ kind: 'describe-secrets', names: ['STRIPE_KEY'] })
    expect(JSON.stringify(parsed)).not.toContain(LOOKS_LIKE_A_KEY)
  })

  test('an empty list is an answer and not a missing one', () => {
    // "The store was read and holds nothing" is worth telling the agent, and it
    // is a different thing from nobody having said — see `secretNames` in
    // ./agent.ts, which keeps the two apart.
    expect(parseControlRequest(JSON.stringify({ kind: 'describe-secrets', names: [] }))).toEqual({
      kind: 'describe-secrets',
      names: [],
    })
  })

  test('a list that is not wholly names is refused rather than partly believed', () => {
    // Refused whole. A partial list is worse than none: the agent would write
    // code against the names it was given and have no way to tell it had been
    // told about fewer secrets than the store holds.
    expect(
      parseControlRequest(JSON.stringify({ kind: 'describe-secrets', names: ['A', 7] })),
    ).toBeNull()
    expect(
      parseControlRequest(JSON.stringify({ kind: 'describe-secrets', names: ['A', ''] })),
    ).toBeNull()
    expect(parseControlRequest(JSON.stringify({ kind: 'describe-secrets' }))).toBeNull()
    expect(
      parseControlRequest(JSON.stringify({ kind: 'describe-secrets', names: 'STRIPE_KEY' })),
    ).toBeNull()
  })

  test('a merge report is the sentence and nothing beside it', () => {
    /*
      Rebuilt to `kind` and `briefing`, like every other request here. The
      sentence is composed where the merge happened — see `mergeBriefing` in
      ./merge.ts — and a field arriving beside it is a field that was never
      read, which is what stops this channel growing a second way to put text in
      front of a confined agent.
    */
    expect(
      parseControlRequest(
        JSON.stringify({
          kind: 'report-merge',
          briefing: 'varnick merged ticket/49 into the live tree.',
          alsoRun: 'rm -rf /',
        }),
      ),
    ).toEqual({ kind: 'report-merge', briefing: 'varnick merged ticket/49 into the live tree.' })
  })

  test('an empty briefing is refused, because the delivery is what clears it', () => {
    // Unlike the empty secret list above, which is a real answer. A briefing is
    // said once and drained, so an empty one would spend the single chance to
    // say a branch landed on a blank paragraph.
    expect(parseControlRequest(JSON.stringify({ kind: 'report-merge', briefing: '' }))).toBeNull()
    expect(parseControlRequest(JSON.stringify({ kind: 'report-merge', briefing: '  ' }))).toBeNull()
    expect(parseControlRequest(JSON.stringify({ kind: 'report-merge' }))).toBeNull()
    expect(parseControlRequest(JSON.stringify({ kind: 'report-merge', briefing: 7 }))).toBeNull()
  })

  test('a turn still has to name its turn', () => {
    // The id fields are per kind rather than one shared field, so widening the
    // channel for a read did not stop a Turn needing the id an interrupt uses.
    expect(parseControlRequest(JSON.stringify({ kind: 'interrupt' }))).toBeNull()
    expect(
      parseControlRequest(
        JSON.stringify({ kind: 'run-turn', prompt: 'hi', model: 'm', effort: 'e' }),
      ),
    ).toBeNull()
  })
})

// ---------------------------------------------------------------------------
// Subagents, while they run and after they are gone
// ---------------------------------------------------------------------------

/*
  A Turn that spawned subagents looked exactly like a Turn that had hung. Four
  of them ran for ten minutes behind one `⚙ Agent(…)` line and a spinner, and
  the only way to answer "is it still working?" was reading the SDK's own
  transcripts off disk.

  Nothing was missing from the SDK. All four of these subtypes were arriving and
  falling through the `system` case, which answered `hook_response` and returned
  nothing for the rest.
*/

const started = (id: string, description: string, subagentType?: string) => ({
  type: 'system',
  subtype: 'task_started',
  task_id: id,
  description,
  ...(subagentType === undefined ? {} : { subagent_type: subagentType }),
})

const progress = (id: string, total_tokens: number, tool_uses: number, duration_ms: number) => ({
  type: 'system',
  subtype: 'task_progress',
  task_id: id,
  usage: { total_tokens, tool_uses, duration_ms },
})

const updated = (id: string, patch: Record<string, unknown>) => ({
  type: 'system',
  subtype: 'task_updated',
  task_id: id,
  patch,
})

/** Just the live sets, in order — what the panel would have shown. */
const setsFrom = (events: readonly TurnEvent[]) =>
  events.filter((e) => e.kind === 'tasks').map((e) => (e as { tasks: readonly unknown[] }).tasks)

/** Just the durable lines. */
const linesFrom = (events: readonly TurnEvent[]) =>
  events.filter((e) => e.kind === 'task-line').map((e) => (e as { text: string }).text)

describe('what is running right now', () => {
  test('a subagent that starts is listed', () => {
    const events = play([started('k1', 'review the diff', 'code-reviewer')])
    expect(setsFrom(events).at(-1)).toEqual([
      {
        id: 'k1',
        description: 'review the diff',
        subagentType: 'code-reviewer',
        tokens: 0,
        toolUses: 0,
        elapsedMs: 0,
      },
    ])
  })

  test('progress patches the entry rather than replacing the set', () => {
    // The reason the fold is host-side: Core would need this same map to apply
    // a patch, and two copies of a merge rule is one too many.
    const events = play([started('k1', 'review', 'code-reviewer'), progress('k1', 34_000, 9, 72_000)])
    expect(setsFrom(events).at(-1)).toEqual([
      {
        id: 'k1',
        description: 'review',
        subagentType: 'code-reviewer',
        tokens: 34_000,
        toolUses: 9,
        elapsedMs: 72_000,
      },
    ])
  })

  test('two subagents stay in the order they started', () => {
    const events = play([started('k1', 'first'), started('k2', 'second')])
    expect(setsFrom(events).at(-1)?.map((t) => (t as { id: string }).id)).toEqual(['k1', 'k2'])
  })

  test('one that finishes leaves the set', () => {
    // The set is what is *running*. A finished subagent left in it would sit
    // there for the rest of the Turn claiming to be working.
    const events = play([started('k1', 'review'), updated('k1', { status: 'completed' })])
    expect(setsFrom(events).at(-1)).toEqual([])
  })

  test('an empty set is a real answer, not a malformed one', () => {
    // It is what "the last subagent finished" looks like.
    const events = play([started('k1', 'x'), updated('k1', { status: 'completed' })])
    expect(events.some((e) => e.kind === 'tasks')).toBe(true)
  })

  test('a paused subagent is still running and stays listed', () => {
    const events = play([started('k1', 'x'), updated('k1', { status: 'paused' })])
    expect(setsFrom(events).at(-1)).toHaveLength(1)
  })

  test('background_tasks_changed replaces the set and keeps the figures it does not carry', () => {
    // Replace semantics are the SDK's own word. Blanking the meters on every
    // arrival would make them flicker each time any task started or stopped.
    const events = play([
      started('k1', 'review', 'code-reviewer'),
      progress('k1', 1_000, 2, 5_000),
      {
        type: 'system',
        subtype: 'background_tasks_changed',
        tasks: [{ task_id: 'k1', description: 'review', task_type: 'code-reviewer' }],
      },
    ])
    expect(setsFrom(events).at(-1)).toEqual([
      {
        id: 'k1',
        description: 'review',
        subagentType: 'code-reviewer',
        tokens: 1_000,
        toolUses: 2,
        elapsedMs: 5_000,
      },
    ])
  })

  test('an entry with no id is dropped rather than defaulted', () => {
    // An id is what a later patch is matched against, so an entry without one
    // could never be updated or removed.
    const events = play([{ type: 'system', subtype: 'task_started', description: 'nameless' }])
    expect(setsFrom(events)).toEqual([])
  })
})

describe('what survives the Turn', () => {
  test('a line when it starts and a line when it ends', () => {
    const events = play([
      started('k1', 'review the diff', 'code-reviewer'),
      progress('k1', 34_000, 9, 72_000),
      updated('k1', { status: 'completed' }),
    ])
    expect(linesFrom(events)).toEqual([
      '\n⚙ code-reviewer · review the diff started\n',
      '\n⚙ code-reviewer · review the diff finished in 1m12s · 34000 tokens · 9 tools\n',
    ])
  })

  test('progress writes no line at all', () => {
    // It arrives every few seconds per task. A transcript is not a meter.
    const events = play([started('k1', 'x'), progress('k1', 1, 1, 1), progress('k1', 2, 2, 2)])
    expect(linesFrom(events)).toHaveLength(1)
  })

  test('a failure says so and quotes the reason', () => {
    // "It finished" and "it failed after four minutes" are different facts and
    // only one of them is good news.
    const events = play([started('k1', 'x'), updated('k1', { status: 'failed', error: 'ran out' })])
    expect(linesFrom(events).at(-1)).toContain('failed')
    expect(linesFrom(events).at(-1)).toContain('ran out')
  })

  test('a killed subagent is not reported as finished', () => {
    const events = play([started('k1', 'x'), updated('k1', { status: 'killed' })])
    expect(linesFrom(events).at(-1)).toContain('was stopped')
  })

  test('the lines are in the answer, so they reach the mirror', () => {
    // The live panel is empty by the time anyone reads the answer back. This is
    // the half that outlives it — same rule as a tool call and a failed hook.
    const events = play([
      started('k1', 'review', 'code-reviewer'),
      updated('k1', { status: 'completed' }),
      success('done'),
    ])
    const answer = events.find((e) => e.kind === 'done') as { text: string }
    expect(answer.text).toContain('code-reviewer · review started')
    expect(answer.text).toContain('finished in')
  })

  test('a subagent with no type still reads as something', () => {
    const events = play([started('k1', 'do the thing')])
    expect(linesFrom(events).at(-1)).toBe('\n⚙ agent · do the thing started\n')
  })
})

describe('a task set crossing into Core', () => {
  test('it survives the wire', () => {
    const event: TurnEvent = {
      kind: 'tasks',
      turnId: 't1',
      tasks: [
        { id: 'k1', description: 'review', subagentType: 'code-reviewer', tokens: 9, toolUses: 2, elapsedMs: 30 },
      ],
    }
    expect(parseTurnEvent(JSON.parse(encodeTurnEvent(event)))).toEqual(event)
  })

  test('an empty set crosses, because that is how a panel empties', () => {
    expect(parseTurnEvent({ kind: 'tasks', turnId: 't1', tasks: [] })).toEqual({
      kind: 'tasks',
      turnId: 't1',
      tasks: [],
    })
  })

  test('a field nobody agreed to does not ride in', () => {
    const parsed = parseTurnEvent({
      kind: 'tasks',
      turnId: 't1',
      tasks: [{ id: 'k1', description: 'x', subagentType: '', tokens: 0, toolUses: 0, elapsedMs: 0, secret: 'no' }],
    })
    expect(parsed).toEqual({
      kind: 'tasks',
      turnId: 't1',
      tasks: [{ id: 'k1', description: 'x', subagentType: '', tokens: 0, toolUses: 0, elapsedMs: 0 }],
    })
  })

  test('a task line crosses like any other transcript line', () => {
    expect(parseTurnEvent({ kind: 'task-line', turnId: 't1', text: '⚙ started' })).toEqual({
      kind: 'task-line',
      turnId: 't1',
      text: '⚙ started',
    })
  })

  test('a negative or absurd figure becomes zero rather than crossing', () => {
    const parsed = parseTurnEvent({
      kind: 'tasks',
      turnId: 't1',
      tasks: [{ id: 'k1', description: '', subagentType: '', tokens: -5, toolUses: NaN, elapsedMs: 1.7 }],
    }) as unknown as { tasks: { tokens: number; toolUses: number; elapsedMs: number }[] }
    expect(parsed.tasks[0]).toMatchObject({ tokens: 0, toolUses: 0, elapsedMs: 1 })
  })
})

// ---------------------------------------------------------------------------
// An answer nobody asked for
// ---------------------------------------------------------------------------

/*
  Two complete answers were produced, recorded by the SDK, and never reached the
  window: a subagent finished, the notification arrived as a prompt varnick
  never sent, and the agent answered it twice. The developer then asked why it
  had not reported, and it correctly said it had.

  These cover the harness half — telling an unprompted Turn from a prompted one,
  and reading why it started off the stream rather than guessing.
*/

describe('telling the two kinds of Turn apart', () => {
  test('a Turn varnick started is not unprompted', () => {
    expect(isUnpromptedTurn('t7')).toBe(false)
  })

  test('one the world started is', () => {
    expect(isUnpromptedTurn(`${UNPROMPTED_TURN_PREFIX}1`)).toBe(true)
  })
})

describe('why the agent started talking', () => {
  const userMessage = (text: string) => ({ type: 'user', message: { content: text } })

  test('a subagent finishing says so', () => {
    expect(unpromptedCauseOf(userMessage('<task-notification>done</task-notification>'))).toBe(
      'a subagent finished',
    )
  })

  test('a runtime reminder says so', () => {
    expect(unpromptedCauseOf(userMessage('<system-reminder>x</system-reminder>'))).toBe(
      'a reminder from the runtime',
    )
  })

  test('a prompt it cannot name still produces a usable divider', () => {
    // Better than nothing: the window must never show an answer with no
    // visible cause, because that reads as the agent talking to itself.
    expect(unpromptedCauseOf(userMessage('go on then'))).toBe(UNPROMPTED_CAUSE_UNKNOWN)
  })

  test('block content is read as well as plain text', () => {
    expect(
      unpromptedCauseOf({
        type: 'user',
        message: { content: [{ type: 'text', text: '<task-notification>x' }] },
      }),
    ).toBe('a subagent finished')
  })

  test('the agent’s own output explains nothing and is left alone', () => {
    // `null` leaves whatever was read last standing, which is what makes the
    // cause survive the several messages between a notification and the first
    // token of the answer to it.
    expect(unpromptedCauseOf({ type: 'assistant', message: { content: [] } })).toBeNull()
    expect(unpromptedCauseOf(textDelta('hi'))).toBeNull()
  })
})

describe('what may open an unprompted Turn', () => {
  test('streamed text does', () => {
    expect(beginsAnAnswer(textDelta('hi'))).toBe(true)
  })

  test('an assembled assistant message does', () => {
    expect(beginsAnAnswer({ type: 'assistant', message: { content: [] } })).toBe(true)
  })

  test('a result on its own does not', () => {
    // A result with no answer before it is the tail of something already gone.
    // Opening a run for it would post an empty message.
    expect(beginsAnAnswer(success('x'))).toBe(false)
  })

  test('nor does a hook, a task, or the runtime’s bookkeeping', () => {
    expect(beginsAnAnswer({ type: 'system', subtype: 'hook_response' })).toBe(false)
    expect(beginsAnAnswer(started('k1', 'x'))).toBe(false)
    expect(beginsAnAnswer({ type: 'system', subtype: 'init' })).toBe(false)
  })

  test('nor does thinking, which is not an answer', () => {
    expect(
      beginsAnAnswer({
        type: 'stream_event',
        event: { type: 'content_block_delta', delta: { type: 'thinking_delta', thinking: 'x' } },
      }),
    ).toBe(false)
  })
})

describe('a cause crossing into Core', () => {
  test('it survives the wire like any other text', () => {
    const event: TurnEvent = { kind: 'cause', turnId: 'u1', text: 'a subagent finished' }
    expect(parseTurnEvent(JSON.parse(encodeTurnEvent(event)))).toEqual(event)
  })
})
