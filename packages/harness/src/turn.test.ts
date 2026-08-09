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

  test('this module reaches one leaf, so a Turn cannot close an import ring', () => {
    /*
      ./bridge.ts imports this file and ./credentials.ts imports ./bridge.ts, so
      a Turn reaching back for the credential module would make a cycle that
      works only because nothing in it is read at load. Asserted rather than
      remembered, because the tempting import is a one-liner.

      It used to be none at all, and one is now admissible on a condition this
      test is what enforces: the thing imported must itself import nothing, so
      it cannot be the first step of a ring. ./preview.ts is that module — the
      closed list of outcomes a `preview-answer` may carry, beside the sentences
      written for them — and the second assertion is the whole of what makes the
      first one safe.
    */
    const runtimeImportsIn = (module: string) => {
      const source = readFileSync(new URL(`./${module}`, import.meta.url), 'utf8')
      return [...source.matchAll(/^import (?!type )(?:.*? from )?'(.+?)'/gm)].map(
        (match) => match[1] as string,
      )
    }
    expect(runtimeImportsIn('turn.ts')).toEqual(['./preview.ts'])
    expect(runtimeImportsIn('preview.ts')).toHaveLength(0)
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
