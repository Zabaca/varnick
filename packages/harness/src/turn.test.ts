import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import {
  TURN_FAILURES,
  beginTurn,
  contextTokens,
  encodeTurnEvent,
  isCredentialRejection,
  parseTurnControl,
  parseTurnEvent,
  toolCallLine,
  turnFailureMessage,
  type TurnEvent,
} from './turn.ts'

/*
  The seam: what a Turn makes of the messages a Session hands it.

  Nothing here opens an Agent SDK session. It cannot — `beginTurn` takes
  messages, one at a time, and knows nothing about where they came from. That is
  the point rather than a testing convenience: a test that opened a session would
  put a Claude Code process on this machine outside srt, which is the one thing
  ADR-0003 says never happens.
*/

const LOOKS_LIKE_A_KEY = 'sk-" + "ant-api03-NEVER-LET-THIS-OUT'

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
        content: [{ type: 'tool_use', name: 'Read', input: { file_path: 'src/a.ts' } }],
      },
    }
    const events = play([call, success('read it')])
    expect(events[0]).toEqual({ kind: 'tool', turnId: 't1', text: toolCallLine('Read', { file_path: 'src/a.ts' }) })
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
          { type: 'tool_use', name: 'Read', input: { file_path: 'a' } },
          { type: 'tool_use', name: 'Read', input: { file_path: 'b' } },
        ],
      },
    }
    expect(play([call, success('ok')]).filter((e) => e.kind === 'tool')).toHaveLength(2)
  })

  test('the tool calls survive into the finished answer, not just the live one', () => {
    // The whole claim is that unattended work is reviewable afterwards. An
    // answer that dropped its tool calls the moment it finished would be
    // auditable only by whoever was watching.
    const call = {
      type: 'assistant',
      message: { content: [{ type: 'tool_use', name: 'Read', input: { file_path: 'src/a.ts' } }] },
    }
    const events = play([call, textDelta('I read it.'), success('I read it.')])
    const done = events.at(-1)
    expect(done?.kind).toBe('done')
    expect(done?.kind === 'done' && done.text).toContain('src/a.ts')
    expect(done?.kind === 'done' && done.text).toContain('I read it.')
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

  test('this module reaches nothing, so a Turn cannot close an import ring', () => {
    // ./bridge.ts imports this file and ./credentials.ts imports ./bridge.ts,
    // so a Turn reaching back for the credential module would make a cycle that
    // works only because nothing in it is read at load. Asserted rather than
    // remembered, because the tempting import is a one-liner.
    const source = readFileSync(new URL('./turn.ts', import.meta.url), 'utf8')
    const runtimeImports = [...source.matchAll(/^import (?!type )/gm)]
    expect(runtimeImports).toHaveLength(0)
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
    })
    expect(parseTurnControl(line)).toEqual({
      kind: 'run-turn',
      turnId: 't1',
      prompt: 'hello',
      model: 'claude-opus-5',
      effort: 'xhigh',
    })
    expect(parseTurnControl(JSON.stringify({ kind: 'interrupt', turnId: 't1' }))).toEqual({
      kind: 'interrupt',
      turnId: 't1',
    })
  })

  test('a control request the agent host does not understand is refused, not guessed at', () => {
    expect(parseTurnControl('not json')).toBeNull()
    expect(parseTurnControl(JSON.stringify({ kind: 'run-turn' }))).toBeNull()
    expect(parseTurnControl(JSON.stringify({ kind: 'exec', command: 'rm -rf /' }))).toBeNull()
  })
})
